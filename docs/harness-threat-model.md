# Agent harness threat model

Everything AfterRay's agent reads is text somebody else wrote — screen
captures, window titles, transcripts, documents that happened to be open. Some
of it will eventually contain a sentence engineered to be read as an
instruction. This document says what the agent can do when that happens, and,
for each limit, **what actually stops it**: the type system, a missing
dependency, a test, or nothing at all.

It exists so that whoever adds the thirteenth tool can tell which invariant
they are about to break.

## The adversary

Not the user. The user is trusted; it is their machine and their vault.

The adversary is **whoever authored text the machine captured**: a web page, a
Slack message, a filename, a code comment, a PDF. They cannot run code and
cannot see the vault. Their whole capability is that a string they control will
one day be pasted into a prompt.

A second, weaker adversary: **a remote model provider**, if the user configured
one. They see what is sent to them. They are trusted with that and nothing
more.

## What the agent can do

Twelve tools, all reads, all against the vault:

`get_now`, `get_day_summary`, `get_slot_card`, `list_activity`,
`search_evidence`, `list_memories`, `list_moments`, `get_moment`, `get_ocr`,
`get_ax_digest`, `get_ax_tree`, `get_transcript`.

Their whole argument vocabulary is `from_ms`, `to_ms`, `at_ms`, `day_ms`,
`moment_id`, `query`, `limit`. No path, URL, command, glob, or format string.

## What stops what

| The agent cannot… | …because | strength |
|---|---|---|
| write, delete or rewrite anything in the vault | tools hold `afterray_store::ReadOnlyVault`; no mutating method exists on the handle | **type system** |
| read or write files | `tools::jail` fails the build on `std::fs`, `File::open`, `tokio::fs` in a tool surface | review lint |
| spawn a process | same check, on `std::process` / `Command::new` | review lint |
| open a socket or make an HTTP request | same check, on `std::net`, `TcpStream::connect`, `reqwest`, `tokio::net` | review lint |
| speak HTTP from inside the harness | `afterray-harness` links no HTTP client: its dependencies are `serde`, `serde_json` and `tokio` (`macros`+`sync`+`time`). A raw socket needs no dependency, so this bounds HTTP only | dependency list |
| name a tool that does not exist | `tools::catalog_drift` holds the catalogue and every system prompt to the dispatch table | test |
| send an embedding query to a remote endpoint | `LlmRouterAdapter` declares `ModelCapability::Llm` and the queue routes by capability; embeddings go to the local worker | **type + routing**, with a test |
| escape the data fence | tool results are wrapped in `<<<AFTERRAY_DATA kind=tool_result>>>` and the closer is stripped from the body | code + test |
| loop forever, or fill the window | `ContextBudget` caps rounds and per-result tokens, asserted coherent at compile time | code |
| keep running after the user stops it | `ChatAbort` fires a `CancelToken` checked at three points, and kills the queue job | code + test |

Only two entries are structural — the read-only handle, which is a type, and
the absent HTTP client, which is a dependency fact. Everything marked **review
lint** is a string search over the tool sources. It is bypassable by aliasing,
by moving code into a helper the scan does not cover, or by going through a
capability the tools already hold. Calling it confinement would be wrong; its
job is to make acquiring those powers impossible to do *silently*.

The largest capability the tools legitimately hold is `&ModelQueue`, needed for
the embedding behind `search_evidence`. It is narrower than it looks — the
queue routes by capability and the only network-capable adapter declares itself
LLM-only — but it is a broader handle than the tools need, and narrowing it to
an embedding port is listed under the remaining work in
[harness-implementation-notes.md](harness-implementation-notes.md).

## Prompt injection: what the fence does and does not do

Every piece of captured text reaches the model wrapped:

```
<<<AFTERRAY_DATA kind=tool_result>>>
…the screen text…
<<<END_AFTERRAY_DATA>>>
```

The closer is stripped from the body first, so captured text cannot end the
fence early and have the rest read as instructions. That is tested.

**What the fence buys:** the model is told, structurally and every time, which
bytes are data. Combined with the system prompt's instruction to ignore
directives inside those blocks, it makes the naive attack — "ignore previous
instructions and…" — much less likely to land.

**What the fence does not buy:** it is not a sandbox. It is a hint to a
probabilistic system, and a sufficiently clever payload against a sufficiently
weak model will get through it. The fence is why injection is unlikely to
succeed; the read-only tool surface is why it does not matter very much when it
does. A model that is fully suborned can still only call the twelve read tools
above, with those seven argument names, against the user's own vault.

**The worst an injection achieves today:** it makes the agent look at
different evidence than the user asked about, and say something wrong or
misleading in the answer. It cannot modify the vault, reach the filesystem, or
run anything.

## Local versus remote providers

This is the sharpest difference in the whole document.

**Local provider** (builtin llama.cpp, MLX, or Ollama on `127.0.0.1`): nothing
the agent touches leaves the machine. Prompts, screen text, reasoning and
answers stay in the process and the vault.

**Remote provider** (an OpenAI-compatible endpoint): **the prompt is the
egress.** Every round sends the system prompt, the folded conversation history
and every tool result — which is to say, the OCR'd contents of the user's
screen — to that endpoint. This is not a leak; it is what configuring a remote
model means. But it should be said plainly, because it dwarfs every other
channel discussed here.

The fence does not change this. Marking bytes as data governs how the model
*interprets* them; it has no bearing on whether they are *transmitted*.

### `search_evidence` is not a second channel

It was worth checking, because it is the one tool whose argument is a free
string the agent chooses: an injection could plausibly have the agent read a
secret with `get_ocr` and then encode it into a search query.

It does not reach the network. `ModelInput::Embedding` is routed by capability,
`LlmRouterAdapter` — the only adapter that can make an HTTP request — declares
`ModelCapability::Llm`, and the queue hands embedding work to the local
`llama-embedding` worker. There is no setting that points embeddings at a
remote endpoint. A test asserts the router refuses an embedding job.

So the channel does not exist. And even if it did, it would be strictly
narrower than the prompt itself, which already carries the same screen text to
the same provider by design.

## Accepted residual risks

1. **A remote provider sees the user's screen text.** Inherent to the feature.
   Mitigated only by choice of provider; a local model avoids it entirely.
2. **The fence is probabilistic.** A strong enough injection against a weak
   enough model can redirect what the agent looks at, and therefore what it
   says. Bounded by the read-only tool surface.
3. **The `jail` check is a review lint, not confinement.** Someone can add
   `std::fs` to a tool and edit the list in the same commit, alias the import,
   or move the code into a module the scan does not read. That is intentional
   — the goal is that it cannot happen *silently* — but it should not be
   mistaken for a sandbox.
4. **`ToolSurface` is an open trait.** It has to be: the daemon implements it
   outside the harness, where the vault lives. A third implementation that
   writes files would compile. Rust has no capability-based module system —
   `std::fs` is in scope in every crate, and no newtype, sealed trait or
   dependency list removes it. This is the reason risk 3 is held by a test
   rather than by the compiler.
5. **Reasoning is stored.** A thinking model's scratch work can quote screen
   text, so `conversation_messages.reasoning` holds captured content. It is in
   the same encrypted vault as everything else and capped per turn, but it is
   one more copy.

## If you are adding a tool

- It reads the vault through `ReadOnlyVault`. If you need a write, you are not
  adding a tool.
- Its arguments are ids, timestamps and limits. If you want to pass a path or a
  URL, stop.
- Add it to the `match` in `ToolHost::invoke` and to `tool_catalog_text`;
  `catalog_drift` fails the build if you do one and not the other.
- Do not name it in a system prompt. Ordering advice belongs in the catalogue.
- If it genuinely needs the filesystem or the network, `jail` will fail. Change
  this document first, then the allowlist, and say why in both.

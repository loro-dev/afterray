//! Working out how much context a provider will actually give us.
//!
//! Three numbers, and they are routinely different:
//!
//! 1. **What the architecture allows.** Qwen3.5 says 262 144 at both 4B and 9B.
//! 2. **What this machine can afford.** The KV cache lives in memory, so Ollama
//!    picks a default from installed RAM: under 24 GiB it is 4 096.
//! 3. **What the loaded instance actually got.** Ollama may give less than
//!    asked, and `/api/ps` is the only place that says so.
//!
//! Budgeting against (1) is the trap. A prompt longer than the real window is
//! cut *before the model reads it*, with no error and no event — the front of
//! the conversation simply is not there. Everything the harness does to compact
//! carefully is undone by a server quietly deleting more.
//!
//! So: plan from (2), declare it per request so the server's own default cannot
//! surprise us, and if (3) comes back smaller, believe (3).

use crate::{LlmRuntimeConfig, catalog::mlx_pack_context_tokens};
use afterray_protocol::LlmProvider;
use serde_json::{Value, json};
use std::time::Duration;

/// Environment variables through which a user pins Ollama's context.
///
/// Read from *our* process, which only sees them when the server was started
/// from the same environment — commonly `ollama serve` in a terminal, not the
/// background service. When they are visible they are treated as a decision
/// already made; when they are not, `/api/ps` still reports the truth after the
/// model loads, so the pin is honoured either way, just later.
pub const CONTEXT_ENV_VARS: [&str; 2] = ["OLLAMA_CONTEXT_LENGTH", "OLLAMA_NUM_CTX"];

/// A user's explicit context pin, if this process can see one.
#[must_use]
pub fn pinned_context_tokens() -> Option<usize> {
    CONTEXT_ENV_VARS.iter().find_map(|name| {
        std::env::var(name)
            .ok()?
            .trim()
            .parse::<usize>()
            .ok()
            .filter(|tokens| *tokens > 0)
    })
}

/// The architectural limit from an `/api/show` body.
///
/// The key is prefixed with the architecture, which changes per model —
/// `qwen35.context_length` for the dense Qwen3.5 models, `qwen3_5_moe.…` for
/// the mixture-of-experts one. Measured on all three installed here, which is
/// why this matches on the suffix rather than assuming a prefix.
#[must_use]
pub fn architecture_context_length(show_body: &Value) -> Option<usize> {
    show_body
        .get("model_info")?
        .as_object()?
        .iter()
        .find(|(key, _)| key.ends_with(".context_length"))
        .and_then(|(_, value)| value.as_u64())
        .and_then(|value| usize::try_from(value).ok())
}

/// What a loaded instance was actually given, from an `/api/ps` body.
///
/// `None` when the model is not resident: nothing has been allocated yet, so
/// there is no truth to read.
#[must_use]
pub fn running_context_length(ps_body: &Value, model: &str) -> Option<usize> {
    ps_body
        .get("models")?
        .as_array()?
        .iter()
        .find(|entry| {
            entry.get("name").and_then(Value::as_str) == Some(model)
                || entry.get("model").and_then(Value::as_str) == Some(model)
        })?
        .get("context_length")?
        .as_u64()
        .and_then(|value| usize::try_from(value).ok())
}

/// The window to plan a turn against.
///
/// `afford` is what this machine's memory tier allows, `architecture` the
/// model's own ceiling, `running` what a resident instance actually got, and
/// `pinned` an explicit user setting.
///
/// A pin wins outright: someone who set it has already made this decision, and
/// silently exceeding it would allocate memory they declined to give. Otherwise
/// take the smallest real constraint — asking for more than any one of them
/// allows is how a prompt gets cut without anybody being told.
#[must_use]
pub fn resolve_context_tokens(
    afford: usize,
    architecture: Option<usize>,
    running: Option<usize>,
    pinned: Option<usize>,
) -> usize {
    if let Some(pinned) = pinned {
        // Still bounded by what actually loaded: a pin above what the server
        // could allocate is a wish, not a window.
        return running.map_or(pinned, |running| pinned.min(running));
    }
    let mut tokens = afford;
    if let Some(architecture) = architecture {
        tokens = tokens.min(architecture);
    }
    if let Some(running) = running {
        tokens = tokens.min(running);
    }
    tokens.max(MINIMUM_CONTEXT_TOKENS)
}

/// Below this a turn cannot hold a system prompt, a tool catalog and a
/// question, so there is nothing to be gained by honouring a smaller number.
pub const MINIMUM_CONTEXT_TOKENS: usize = 2_048;

/// What to assume of an OpenAI-compatible endpoint we cannot ask.
///
/// There is no portable way to read a hosted window, and this machine's memory
/// says nothing about someone else's server. The saving grace is that these
/// endpoints reject an over-long prompt with an error instead of quietly
/// dropping the front of it, so a wrong guess here is visible rather than
/// invisible — which is why this is allowed to be a guess at all.
pub const REMOTE_DEFAULT_CONTEXT_TOKENS: usize = 32_768;

/// Everything that went into a context decision, kept for the log line.
///
/// The inputs are worth reporting because they disagree so often: a user whose
/// window came out at 4 096 wants to know it was their 16 GB machine and not
/// their model.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContextProbe {
    /// What this machine's memory tier allows.
    pub afford: usize,
    /// The model's own ceiling, when the provider will say.
    pub architecture: Option<usize>,
    /// What a loaded instance actually got.
    pub running: Option<usize>,
    /// An explicit user pin, when this process can see one.
    pub pinned: Option<usize>,
    /// The window to plan and to declare.
    pub resolved: usize,
}

impl ContextProbe {
    /// One line for the daemon log: the answer and the reason for it.
    #[must_use]
    pub fn summary(&self) -> String {
        let describe = |value: Option<usize>| match value {
            Some(value) => value.to_string(),
            None => "-".to_owned(),
        };
        format!(
            "context {} (machine {}, architecture {}, running {}, pinned {})",
            self.resolved,
            self.afford,
            describe(self.architecture),
            describe(self.running),
            describe(self.pinned),
        )
    }
}

/// Ask the provider what window this turn actually has.
///
/// Runs before each turn rather than once at startup: `/api/ps` only tells the
/// truth after the model is resident, and a user can load, unload or re-pin
/// between turns. Two localhost round trips against a short timeout are cheap
/// next to the generation that follows, and a provider that does not answer
/// leaves the machine tier standing.
pub async fn probe_context_tokens(config: &LlmRuntimeConfig, afford: usize) -> ContextProbe {
    let mut probe = ContextProbe {
        afford,
        architecture: None,
        running: None,
        pinned: None,
        resolved: afford,
    };
    match config.provider {
        LlmProvider::MlxLocal => {
            probe.architecture = config.mlx_pack_id().and_then(mlx_pack_context_tokens);
        }
        LlmProvider::Ollama => {
            probe.pinned = pinned_context_tokens();
            let model = config.chat_model();
            let origin = config.resolved_base_url();
            if !model.is_empty() && !origin.is_empty() {
                if let Some(client) = probe_client() {
                    probe.architecture =
                        ollama_architecture_context(&client, &origin, model).await;
                    probe.running = ollama_running_context(&client, &origin, model).await;
                }
            }
        }
        LlmProvider::OpenaiCompatible => {
            // Not this machine's memory: someone else's server.
            probe.afford = REMOTE_DEFAULT_CONTEXT_TOKENS;
        }
    }
    probe.resolved = resolve_context_tokens(
        probe.afford,
        probe.architecture,
        probe.running,
        probe.pinned,
    );
    probe
}

/// `POST /api/show` — the model's architectural limit.
async fn ollama_architecture_context(
    client: &reqwest::Client,
    origin: &str,
    model: &str,
) -> Option<usize> {
    let body = json!({ "model": model });
    let value: Value = client
        .post(ollama_api_url(origin, "show"))
        .json(&body)
        .send()
        .await
        .ok()?
        .json()
        .await
        .ok()?;
    architecture_context_length(&value)
}

/// `GET /api/ps` — what the resident instance was given.
async fn ollama_running_context(
    client: &reqwest::Client,
    origin: &str,
    model: &str,
) -> Option<usize> {
    let value: Value = client
        .get(ollama_api_url(origin, "ps"))
        .send()
        .await
        .ok()?
        .json()
        .await
        .ok()?;
    running_context_length(&value, model)
}

/// The native Ollama API sits beside `/v1`, not under it.
fn ollama_api_url(origin: &str, path: &str) -> String {
    let origin = origin.trim_end_matches('/');
    let host = origin.strip_suffix("/v1").unwrap_or(origin);
    format!("{host}/api/{path}")
}

fn probe_client() -> Option<reqwest::Client> {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(1))
        .timeout(Duration::from_secs(3))
        // A redirect would carry this probe to a host the user never approved.
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The key is architecture-prefixed and the prefix changes per model.
    /// These three bodies are the shape returned by the models installed on
    /// the machine this was written against.
    #[test]
    fn the_architecture_limit_is_found_whatever_the_prefix() {
        for prefix in ["qwen35", "qwen3_5_moe", "llama", "something.new"] {
            let body = json!({
                "model_info": {
                    "general.architecture": prefix,
                    format!("{prefix}.context_length"): 262_144,
                    format!("{prefix}.embedding_length"): 2_560,
                }
            });
            assert_eq!(architecture_context_length(&body), Some(262_144), "{prefix}");
        }
        assert_eq!(architecture_context_length(&json!({})), None);
    }

    #[test]
    fn the_running_length_is_matched_by_either_name_field() {
        let body = json!({
            "models": [
                {"name": "other:1b", "context_length": 4_096},
                {"model": "qwen3.5:4b", "context_length": 262_144},
            ]
        });
        assert_eq!(running_context_length(&body, "qwen3.5:4b"), Some(262_144));
        assert_eq!(running_context_length(&body, "other:1b"), Some(4_096));
        assert_eq!(running_context_length(&body, "absent:7b"), None);
        // Nothing loaded: no truth to read, rather than a zero.
        assert_eq!(running_context_length(&json!({"models": []}), "x"), None);
    }

    /// The whole point: plan against the smallest real constraint. Asking for
    /// the architecture limit on a 16 GB machine is how a prompt gets cut
    /// before the model reads it.
    #[test]
    fn the_smallest_real_constraint_wins() {
        // A small machine against a huge model.
        assert_eq!(
            resolve_context_tokens(4_096, Some(262_144), None, None),
            4_096
        );
        // A large machine against a small model.
        assert_eq!(
            resolve_context_tokens(262_144, Some(8_192), None, None),
            8_192
        );
        // The server gave less than we could afford: believe the server.
        assert_eq!(
            resolve_context_tokens(262_144, Some(262_144), Some(32_768), None),
            32_768
        );
        // Nothing known but the machine.
        assert_eq!(resolve_context_tokens(32_768, None, None, None), 32_768);
    }

    /// A user who set the environment variable has already made this choice.
    #[test]
    fn an_explicit_pin_is_honoured_over_the_tier() {
        // Above what the tier would pick.
        assert_eq!(
            resolve_context_tokens(4_096, Some(262_144), None, Some(65_536)),
            65_536
        );
        // And below it.
        assert_eq!(
            resolve_context_tokens(262_144, Some(262_144), None, Some(8_192)),
            8_192
        );
        // But a pin the server could not satisfy is still bounded by reality.
        assert_eq!(
            resolve_context_tokens(262_144, Some(262_144), Some(16_384), Some(65_536)),
            16_384
        );
    }

    #[test]
    fn a_pathologically_small_answer_is_floored() {
        assert_eq!(
            resolve_context_tokens(512, Some(512), Some(512), None),
            MINIMUM_CONTEXT_TOKENS
        );
    }
}

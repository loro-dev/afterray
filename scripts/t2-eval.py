#!/usr/bin/env python3
"""T2 card eval harness. See docs/t1-t2-card-quality-plan.md.

Talks to the running afterrayd over its unix socket (newline-delimited JSON),
runs `slot_summarize` for a set of real slots under one or more Ollama models,
and computes deterministic quality metrics. The daemon persists every card it
summarises, so `run` snapshots the day payloads first.

Usage:
  python3 scripts/t2-eval.py run --tag baseline \
      --models qwen3.5:4b qwen3.8:27b-mlx
  python3 scripts/t2-eval.py report --tags baseline after
"""

import argparse
import datetime
import itertools
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import time
import unicodedata

REPO = pathlib.Path(__file__).resolve().parent.parent
SOCKET_PATH = os.environ.get("AFTERRAY_SOCKET", str(REPO / ".afterray-dev/afterray.sock"))
OUT_DIR = REPO / "docs/evals/t2-cards"

DAY_MS = 24 * 60 * 60 * 1000


class DaemonDied(RuntimeError):
    """The daemon closed the connection without answering (crash/restart)."""


def rpc(request: dict, timeout: float = 900.0) -> dict:
    """One request line out, one response line back."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCKET_PATH)
    sock.settimeout(timeout)
    sock.sendall((json.dumps(request) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = sock.recv(1 << 16)
        if not chunk:
            break
        buf += chunk
    sock.close()
    if not buf.strip():
        raise DaemonDied(f"no response to {request.get('type')}")
    return json.loads(buf)


def now_ms() -> int:
    return int(time.time() * 1000)


def hhmm(ms: int) -> str:
    return datetime.datetime.fromtimestamp(ms / 1000).strftime("%m-%d %H:%M")


# ---------------------------------------------------------------- selection


def eligible_slots(max_slots: int) -> list[dict]:
    """Occupied slots from today and yesterday with enough captured material."""
    slots = []
    for day_offset in (1, 0):
        day = rpc({"type": "day_summary", "day_ms": now_ms() - day_offset * DAY_MS})
        payload = day.get("data") or {}
        for slot in payload.get("slots", []):
            if slot["state"] not in ("done", "degraded", "failed"):
                continue
            if slot["facts"]["moment_count"] < 20:
                continue
            slots.append(slot)
    slots.sort(key=lambda s: s["slot_start_ms"])
    return slots[-max_slots:]


# ---------------------------------------------------------------- metrics

BACKTICK = re.compile(r"`([^`]+)`")
IDENTIFIER = re.compile(
    r"[\w.-]*\d[\w.-]*:[\w.-]+"          # model tags: qwen3.5:4b
    r"|[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+"  # paths, repos, branches
    r"|https?://\S+"                       # urls
    r"|\b[A-Za-z]+\d+(?:\.\d+)+[A-Za-z0-9-]*\b"  # versioned names: Qwen3.5
    r"|\bv?\d+\.\d+(?:\.\d+)+\b"           # bare versions with >= 2 dots
)
STOP_IDENTIFIERS = {"localhost", "127.0.0.1"}


def normalise(text: str) -> str:
    folded = unicodedata.normalize("NFKC", text).casefold()
    return re.sub(r"\s+", "", folded)


def card_text(card: dict) -> str:
    parts = [card.get("title") or ""]
    parts += card.get("bullets") or []
    for thread in card.get("threads") or []:
        parts.append(thread.get("name") or "")
        parts.append(thread.get("prose") or "")
    for entity in card.get("entities") or []:
        parts.append(entity.get("text") or "")
    parts += card.get("decisions") or []
    return "\n".join(parts)


def extract_identifiers(text: str) -> list[str]:
    found = set(BACKTICK.findall(text))
    found.update(match.group(0) for match in IDENTIFIER.finditer(text))
    cleaned = set()
    for token in found:
        token = token.strip().strip(".,;:!?)('\"”“」。，")
        if len(token) < 4 or token in STOP_IDENTIFIERS:
            continue
        if re.fullmatch(r"\d+(\.\d+)*", token):
            continue  # bare numbers: durations, percentages
        cleaned.add(token)
    return sorted(cleaned)


def fidelity(card: dict, evidence: str) -> dict:
    """Which identifier-like tokens in the card exist verbatim in the input."""
    haystack = normalise(evidence)
    grounded, fabricated = [], []
    for token in extract_identifiers(card_text(card)):
        if normalise(token) in haystack:
            grounded.append(token)
        else:
            fabricated.append(token)
    total = len(grounded) + len(fabricated)
    return {
        "identifiers": total,
        "grounded": grounded,
        "fabricated": fabricated,
        "fidelity": round(len(grounded) / total, 3) if total else None,
    }


def han_ratio(text: str) -> float:
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return 0.0
    han = sum(1 for c in letters if "一" <= c <= "鿿")
    return round(han / len(letters), 3)


def char_bigrams(text: str) -> set:
    folded = normalise(text)
    return {folded[i : i + 2] for i in range(len(folded) - 1)}


def title_distinctiveness(titles: list[str]) -> float | None:
    """Mean pairwise Jaccard of adjacent titles. Lower = more distinct."""
    pairs = [(a, b) for a, b in zip(titles, titles[1:]) if a and b]
    if not pairs:
        return None
    scores = []
    for a, b in pairs:
        ga, gb = char_bigrams(a), char_bigrams(b)
        if not ga or not gb:
            continue
        scores.append(len(ga & gb) / len(ga | gb))
    return round(sum(scores) / len(scores), 3) if scores else None


# ---------------------------------------------------------------- commands


def set_model(model: str) -> None:
    response = rpc({"type": "update_settings", "llm_provider": "ollama", "llm_model": model})
    if not response.get("ok"):
        raise SystemExit(f"update_settings failed: {response.get('error')}")
    settings = rpc({"type": "settings"})
    got = (settings.get("data") or {}).get("llm_model")
    if got != model:
        raise SystemExit(f"model did not apply: wanted {model}, daemon reports {got}")


def cmd_run(args: argparse.Namespace) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")

    # The daemon persists each summarised card; keep what is there now.
    snapshot = {
        "taken_at": stamp,
        "days": [
            rpc({"type": "day_summary", "day_ms": now_ms() - offset * DAY_MS}).get("data")
            for offset in (1, 0)
        ],
    }
    snap_path = OUT_DIR / f"snapshot-{args.tag}-{stamp}.json"
    snap_path.write_text(json.dumps(snapshot, ensure_ascii=False, indent=1))
    print(f"snapshot -> {snap_path.relative_to(REPO)}")

    slots = eligible_slots(10_000 if args.slots else args.max_slots)
    if args.slots:
        wanted = set(args.slots)
        slots = [s for s in slots if s["slot_start_ms"] in wanted]
    if not slots:
        raise SystemExit("no eligible slots")
    print(f"slots: {[hhmm(s['slot_start_ms']) for s in slots]}")

    results = {"tag": args.tag, "stamp": stamp, "models": {}, "slot_ids": [s["slot_start_ms"] for s in slots]}
    for model in args.models:
        print(f"\n=== {model} ===")
        set_model(model)
        rows = []
        for slot in slots:
            at_ms = slot["slot_start_ms"]
            started = time.time()
            try:
                prompt = rpc({"type": "slot_prompt", "at_ms": at_ms}).get("data") or {}
                user_text = prompt.get("user") or ""
                response = rpc({"type": "slot_summarize", "at_ms": at_ms})
            except DaemonDied as died:
                # The daemon crashed on this slot (a baseline finding in its
                # own right). Record it, wait for the supervisor restart,
                # and keep going.
                rows.append({
                    "slot_start_ms": at_ms,
                    "label": hhmm(at_ms),
                    "ok": False,
                    "error": f"daemon died: {died}",
                    "wall_ms": int((time.time() - started) * 1000),
                    "latency_ms": None,
                    "prompt_chars": 0,
                    "metrics": None,
                })
                print(f"  {hhmm(at_ms)}  DAEMON DIED — waiting for restart")
                for _ in range(60):
                    time.sleep(2)
                    try:
                        if rpc({"type": "ping"}, timeout=5).get("ok"):
                            break
                    except (OSError, DaemonDied, json.JSONDecodeError):
                        continue
                set_model(model)  # restart may have reloaded stale settings
                continue
            wall_ms = int((time.time() - started) * 1000)
            data = response.get("data") or {}
            card = data.get("card") or {}
            row = {
                "slot_start_ms": at_ms,
                "label": hhmm(at_ms),
                "ok": bool(response.get("ok")),
                "error": response.get("error"),
                "wall_ms": wall_ms,
                "latency_ms": data.get("latency_ms"),
                "prompt_chars": len(user_text),
                "prompt_user": user_text,
                "response": data,
                "metrics": None,
            }
            if card:
                # Grounding evidence is everything the model saw: the prompt
                # plus whatever its tools returned during the turn.
                evidence = "\n".join([user_text, *(data.get("tool_results") or [])])
                row["metrics"] = {
                    **fidelity(card, evidence),
                    "han_ratio": han_ratio(card_text(card)),
                    "title": card.get("title"),
                    "tool_rounds": len(data.get("tool_calls") or []),
                    "entities_dropped_by_daemon": len(
                        ((data.get("verification") or {}).get("entities_dropped")) or []
                    ),
                }
            rows.append(row)
            status = "ok" if row["ok"] else f"FAIL {row['error']}"
            fab = (row["metrics"] or {}).get("fabricated")
            print(f"  {row['label']}  {status}  {wall_ms}ms  fabricated={fab}")
        results["models"][model] = rows

    out_path = OUT_DIR / f"{args.tag}-{stamp}.json"
    out_path.write_text(json.dumps(results, ensure_ascii=False, indent=1))
    print(f"\nresults -> {out_path.relative_to(REPO)}")
    summarise([out_path])


def latest_for_tag(tag: str) -> pathlib.Path:
    candidates = sorted(OUT_DIR.glob(f"{tag}-*.json"))
    candidates = [c for c in candidates if not c.name.startswith("snapshot-")]
    if not candidates:
        raise SystemExit(f"no results for tag `{tag}`")
    return candidates[-1]


def summarise(paths: list[pathlib.Path]) -> None:
    print("\n| run | model | slots ok | fidelity | fabricated | title jaccard | han | prompt chars | latency s |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for path in paths:
        data = json.loads(path.read_text())
        for model, rows in data["models"].items():
            ok_rows = [r for r in rows if r["ok"] and r["metrics"]]
            fabricated = list(
                itertools.chain.from_iterable((r["metrics"]["fabricated"]) for r in ok_rows)
            )
            fidelities = [r["metrics"]["fidelity"] for r in ok_rows if r["metrics"]["fidelity"] is not None]
            titles = [r["metrics"]["title"] or "" for r in ok_rows]
            hans = [r["metrics"]["han_ratio"] for r in ok_rows]
            prompts = [r["prompt_chars"] for r in rows]
            latencies = [r["latency_ms"] or r["wall_ms"] for r in ok_rows]
            print(
                f"| {data['tag']} | {model} "
                f"| {len(ok_rows)}/{len(rows)} "
                f"| {round(sum(fidelities)/len(fidelities), 3) if fidelities else '-'} "
                f"| {len(fabricated)} "
                f"| {title_distinctiveness(titles) or '-'} "
                f"| {round(sum(hans)/len(hans), 2) if hans else '-'} "
                f"| {round(sum(prompts)/len(prompts)) if prompts else '-'} "
                f"| {round(sum(latencies)/len(latencies)/1000, 1) if latencies else '-'} |"
            )


def cmd_report(args: argparse.Namespace) -> None:
    summarise([latest_for_tag(tag) for tag in args.tags])


# ------------------------------------------------------- worktree baseline

WORKTREE = REPO / ".scratch/baseline-2c202fa"
DATA_DIR = REPO / ".afterray/v0-data"


def worktree_prompts(slot_ids: list[int]) -> dict[int, dict]:
    """Baseline card+prompt for every wanted slot, in ONE `slot_cards`
    process. One process means at most one keychain consent dialog; the
    per-slot version re-prompted on every spawn when the user granted
    "Allow" rather than "Always Allow"."""
    newest = max(slot_ids)
    reach = max((newest - min(slot_ids)) // (30 * 60 * 1000) + 2, len(slot_ids))
    out = subprocess.run(
        [
            str(WORKTREE / "target/debug/examples/slot_cards"),
            "--data-dir", str(DATA_DIR),
            "--at-ms", str(newest),
            "--slots", str(reach),
            "--json",
            "--language", "English",
        ],
        cwd=WORKTREE,
        capture_output=True,
        text=True,
        timeout=900,
    )
    wanted = set(slot_ids)
    records = {}
    for line in out.stdout.splitlines():
        if not line.startswith("{"):
            continue
        record = json.loads(line)
        start = ((record.get("card") or {}).get("slot_start_ms"))
        if start in wanted:
            records[start] = record
    missing = wanted - set(records)
    if missing:
        raise RuntimeError(
            f"slot_cards missed slots {sorted(missing)}: {out.stderr[-400:]}"
        )
    return records


def ollama_generate(model: str, system: str, user: str) -> tuple[str, int]:
    """One chat completion against local Ollama — the same OpenAI-compatible
    endpoint the daemon's router uses."""
    import urllib.request

    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
    }).encode()
    request = urllib.request.Request(
        "http://127.0.0.1:11434/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    started = time.time()
    with urllib.request.urlopen(request, timeout=1800) as response:
        payload = json.load(response)
    wall_ms = int((time.time() - started) * 1000)
    text = payload["choices"][0]["message"]["content"] or ""
    return text, wall_ms


def extract_json_block(raw: str) -> dict | None:
    start = raw.find("{")
    while start != -1:
        depth, in_string, escaped = 0, False, False
        for index in range(start, len(raw)):
            ch = raw[index]
            if in_string:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == '"':
                    in_string = False
                continue
            if ch == '"':
                in_string = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    try:
                        parsed = json.loads(raw[start : index + 1])
                        if isinstance(parsed, dict):
                            return parsed
                    except json.JSONDecodeError:
                        break
                    break
        start = raw.find("{", start + 1)
    return None


def cmd_run_worktree(args: argparse.Namespace) -> None:
    """Baseline: pinned pipeline renders the prompt, Ollama answers, the
    daemon is never involved and nothing is persisted."""
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    results = {"tag": args.tag, "stamp": stamp, "models": {}, "slot_ids": args.slots}
    prompts = worktree_prompts(args.slots)
    for at_ms in args.slots:
        print(f"prompt {hhmm(at_ms)}: {len(prompts[at_ms]['user'])} chars")
    for model in args.models:
        print(f"\n=== {model} ===")
        rows = []
        for at_ms in args.slots:
            record = prompts[at_ms]
            try:
                raw, wall_ms = ollama_generate(model, record["system"], record["user"])
            except Exception as error:  # noqa: BLE001 — record and continue
                rows.append({
                    "slot_start_ms": at_ms, "label": hhmm(at_ms), "ok": False,
                    "error": str(error), "wall_ms": None, "latency_ms": None,
                    "prompt_chars": len(record["user"]), "metrics": None,
                })
                print(f"  {hhmm(at_ms)}  FAIL {error}")
                continue
            card = extract_json_block(raw)
            ok = bool(card and (card.get("title") or "").strip())
            row = {
                "slot_start_ms": at_ms,
                "label": hhmm(at_ms),
                "ok": ok,
                "error": None if ok else "no parseable card",
                "wall_ms": wall_ms,
                "latency_ms": wall_ms,
                "prompt_chars": len(record["user"]),
                "prompt_user": record["user"],
                "response": {"card": card, "raw": raw},
                "metrics": None,
            }
            if card:
                row["metrics"] = {
                    **fidelity(card, record["user"]),
                    "han_ratio": han_ratio(card_text(card)),
                    "title": card.get("title"),
                    "tool_rounds": 0,
                }
            fab = (row["metrics"] or {}).get("fabricated")
            print(f"  {hhmm(at_ms)}  {'ok' if ok else 'PARSE FAIL'}  {wall_ms}ms  fabricated={fab}")
            rows.append(row)
        results["models"][model] = rows
    out_path = OUT_DIR / f"{args.tag}-{stamp}.json"
    out_path.write_text(json.dumps(results, ensure_ascii=False, indent=1))
    print(f"\nresults -> {out_path.relative_to(REPO)}")
    summarise([out_path])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="summarise slots under each model and score the cards")
    run.add_argument("--tag", required=True, help="baseline / after / …")
    run.add_argument("--models", nargs="+", required=True)
    run.add_argument("--max-slots", type=int, default=8)
    run.add_argument("--slots", nargs="*", type=int, help="explicit slot_start_ms filter")
    run.set_defaults(func=cmd_run)

    report = sub.add_parser("report", help="print the comparison table for saved runs")
    report.add_argument("--tags", nargs="+", required=True)
    report.set_defaults(func=cmd_report)

    worktree = sub.add_parser(
        "run-worktree",
        help="baseline via the pinned worktree examples + direct Ollama (no daemon)",
    )
    worktree.add_argument("--tag", default="baseline")
    worktree.add_argument("--models", nargs="+", required=True)
    worktree.add_argument("--slots", nargs="+", type=int, required=True)
    worktree.set_defaults(func=cmd_run_worktree)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

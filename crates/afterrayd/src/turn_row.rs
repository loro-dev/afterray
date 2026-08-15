//! The assistant row a turn writes into while it runs.
//!
//! The row is inserted the moment the stream opens and updated as output
//! arrives, rather than composed in memory and written at the end. That is
//! pi's shape (`agent-loop.ts` pushes the partial message into history at
//! `message_start` and updates it in place), and it is what makes an
//! interrupted turn keep what it produced: being stopped only stops the
//! updating, because the row was already there.
//!
//! Before this, a turn that did not reach `done` stored nothing. The app
//! papered over it with a local placeholder whose id no reload could ever
//! match, so switching conversations and coming back made the answer vanish.

use afterray_harness::{RoundReasoning, TurnUsage, truncate_head};
use afterray_protocol::{
    MESSAGE_STATUS_ABORTED, MESSAGE_STATUS_COMPLETE, MESSAGE_STATUS_STREAMING,
};
use afterray_store::{MessageUpdate, Vault};
use std::time::{Duration, Instant};

/// How often the row is rewritten while a turn streams.
///
/// A write per token would spend the turn in `SQLite`; a write only at the end is
/// the bug. At this cadence an abrupt kill — a crash, a logout — loses at most
/// this much of the answer, and a normal stop loses nothing because stopping
/// flushes.
const FLUSH_INTERVAL: Duration = Duration::from_millis(500);

/// What one turn's reasoning may occupy, in estimated tokens.
///
/// Reasoning is far bigger than the answer it justifies — 131 deltas for a
/// two-character reply, measured — and the vault is encrypted, so every stored
/// byte is paid for twice. This keeps the beginning, which is where a model
/// states what it is about to do; the tail is usually it convincing itself.
const REASONING_TOKEN_CAP: usize = 2_048;

/// A turn's assistant row, updated in place as the turn runs.
pub(crate) struct TurnRow<'a> {
    store: &'a Vault,
    id: String,
    answer: String,
    tool_log: Option<String>,
    reasoning: Vec<RoundReasoning>,
    usage: Option<TurnUsage>,
    last_flush: Instant,
    dirty: bool,
}

impl<'a> TurnRow<'a> {
    /// Inserts the empty row. From here on the turn has somewhere to land.
    pub(crate) fn open(
        store: &'a Vault,
        conversation_id: &str,
        now_ms: i64,
    ) -> Result<Self, String> {
        let id = store
            .append_message(
                conversation_id,
                "assistant",
                "",
                None,
                now_ms,
            )
            .map_err(|error| error.to_string())?;
        let row = Self {
            store,
            id,
            answer: String::new(),
            tool_log: None,
            reasoning: Vec::new(),
            usage: None,
            last_flush: Instant::now(),
            dirty: false,
        };
        row.write(MESSAGE_STATUS_STREAMING)?;
        Ok(row)
    }

    pub(crate) fn id(&self) -> &str {
        &self.id
    }

    pub(crate) fn push_token(&mut self, text: &str) {
        self.answer.push_str(text);
        self.dirty = true;
    }

    pub(crate) fn set_tool_log(&mut self, log: Option<String>) {
        self.tool_log = log;
        self.dirty = true;
    }

    pub(crate) fn push_reasoning(&mut self, round: usize, text: &str) {
        match self
            .reasoning
            .iter_mut()
            .find(|entry| entry.round == round)
        {
            Some(entry) => entry.text.push_str(text),
            None => self.reasoning.push(RoundReasoning {
                round,
                text: text.to_owned(),
                signature: None,
            }),
        }
        self.dirty = true;
    }

    pub(crate) fn set_usage(&mut self, usage: TurnUsage) {
        self.usage = Some(usage);
        self.dirty = true;
    }

    /// Writes if enough has changed and enough time has passed.
    pub(crate) fn flush_if_due(&mut self) {
        if !self.dirty || self.last_flush.elapsed() < FLUSH_INTERVAL {
            return;
        }
        if let Err(error) = self.write(MESSAGE_STATUS_STREAMING) {
            eprintln!("chat.row flush failed: {error}");
        }
        self.last_flush = Instant::now();
        self.dirty = false;
    }

    /// Final write. `aborted` when the turn was stopped part-way.
    pub(crate) fn close(&self, aborted: bool) -> Result<(), String> {
        self.write(if aborted {
            MESSAGE_STATUS_ABORTED
        } else {
            MESSAGE_STATUS_COMPLETE
        })
    }

    fn write(&self, status: &str) -> Result<(), String> {
        let reasoning = self.reasoning_json();
        let usage = self.usage.map(|usage| {
            serde_json::json!({
                "prompt_tokens": usage.prompt_tokens,
                "window_tokens": usage.window_tokens,
                "round": usage.rounds,
            })
            .to_string()
        });
        self.store
            .update_message(
                &self.id,
                &MessageUpdate {
                    content: &self.answer,
                    tool_log: self.tool_log.as_deref(),
                    reasoning: reasoning.as_deref(),
                    status: Some(status),
                    usage_json: usage.as_deref(),
                },
            )
            .map_err(|error| error.to_string())
    }

    /// Reasoning as the JSON array the column holds, capped.
    ///
    /// The cap is applied per round so one long round cannot crowd out the
    /// others, and `truncate_head` marks what it cut, so a reader never mistakes
    /// a shortened reasoning block for the whole of it.
    fn reasoning_json(&self) -> Option<String> {
        if self.reasoning.is_empty() {
            return None;
        }
        let per_round = REASONING_TOKEN_CAP / self.reasoning.len().max(1);
        let capped: Vec<RoundReasoning> = self
            .reasoning
            .iter()
            .map(|entry| RoundReasoning {
                round: entry.round,
                text: truncate_head(&entry.text, per_round).text,
                signature: entry.signature.clone(),
            })
            .collect();
        serde_json::to_string(&capped).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use afterray_store::VaultConfig;

    fn vault() -> (tempfile::TempDir, Vault) {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                ..VaultConfig::default()
            },
            [5_u8; 32],
        )
        .unwrap();
        (directory, vault)
    }

    /// The whole point: a turn that never finishes still leaves what it had.
    #[test]
    fn an_abandoned_row_keeps_what_it_had() {
        let (_dir, vault) = vault();
        let conversation = vault.create_conversation("t", 1).unwrap();
        let mut row = TurnRow::open(&vault, &conversation, 2).unwrap();
        row.push_token("half an ans");
        row.push_reasoning(1, "because");
        row.close(true).unwrap();

        let stored = vault.conversation_messages(&conversation).unwrap();
        let assistant = stored.iter().find(|m| m.role == "assistant").unwrap();
        assert_eq!(assistant.content, "half an ans");
        assert_eq!(assistant.status.as_deref(), Some(MESSAGE_STATUS_ABORTED));
        assert!(assistant.reasoning.as_deref().unwrap().contains("because"));
    }

    /// The row exists from the moment the stream opens, so a client can name it
    /// before any output arrives.
    #[test]
    fn the_row_exists_before_any_output() {
        let (_dir, vault) = vault();
        let conversation = vault.create_conversation("t", 1).unwrap();
        let row = TurnRow::open(&vault, &conversation, 2).unwrap();

        let stored = vault.conversation_messages(&conversation).unwrap();
        let assistant = stored.iter().find(|m| m.id == row.id()).unwrap();
        assert_eq!(assistant.content, "");
        assert_eq!(assistant.status.as_deref(), Some(MESSAGE_STATUS_STREAMING));
    }

    #[test]
    fn a_finished_row_is_marked_complete_and_carries_its_usage() {
        let (_dir, vault) = vault();
        let conversation = vault.create_conversation("t", 1).unwrap();
        let mut row = TurnRow::open(&vault, &conversation, 2).unwrap();
        row.push_token("done");
        row.set_usage(TurnUsage {
            prompt_tokens: 4_000,
            window_tokens: 16_384,
            rounds: 2,
        });
        row.close(false).unwrap();

        let stored = vault.conversation_messages(&conversation).unwrap();
        let assistant = stored.iter().find(|m| m.role == "assistant").unwrap();
        assert_eq!(assistant.status.as_deref(), Some(MESSAGE_STATUS_COMPLETE));
        let usage = assistant.usage_json.as_deref().unwrap();
        assert!(usage.contains("4000"), "{usage}");
        assert!(usage.contains("16384"), "{usage}");
    }

    /// Reasoning is much bigger than the answer it justifies, and the vault is
    /// encrypted. The cap has to bite, and has to say that it did.
    #[test]
    fn oversized_reasoning_is_capped_and_says_so() {
        let (_dir, vault) = vault();
        let conversation = vault.create_conversation("t", 1).unwrap();
        let mut row = TurnRow::open(&vault, &conversation, 2).unwrap();
        for round in 1..=3 {
            row.push_reasoning(round, &"thinking out loud. ".repeat(4_000));
        }
        row.close(false).unwrap();

        let stored = vault.conversation_messages(&conversation).unwrap();
        let assistant = stored.iter().find(|m| m.role == "assistant").unwrap();
        let reasoning = assistant.reasoning.as_deref().unwrap();
        let rounds: Vec<RoundReasoning> = serde_json::from_str(reasoning).unwrap();
        assert_eq!(rounds.len(), 3, "every round survives the cap");
        assert!(
            rounds.iter().all(|entry| entry.text.contains("were cut to fit")),
            "the cut has to be visible"
        );
        assert!(
            reasoning.len() < 40_000,
            "still {} bytes after capping",
            reasoning.len()
        );
    }

    /// Rounds stay apart, because the one API that wants reasoning back wants
    /// it verbatim per message.
    #[test]
    fn reasoning_keeps_its_rounds_apart() {
        let (_dir, vault) = vault();
        let conversation = vault.create_conversation("t", 1).unwrap();
        let mut row = TurnRow::open(&vault, &conversation, 2).unwrap();
        row.push_reasoning(1, "first ");
        row.push_reasoning(1, "round");
        row.push_reasoning(2, "second round");
        row.close(false).unwrap();

        let stored = vault.conversation_messages(&conversation).unwrap();
        let assistant = stored.iter().find(|m| m.role == "assistant").unwrap();
        let rounds: Vec<RoundReasoning> =
            serde_json::from_str(assistant.reasoning.as_deref().unwrap()).unwrap();
        assert_eq!(rounds.len(), 2);
        assert_eq!(rounds[0].text, "first round");
        assert_eq!(rounds[1].round, 2);
    }
}

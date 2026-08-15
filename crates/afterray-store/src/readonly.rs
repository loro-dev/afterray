//! A vault handle that can only read.
//!
//! The agent's tools are all read-only, and until now that was a property of
//! how they happened to be written: they held a `&Vault`, and every mutating
//! method on it was one keystroke away. A new tool could insert, delete or
//! rewrite anything in the vault and nothing but review would notice.
//!
//! This is the same set of tools with the writes removed from the type. A tool
//! that holds a [`ReadOnlyVault`] cannot call `append_message`, `insert_moment`,
//! `delete_conversation` or `clear_history`, because those names do not exist
//! on it. Adding a writing tool now means either widening this file — which is
//! a visible, reviewable act — or reaching around it for the `&Vault`, which
//! `tools::jail` fails the build over.
//!
//! **What this does not cover.** Rust has no capability-based module system:
//! `std::fs`, `std::process` and `std::net` are in scope everywhere, in every
//! crate, and no dependency list or newtype can take them away. The vault is
//! the one axis a type can close, so it is closed here; the rest is held by the
//! source check in `afterrayd::tools::jail` and written down in
//! `docs/harness-threat-model.md`.

use crate::{
    ActivitySpan, Memory, Moment, MomentAt, SearchHit, StoreError, TranscriptLine, Vault,
    infoscore, slot,
};

/// Read-only view of a [`Vault`], for the agent's tools.
///
/// Every method forwards unchanged. The value is in what is absent.
#[derive(Clone, Copy)]
pub struct ReadOnlyVault<'a> {
    inner: &'a Vault,
}

impl<'a> ReadOnlyVault<'a> {
    /// Narrows a vault to its reads.
    ///
    /// The one place a write capability becomes a read capability, so it is the
    /// one place to look when asking how a tool got its handle.
    #[must_use]
    pub fn new(inner: &'a Vault) -> Self {
        Self { inner }
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn moment_time_bounds(&self) -> Result<Option<(i64, i64)>, StoreError> {
        self.inner.moment_time_bounds()
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn activity_spans(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: usize,
    ) -> Result<Vec<ActivitySpan>, StoreError> {
        self.inner.activity_spans(from_ms, to_ms, limit)
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn memories(&self, from_ms: i64, to_ms: i64, limit: usize) -> Result<Vec<Memory>, StoreError> {
        self.inner.memories(from_ms, to_ms, limit)
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn moment_ids_in_range(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: usize,
    ) -> Result<Vec<MomentAt>, StoreError> {
        self.inner.moment_ids_in_range(from_ms, to_ms, limit)
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn transcripts_in_range(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: usize,
    ) -> Result<Vec<TranscriptLine>, StoreError> {
        self.inner.transcripts_in_range(from_ms, to_ms, limit)
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn day_summary(
        &self,
        day_ms: i64,
        capture_interval_ms: i64,
    ) -> Result<slot::DaySummary, StoreError> {
        self.inner.day_summary(day_ms, capture_interval_ms)
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn slot_card(
        &self,
        at_ms: i64,
        capture_interval_ms: i64,
    ) -> Result<slot::SlotCard, StoreError> {
        self.inner.slot_card(at_ms, capture_interval_ms)
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn background_stats(
        &self,
        card: &slot::SlotCard,
    ) -> Result<infoscore::BackgroundStats, StoreError> {
        self.inner.background_stats(card)
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn moment_by_id(&self, moment_id: &str) -> Result<Option<Moment>, StoreError> {
        self.inner.moment_by_id(moment_id)
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn ocr_evidence_for_moment(
        &self,
        moment_id: &str,
    ) -> Result<Option<(String, Option<String>)>, StoreError> {
        self.inner.ocr_evidence_for_moment(moment_id)
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn accessibility_bytes_for_moment(
        &self,
        moment_id: &str,
    ) -> Result<Option<Vec<u8>>, StoreError> {
        self.inner.accessibility_bytes_for_moment(moment_id)
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn previous_slot_titles(
        &self,
        before_start_ms: i64,
        limit: usize,
    ) -> Result<Vec<slot::PrevCard>, StoreError> {
        self.inner.previous_slot_titles(before_start_ms, limit)
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>, StoreError> {
        self.inner.search(query, limit)
    }

    /// # Errors
    /// Propagates the underlying query failure.
    pub fn semantic_search(
        &self,
        query_vector: &[f32],
        model_version: &str,
        limit: usize,
    ) -> Result<Vec<SearchHit>, StoreError> {
        self.inner.semantic_search(query_vector, model_version, limit)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::VaultConfig;

    /// The guarantee, stated as a test even though the compiler is what
    /// enforces it: a tool holding this handle has no way to reach a write.
    ///
    /// If someone adds a mutating forward to `ReadOnlyVault`, this comment is
    /// the thing they have to argue with.
    #[test]
    fn a_read_only_handle_exposes_only_reads() {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                ..VaultConfig::default()
            },
            [8_u8; 32],
        )
        .unwrap();
        let readable = ReadOnlyVault::new(&vault);

        // Reads work.
        assert!(readable.moment_time_bounds().unwrap().is_none());
        assert!(readable.activity_spans(0, 1, 10).unwrap().is_empty());

        // Writes are not merely discouraged; the names are not on the type.
        // Uncommenting either line fails to compile:
        //
        //     readable.append_message("c", "user", "hi", None, 1);
        //     readable.insert_moment("s", 1, "image/jpeg", b"x");
        //
        // The source-level half of the jail lives in `afterrayd::tools::jail`.
        // Only the forwarding half of the file: the needles below would
        // otherwise match this very list. Each is split and rejoined so the
        // whole string exists in the source only where it is real code.
        let source = include_str!("readonly.rs");
        let forwarding = source.split("mod tests").next().unwrap_or_default();
        let forwards = forwarding.matches("self.inner.").count();
        assert!(forwards >= 12, "only {forwards} reads are forwarded");
        for write in [
            concat!("self.inner.", "append_message"),
            concat!("self.inner.", "insert_moment"),
            concat!("self.inner.", "delete_conversation"),
            concat!("self.inner.", "update_message"),
            concat!("self.inner.", "clear_history"),
            concat!("self.inner.", "put_t2_summary"),
        ] {
            assert!(
                !forwarding.contains(write),
                "`{write}` was forwarded; the read-only handle is no longer read-only"
            );
        }
    }
}

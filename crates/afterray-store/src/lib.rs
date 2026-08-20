#![allow(
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::needless_pass_by_value,
    clippy::too_many_arguments,
    clippy::cast_possible_truncation
)]

use afterray_core::{CoreError, Store};
use afterray_protocol::{
    ActivitySpan, ArtifactPayload, AudioSegment, AudioTrack, Conversation, ConversationMessage,
    DEFAULT_STORAGE_LIMIT_BYTES, Memory, Moment, SearchHit, Session,
};
use async_trait::async_trait;
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, KeyInit, Payload},
};
#[cfg(target_os = "macos")]
use core_foundation::{base::TCFType, string::CFString};
use rand::RngCore;
use rusqlite::{Connection, OptionalExtension, params};
#[cfg(target_os = "macos")]
use security_framework::{
    access_control::{ProtectionMode, SecAccessControl},
    passwords::{
        PasswordOptions, delete_generic_password_options, generic_password,
        set_generic_password_options,
    },
};
#[cfg(target_os = "macos")]
use security_framework_sys::base::errSecItemNotFound;
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};
use std::{
    collections::HashMap,
    fs::{self, File, OpenOptions},
    io::Write as _,
    path::{Path, PathBuf},
    sync::{
        Mutex, RwLock,
        atomic::{AtomicU64, Ordering},
    },
};
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

mod activity;
pub use activity::ActivityMomentRow;
pub mod acts;
mod ax_compress;
mod gop;
pub mod infoscore;
mod jpeg;
mod memory;
pub mod search_index;
mod slot;

pub use gop::{
    GopCommitFrame, GopCommitRequest, GopFrameRow, GopPackJob, GopSegmentRecord, MIN_PACK_FRAMES,
    PackCandidate, PackPolicy, PackStatusCounts, first_packable_run, fold_pack_runs,
    packable_frame_count,
};
pub use jpeg::jpeg_pixel_size;
pub use memory::{
    AccessibilityDigest, AxScopeNode, AxScopeTree, accessibility_scope_tree,
    accessibility_text_lines, digest_fingerprint, is_idle_digest, parse_accessibility_digest,
};
use search_index::{index_text, match_query};
/// One stretch of transcribed speech: when it started, which track it came
/// from, and what was said.
pub type TranscriptLine = (i64, String, String);

/// A capture id paired with the instant it was taken.
pub type MomentAt = (String, i64);

pub use slot::{
    AppFact, CURRENT_SLOT_DURATION_MS, DaySlot, DaySummary, GapEntry, MentionKind, PrevCard,
    Revisit, RunRow, LEGACY_SLOT_SUMMARY_SCHEMA_VERSION, SLOT_DURATION_CHOICES_MINUTES,
    SLOT_DURATION_MS, SLOT_SUMMARY_SCHEMA_VERSION, SlotBounds, SlotCard, SlotEvidence,
    SlotExportFacts, SlotFacts, SlotMention, SlotMomentRow, SlotSegment, SlotState,
    SlotSummaryExport, SlotSummaryState, StoredSlotOverlay, T2_SYSTEM_PROMPT, T2_SYSTEM_PROMPT_V2,
    T2_SYSTEM_PROMPT_V3, T2Card, T2CardV2, T2CardV3, T2Entity, T2GroundingReport, T2Thread,
    T2VerifyReport, TimelineEntry, V2_SLOT_SUMMARY_SCHEMA_VERSION, assemble_day_summary,
    attach_entity_candidates, build_slot_card, build_slot_card_with_end, dedup_key_of,
    details_sections, extract_json_object, ground_t2_details, legacy_segments, local_day_bounds,
    local_day_for, match_slot_mention, next_legacy_slot_boundary, parse_t2_card, parse_t2_card_v2,
    parse_t2_card_v3, render_t2_prompt, render_t2_system_prompt, shorten_place, slot_bounds_for,
    slot_bounds_in,
    slot_clock_label, slot_duration_ms_for_minutes, slot_start_for, verify_t2_card,
};

mod readonly;
pub use readonly::{ReadOnlyVault, SharedReadOnlyVault};

pub const SCHEMA_VERSION: u32 = 26;

// @dec:size-driven-retention — docs/decisions/active/architecture/2026-08-20-size-driven-retention.md
/// How long a runtime marker in the event stream lives.
///
/// This is **not** content retention. A `signal_gap` row records that the
/// daemon lost observations — the tap died, or a batch failed to land — so T1
/// reads the stretch as unobservable rather than idle. It is bookkeeping about
/// the recorder, not a record of the user, and it is worth nothing once every
/// card covering its stretch has been built. Two days is comfortably past the
/// five-minute sweeper that seals slots and freezes their acts.
///
/// Everything else in `input_events`, and the R3 trees in `edge_snapshots`,
/// lives under the vault's general retention like any other captured content
/// (`docs/event-capture-v2-plan.md` §信任模型变更 retired the 48h channel for
/// them). This short channel is for markers only.
pub const SIGNAL_MARKER_RETENTION_MS: i64 = 48 * 60 * 60 * 1000;

/// One coalesced input observation, as the vault holds it.
///
/// A verbatim mirror of the shim's record (`InputEventRecord` in
/// `afterray-platform-macos`): `kind` stays an uninterpreted string and
/// `target_json` an uninterpreted blob because the vault is not the layer that
/// decides what an act means — the T1 join is. A `kind` this build has never
/// heard of must still round-trip; the shim can ship ahead of its reader.
///
/// Since event-capture v2 (schema 25) a row may carry content: the typed run in
/// `text` and the focused field's value inside `target_json`. The ban that kept
/// this table content-free (CAP-005) lapsed with the local trust model — all
/// processing is local, the vault is encrypted, and nothing leaves the machine
/// without an explicit export. The one guard left is the shim's, at the source:
/// a secure field yields no keystream and no value, ever, and nothing here
/// re-checks it because by this point the content is already absent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputEventRow {
    /// When the observation began.
    pub at_ms: i64,
    /// When it ended, for spans (typing bursts, coalesced scrolls). `None`
    /// makes the row a point at `at_ms`.
    pub end_ms: Option<i64>,
    /// `burst` | `command` | `click` | `scroll` — and whatever a newer shim
    /// invents.
    pub kind: String,
    /// Keystrokes in a burst, or coalesced scroll ticks.
    pub count: Option<u32>,
    /// The command key that closed a burst ("submit/execute" semantics).
    pub ended_with: Option<String>,
    /// The named command for a `command` event.
    pub command: Option<String>,
    pub bundle_identifier: Option<String>,
    /// The platform layer's resolved element identity, serialised verbatim.
    pub target_json: Option<String>,
    /// What a typing run left standing, as the shim coalesced it. The secondary
    /// content channel: measured, a CJK keystream is pinyin fragments, so the
    /// primary one is the target's `value` inside `target_json`.
    pub text: Option<String>,
    /// Everything else the shim's record carries, as one JSON object with only
    /// the present keys (`application_name`, `window_title`, `source`,
    /// `destination`).
    ///
    /// One column rather than four because the vault does not model the input
    /// vocabulary — it stores it. A shim that invents a fifth field needs a
    /// mapping line in the daemon, not a migration here, and the columns that
    /// do exist stay the ones every reader queries on.
    pub extra_json: Option<String>,
}

/// Content type of a stored R3 edge snapshot.
///
/// The payload is the shim's ordinary accessibility snapshot; the
/// `purpose=edge-ax` parameter is what separates an edge tree from a heartbeat
/// tree in the `artifacts` table, which has no purpose column of its own. It is
/// a constant rather than a value copied off the capture event because the
/// encryption AAD binds the content type: an artifact stored under one string
/// and read back under another is undecryptable.
pub const EDGE_SNAPSHOT_CONTENT_TYPE: &str = "application/vnd.afterray.ax+json; purpose=edge-ax";

/// One R3 edge snapshot: an accessibility tree walked because the user changed
/// scope, not because the capture heartbeat came round.
///
/// It has no moment, no thumbnail, and no OCR — it is not a frame of the screen,
/// it is extra tree for the join to partition text against. It lives exactly as
/// long as the input events that triggered it — both are swept against the same
/// retention horizon ([`Vault::prune_edge_snapshots_before`]): a tree driven by
/// an event and outliving it would still expose the instant of an interaction
/// whose record was erased.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EdgeSnapshotRow {
    pub id: String,
    pub captured_at_ms: i64,
    pub artifact_id: String,
}

/// How a search is narrowed before anything is ranked.
///
/// Every field is optional and an unset field means "do not narrow on this".
/// Passed as a struct rather than three arguments because the two searches —
/// evidence and summaries — must offer the same narrowing or the agent has to
/// remember which one can do what.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SearchFilter {
    /// Inclusive lower bound on when the evidence was captured.
    pub from_ms: Option<i64>,
    /// Inclusive upper bound.
    pub to_ms: Option<i64>,
    /// Application name, matched case-insensitively. Transcripts belong to no
    /// application, so setting this excludes them.
    pub app: Option<String>,
}

impl SearchFilter {
    /// A range with no application constraint.
    #[must_use]
    pub const fn range(from_ms: Option<i64>, to_ms: Option<i64>) -> Self {
        Self {
            from_ms,
            to_ms,
            app: None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ClaimedAudioTranscription {
    pub segment: AudioSegment,
    pub attempts: u32,
}

/// Which audio segments the transcription sweeper may claim, as one predicate
/// over `audio_segments a`. `?1` is now, in epoch-ms.
///
/// Shared with the dashboard's backlog count: a hand-copy that omitted the
/// retry-backoff clause counted segments the sweeper would not touch, so
/// "start now" promised more than it could drain.
/// How far back the "no screen text" count looks. A day: long enough to show
/// what an overnight `off` cost, short enough that the query stays a bounded
/// range scan instead of walking the whole vault every refresh.
const UNINDEXED_LOOKBACK_MS: i64 = 24 * 60 * 60 * 1_000;

const AUDIO_CLAIMABLE_PREDICATE: &str = "a.transcription_state IN ('pending', 'failed')
                    AND a.transcription_next_attempt_ms <= ?1
                    AND NOT EXISTS (
                        SELECT 1 FROM text_evidence te
                         WHERE te.audio_segment_id = a.id AND te.source = 'transcript'
                    )";

/// Which audio segments still owe a transcript, as one predicate over
/// `audio_segments a`. Takes no parameters.
///
/// A strict superset of [`AUDIO_CLAIMABLE_PREDICATE`], and deliberately so: it
/// drops the retry-backoff clause (a segment sitting out a backoff is still
/// owed a transcript) and adds `running` (one being transcribed right now is
/// the strongest possible reason to wait). Claimable answers "may the sweeper
/// pick this up *now*"; this answers "is a transcript still coming".
///
/// The state list is what keeps `done` out, and it is not redundant with the
/// `NOT EXISTS`: [`Vault::complete_audio_transcription`] marks a segment `done`
/// even when the model returned nothing to index — silence, an empty room, a
/// muted track — and writes no evidence row. On the `NOT EXISTS` half alone
/// every silent segment would read as untranscribed forever, and a summary
/// waiting on one would wait out its whole cap on every quiet slot.
const AUDIO_UNTRANSCRIBED_PREDICATE: &str = "a.transcription_state IN ('pending', 'failed', 'running')
                    AND NOT EXISTS (
                        SELECT 1 FROM text_evidence te
                         WHERE te.audio_segment_id = a.id AND te.source = 'transcript'
                    )";

/// The attempt count at which ASR's retry backoff stops growing.
///
/// There is no retry *cap* in this codebase — a failed segment is retried
/// forever — but the daemon's delay is `1 << min(attempts, this)` minutes, so
/// from here on every further attempt is an hour apart and the queue has, in
/// effect, given up making progress on that segment. That is the only place in
/// the code where retrying stops escalating, so it is the rule
/// [`AsrHealth::exhausted_segments`] counts against rather than a fresh cap
/// invented for the summariser. Shared with the daemon's `fail_claimed_audio`
/// so the two cannot drift.
pub const AUDIO_BACKOFF_SATURATION_ATTEMPTS: u32 = 6;

/// Whether transcription is getting anywhere, for callers deciding if waiting
/// on a transcript is justified.
///
/// One snapshot rather than four queries because every caller needs the whole
/// picture to decide anything: "a segment is pending" only means "wait" if the
/// worker is also demonstrably alive.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AsrHealth {
    /// When a segment last reached `done`. `None` means transcription has
    /// never once succeeded on this vault — a cold start, an absent model, or
    /// a worker that cannot run at all.
    pub last_success_ms: Option<i64>,
    /// When a segment last recorded an error. Cleared on the segment when it
    /// is re-claimed, so this is "the last thing that happened to some segment
    /// was a failure", not "a failure ever happened".
    pub last_failure_ms: Option<i64>,
    /// Segments still owed a transcript, vault-wide.
    pub waiting_segments: usize,
    /// The subset of those whose backoff has saturated
    /// ([`AUDIO_BACKOFF_SATURATION_ATTEMPTS`]).
    pub exhausted_segments: usize,
}

/// Outstanding background work that survives a restart.
///
/// Counted from the vault, not from the in-memory job queue: the queue only
/// knows about work already submitted, which is a few seconds of it. What the
/// user wants to see is the pile — "42 slots still need summarising" — and
/// whether pressing start will make it shrink.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ComputeBacklog {
    /// Stills eligible for AV1 packing right now.
    pub archive_stills: usize,
    /// Audio segments waiting for, or retrying, transcription.
    pub transcripts: usize,
    /// Moments that still have their JPEG but no screen text.
    ///
    /// Bounded to what is still recoverable on purpose: once a moment is packed
    /// into a GOP its JPEG is gone and Rust cannot decode AV1 back, so counting
    /// those would be reporting a backlog nothing can ever drain.
    pub unindexed_moments: usize,
}

/// One completed summary pass and what it cost in wall-clock time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SummaryRun {
    pub slot_start_ms: i64,
    pub produced_at_ms: i64,
    pub latency_ms: i64,
}

/// What conversations may occupy, separate from the capture budget.
///
/// Deliberately its own pool rather than a share of `storage_limit_bytes`.
/// Chat is a few kilobytes per turn against gigabytes of frames, so a shared
/// pool would let screenshots evict a year of conversations without ever
/// noticeably relieving the pressure — and shrinking the capture limit would
/// silently take chat history with it.
///
/// At roughly two kilobytes a message this holds well over a hundred thousand
/// of them, so in practice it bounds a runaway rather than trimming real use.
pub const CONVERSATION_LIMIT_BYTES: u64 = 256 * 1024 * 1024;

/// Per-row overhead charged on top of the text: ids, timestamps, indexes.
const CONVERSATION_ROW_OVERHEAD_BYTES: i64 = 256;

/// Cosine floor for a semantic hit to count as a hit at all.
///
/// `semantic_search` returns nearest neighbours, and *nearest* is not *near*:
/// without a floor the top of an empty-handed search is still handed back, so
/// every query filled its page with the least-unrelated thing in the vault.
/// nomic-embed-text puts unrelated everyday screen text well below this, so
/// anything under it is noise wearing a rank.
pub const SEMANTIC_MIN_SIMILARITY: f32 = 0.72;

/// `text_evidence.source` for the synthetic rows that put window titles in FTS.
pub const WINDOW_EVIDENCE_SOURCE: &str = "window";
/// A window usually stays put for minutes while capture fires every ~10s.
/// Re-indexing a title only after this long keeps the index from filling with
/// thousands of identical rows, and collapses A↔B window flapping too.
const WINDOW_TITLE_DEDUPE_MS: i64 = 600_000;

/// Thumbnails are always JPEG, whatever the still they were derived from.
pub const THUMBNAIL_CONTENT_TYPE: &str = "image/jpeg";

const LEGACY_ARTIFACT_MAGIC: &[u8; 4] = b"ARV0";
const ARTIFACT_MAGIC: &[u8; 4] = b"ARV1";
const ARTIFACT_FORMAT_VERSION: i64 = 1;
const NONCE_LENGTH: usize = 24;
const WRAPPED_DEK_LENGTH: usize = 32 + 16;
const ARTIFACT_HEADER_LENGTH: usize = 4 + NONCE_LENGTH;
const ARTIFACT_FILE_OVERHEAD_BYTES: i64 = (ARTIFACT_HEADER_LENGTH + 16) as i64;
const RETENTION_BATCH_SIZE: i64 = 256;
const DATABASE_KEY_CONTEXT: &str = "dev.afterray.vault.database-key.v1";
const ARTIFACT_WRAP_KEY_CONTEXT: &str = "dev.afterray.vault.artifact-wrap-key.v1";
const KEYCHAIN_SERVICE: &str = "dev.afterray.v0.vault";
type ArtifactRecordMetadata = (String, i64, Option<Vec<u8>>, Option<Vec<u8>>);
pub type VaultKey = Zeroizing<[u8; 32]>;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("crypto operation failed")]
    Crypto,
    #[error("invalid vault key")]
    InvalidKey,
    #[error("the existing Vault key is missing from macOS Keychain")]
    MissingVaultKey,
    #[error("artifact not found: {0}")]
    ArtifactNotFound(String),
    #[error("key provider: {0}")]
    KeyProvider(String),
    #[error("invalid embedding: {0}")]
    InvalidEmbedding(String),
    #[error("gop segment not found: {0}")]
    GopNotFound(String),
    #[error("gop commit raced with retention")]
    GopStale,
    #[error("moment not found: {0}")]
    MomentNotFound(String),
    #[error("{0} ms is not an offered summary slot length")]
    InvalidSlotDuration(i64),
}

pub trait KeyProvider: Send + Sync {
    fn load(&self) -> Result<Option<VaultKey>, StoreError>;
    fn create(&self) -> Result<VaultKey, StoreError>;

    fn load_or_create(&self) -> Result<VaultKey, StoreError> {
        self.load()?.map_or_else(|| self.create(), Ok)
    }
}

#[derive(Debug, Default)]
pub struct MacOsKeychainProvider;

impl KeyProvider for MacOsKeychainProvider {
    fn load(&self) -> Result<Option<VaultKey>, StoreError> {
        let account = std::env::var("USER").unwrap_or_else(|_| "afterray".to_owned());
        load_keychain_key(&account)
    }

    fn create(&self) -> Result<VaultKey, StoreError> {
        let account = std::env::var("USER").unwrap_or_else(|_| "afterray".to_owned());
        create_keychain_key(&account)
    }
}

/// Developer ID helper tools cannot use the Data Protection keychain or
/// `SecAccessControl`: both require entitlements that AMFI rejects without a
/// provisioning profile (`errSecMissingEntitlement` or a launch-time kill).
/// The file-based keychain with `WhenUnlockedThisDeviceOnly` and iCloud sync
/// disabled meets the same device-bound, unlocked-only contract.
#[cfg(target_os = "macos")]
const ERR_SEC_MISSING_ENTITLEMENT: i32 = -34018;

/// `kSecAttrAccessible` / `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
/// security-framework does not expose this attribute key through a safe API.
#[cfg(target_os = "macos")]
const SEC_ATTR_ACCESSIBLE: &str = "pdmn";
#[cfg(target_os = "macos")]
const SEC_ATTR_ACCESSIBLE_WHEN_UNLOCKED_THIS_DEVICE_ONLY: &str = "aku";

#[cfg(target_os = "macos")]
fn load_keychain_key(account: &str) -> Result<Option<VaultKey>, StoreError> {
    if let Some(key) = read_keychain_item(protected_keychain_query_options(account))? {
        let _ = remove_file_keychain_item(account);
        return Ok(Some(key));
    }
    if let Some(key) = read_keychain_item(file_keychain_query_options(account))? {
        promote_keychain_item(account, &key)?;
        return Ok(Some(key));
    }
    match generic_password(PasswordOptions::new_generic_password(
        KEYCHAIN_SERVICE,
        account,
    )) {
        Ok(existing) => {
            let mut existing = Zeroizing::new(existing);
            let key = decode_key(&existing)?;
            existing.zeroize();
            persist_keychain_item(account, &key)?;
            remove_legacy_keychain_item(account)?;
            Ok(Some(key))
        }
        Err(error) if is_item_not_found(error) => Ok(None),
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn read_keychain_item(options: PasswordOptions) -> Result<Option<VaultKey>, StoreError> {
    match generic_password(options) {
        Ok(existing) => {
            let existing = Zeroizing::new(existing);
            Ok(Some(decode_key(&existing)?))
        }
        Err(error) if is_item_not_found(error) || is_missing_entitlement(error) => Ok(None),
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn persist_keychain_item(account: &str, key: &VaultKey) -> Result<(), StoreError> {
    match set_generic_password_options(&**key, protected_keychain_create_options(account)?) {
        Ok(()) => Ok(()),
        Err(error) if is_missing_entitlement(error) => {
            set_generic_password_options(&**key, file_keychain_create_options(account))
                .map_err(|error| StoreError::KeyProvider(error.to_string()))
        }
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn promote_keychain_item(account: &str, key: &VaultKey) -> Result<(), StoreError> {
    match set_generic_password_options(&**key, protected_keychain_create_options(account)?) {
        Ok(()) => {
            let verified = read_keychain_item(protected_keychain_query_options(account))?
                .ok_or(StoreError::InvalidKey)?;
            if *verified != **key {
                return Err(StoreError::InvalidKey);
            }
            let _ = remove_file_keychain_item(account);
            Ok(())
        }
        Err(error) if is_missing_entitlement(error) => Ok(()),
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn remove_file_keychain_item(account: &str) -> Result<(), StoreError> {
    match delete_generic_password_options(file_keychain_query_options(account)) {
        Ok(()) => Ok(()),
        Err(error) if is_item_not_found(error) => Ok(()),
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn remove_legacy_keychain_item(account: &str) -> Result<(), StoreError> {
    match delete_generic_password_options(PasswordOptions::new_generic_password(
        KEYCHAIN_SERVICE,
        account,
    )) {
        Ok(()) => Ok(()),
        Err(error) if is_item_not_found(error) => Ok(()),
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn create_keychain_key(account: &str) -> Result<VaultKey, StoreError> {
    let mut key = Zeroizing::new([0_u8; 32]);
    rand::rng().fill_bytes(key.as_mut());
    persist_keychain_item(account, &key)?;
    Ok(key)
}

#[cfg(target_os = "macos")]
fn file_keychain_query_options(account: &str) -> PasswordOptions {
    let mut options = PasswordOptions::new_generic_password(KEYCHAIN_SERVICE, account);
    options.set_access_synchronized(Some(false));
    options
}

#[cfg(target_os = "macos")]
fn file_keychain_create_options(account: &str) -> PasswordOptions {
    let mut options = file_keychain_query_options(account);
    options.set_label("AfterRay Vault Key");
    #[allow(deprecated)]
    {
        options.query.push((
            CFString::from(SEC_ATTR_ACCESSIBLE),
            CFString::from(SEC_ATTR_ACCESSIBLE_WHEN_UNLOCKED_THIS_DEVICE_ONLY).into_CFType(),
        ));
    }
    options
}

#[cfg(target_os = "macos")]
fn protected_keychain_query_options(account: &str) -> PasswordOptions {
    let mut options = file_keychain_query_options(account);
    options.use_protected_keychain();
    options
}

#[cfg(target_os = "macos")]
fn protected_keychain_create_options(account: &str) -> Result<PasswordOptions, StoreError> {
    let access_control = SecAccessControl::create_with_protection(
        Some(ProtectionMode::AccessibleWhenUnlockedThisDeviceOnly),
        0,
    )
    .map_err(|error| StoreError::KeyProvider(error.to_string()))?;
    let mut options = protected_keychain_query_options(account);
    options.set_access_control(access_control);
    Ok(options)
}

#[cfg(target_os = "macos")]
fn is_item_not_found(error: security_framework::base::Error) -> bool {
    error.code() == errSecItemNotFound
}

#[cfg(target_os = "macos")]
fn is_missing_entitlement(error: security_framework::base::Error) -> bool {
    error.code() == ERR_SEC_MISSING_ENTITLEMENT
}

#[cfg(not(target_os = "macos"))]
fn load_keychain_key(_account: &str) -> Result<Option<VaultKey>, StoreError> {
    Err(StoreError::KeyProvider(
        "the production Vault key provider requires macOS Keychain".to_owned(),
    ))
}

#[cfg(not(target_os = "macos"))]
fn create_keychain_key(_account: &str) -> Result<VaultKey, StoreError> {
    Err(StoreError::KeyProvider(
        "the production Vault key provider requires macOS Keychain".to_owned(),
    ))
}

/// Secrets that are not the vault key — today only the assistant API key.
///
/// It used to live in cleartext in `settings.json` beside the vault, written
/// with the process umask, so a `0644` file held a billable credential. The
/// Keychain gives it the same device-bound, unlocked-only protection the
/// vault key already has.
#[cfg(target_os = "macos")]
const SECRET_KEYCHAIN_SERVICE: &str = "dev.afterray.v0.secrets";

/// Keychain account for the OpenAI-compatible API key.
pub const LLM_API_KEY_SECRET: &str = "llm-api-key";

pub fn load_secret(name: &str) -> Result<Option<String>, StoreError> {
    #[cfg(target_os = "macos")]
    {
        let mut protected = secret_query_options(name);
        protected.use_protected_keychain();
        if let Some(value) = read_secret_item(protected)? {
            return Ok(Some(value));
        }
        read_secret_item(secret_query_options(name))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = name;
        Err(StoreError::KeyProvider(
            "storing secrets requires the macOS Keychain".to_owned(),
        ))
    }
}

pub fn store_secret(name: &str, value: &str) -> Result<(), StoreError> {
    #[cfg(target_os = "macos")]
    {
        match set_generic_password_options(
            value.as_bytes(),
            secret_create_options(name, /* protected */ true)?,
        ) {
            Ok(()) => Ok(()),
            Err(error) if is_missing_entitlement(error) => set_generic_password_options(
                value.as_bytes(),
                secret_create_options(name, /* protected */ false)?,
            )
            .map_err(|error| StoreError::KeyProvider(error.to_string())),
            Err(error) => Err(StoreError::KeyProvider(error.to_string())),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (name, value);
        Err(StoreError::KeyProvider(
            "storing secrets requires the macOS Keychain".to_owned(),
        ))
    }
}

/// Clearing a secret has to clear it everywhere it could have landed, or a
/// user who deletes their API key keeps a working credential on disk.
pub fn delete_secret(name: &str) -> Result<(), StoreError> {
    #[cfg(target_os = "macos")]
    {
        let mut protected = secret_query_options(name);
        protected.use_protected_keychain();
        remove_secret_item(protected)?;
        remove_secret_item(secret_query_options(name))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = name;
        Err(StoreError::KeyProvider(
            "storing secrets requires the macOS Keychain".to_owned(),
        ))
    }
}

#[cfg(target_os = "macos")]
fn secret_query_options(name: &str) -> PasswordOptions {
    let mut options = PasswordOptions::new_generic_password(SECRET_KEYCHAIN_SERVICE, name);
    options.set_access_synchronized(Some(false));
    options
}

#[cfg(target_os = "macos")]
fn secret_create_options(name: &str, protected: bool) -> Result<PasswordOptions, StoreError> {
    let mut options = secret_query_options(name);
    options.set_label("AfterRay Assistant Credential");
    #[allow(deprecated)]
    {
        options.query.push((
            CFString::from(SEC_ATTR_ACCESSIBLE),
            CFString::from(SEC_ATTR_ACCESSIBLE_WHEN_UNLOCKED_THIS_DEVICE_ONLY).into_CFType(),
        ));
    }
    if protected {
        let access_control = SecAccessControl::create_with_protection(
            Some(ProtectionMode::AccessibleWhenUnlockedThisDeviceOnly),
            0,
        )
        .map_err(|error| StoreError::KeyProvider(error.to_string()))?;
        options.use_protected_keychain();
        options.set_access_control(access_control);
    }
    Ok(options)
}

#[cfg(target_os = "macos")]
fn read_secret_item(options: PasswordOptions) -> Result<Option<String>, StoreError> {
    match generic_password(options) {
        Ok(value) => {
            let value = Zeroizing::new(value);
            let text = std::str::from_utf8(&value)
                .map_err(|_| StoreError::KeyProvider("stored secret is not UTF-8".to_owned()))?;
            Ok(Some(text.to_owned()))
        }
        Err(error) if is_item_not_found(error) || is_missing_entitlement(error) => Ok(None),
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

#[cfg(target_os = "macos")]
fn remove_secret_item(options: PasswordOptions) -> Result<(), StoreError> {
    match delete_generic_password_options(options) {
        Ok(()) => Ok(()),
        Err(error) if is_item_not_found(error) || is_missing_entitlement(error) => Ok(()),
        Err(error) => Err(StoreError::KeyProvider(error.to_string())),
    }
}

fn decode_key(value: &[u8]) -> Result<VaultKey, StoreError> {
    if value.len() == 32 {
        return value
            .try_into()
            .map(Zeroizing::new)
            .map_err(|_| StoreError::InvalidKey);
    }
    let decoded = BASE64.decode(value).map_err(|_| StoreError::InvalidKey)?;
    decoded
        .try_into()
        .map(Zeroizing::new)
        .map_err(|_| StoreError::InvalidKey)
}

#[derive(Debug, Clone)]
pub struct VaultConfig {
    pub data_dir: PathBuf,
    pub max_storage_bytes: u64,
}

impl Default for VaultConfig {
    fn default() -> Self {
        Self {
            data_dir: default_data_dir(),
            max_storage_bytes: DEFAULT_STORAGE_LIMIT_BYTES,
        }
    }
}

pub struct Vault {
    /// The single writer. SQLite in WAL mode supports many readers beside
    /// one writer; funnelling reads through this same mutex — the original
    /// design — serialised the whole store behind whichever caller was
    /// building a day of slot cards.
    connection: Mutex<Connection>,
    readers: ReadPool,
    /// Slot cards for settled half-hours, keyed by slot start. See
    /// [`Vault::slot_card`] for the eligibility rule.
    card_cache: Mutex<HashMap<i64, slot::SlotCard>>,
    artifacts_dir: PathBuf,
    artifact_wrap_key: Zeroizing<[u8; 32]>,
    legacy_artifact_key: Mutex<Option<Zeroizing<[u8; 32]>>>,
    /// Serializes artifact *writes* (put/delete/migrate) against each other and
    /// against reads of the same file tree. Concurrent reads share a read lock
    /// so filmstrip scrubbing can decrypt many JPEGs in parallel.
    artifact_io: RwLock<()>,
    max_storage_bytes: AtomicU64,
    /// How long a summary slot has been at each point in this vault's life,
    /// oldest first. Persisted, because a card already written must keep the
    /// shape it was summarised at however often the user changes the setting.
    summary_slot_segments: RwLock<Vec<slot::SlotSegment>>,
}

/// A handful of `PRAGMA query_only` connections, handed out round-robin.
/// `query_only` makes a misclassified write a loud error instead of a data
/// race — the pool must never be able to corrupt anything.
struct ReadPool {
    connections: Vec<Mutex<Connection>>,
    next: std::sync::atomic::AtomicUsize,
}

impl ReadPool {
    /// Sized for overlapping UI reads (timeline + filmstrip + search) while a
    /// day-summary build is also fanning out slot cards on scoped threads.
    const SIZE: usize = 6;

    fn open(path: &Path, key: &Zeroizing<[u8; 32]>) -> Result<Self, StoreError> {
        let mut connections = Vec::with_capacity(Self::SIZE);
        for _ in 0..Self::SIZE {
            let connection = open_keyed_database(path, key)?;
            connection.execute_batch(
                "PRAGMA query_only = ON;
                 PRAGMA busy_timeout = 5000;",
            )?;
            connections.push(Mutex::new(connection));
        }
        Ok(Self {
            connections,
            next: std::sync::atomic::AtomicUsize::new(0),
        })
    }

    /// Prefers an idle connection; blocks on one only when all are busy.
    fn get(&self) -> std::sync::MutexGuard<'_, Connection> {
        let start = self.next.fetch_add(1, Ordering::Relaxed);
        for offset in 0..self.connections.len() {
            let index = (start + offset) % self.connections.len();
            if let Ok(guard) = self.connections[index].try_lock() {
                return guard;
            }
        }
        self.connections[start % self.connections.len()]
            .lock()
            .unwrap()
    }
}

/// What one [`Vault::update_message`] call writes.
///
/// Every field is overwritten, so a caller passes the whole current state
/// rather than a delta: the turn holds it in memory anyway, and a partial
/// update would let a crash leave two halves written at different beats.
#[derive(Debug, Clone, Copy, Default)]
pub struct MessageUpdate<'a> {
    pub content: &'a str,
    pub tool_log: Option<&'a str>,
    pub reasoning: Option<&'a str>,
    pub status: Option<&'a str>,
    pub usage_json: Option<&'a str>,
}

type SlotSummaryExportRow = (
    String,
    i64,
    i64,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<f32>,
    Option<i64>,
    Option<String>,
    Option<i64>,
    Option<i64>,
    // details — the v3 card body.
    Option<String>,
);


impl Vault {
    /// The whole geometry history, oldest first. Callers that bound many
    /// moments at once should take this once and use [`slot::slot_bounds_in`]
    /// rather than re-locking per row.
    #[must_use]
    pub fn summary_slot_segments(&self) -> Vec<slot::SlotSegment> {
        self.summary_slot_segments
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// The length new slots are being cut at right now.
    #[must_use]
    pub fn summary_slot_duration_ms(&self) -> i64 {
        self.summary_slot_segments
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .last()
            .map_or(slot::CURRENT_SLOT_DURATION_MS, |segment| {
                segment.duration_ms
            })
    }

    #[must_use]
    pub fn summary_slot_bounds(&self, at_ms: i64) -> slot::SlotBounds {
        slot::slot_bounds_in(
            at_ms,
            &self
                .summary_slot_segments
                .read()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        )
    }

    /// Changes the length of slots cut from `now_ms` onwards, leaving every
    /// slot already summarised exactly as it was.
    ///
    /// The change takes effect immediately rather than at the next boundary:
    /// waiting for one would mean up to an hour of a setting the user can see
    /// but not feel. The stretch in progress is clipped at `now_ms`, so the
    /// two geometries still tile the timeline.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError::InvalidSlotDuration`] for a length that is not
    /// offered, or an error if the vault cannot be written.
    pub fn set_summary_slot_duration_ms(
        &self,
        duration_ms: i64,
        now_ms: i64,
    ) -> Result<(), StoreError> {
        if !slot::SLOT_DURATION_CHOICES_MINUTES.contains(&(duration_ms / 60_000))
            || duration_ms % 60_000 != 0
        {
            return Err(StoreError::InvalidSlotDuration(duration_ms));
        }
        let mut segments = self
            .summary_slot_segments
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if segments
            .last()
            .is_some_and(|segment| segment.duration_ms == duration_ms)
        {
            return Ok(());
        }
        let mut next = segments.clone();
        // A segment that never held a moment described no slot anyone read, so
        // flipping the control twice on an idle Mac leaves one boundary, not a
        // trail of empty geometries.
        while next.len() > 1
            && next
                .last()
                .is_some_and(|segment| !self.has_moment_at_or_after(segment.from_ms).unwrap_or(true))
        {
            next.pop();
        }
        if next
            .last()
            .is_some_and(|segment| segment.duration_ms == duration_ms)
        {
            // Unwinding the empty segments already restored this length.
            self.write_summary_slot_segments(&next)?;
            *segments = next;
            drop(segments);
            self.flush_card_cache();
            return Ok(());
        }
        let from_ms = next
            .last()
            .map_or(now_ms, |segment| now_ms.max(segment.from_ms + 1));
        next.push(slot::SlotSegment::new(from_ms, duration_ms));
        self.write_summary_slot_segments(&next)?;
        *segments = next;
        drop(segments);
        // Cached cards are keyed by slot start; the boundaries just moved.
        self.flush_card_cache();
        Ok(())
    }

    fn has_moment_at_or_after(&self, from_ms: i64) -> Result<bool, StoreError> {
        let connection = self.readers.get();
        let found: Option<i64> = connection
            .query_row(
                "SELECT 1 FROM moments WHERE captured_at_ms >= ?1 LIMIT 1",
                [from_ms],
                |row| row.get(0),
            )
            .optional()?;
        Ok(found.is_some())
    }

    fn write_summary_slot_segments(
        &self,
        segments: &[slot::SlotSegment],
    ) -> Result<(), StoreError> {
        let connection = self.connection.lock().unwrap();
        let tx = connection.unchecked_transaction()?;
        tx.execute("DELETE FROM summary_slot_geometry", [])?;
        {
            let mut insert = tx.prepare(
                "INSERT INTO summary_slot_geometry (from_ms, duration_ms) VALUES (?1, ?2)",
            )?;
            for segment in segments {
                insert.execute(params![segment.from_ms, segment.duration_ms])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn open(config: VaultConfig, provider: &dyn KeyProvider) -> Result<Self, StoreError> {
        let database_path = config.data_dir.join("afterray.sqlite3");
        let existing_vault = database_path
            .metadata()
            .is_ok_and(|metadata| metadata.len() > 0);
        let key = match provider.load()? {
            Some(key) => key,
            None if existing_vault => return Err(StoreError::MissingVaultKey),
            None => provider.create()?,
        };
        Self::open_with_key(config, *key)
    }

    pub fn open_with_key(config: VaultConfig, key: [u8; 32]) -> Result<Self, StoreError> {
        let master_key = Zeroizing::new(key);
        create_private_directory(&config.data_dir)?;
        let artifacts_dir = config.data_dir.join("artifacts");
        create_private_directory(&artifacts_dir)?;
        let database_key = Zeroizing::new(blake3::derive_key(DATABASE_KEY_CONTEXT, &*master_key));
        let database_path = config.data_dir.join("afterray.sqlite3");
        let connection =
            open_database_with_legacy_migration(&database_path, &database_key, &master_key)?;
        migrate(&connection)?;
        let summary_slot_segments = read_summary_slot_segments(&connection)?;
        connection.execute_batch("PRAGMA busy_timeout = 5000;")?;
        set_database_file_permissions(&database_path)?;
        // Readers open only after migration has settled the schema.
        let readers = ReadPool::open(&database_path, &database_key)?;
        let vault = Self {
            connection: Mutex::new(connection),
            readers,
            card_cache: Mutex::new(HashMap::new()),
            artifacts_dir,
            artifact_wrap_key: Zeroizing::new(blake3::derive_key(
                ARTIFACT_WRAP_KEY_CONTEXT,
                &*master_key,
            )),
            legacy_artifact_key: Mutex::new(Some(Zeroizing::new(*master_key))),
            artifact_io: RwLock::new(()),
            max_storage_bytes: AtomicU64::new(config.max_storage_bytes),
            summary_slot_segments: RwLock::new(summary_slot_segments),
        };
        let _ = vault.rollback_orphan_gops();
        let _ = vault.reconcile_packed_stills();
        let _ = vault.cleanup_unreferenced_gop_artifacts();
        vault.enforce_retention()?;
        Ok(vault)
    }

    #[must_use]
    pub fn storage_limit_bytes(&self) -> u64 {
        self.max_storage_bytes.load(Ordering::Relaxed)
    }

    pub fn set_storage_limit_bytes(&self, bytes: u64) -> Result<(), StoreError> {
        let previous = self.max_storage_bytes.swap(bytes, Ordering::Relaxed);
        if let Err(error) = self.enforce_retention() {
            self.max_storage_bytes.store(previous, Ordering::Relaxed);
            return Err(error);
        }
        Ok(())
    }

    pub fn storage_usage_bytes(&self) -> Result<u64, StoreError> {
        let bytes = self.readers.get().query_row(
            "SELECT COALESCE(SUM(byte_length + ?1), 0) FROM artifacts",
            [ARTIFACT_FILE_OVERHEAD_BYTES],
            |row| row.get::<_, i64>(0),
        )?;
        Ok(u64::try_from(bytes).unwrap_or(u64::MAX))
    }

    pub fn create_session_sync(&self, started_at_ms: i64) -> Result<Session, StoreError> {
        let session = Session {
            id: Uuid::now_v7().to_string(),
            started_at_ms,
            ended_at_ms: None,
        };
        self.connection.lock().unwrap().execute(
            "INSERT INTO sessions (id, started_at_ms) VALUES (?1, ?2)",
            params![session.id, session.started_at_ms],
        )?;
        Ok(session)
    }

    pub fn end_session_sync(&self, id: &str, ended_at_ms: i64) -> Result<(), StoreError> {
        self.connection.lock().unwrap().execute(
            "UPDATE sessions SET ended_at_ms = ?2 WHERE id = ?1",
            params![id, ended_at_ms],
        )?;
        Ok(())
    }

    /// Closes sessions left open by an interrupted daemon. Earlier sessions end
    /// when the next one starts; the newest ends at its last captured moment.
    pub fn close_orphaned_sessions_sync(&self, fallback_ms: i64) -> Result<usize, StoreError> {
        let changed = self.connection.lock().unwrap().execute(
            "UPDATE sessions
                SET ended_at_ms = COALESCE(
                    (SELECT MIN(next.started_at_ms)
                       FROM sessions next
                      WHERE next.started_at_ms > sessions.started_at_ms),
                    (SELECT MAX(moment.captured_at_ms)
                       FROM moments moment
                      WHERE moment.session_id = sessions.id),
                    ?1
                )
              WHERE ended_at_ms IS NULL",
            [fallback_ms],
        )?;
        Ok(changed)
    }

    pub fn sessions_sync(&self) -> Result<Vec<Session>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT id, started_at_ms, ended_at_ms FROM sessions ORDER BY started_at_ms DESC",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(Session {
                id: row.get(0)?,
                started_at_ms: row.get(1)?,
                ended_at_ms: row.get(2)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn moments_sync(&self, session_id: &str) -> Result<Vec<Moment>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT m.id, m.session_id, m.captured_at_ms, m.image_artifact_id, m.is_favorite,
                    (SELECT group_concat(te.text, '\n') FROM text_evidence te WHERE te.moment_id = m.id AND te.source = 'ocr'),
                    (SELECT group_concat(te.text, '\n')
                       FROM text_evidence te
                       JOIN audio_segments audio ON audio.id = te.audio_segment_id
                      WHERE audio.session_id = m.session_id
                        AND m.captured_at_ms BETWEEN audio.started_at_ms AND audio.ended_at_ms
                        AND te.source = 'transcript'),
                    (SELECT audio.audio_artifact_id
                       FROM audio_segments audio
                      WHERE audio.session_id = m.session_id
                        AND audio.started_at_ms <= m.captured_at_ms + 30000
                        AND audio.ended_at_ms >= m.captured_at_ms - 30000
                      ORDER BY CASE audio.track WHEN 'system' THEN 0 ELSE 1 END,
                        audio.started_at_ms DESC
                      LIMIT 1),
                    (SELECT audio.started_at_ms
                       FROM audio_segments audio
                      WHERE audio.session_id = m.session_id
                        AND audio.started_at_ms <= m.captured_at_ms + 30000
                        AND audio.ended_at_ms >= m.captured_at_ms - 30000
                      ORDER BY CASE audio.track WHEN 'system' THEN 0 ELSE 1 END,
                        audio.started_at_ms DESC
                      LIMIT 1),
                    m.accessibility_artifact_id,
                    m.application_name,
                    m.bundle_identifier,
                    m.window_title,
                    m.url,
                    m.document,
                    (SELECT gs.id FROM gop_segments gs WHERE gs.id = m.gop_segment_id AND gs.status = 'ready'),
                    m.gop_index,
                    m.still_origin,
                    (SELECT gs.frame_count FROM gop_segments gs WHERE gs.id = m.gop_segment_id)
             FROM moments m WHERE m.session_id = ?1 ORDER BY m.captured_at_ms",
        )?;
        let rows = statement.query_map([session_id], moment_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn timeline_sync(&self) -> Result<Vec<Moment>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT m.id, m.session_id, m.captured_at_ms, m.image_artifact_id, m.is_favorite,
                    (SELECT group_concat(te.text, '\n') FROM text_evidence te WHERE te.moment_id = m.id AND te.source = 'ocr'),
                    (SELECT group_concat(te.text, '\n')
                       FROM text_evidence te
                       JOIN audio_segments audio ON audio.id = te.audio_segment_id
                      WHERE audio.session_id = m.session_id
                        AND m.captured_at_ms BETWEEN audio.started_at_ms AND audio.ended_at_ms
                        AND te.source = 'transcript'),
                    (SELECT audio.audio_artifact_id
                       FROM audio_segments audio
                      WHERE audio.session_id = m.session_id
                        AND audio.started_at_ms <= m.captured_at_ms + 30000
                        AND audio.ended_at_ms >= m.captured_at_ms - 30000
                      ORDER BY CASE audio.track WHEN 'system' THEN 0 ELSE 1 END,
                        audio.started_at_ms DESC
                      LIMIT 1),
                    (SELECT audio.started_at_ms
                       FROM audio_segments audio
                      WHERE audio.session_id = m.session_id
                        AND audio.started_at_ms <= m.captured_at_ms + 30000
                        AND audio.ended_at_ms >= m.captured_at_ms - 30000
                      ORDER BY CASE audio.track WHEN 'system' THEN 0 ELSE 1 END,
                        audio.started_at_ms DESC
                      LIMIT 1),
                    m.accessibility_artifact_id,
                    m.application_name,
                    m.bundle_identifier,
                    m.window_title,
                    m.url,
                    m.document,
                    (SELECT gs.id FROM gop_segments gs WHERE gs.id = m.gop_segment_id AND gs.status = 'ready'),
                    m.gop_index,
                    m.still_origin,
                    (SELECT gs.frame_count FROM gop_segments gs WHERE gs.id = m.gop_segment_id)
             FROM moments m ORDER BY m.captured_at_ms, m.id",
        )?;
        let rows = statement.query_map([], moment_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn timeline_since_sync(&self, since_ms: i64) -> Result<Vec<Moment>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT m.id, m.session_id, m.captured_at_ms, m.image_artifact_id, m.is_favorite,
                    (SELECT group_concat(te.text, '\n') FROM text_evidence te WHERE te.moment_id = m.id AND te.source = 'ocr'),
                    (SELECT group_concat(te.text, '\n')
                       FROM text_evidence te
                       JOIN audio_segments audio ON audio.id = te.audio_segment_id
                      WHERE audio.session_id = m.session_id
                        AND m.captured_at_ms BETWEEN audio.started_at_ms AND audio.ended_at_ms
                        AND te.source = 'transcript'),
                    (SELECT audio.audio_artifact_id
                       FROM audio_segments audio
                      WHERE audio.session_id = m.session_id
                        AND audio.started_at_ms <= m.captured_at_ms + 30000
                        AND audio.ended_at_ms >= m.captured_at_ms - 30000
                      ORDER BY CASE audio.track WHEN 'system' THEN 0 ELSE 1 END,
                        audio.started_at_ms DESC
                      LIMIT 1),
                    (SELECT audio.started_at_ms
                       FROM audio_segments audio
                      WHERE audio.session_id = m.session_id
                        AND audio.started_at_ms <= m.captured_at_ms + 30000
                        AND audio.ended_at_ms >= m.captured_at_ms - 30000
                      ORDER BY CASE audio.track WHEN 'system' THEN 0 ELSE 1 END,
                        audio.started_at_ms DESC
                      LIMIT 1),
                    m.accessibility_artifact_id,
                    m.application_name,
                    m.bundle_identifier,
                    m.window_title,
                    m.url,
                    m.document,
                    (SELECT gs.id FROM gop_segments gs WHERE gs.id = m.gop_segment_id AND gs.status = 'ready'),
                    m.gop_index,
                    m.still_origin,
                    (SELECT gs.frame_count FROM gop_segments gs WHERE gs.id = m.gop_segment_id)
             FROM moments m
             WHERE m.captured_at_ms >= ?1
             ORDER BY m.captured_at_ms, m.id",
        )?;
        let rows = statement.query_map([since_ms], moment_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn insert_moment(
        &self,
        session_id: &str,
        captured_at_ms: i64,
        content_type: &str,
        image: &[u8],
    ) -> Result<Moment, StoreError> {
        let artifact_id = self.put_artifact(content_type, image)?;
        let (width, height) = match jpeg_pixel_size(image) {
            Some((width, height)) => (Some(width), Some(height)),
            None => (None, None),
        };
        let moment = Moment {
            id: Uuid::now_v7().to_string(),
            session_id: session_id.to_owned(),
            captured_at_ms,
            image_artifact_id: Some(artifact_id.clone()),
            is_favorite: false,
            ocr_text: None,
            transcript_text: None,
            audio_artifact_id: None,
            audio_started_at_ms: None,
            accessibility_artifact_id: None,
            application_name: None,
            bundle_identifier: None,
            window_title: None,
            url: None,
            document: None,
            gop: None,
            still_origin: "capture".to_owned(),
        };
        let result = self.connection.lock().unwrap().execute(
            "INSERT INTO moments
             (id, session_id, captured_at_ms, image_artifact_id, is_favorite, still_origin, width, height)
             VALUES (?1, ?2, ?3, ?4, 0, 'capture', ?5, ?6)",
            params![
                moment.id,
                moment.session_id,
                moment.captured_at_ms,
                artifact_id,
                width,
                height
            ],
        );
        if let Err(error) = result {
            let _ = self.delete_artifact_record_and_file(&artifact_id);
            return Err(error.into());
        }
        self.enforce_retention()?;
        Ok(moment)
    }

    pub fn insert_audio_segment(
        &self,
        session_id: &str,
        track: AudioTrack,
        started_at_ms: i64,
        ended_at_ms: i64,
        content_type: &str,
        audio: &[u8],
    ) -> Result<AudioSegment, StoreError> {
        let artifact_id = self.put_artifact(content_type, audio)?;
        let segment = AudioSegment {
            id: Uuid::now_v7().to_string(),
            session_id: session_id.to_owned(),
            track,
            started_at_ms,
            ended_at_ms,
            audio_artifact_id: artifact_id.clone(),
        };
        let result = self.connection.lock().unwrap().execute(
            "INSERT INTO audio_segments
             (id, session_id, track, started_at_ms, ended_at_ms, audio_artifact_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                segment.id,
                segment.session_id,
                track_name(segment.track),
                segment.started_at_ms,
                segment.ended_at_ms,
                artifact_id
            ],
        );
        if let Err(error) = result {
            let _ = self.delete_artifact_record_and_file(&segment.audio_artifact_id);
            return Err(error.into());
        }
        Ok(segment)
    }

    pub fn attach_accessibility_snapshot(
        &self,
        session_id: &str,
        captured_at_ms: i64,
        content_type: &str,
        snapshot: &[u8],
        application_name: Option<&str>,
        bundle_identifier: Option<&str>,
    ) -> Result<Option<String>, StoreError> {
        let candidate = self
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT id, captured_at_ms, accessibility_artifact_id
                   FROM moments
                  WHERE session_id = ?1
                  ORDER BY ABS(captured_at_ms - ?2), captured_at_ms DESC
                  LIMIT 1",
                params![session_id, captured_at_ms],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, Option<String>>(2)?,
                    ))
                },
            )
            .optional()?;
        let Some((moment_id, moment_time, previous_artifact)) = candidate else {
            return Ok(None);
        };
        if moment_time.abs_diff(captured_at_ms) > 2_000 {
            return Ok(None);
        }

        let context = activity::merge_activity_context(
            activity::parse_accessibility_context(snapshot),
            application_name,
            bundle_identifier,
        );
        let prepared = ax_compress::prepare_accessibility_artifact(snapshot);
        let artifact_id = self.put_artifact(content_type, &prepared)?;
        let update_result = {
            let connection = self.connection.lock().unwrap();
            connection.execute(
                "UPDATE moments
                    SET accessibility_artifact_id = ?2,
                        application_name = ?3,
                        bundle_identifier = ?4,
                        window_title = ?5,
                        url = ?6,
                        document = ?7
                  WHERE id = ?1",
                params![
                    moment_id,
                    artifact_id,
                    context.application_name.as_deref(),
                    context.bundle_identifier.as_deref(),
                    context.window_title.as_deref(),
                    context.url.as_deref(),
                    context.document.as_deref()
                ],
            )
        };
        if let Err(error) = update_result {
            let _ = self.delete_artifact_record_and_file(&artifact_id);
            return Err(error.into());
        }
        if let Some(previous) = previous_artifact {
            self.delete_artifact_record_and_file(&previous)?;
        }
        if is_lock_screen_identity(
            context.application_name.as_deref(),
            context.bundle_identifier.as_deref(),
        ) {
            self.delete_moment_and_artifacts(&moment_id)?;
            return Ok(None);
        }
        self.index_window_title(session_id, &moment_id, moment_time, &context)?;
        Ok(Some(artifact_id))
    }

    /// Makes a moment findable by what its window was *called*.
    ///
    /// Titles land in `moments.window_title`, but `evidence_fts` only indexes
    /// `text_evidence`, so search could never reach them. Mirroring the title
    /// into a synthetic evidence row puts it through the same FTS, ranking, and
    /// hit-opening path that OCR and transcripts already use.
    fn index_window_title(
        &self,
        session_id: &str,
        moment_id: &str,
        captured_at_ms: i64,
        context: &activity::ActivityContext,
    ) -> Result<(), StoreError> {
        let Some(title) = trimmed(context.window_title.as_deref()) else {
            return Ok(());
        };
        // The URL is the stronger recall handle for a browser window, and it is
        // never on screen as OCR text when the address bar is hidden.
        let text = match trimmed(context.url.as_deref()) {
            Some(url) => format!("{title}\n{url}"),
            None => title.to_owned(),
        };

        let seen_recently = {
            let connection = self.connection.lock().unwrap();
            connection
                .query_row(
                    "SELECT 1 FROM text_evidence
                      WHERE session_id = ?1 AND source = ?2 AND text = ?3
                        AND started_at_ms > ?4
                      LIMIT 1",
                    params![
                        session_id,
                        WINDOW_EVIDENCE_SOURCE,
                        text,
                        captured_at_ms - WINDOW_TITLE_DEDUPE_MS
                    ],
                    |_| Ok(()),
                )
                .optional()?
                .is_some()
        };
        if seen_recently {
            return Ok(());
        }

        self.insert_text_evidence(
            session_id,
            Some(moment_id),
            None,
            WINDOW_EVIDENCE_SOURCE,
            &text,
            captured_at_ms,
            None,
            "activity",
            None,
        )?;
        Ok(())
    }

    pub fn activity_spans(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: usize,
    ) -> Result<Vec<ActivitySpan>, StoreError> {
        self.activity_spans_in_app(from_ms, to_ms, None, limit)
    }

    /// Activity spans in a range, optionally only those in one application.
    ///
    /// The application filter runs **after folding and before the limit**, and
    /// both halves of that matter.
    ///
    /// After folding, because filtering the moments first would let the fold
    /// merge two stretches that were separated by another application into one
    /// span claiming the gap — "Zed 09:00–17:00" for a morning and an
    /// afternoon with three hours of something else between them.
    ///
    /// Before the limit, because [`activity::fold_activity_spans`] stops the
    /// moment it reaches its limit, so a caller that folds-then-filters is
    /// filtering the *earliest* spans of the range. Ask for 40 spans of Zed on
    /// a day whose first 160 spans are Chrome and it answers "no activity"
    /// while the Zed spans sit in the range, unread.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn activity_spans_in_app(
        &self,
        from_ms: i64,
        to_ms: i64,
        app: Option<&str>,
        limit: usize,
    ) -> Result<Vec<ActivitySpan>, StoreError> {
        if limit == 0 || from_ms > to_ms {
            return Ok(Vec::new());
        }
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT id, captured_at_ms, application_name, bundle_identifier,
                    window_title, url, document
               FROM moments
              WHERE captured_at_ms >= ?1 AND captured_at_ms <= ?2
              ORDER BY captured_at_ms, id",
        )?;
        let rows = statement.query_map(params![from_ms, to_ms], |row| {
            Ok(activity::ActivityMomentRow {
                id: row.get(0)?,
                captured_at_ms: row.get(1)?,
                application_name: row.get(2)?,
                bundle_identifier: row.get(3)?,
                window_title: row.get(4)?,
                url: row.get(5)?,
                document: row.get(6)?,
            })
        })?;
        let moments = rows.collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        drop(connection);
        // Folded whole, then narrowed, then cut. The unbounded fold costs
        // nothing extra: the query above has no LIMIT, so every moment in the
        // range is already in hand, and the fold is linear over it.
        let mut spans = activity::fold_activity_spans(&moments, usize::MAX);
        if let Some(wanted) = app {
            spans.retain(|span| {
                span.application_name
                    .as_deref()
                    .is_some_and(|name| name.eq_ignore_ascii_case(wanted))
            });
        }
        spans.truncate(limit);
        Ok(spans)
    }

    /// The most recent capture in `[from_ms, to_ms]`, and where it was taken.
    ///
    /// Deliberately not "the last element of `activity_spans`". That folds
    /// forward from the start of the range and returns the moment it reaches
    /// its limit, so its last element is the *earliest* limit-th span, not the
    /// current one — on a day with more switches than the limit it is hours
    /// stale, which is the worst possible error for something labelled "now".
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn latest_activity_moment(
        &self,
        from_ms: i64,
        to_ms: i64,
    ) -> Result<Option<activity::ActivityMomentRow>, StoreError> {
        let connection = self.readers.get();
        connection
            .query_row(
                "SELECT id, captured_at_ms, application_name, bundle_identifier,
                        window_title, url, document
                   FROM moments
                  WHERE captured_at_ms >= ?1 AND captured_at_ms <= ?2
                  ORDER BY captured_at_ms DESC, id DESC
                  LIMIT 1",
                params![from_ms, to_ms],
                |row| {
                    Ok(activity::ActivityMomentRow {
                        id: row.get(0)?,
                        captured_at_ms: row.get(1)?,
                        application_name: row.get(2)?,
                        bundle_identifier: row.get(3)?,
                        window_title: row.get(4)?,
                        url: row.get(5)?,
                        document: row.get(6)?,
                    })
                },
            )
            .optional()
            .map_err(StoreError::from)
    }

    /// Applications by how much of a range they occupied, most first.
    ///
    /// Aggregated in SQL rather than by walking spans, so a day with more
    /// switches than a span limit cannot hide its afternoon behind its
    /// morning. Capture is interval-driven, so a frame count is time.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn top_apps_in_range(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: usize,
    ) -> Result<Vec<String>, StoreError> {
        if limit == 0 || from_ms > to_ms {
            return Ok(Vec::new());
        }
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT application_name, COUNT(*) AS frames
               FROM moments
              WHERE captured_at_ms >= ?1 AND captured_at_ms <= ?2
                AND application_name IS NOT NULL
                AND TRIM(application_name) != ''
              GROUP BY application_name
              ORDER BY frames DESC, application_name
              LIMIT ?3",
        )?;
        let rows = statement.query_map(
            params![from_ms, to_ms, i64::try_from(limit).unwrap_or(i64::MAX)],
            |row| row.get::<_, String>(0),
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Builds the deterministic T1 card for the slot containing `at_ms`.
    ///
    /// # Errors
    ///
    /// Returns an error if the vault cannot be queried.
    /// How long after a slot ends before its card may be cached. OCR and
    /// transcripts land minutes after their frames; caching too early would
    /// freeze a card that is still gaining text.
    const CARD_CACHE_SETTLE_MS: i64 = 2 * 60 * 60 * 1000;
    /// Bounded so a long-running daemon cannot grow the cache without limit;
    /// on overflow the whole map is dropped and simply rebuilds on demand.
    const CARD_CACHE_CAP: usize = 96;

    pub fn slot_card(
        &self,
        at_ms: i64,
        capture_interval_ms: i64,
    ) -> Result<slot::SlotCard, StoreError> {
        let bounds = self.summary_slot_bounds(at_ms);
        let slot_start_ms = bounds.start_ms;
        let slot_end_ms = bounds.end_ms;

        // A settled half hour is immutable except for deletion, and every
        // deletion path flushes this cache. The same card used to be rebuilt
        // — per-frame AX decryption included — by the day panel, the T2
        // prompt, and the sweeper, each within minutes of the others.
        let wall_ms = i64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or_default(),
        )
        .unwrap_or(i64::MAX);
        let settled = slot_end_ms.saturating_add(Self::CARD_CACHE_SETTLE_MS) <= wall_ms;
        if settled && let Some(card) = self.card_cache.lock().unwrap().get(&slot_start_ms) {
            return Ok(card.clone());
        }

        let mut rows = self.slot_moment_rows(slot_start_ms, slot_end_ms)?;
        // The second fact stream. Fetched before the frame loop because the
        // join happens inside it, against each frame's own tree, and an empty
        // stream must leave that loop exactly as it was: a slot with no events
        // is not a degraded card, it is the card this pipeline always built.
        let mut events =
            acts::parse_events(&self.input_events_between(slot_start_ms, slot_end_ms)?);
        let step = capture_interval_ms.max(1_000);
        // The AX artifact is decrypted once per frame at T1 build time
        // (once per half hour). It yields the two strongest intent signals
        // (selection, composition) and, when the tree is rich enough, the
        // frame's text itself: AX text is exact where OCR guesses, and is
        // scoped to the frontmost app — the thing the user was operating,
        // not everything on screen. Measured on a real slot, the two
        // sources barely merge (60KB + 73KB ≈ 132KB combined), so this is
        // a per-frame either/or, never a blend.
        for row in &mut rows {
            if !row.ax_present {
                continue;
            }
            if let Ok(Some(bytes)) = self.accessibility_bytes_for_moment(&row.id) {
                let digest = parse_accessibility_digest(&bytes);
                row.selected_text = digest.selected_text;
                row.focused_value = digest.focused_value;
                // The geometry-bearing parse yields the same line vector as
                // `accessibility_text_lines` by construction — one traversal —
                // so the text-source decision below still counts every line.
                // Partitioning must never be able to flip a frame's source.
                let tree = if events.is_empty() {
                    None
                } else {
                    accessibility_scope_tree(&bytes)
                };
                let lines = match tree.as_ref() {
                    Some(tree) => tree.lines.clone(),
                    None => accessibility_text_lines(&bytes),
                };
                let chars: usize = lines.iter().map(|line| line.chars().count()).sum();
                if chars >= slot::AX_TEXT_MIN_CHARS {
                    row.ocr_text = Some(lines.join("\n"));
                    row.text_from_ax = true;
                }
                if let Some(tree) = tree {
                    // One pass over this frame's events serves both readers:
                    // each event learns the region it individually landed in
                    // (which is what run splitting segments on), and the frame
                    // learns the region covering all of them (which is what
                    // partitions its text).
                    let indices = acts::frame_event_indices(
                        &events,
                        row.captured_at_ms,
                        step,
                        row.bundle_identifier.as_deref(),
                    );
                    let mut rects = Vec::with_capacity(indices.len());
                    for index in indices {
                        let Some(rect) = events[index].frame else {
                            continue;
                        };
                        rects.push(rect);
                        if events[index].scope.is_none() {
                            events[index].scope = acts::event_scope(&tree, rect);
                        }
                    }
                    row.ax_join = acts::join_frame(&tree, &rects);
                }
            }
        }
        let materialized = if events.is_empty() {
            self.slot_acts(slot_start_ms)?
        } else {
            None
        };
        // R3 edge trees: the content the heartbeat missed between two ticks.
        // Only fetched when there is an event stream to partition by — with no
        // events they would be text the card never used to have and could not
        // attribute. They expire with the events, so history loses both at once.
        let edges = if events.is_empty() {
            Vec::new()
        } else {
            self.edge_frames_between(slot_start_ms, slot_end_ms, step, &events)?
        };
        let idle_ms = self.idle_overlap_ms(slot_start_ms, slot_end_ms)?;
        let card = slot::build_slot_card_with_edges(
            slot_start_ms,
            slot_end_ms,
            &rows,
            idle_ms,
            capture_interval_ms,
            &events,
            materialized.as_ref(),
            &edges,
        );
        if settled {
            let mut cache = self.card_cache.lock().unwrap();
            if cache.len() >= Self::CARD_CACHE_CAP {
                cache.clear();
            }
            cache.insert(slot_start_ms, card.clone());
        }
        Ok(card)
    }

    /// Decrypts the slot's R3 edge trees and joins each against the events it
    /// can speak for — the same hit-test the frame loop runs, on trees that have
    /// no frame.
    ///
    /// A tree that will not decrypt or parse is skipped, not raised: an edge
    /// snapshot is an addition to a card, and losing one must never cost the
    /// card. Unlike the frame loop this does **not** write resolved scopes back
    /// onto the events: run splitting segments on those scopes, and R3's job is
    /// to widen the text a run shows, not to re-cut the runs.
    fn edge_frames_between(
        &self,
        from_ms: i64,
        to_ms: i64,
        step_ms: i64,
        events: &[acts::ActEvent],
    ) -> Result<Vec<slot::EdgeFrame>, StoreError> {
        let stored = self.edge_snapshots_between(from_ms, to_ms)?;
        let mut frames = Vec::with_capacity(stored.len());
        for row in stored {
            let Ok(payload) = self.read_artifact(&row.artifact_id) else {
                continue;
            };
            let Some(tree) = accessibility_scope_tree(&payload.bytes) else {
                continue;
            };
            let bundle = activity::parse_accessibility_context(&payload.bytes).bundle_identifier;
            let rects: Vec<acts::AxRect> =
                acts::frame_event_indices(events, row.captured_at_ms, step_ms, bundle.as_deref())
                    .into_iter()
                    .filter_map(|index| events[index].frame)
                    .collect();
            frames.push(slot::EdgeFrame {
                captured_at_ms: row.captured_at_ms,
                join: acts::join_frame(&tree, &rects),
                lines: tree.lines,
            });
        }
        Ok(frames)
    }

    /// Every path that removes moments must call this: a cached card for a
    /// half hour whose frames were deleted would resurrect them.
    fn flush_card_cache(&self) {
        self.card_cache.lock().unwrap().clear();
    }

    /// Folds up to `max_slots` closed-but-uncounted slots into the text DF
    /// corpus, oldest first, and returns how many were processed. Called
    /// repeatedly from a background task until it returns 0; each call is one
    /// short transaction, so a cold-start backfill never blocks a reader.
    ///
    /// A slot enters the corpus once, decided by the watermark. Only closed
    /// slots count — the half hour still being written must not see itself
    /// in its own background.
    ///
    /// # Errors
    ///
    /// Returns an error if the vault cannot be read or written.
    pub fn advance_text_df(
        &self,
        now_ms: i64,
        capture_interval_ms: i64,
        max_slots: usize,
    ) -> Result<usize, StoreError> {
        const BACKFILL_REACH_MS: i64 = 14 * 24 * 60 * 60 * 1000;
        let current_slot = self.summary_slot_bounds(now_ms).start_ms;
        let floor = now_ms.saturating_sub(BACKFILL_REACH_MS);
        let mut watermark = {
            let connection = self.connection.lock().unwrap();
            let mut statement =
                connection.prepare("SELECT watermark_ms FROM text_df_meta WHERE id = 1")?;
            let mut rows = statement.query([])?;
            match rows.next()? {
                Some(row) => row.get::<_, i64>(0)?,
                None => self.summary_slot_bounds(floor).start_ms,
            }
        }
        .max(self.summary_slot_bounds(floor).start_ms);

        let mut processed = 0_usize;
        while processed < max_slots {
            let bounds = self.summary_slot_bounds(watermark);
            if bounds.end_ms > current_slot.min(now_ms) {
                break; // only slots that have fully closed
            }
            let slot_start = bounds.start_ms;
            watermark = bounds.end_ms;
            let rows = self.slot_moment_rows(slot_start, bounds.end_ms)?;
            let (line_keys, tokens) = slot::df_contribution(&rows);
            let connection = self.connection.lock().unwrap();
            let tx = connection.unchecked_transaction()?;
            {
                let mut upsert = tx.prepare_cached(
                    "INSERT INTO text_df (kind, key, df, last_seen_ms) VALUES (?1, ?2, 1, ?3)
                     ON CONFLICT(kind, key) DO UPDATE SET
                       df = df + 1, last_seen_ms = excluded.last_seen_ms",
                )?;
                for key in &line_keys {
                    upsert.execute(params![0_i64, key, slot_start])?;
                }
                for token in &tokens {
                    upsert.execute(params![1_i64, token, slot_start])?;
                }
            }
            let occupied = i64::from(!line_keys.is_empty() || !tokens.is_empty());
            tx.execute(
                "INSERT INTO text_df_meta (id, watermark_ms, slot_count)
                 VALUES (1, ?1, ?2)
                 ON CONFLICT(id) DO UPDATE SET
                   watermark_ms = excluded.watermark_ms,
                   slot_count = text_df_meta.slot_count + ?2",
                params![watermark, occupied],
            )?;
            tx.commit()?;
            processed += 1;
        }
        let _ = capture_interval_ms; // rows query is interval-independent
        Ok(processed)
    }

    /// Batch DF lookup for exactly the keys and tokens one card needs.
    /// Loading the whole corpus would be megabytes; a card asks after a few
    /// thousand strings.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn background_stats(
        &self,
        card: &slot::SlotCard,
    ) -> Result<infoscore::BackgroundStats, StoreError> {
        let (line_keys, tokens) = slot::card_df_queries(card);
        let connection = self.readers.get();
        let (slots, watermark_ms) = {
            let mut statement = connection
                .prepare("SELECT slot_count, watermark_ms FROM text_df_meta WHERE id = 1")?;
            let mut rows = statement.query([])?;
            match rows.next()? {
                Some(row) => (row.get::<_, i64>(0)?, row.get::<_, i64>(1)?),
                None => (0, i64::MIN),
            }
        };
        let mut stats = infoscore::BackgroundStats {
            slots: u32::try_from(slots.max(0)).unwrap_or(u32::MAX),
            corpus_includes_slot: card.slot_end_ms <= watermark_ms,
            line_df: HashMap::new(),
            token_df: HashMap::new(),
        };
        let mut lookup =
            connection.prepare_cached("SELECT df FROM text_df WHERE kind = ?1 AND key = ?2")?;
        for key in line_keys {
            if let Some(df) = lookup
                .query_row(params![0_i64, &key], |row| row.get::<_, i64>(0))
                .optional()?
            {
                stats
                    .line_df
                    .insert(key, u32::try_from(df.max(0)).unwrap_or(u32::MAX));
            }
        }
        for token in tokens {
            if let Some(df) = lookup
                .query_row(params![1_i64, &token], |row| row.get::<_, i64>(0))
                .optional()?
            {
                stats
                    .token_df
                    .insert(token, u32::try_from(df.max(0)).unwrap_or(u32::MAX));
            }
        }
        Ok(stats)
    }

    /// Persists a successful T2 card. Re-running the same slot increments
    /// `generation` so a later model swap can tell the row is stale.
    ///
    /// # Errors
    ///
    /// Returns an error if the row cannot be written.
    pub fn put_t2_summary(
        &self,
        card: &slot::SlotCard,
        t2: &slot::T2Card,
        producer: &str,
        produced_at_ms: i64,
        latency_ms: Option<i64>,
    ) -> Result<(), StoreError> {
        let facts_json = serde_json::to_string(&card.facts).unwrap_or_else(|_| "{}".to_owned());
        let artifacts_json = serde_json::to_string(&t2.artifacts).ok();
        let bullets_json = serde_json::to_string(&t2.bullets).ok();
        let evidence_json =
            serde_json::to_string(&card.evidence).unwrap_or_else(|_| "{}".to_owned());
        let id = Uuid::now_v7().to_string();
        self.connection.lock().unwrap().execute(
            "INSERT INTO slot_summaries (
                id, slot_start_ms, slot_end_ms, local_day, state, generation, schema_version,
                facts_json, theme_key, artifacts_json, title, bullets_json, category, confidence,
                evidence_json, producer, produced_at_ms, latency_ms
             ) VALUES (
                ?1, ?2, ?3, ?4, 'done', 1, ?5,
                ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                ?13, ?14, ?15, ?16
             )
             ON CONFLICT(slot_start_ms) DO UPDATE SET
                slot_end_ms = excluded.slot_end_ms,
                local_day = excluded.local_day,
                state = excluded.state,
                generation = slot_summaries.generation + 1,
                schema_version = excluded.schema_version,
                facts_json = excluded.facts_json,
                theme_key = excluded.theme_key,
                artifacts_json = excluded.artifacts_json,
                title = excluded.title,
                bullets_json = excluded.bullets_json,
                category = excluded.category,
                confidence = excluded.confidence,
                evidence_json = excluded.evidence_json,
                producer = excluded.producer,
                produced_at_ms = excluded.produced_at_ms,
                latency_ms = excluded.latency_ms,
                description = NULL,
                details = NULL,
                threads_json = NULL,
                entities_json = NULL,
                decisions_json = NULL,
                not_captured_json = NULL",
            params![
                id,
                card.slot_start_ms,
                card.slot_end_ms,
                card.local_day,
                LEGACY_SLOT_SUMMARY_SCHEMA_VERSION,
                facts_json,
                card.theme_key,
                artifacts_json,
                t2.title.trim(),
                bullets_json,
                t2.category.as_deref(),
                t2.confidence,
                evidence_json,
                producer,
                produced_at_ms,
                latency_ms,
            ],
        )?;
        Ok(())
    }

    /// Persists a v3 card: title, description, and the Markdown body.
    ///
    /// Written through `put_t2_summary` first, exactly like v2 — that write
    /// nulls every column belonging to another card shape, so a slot
    /// re-summarised across a version change never keeps half of its old card.
    /// Bullets are derived from the body's headings so every v1 reader keeps
    /// working without the model writing a list it no longer has a field for.
    ///
    /// # Errors
    ///
    /// Returns an error if the row cannot be written.
    pub fn put_t2_summary_v3(
        &self,
        card: &slot::SlotCard,
        t2: &slot::T2CardV3,
        producer: &str,
        produced_at_ms: i64,
        latency_ms: Option<i64>,
    ) -> Result<(), StoreError> {
        let compat = slot::T2Card {
            artifacts: Vec::new(),
            title: t2.title.clone(),
            bullets: t2.derived_bullets(),
            category: None,
            confidence: None,
        };
        self.put_t2_summary(card, &compat, producer, produced_at_ms, latency_ms)?;
        self.connection.lock().unwrap().execute(
            "UPDATE slot_summaries SET
                schema_version = ?2,
                description = ?3,
                details = ?4
              WHERE slot_start_ms = ?1",
            params![
                card.slot_start_ms,
                SLOT_SUMMARY_SCHEMA_VERSION,
                t2.description.trim(),
                t2.details.trim(),
            ],
        )?;
        Ok(())
    }

    /// Persists a v2 card. Bullets are derived from threads so every v1
    /// reader — the day panel, old CLI output — keeps working unchanged.
    ///
    /// Kept for the cards already on disk and for any caller still producing
    /// the JSON shape; the T2 loop writes v3.
    ///
    /// # Errors
    ///
    /// Returns an error if the row cannot be written.
    pub fn put_t2_summary_v2(
        &self,
        card: &slot::SlotCard,
        t2: &slot::T2CardV2,
        producer: &str,
        produced_at_ms: i64,
        latency_ms: Option<i64>,
    ) -> Result<(), StoreError> {
        let compat = slot::T2Card {
            artifacts: Vec::new(),
            title: t2.title.clone(),
            bullets: t2.derived_bullets(),
            category: t2.category.clone(),
            confidence: t2.confidence,
        };
        self.put_t2_summary(card, &compat, producer, produced_at_ms, latency_ms)?;
        self.connection.lock().unwrap().execute(
            "UPDATE slot_summaries SET
                schema_version = ?2,
                description = ?3,
                threads_json = ?4,
                entities_json = ?5,
                decisions_json = ?6,
                not_captured_json = ?7
              WHERE slot_start_ms = ?1",
            params![
                card.slot_start_ms,
                V2_SLOT_SUMMARY_SCHEMA_VERSION,
                t2.description.trim(),
                serde_json::to_string(&t2.threads).ok(),
                serde_json::to_string(&t2.entities).ok(),
                serde_json::to_string(&t2.decisions).ok(),
                serde_json::to_string(&t2.not_captured).ok(),
            ],
        )?;
        Ok(())
    }

    /// Neighbouring cards, oldest first: title **and** description.
    ///
    /// Fed to the next T2 pass as the context to continue from, and as a
    /// negative constraint so adjacent cards do not copy each other's wording.
    /// The description rides along because the tool that used to serve these
    /// was never called by any measured model, and a bare title cannot say
    /// what the previous stretch left unfinished.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn previous_slot_titles(
        &self,
        before_start_ms: i64,
        limit: usize,
    ) -> Result<Vec<slot::PrevCard>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT slot_start_ms, title, description FROM slot_summaries
              WHERE title IS NOT NULL AND TRIM(title) != '' AND slot_start_ms < ?1
              ORDER BY slot_start_ms DESC
              LIMIT ?2",
        )?;
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows = statement.query_map(params![before_start_ms, limit], |row| {
            let start_ms: i64 = row.get(0)?;
            let title: String = row.get(1)?;
            let description: Option<String> = row.get(2)?;
            Ok(slot::PrevCard {
                from_label: slot::slot_clock_label(start_ms),
                title,
                description: description.unwrap_or_default(),
            })
        })?;
        let mut cards = rows.collect::<Result<Vec<_>, _>>()?;
        cards.reverse();
        Ok(cards)
    }

    /// Counts the durable background backlog.
    ///
    /// Three counts in one call because the dashboard shows them together, and
    /// each is a scan the panel must not repeat per row. Callers should cache
    /// the result for a few seconds rather than issuing it per poll —
    /// `unindexed_moments` walks `moments` against `text_evidence`.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError`] when the vault cannot be queried.
    pub fn compute_backlog(
        &self,
        now_ms: i64,
        policy: &PackPolicy,
    ) -> Result<ComputeBacklog, StoreError> {
        let archive_stills = packable_frame_count(
            &self.list_pack_candidates_read(now_ms, policy)?,
            policy.keyint,
        );
        let connection = self.readers.get();
        let transcripts: i64 = connection.query_row(
            &format!(
                "SELECT count(*) FROM audio_segments a WHERE {AUDIO_CLAIMABLE_PREDICATE}"
            ),
            [now_ms],
            |row| row.get(0),
        )?;
        // Two bounds, both deliberate. A minute of grace so a frame whose OCR is
        // in flight is not counted as neglected — at a ten-second capture
        // interval that would otherwise report a permanent backlog of one or
        // two. And a lookback window, because nothing drains old un-OCR'd frames
        // (there is no OCR backlog) and an unbounded `NOT EXISTS` probe per row
        // would scan the whole of `moments` on every dashboard refresh — three
        // million rows on a year-old vault.
        let unindexed_moments: i64 = connection.query_row(
            "SELECT count(*) FROM moments m
              WHERE m.image_artifact_id IS NOT NULL
                AND m.gop_segment_id IS NULL
                AND m.captured_at_ms <= ?1
                AND m.captured_at_ms >= ?2
                AND NOT EXISTS (
                    SELECT 1 FROM text_evidence te
                     WHERE te.moment_id = m.id AND te.source = 'ocr'
                )",
            [
                now_ms.saturating_sub(60_000),
                now_ms.saturating_sub(UNINDEXED_LOOKBACK_MS),
            ],
            |row| row.get(0),
        )?;
        Ok(ComputeBacklog {
            archive_stills,
            transcripts: usize::try_from(transcripts).unwrap_or(0),
            unindexed_moments: usize::try_from(unindexed_moments).unwrap_or(0),
        })
    }

    /// How long the most recent summary passes took, newest first.
    ///
    /// Feeds the compute dashboard's answer to "I am slow now — how much
    /// longer?". Read once at daemon start to seed an in-memory window: the
    /// panel polls every couple of seconds, and there is no index on
    /// `produced_at_ms`, so this must not be on the polling path.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError`] when the vault cannot be queried.
    pub fn recent_summary_runs(&self, limit: usize) -> Result<Vec<SummaryRun>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT slot_start_ms, produced_at_ms, latency_ms
               FROM slot_summaries
              WHERE latency_ms IS NOT NULL AND produced_at_ms IS NOT NULL
              ORDER BY produced_at_ms DESC
              LIMIT ?1",
        )?;
        let rows = statement.query_map([i64::try_from(limit).unwrap_or(20)], |row| {
            Ok(SummaryRun {
                slot_start_ms: row.get(0)?,
                produced_at_ms: row.get(1)?,
                latency_ms: row.get(2)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// The stored summary covering `at_ms`, if a model has titled it.
    ///
    /// Keyed off the row's own `slot_end_ms` rather than recomputed bounds, so
    /// callers never have to know whether this vault is 30- or 10-minute-wide
    /// at that instant.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn slot_title_covering(&self, at_ms: i64) -> Result<Option<(i64, String)>, StoreError> {
        let connection = self.readers.get();
        connection
            .query_row(
                "SELECT slot_start_ms, title FROM slot_summaries
                  WHERE slot_start_ms <= ?1 AND slot_end_ms > ?1
                    AND title IS NOT NULL AND TRIM(title) != ''
                  ORDER BY slot_start_ms DESC
                  LIMIT 1",
                params![at_ms],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(StoreError::from)
    }

    /// Stretches of work whose stored summary names `query`, oldest first.
    ///
    /// The index the agent had no way to ask for: answering "which Lody issues
    /// did I handle" meant reading every slot of the day and scanning the prose.
    /// The v2 card already writes grounded `entities` and named `threads`, so
    /// this searches those directly and hands back the frames they cite.
    ///
    /// `SQL LIKE` is only a prefilter — [`slot::match_slot_mention`] decides,
    /// in the same folded space `verify_t2_card` grounds entities in.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn find_slot_mentions(
        &self,
        query: &str,
        filter: &SearchFilter,
        limit: usize,
    ) -> Result<Vec<slot::SlotMention>, StoreError> {
        let Some(pattern) = like_prefilter(query) else {
            return Ok(Vec::new());
        };
        // Wider than `limit` so the exact match below has slack when a `LIKE`
        // hit turns out not to be one, and capped so a one-letter query cannot
        // walk a year of summaries.
        let candidate_limit = i64::try_from(limit.saturating_mul(8).clamp(limit, 400)).unwrap_or(400);
        let connection = self.readers.get();
        // The candidate window is chosen by **match kind first, recency
        // second, across the whole filtered range**. Ordering by recency alone
        // and ranking afterwards ranked only the survivors: with four hundred
        // recent summaries mentioning a long-running project in passing, the
        // one old summary that recorded it as a grounded entity fell outside
        // the window and became unreachable, however small the limit.
        //
        // Both the test and the rank read **values**, through `json_each`, not
        // the serialised JSON around them. `entities_json LIKE '%text%'`
        // matched the `"text"` key on every card that had any entity at all,
        // and `threads_json` did the same for `"name"` and `"prose"`: ordinary
        // words to search for, and each one filled the window with rows that
        // `match_slot_mention` then discarded — reaching nothing while
        // reporting nothing, for exactly the terms a person would try.
        //
        // `details` is raw Markdown, not JSON, so a `LIKE` on it *is* a value
        // test — there are no serde key names inside it to match by accident.
        // It is in the gate because a v3 card keeps its whole body there: left
        // out, every card written after v3 would be findable by title alone.
        let mut statement = connection.prepare(&format!(
            "SELECT slot_start_ms, slot_end_ms, local_day, title,
                    threads_json, entities_json, decisions_json, details
               FROM slot_summaries
              WHERE schema_version >= ?1
                AND (?2 IS NULL OR slot_start_ms >= ?2)
                AND (?3 IS NULL OR slot_start_ms <= ?3)
                -- Cheap superset gate, so the per-value tests below only run
                -- on rows that could possibly match: a value containing the
                -- pattern implies the raw JSON does too.
                AND (title LIKE ?4 ESCAPE '\\'
                     OR threads_json LIKE ?4 ESCAPE '\\'
                     OR entities_json LIKE ?4 ESCAPE '\\'
                     OR details LIKE ?4 ESCAPE '\\')
                AND (title LIKE ?4 ESCAPE '\\' OR details LIKE ?4 ESCAPE '\\'
                     OR {ENTITY_VALUE_MATCH} OR {THREAD_VALUE_MATCH})
                AND (?6 IS NULL OR EXISTS (
                      SELECT 1 FROM moments frame
                       WHERE frame.captured_at_ms >= slot_start_ms
                         AND frame.captured_at_ms < slot_end_ms
                         AND frame.application_name = ?6 COLLATE NOCASE))
              ORDER BY CASE
                         WHEN {ENTITY_VALUE_MATCH} THEN 2
                         WHEN title LIKE ?4 ESCAPE '\\' THEN 1
                         ELSE 0
                       END DESC,
                       slot_start_ms DESC
              LIMIT ?5"
        ))?;
        let rows = statement.query_map(
            params![
                // "at least v2": the gate rejects the v1 rows, which hold no
                // searchable field but their title. Bumping the *current*
                // version constant here would have un-indexed every v2 card on
                // disk the day v3 shipped.
                slot::V2_SLOT_SUMMARY_SCHEMA_VERSION,
                filter.from_ms,
                filter.to_ms,
                pattern,
                candidate_limit,
                filter.app.as_deref(),
            ],
            |row| {
                let threads: Option<String> = row.get(4)?;
                let entities: Option<String> = row.get(5)?;
                let decisions: Option<String> = row.get(6)?;
                let details: Option<String> = row.get(7)?;
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    // A v3 body enters the matcher as its own sections, so one
                    // card answers with the section that mentions the string
                    // rather than with the whole document.
                    details
                        .as_deref()
                        .map(slot::details_sections)
                        .or_else(|| threads
                        .and_then(|raw| serde_json::from_str::<Vec<slot::T2Thread>>(&raw).ok()))
                        .unwrap_or_default(),
                    entities
                        .and_then(|raw| serde_json::from_str::<Vec<slot::T2Entity>>(&raw).ok())
                        .unwrap_or_default(),
                    decisions
                        .and_then(|raw| serde_json::from_str::<Vec<String>>(&raw).ok())
                        .unwrap_or_default(),
                ))
            },
        )?;

        let mut ranked: Vec<(slot::MentionKind, slot::SlotMention)> = Vec::new();
        for row in rows {
            let (start, end, day, title, threads, entities, decisions) = row?;
            if let Some((mention, kind)) = slot::match_slot_mention(
                query,
                start,
                end,
                &day,
                title.as_deref(),
                &threads,
                &entities,
                &decisions,
            ) {
                ranked.push((kind, mention));
            }
        }
        // Rank to decide *what* survives the cut — a verbatim entity beats
        // prose that happens to contain the letters — then restore time order,
        // because what comes back is read as a timeline. The `CASE` above has
        // already ordered the candidates this way over the whole range; this
        // repeats it on the exact classification, which is what corrects a row
        // the raw-JSON `LIKE` over-ranked.
        ranked.sort_by(|a, b| {
            b.0.cmp(&a.0)
                .then(b.1.slot_start_ms.cmp(&a.1.slot_start_ms))
        });
        ranked.truncate(limit);
        ranked.sort_by_key(|(_, mention)| mention.slot_start_ms);
        Ok(ranked.into_iter().map(|(_, mention)| mention).collect())
    }

    /// Returns one slot's user-visible facts and parsed persisted `P2`. The
    /// query deliberately does not select evidence_json, artifacts, prompts,
    /// tool results, or model completion text.
    #[allow(clippy::too_many_lines)]
    pub fn slot_summary_export(
        &self,
        at_ms: i64,
        capture_interval_ms: i64,
    ) -> Result<slot::SlotSummaryExport, StoreError> {
        let card = self.slot_card(at_ms, capture_interval_ms)?;
        let connection = self.readers.get();
        let row: Option<SlotSummaryExportRow> = connection
            .query_row(
                "SELECT state, generation, schema_version, title, bullets_json, artifacts_json,
                        category, description, threads_json, entities_json,
                        decisions_json, not_captured_json, confidence, produced_at_ms, producer,
                        latency_ms, slot_end_ms, details
                   FROM slot_summaries
                  WHERE slot_start_ms = ?1",
                [card.slot_start_ms],
                |row| {
                    Ok((
                        row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?,
                        row.get(5)?, row.get(6)?, row.get(7)?, row.get(8)?, row.get(9)?,
                        row.get(10)?, row.get(11)?, row.get(12)?, row.get(13)?, row.get(14)?,
                        row.get(15)?, row.get(16)?, row.get(17)?,
                    ))
                },
            )
            .optional()?;

        let Some((
            state_raw, generation, schema_version, title, bullets_json, artifacts_json, category,
            description, threads_json, entities_json, decisions_json, not_captured_json, confidence,
            produced_at_ms, producer, latency_ms, stored_end_ms, details,
        )) = row else {
            return Ok(slot::SlotSummaryExport {
                slot_start_ms: card.slot_start_ms,
                slot_end_ms: card.slot_end_ms,
                state: slot::SlotSummaryState::from_t1(card.state),
                schema_version: None,
                summary: None,
                facts: slot::SlotExportFacts::from(&card.facts),
                generation: None,
                producer: None,
                produced_at_ms: None,
                latency_ms: None,
            });
        };

        // Three card shapes, exported as themselves. Which one a row is comes
        // from `schema_version` alone — never from which columns are null,
        // since every write path nulls the columns of the other two.
        let summary = title.as_ref().map(|title| {
            if schema_version >= slot::SLOT_SUMMARY_SCHEMA_VERSION {
                serde_json::to_value(slot::T2CardV3 {
                    title: title.clone(),
                    description: description.unwrap_or_default(),
                    details: details.unwrap_or_default(),
                    low_trust: false,
                })
                .unwrap_or(serde_json::Value::Null)
            } else if schema_version >= slot::V2_SLOT_SUMMARY_SCHEMA_VERSION {
                serde_json::to_value(slot::T2CardV2 {
                    title: title.clone(),
                    description: description.unwrap_or_default(),
                    threads: threads_json
                        .and_then(|raw| serde_json::from_str(&raw).ok())
                        .unwrap_or_default(),
                    entities: entities_json
                        .and_then(|raw| serde_json::from_str(&raw).ok())
                        .unwrap_or_default(),
                    decisions: decisions_json
                        .and_then(|raw| serde_json::from_str(&raw).ok())
                        .unwrap_or_default(),
                    not_captured: not_captured_json
                        .and_then(|raw| serde_json::from_str(&raw).ok())
                        .unwrap_or_default(),
                    category,
                    confidence,
                })
                .unwrap_or(serde_json::Value::Null)
            } else {
                serde_json::to_value(slot::T2Card {
                    artifacts: artifacts_json
                        .and_then(|raw| serde_json::from_str(&raw).ok())
                        .unwrap_or_default(),
                    title: title.clone(),
                    bullets: bullets_json
                        .and_then(|raw| serde_json::from_str(&raw).ok())
                        .unwrap_or_default(),
                    category,
                    confidence,
                })
                .unwrap_or(serde_json::Value::Null)
            }
        });
        Ok(slot::SlotSummaryExport {
            slot_start_ms: card.slot_start_ms,
            slot_end_ms: stored_end_ms.unwrap_or(card.slot_end_ms),
            state: slot::SlotSummaryState::parse(&state_raw)
                .unwrap_or(slot::SlotSummaryState::Degraded),
            schema_version: Some(schema_version),
            summary,
            facts: slot::SlotExportFacts::from(&card.facts),
            generation: Some(generation),
            producer,
            produced_at_ms,
            latency_ms,
        })
    }

    /// The day panel payload: every occupied slot that day, with T2 titles
    /// when they exist and T1 facts otherwise.
    ///
    /// AX is not decrypted here. Facts only need app names and durations;
    /// walking every tree on a 48-slot day would stall the overlay.
    ///
    /// # Errors
    ///
    /// Returns an error if the vault cannot be queried.
    pub fn day_summary(
        &self,
        day_ms: i64,
        capture_interval_ms: i64,
    ) -> Result<slot::DaySummary, StoreError> {
        let day = slot::local_day_for(day_ms);
        let (day_start_ms, day_end_ms) = slot::local_day_bounds(day_ms);
        let rows = self.slot_moment_rows(day_start_ms, day_end_ms)?;
        // One snapshot for the whole day: a geometry change landing mid-build
        // would otherwise group some rows by the old boundaries and some by
        // the new, and the day would show two overlapping slots.
        let segments = self.summary_slot_segments();
        let mut grouped: HashMap<i64, Vec<slot::SlotMomentRow>> = HashMap::new();
        for row in rows {
            let bounds = slot::slot_bounds_in(row.captured_at_ms, &segments);
            grouped
                .entry(bounds.start_ms)
                .or_default()
                .push(row);
        }
        // Slots are independent — one card's build reads nothing from
        // another's — and a day holds up to 48 of them. Building serially
        // made opening the day panel cost the sum of every slot; scoped
        // threads bound the cost by the slowest slot per lane, with the
        // reader pool serving `idle_overlap_ms` lookups concurrently.
        let mut starts: Vec<i64> = grouped.keys().copied().collect();
        starts.sort_unstable();
        let lanes = starts.len().clamp(1, 4);
        let work: Vec<(i64, Vec<slot::SlotMomentRow>)> = starts
            .iter()
            .map(|start| (*start, grouped.remove(start).unwrap_or_default()))
            .collect();
        let segments = segments.as_slice();
        let mut cards: Vec<(i64, slot::SlotCard)> = std::thread::scope(|scope| {
            let mut handles = Vec::with_capacity(lanes);
            for chunk in work.chunks(work.len().div_ceil(lanes).max(1)) {
                handles.push(scope.spawn(move || {
                    chunk
                        .iter()
                        .map(|(start, slot_rows)| {
                            let bounds = slot::slot_bounds_in(*start, segments);
                            let idle_ms = self.idle_overlap_ms(bounds.start_ms, bounds.end_ms)?;
                            Ok((
                                *start,
                                slot::build_slot_card_with_end(
                                    bounds.start_ms,
                                    bounds.end_ms,
                                    slot_rows,
                                    idle_ms,
                                    capture_interval_ms,
                                ),
                            ))
                        })
                        .collect::<Result<Vec<_>, StoreError>>()
                }));
            }
            handles
                .into_iter()
                .map(|handle| handle.join().expect("card build thread panicked"))
                .collect::<Result<Vec<_>, StoreError>>()
        })?
        .into_iter()
        .flatten()
        .collect();
        cards.sort_unstable_by_key(|(start, _)| *start);
        let cards: Vec<slot::SlotCard> = cards.into_iter().map(|(_, card)| card).collect();
        let overlays = self.slot_overlays_for_day(&day)?;
        Ok(slot::assemble_day_summary(
            day,
            day_start_ms,
            day_end_ms,
            &cards,
            &overlays,
        ))
    }

    /// A small, cursor-paginated slice of occupied local days for the history
    /// summary panel. The query only keeps one page in memory; clients pass
    /// `next_before_ms` back unchanged to continue toward older history.
    ///
    /// # Errors
    ///
    /// Returns an error if the vault cannot be queried.
    pub fn summary_history(
        &self,
        before_ms: Option<i64>,
        limit: usize,
        capture_interval_ms: i64,
    ) -> Result<slot::SummaryHistoryPage, StoreError> {
        let mut cursor = before_ms.unwrap_or(i64::MAX);
        let mut days = Vec::with_capacity(limit.clamp(1, 31));

        for _ in 0..limit.clamp(1, 31) {
            let Some(latest_ms) = self.latest_moment_before(cursor)? else {
                break;
            };
            let summary = self.day_summary(latest_ms, capture_interval_ms)?;
            // The cursor is the local midnight, rather than a fixed 24-hour
            // subtraction, so it remains correct over DST changes too.
            cursor = summary.day_start_ms;
            if !summary.slots.is_empty() {
                days.push(summary);
            }
        }

        let has_more = self.latest_moment_before(cursor)?.is_some();
        Ok(slot::SummaryHistoryPage {
            days,
            next_before_ms: has_more.then_some(cursor),
            has_more,
            total_days: Some(self.occupied_local_day_count()?),
        })
    }

    /// Distinct local calendar days that have at least one moment. Matches
    /// the days `summary_history` will eventually page — one query, not a
    /// walk of every day summary.
    fn occupied_local_day_count(&self) -> Result<usize, StoreError> {
        let connection = self.readers.get();
        let count: i64 = connection.query_row(
            "SELECT COUNT(DISTINCT date(captured_at_ms / 1000, 'unixepoch', 'localtime'))
               FROM moments",
            [],
            |row| row.get(0),
        )?;
        Ok(count.max(0) as usize)
    }

    fn latest_moment_before(&self, before_ms: i64) -> Result<Option<i64>, StoreError> {
        let connection = self.connection.lock().unwrap();
        connection
            .query_row(
                "SELECT captured_at_ms
                   FROM moments
                  WHERE captured_at_ms < ?1
                  ORDER BY captured_at_ms DESC, id DESC
                  LIMIT 1",
                params![before_ms],
                |row| row.get(0),
            )
            .optional()
            .map_err(StoreError::from)
    }

    fn slot_overlays_for_day(
        &self,
        local_day: &str,
    ) -> Result<HashMap<i64, slot::StoredSlotOverlay>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT slot_start_ms, slot_end_ms, state, schema_version, title, bullets_json, category,
                    description, threads_json, entities_json, decisions_json,
                    not_captured_json, details
               FROM slot_summaries
              WHERE local_day = ?1
              ORDER BY slot_start_ms",
        )?;
        let rows = statement.query_map(params![local_day], |row| {
            let start: i64 = row.get(0)?;
            let slot_end_ms: i64 = row.get(1)?;
            let state_raw: String = row.get(2)?;
            let schema_version: i64 = row.get(3)?;
            let title: Option<String> = row.get(4)?;
            let bullets_json: Option<String> = row.get(5)?;
            let category: Option<String> = row.get(6)?;
            let description: Option<String> = row.get(7)?;
            let threads_json: Option<String> = row.get(8)?;
            let entities_json: Option<String> = row.get(9)?;
            let decisions_json: Option<String> = row.get(10)?;
            let not_captured_json: Option<String> = row.get(11)?;
            let details: Option<String> = row.get(12)?;
            // A row's shape is its `schema_version`, never the nullness of a
            // column: "at least v2" is what carries a description, and only v3
            // carries a body. A v3 row has the v2 columns null, so reading them
            // by presence would answer "v1" for the newest card in the vault.
            let is_v2 = schema_version >= slot::V2_SLOT_SUMMARY_SCHEMA_VERSION;
            let is_v3 = schema_version >= slot::SLOT_SUMMARY_SCHEMA_VERSION;
            let parse_list =
                |json: Option<String>| json.and_then(|raw| serde_json::from_str(&raw).ok());
            let bullets = bullets_json.and_then(|json| serde_json::from_str(&json).ok());
            let description = if is_v2 {
                description.filter(|text| !text.is_empty())
            } else {
                None
            };
            let details = if is_v3 {
                details.filter(|text| !text.trim().is_empty())
            } else {
                None
            };
            let threads = if is_v2 {
                threads_json.and_then(|raw| serde_json::from_str(&raw).ok())
            } else {
                None
            };
            let entities = if is_v2 {
                entities_json.and_then(|raw| serde_json::from_str(&raw).ok())
            } else {
                None
            };
            let decisions = if is_v2 { parse_list(decisions_json) } else { None };
            let not_captured = if is_v2 { parse_list(not_captured_json) } else { None };
            Ok((
                start,
                slot::StoredSlotOverlay {
                    slot_end_ms: Some(slot_end_ms),
                    state: slot::SlotSummaryState::parse(&state_raw),
                    title,
                    bullets,
                    category,
                    description,
                    details,
                    threads,
                    entities,
                    decisions,
                    not_captured,
                },
            ))
        })?;
        rows.collect::<Result<HashMap<_, _>, _>>()
            .map_err(StoreError::from)
    }

    /// Moments in `[from_ms, to_ms)` joined with their OCR text and evidence flags.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn slot_moment_rows(
        &self,
        from_ms: i64,
        to_ms: i64,
    ) -> Result<Vec<slot::SlotMomentRow>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT m.id, m.captured_at_ms, m.application_name, m.bundle_identifier,
                    m.window_title, m.url, m.document,
                    (SELECT group_concat(te.text, '\n') FROM text_evidence te
                      WHERE te.moment_id = m.id AND te.source = 'ocr'),
                    m.accessibility_artifact_id IS NOT NULL,
                    EXISTS (SELECT 1 FROM audio_segments a
                             WHERE m.captured_at_ms BETWEEN a.started_at_ms AND a.ended_at_ms)
               FROM moments m
              WHERE m.captured_at_ms >= ?1 AND m.captured_at_ms < ?2
              ORDER BY m.captured_at_ms, m.id",
        )?;
        let rows = statement.query_map(params![from_ms, to_ms], |row| {
            Ok(slot::SlotMomentRow {
                id: row.get(0)?,
                captured_at_ms: row.get(1)?,
                application_name: row.get(2)?,
                bundle_identifier: row.get(3)?,
                window_title: row.get(4)?,
                url: row.get(5)?,
                document: row.get(6)?,
                ocr_text: row.get(7)?,
                selected_text: None,
                focused_value: None,
                text_from_ax: false,
                ax_present: row.get(8)?,
                has_audio: row.get(9)?,
                // Filled by `slot_card`, where the trees are decrypted.
                ax_join: None,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)
    }

    /// Milliseconds of `[from_ms, to_ms)` covered by recorded idle spans.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn idle_overlap_ms(&self, from_ms: i64, to_ms: i64) -> Result<i64, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT started_at_ms, ended_at_ms FROM idle_spans
              WHERE started_at_ms < ?2 AND (ended_at_ms IS NULL OR ended_at_ms > ?1)",
        )?;
        let rows = statement.query_map(params![from_ms, to_ms], |row| {
            let started: i64 = row.get(0)?;
            let ended: Option<i64> = row.get(1)?;
            Ok((started, ended.unwrap_or(to_ms)))
        })?;
        let mut total = 0_i64;
        for span in rows {
            let (started, ended) = span?;
            let overlap = ended.min(to_ms).saturating_sub(started.max(from_ms));
            total += overlap.max(0);
        }
        Ok(total.min(to_ms.saturating_sub(from_ms)))
    }

    /// Speech transcribed in a window, oldest first.
    ///
    /// Meetings are otherwise unreachable to an agent: transcripts hang off
    /// audio segments, not moments, so asking about "the call at three" has
    /// no moment id to start from.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn transcripts_in_range(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: usize,
    ) -> Result<Vec<TranscriptLine>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT te.started_at_ms, COALESCE(a.track, 'unknown'), te.text
               FROM text_evidence te
               LEFT JOIN audio_segments a ON a.id = te.audio_segment_id
              WHERE te.source = 'transcript'
                AND te.started_at_ms >= ?1 AND te.started_at_ms <= ?2
              ORDER BY te.started_at_ms
              LIMIT ?3",
        )?;
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows = statement.query_map(params![from_ms, to_ms, limit], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)
    }

    /// Moments captured in a window, oldest first. Entry points for an agent
    /// that knows a time but no ids.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn moment_ids_in_range(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: usize,
    ) -> Result<Vec<MomentAt>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT id, captured_at_ms FROM moments
              WHERE captured_at_ms >= ?1 AND captured_at_ms <= ?2
              ORDER BY captured_at_ms
              LIMIT ?3",
        )?;
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows = statement.query_map(params![from_ms, to_ms, limit], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)
    }

    /// Oldest and newest capture held by the vault, or `None` when nothing has
    /// been recorded. An agent needs this to tell a window that is genuinely
    /// quiet from one that falls outside the recording altogether.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn moment_time_bounds(&self) -> Result<Option<(i64, i64)>, StoreError> {
        let connection = self.readers.get();
        let mut statement =
            connection.prepare("SELECT MIN(captured_at_ms), MAX(captured_at_ms) FROM moments")?;
        let mut rows = statement.query([])?;
        let Some(row) = rows.next()? else {
            return Ok(None);
        };
        let first: Option<i64> = row.get(0)?;
        let last: Option<i64> = row.get(1)?;
        Ok(first.zip(last))
    }

    /// Nearest moment to `at_ms`, in either direction.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn moment_nearest(&self, at_ms: i64) -> Result<Option<String>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT id FROM moments
              ORDER BY ABS(captured_at_ms - ?1), captured_at_ms
              LIMIT 1",
        )?;
        let mut rows = statement.query(params![at_ms])?;
        Ok(match rows.next()? {
            Some(row) => Some(row.get(0)?),
            None => None,
        })
    }

    /// Creates a conversation and returns its id.
    ///
    /// # Errors
    ///
    /// Returns an error if the row cannot be written.
    pub fn create_conversation(&self, title: &str, now_ms: i64) -> Result<String, StoreError> {
        let id = Uuid::now_v7().to_string();
        self.connection.lock().unwrap().execute(
            "INSERT INTO conversations (id, title, created_at_ms, updated_at_ms)
             VALUES (?1, ?2, ?3, ?3)",
            params![id, title, now_ms],
        )?;
        Ok(id)
    }

    /// Conversations, most recently touched first.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn conversations(&self, limit: usize) -> Result<Vec<Conversation>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT c.id, c.title, c.created_at_ms, c.updated_at_ms,
                    (SELECT COUNT(*) FROM conversation_messages m
                      WHERE m.conversation_id = c.id)
               FROM conversations c
              ORDER BY c.updated_at_ms DESC
              LIMIT ?1",
        )?;
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let rows = statement.query_map(params![limit], |row| {
            Ok(Conversation {
                id: row.get(0)?,
                title: row.get(1)?,
                created_at_ms: row.get(2)?,
                updated_at_ms: row.get(3)?,
                message_count: usize::try_from(row.get::<_, i64>(4)?).unwrap_or(0),
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)
    }

    /// One conversation by id, if it exists.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn conversation(&self, id: &str) -> Result<Option<Conversation>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT c.id, c.title, c.created_at_ms, c.updated_at_ms,
                    (SELECT COUNT(*) FROM conversation_messages m
                      WHERE m.conversation_id = c.id)
               FROM conversations c
              WHERE c.id = ?1",
        )?;
        let mut rows = statement.query(params![id])?;
        Ok(match rows.next()? {
            Some(row) => Some(Conversation {
                id: row.get(0)?,
                title: row.get(1)?,
                created_at_ms: row.get(2)?,
                updated_at_ms: row.get(3)?,
                message_count: usize::try_from(row.get::<_, i64>(4)?).unwrap_or(0),
            }),
            None => None,
        })
    }

    /// Appends a message and bumps the conversation's updated timestamp.
    ///
    /// # Errors
    ///
    /// Returns an error if either write fails.
    pub fn append_message(
        &self,
        conversation_id: &str,
        role: &str,
        content: &str,
        tool_log: Option<&str>,
        now_ms: i64,
    ) -> Result<String, StoreError> {
        let id = Uuid::now_v7().to_string();
        let connection = self.connection.lock().unwrap();
        connection.execute(
            "INSERT INTO conversation_messages
               (id, conversation_id, role, content, tool_log, created_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, conversation_id, role, content, tool_log, now_ms],
        )?;
        connection.execute(
            "UPDATE conversations SET updated_at_ms = ?2 WHERE id = ?1",
            params![conversation_id, now_ms],
        )?;
        Ok(id)
    }

    /// Overwrites a message's body as a turn produces it.
    ///
    /// The row is inserted empty when the stream opens and updated as it runs,
    /// so an interrupted turn leaves what it had rather than nothing. Callers
    /// throttle: this is a write per call, and a token-rate write would spend
    /// the whole turn in `SQLite`.
    ///
    /// # Errors
    ///
    /// Returns an error if the update fails.
    pub fn update_message(
        &self,
        id: &str,
        update: &MessageUpdate<'_>,
    ) -> Result<(), StoreError> {
        let connection = self.connection.lock().unwrap();
        connection.execute(
            "UPDATE conversation_messages
                SET content = ?2, tool_log = ?3, reasoning = ?4, status = ?5, usage_json = ?6
              WHERE id = ?1",
            params![
                id,
                update.content,
                update.tool_log,
                update.reasoning,
                update.status,
                update.usage_json
            ],
        )?;
        Ok(())
    }

    /// Marks every row still flagged `streaming` as stopped.
    ///
    /// Run at startup: a row in that state means the daemon died mid-turn, and
    /// nothing will ever finish it. Leaving it would show a permanently live
    /// spinner in the thread.
    ///
    /// # Errors
    ///
    /// Returns an error if the update fails.
    pub fn settle_orphaned_streams(&self) -> Result<usize, StoreError> {
        let connection = self.connection.lock().unwrap();
        let changed = connection.execute(
            "UPDATE conversation_messages SET status = ?1 WHERE status = ?2",
            params![
                afterray_protocol::MESSAGE_STATUS_ABORTED,
                afterray_protocol::MESSAGE_STATUS_STREAMING
            ],
        )?;
        Ok(changed)
    }

    /// Messages of one conversation in order.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn conversation_messages(
        &self,
        conversation_id: &str,
    ) -> Result<Vec<ConversationMessage>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT id, conversation_id, role, content, tool_log, created_at_ms,
                    reasoning, status, usage_json
               FROM conversation_messages
              WHERE conversation_id = ?1
              ORDER BY created_at_ms, id",
        )?;
        let rows = statement.query_map(params![conversation_id], |row| {
            Ok(ConversationMessage {
                id: row.get(0)?,
                conversation_id: row.get(1)?,
                role: row.get(2)?,
                content: row.get(3)?,
                tool_log: row.get(4)?,
                created_at_ms: row.get(5)?,
                reasoning: row.get(6)?,
                status: row.get(7)?,
                usage_json: row.get(8)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)
    }

    /// Renames a conversation — used to replace the placeholder title with
    /// one derived from the opening question.
    ///
    /// # Errors
    ///
    /// Returns an error if the update fails.
    pub fn rename_conversation(&self, id: &str, title: &str) -> Result<(), StoreError> {
        self.connection.lock().unwrap().execute(
            "UPDATE conversations SET title = ?2 WHERE id = ?1",
            params![id, title],
        )?;
        Ok(())
    }

    /// Deletes a conversation and, by cascade, its messages.
    ///
    /// # Errors
    ///
    /// Returns an error if the delete fails.
    pub fn delete_conversation(&self, id: &str) -> Result<(), StoreError> {
        self.connection
            .lock()
            .unwrap()
            .execute("DELETE FROM conversations WHERE id = ?1", params![id])?;
        Ok(())
    }

    pub fn begin_idle_span(&self, started_at_ms: i64, reason: &str) -> Result<String, StoreError> {
        let connection = self.connection.lock().unwrap();
        let open: Option<String> = connection
            .query_row(
                "SELECT id FROM idle_spans WHERE ended_at_ms IS NULL ORDER BY started_at_ms DESC LIMIT 1",
                [],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(id) = open {
            return Ok(id);
        }
        let id = Uuid::now_v7().to_string();
        connection.execute(
            "INSERT INTO idle_spans (id, started_at_ms, reason) VALUES (?1, ?2, ?3)",
            params![id, started_at_ms, reason],
        )?;
        Ok(id)
    }

    pub fn end_open_idle_spans(&self, ended_at_ms: i64) -> Result<usize, StoreError> {
        let changed = self.connection.lock().unwrap().execute(
            "UPDATE idle_spans SET ended_at_ms = ?1 WHERE ended_at_ms IS NULL",
            [ended_at_ms],
        )?;
        Ok(changed)
    }

    pub fn idle_spans_sync(&self) -> Result<Vec<(String, i64, Option<i64>, String)>, StoreError> {
        let connection = self.connection.lock().unwrap();
        let mut statement = connection.prepare(
            "SELECT id, started_at_ms, ended_at_ms, reason FROM idle_spans ORDER BY started_at_ms",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn delete_moment_and_artifacts(&self, moment_id: &str) -> Result<(), StoreError> {
        self.flush_card_cache();
        let connection = self.connection.lock().unwrap();
        let artifacts: Vec<Option<String>> = connection.query_row(
            "SELECT image_artifact_id, accessibility_artifact_id, thumbnail_artifact_id
               FROM moments WHERE id = ?1",
            [moment_id],
            |row| Ok(vec![row.get(0)?, row.get(1)?, row.get(2)?]),
        )?;
        connection.execute(
            "DELETE FROM evidence_fts WHERE evidence_id IN
             (SELECT id FROM text_evidence WHERE moment_id = ?1)",
            [moment_id],
        )?;
        connection.execute("DELETE FROM moments WHERE id = ?1", [moment_id])?;
        drop(connection);
        for artifact_id in artifacts.into_iter().flatten() {
            self.delete_artifact_record_and_file(&artifact_id)?;
        }
        Ok(())
    }

    pub fn insert_memory(&self, memory: &Memory) -> Result<(), StoreError> {
        self.connection.lock().unwrap().execute(
            "INSERT INTO memories
             (id, start_ms, end_ms, moment_id, application_name, bundle_identifier,
              window_title, url, document, summary, fingerprint, model_version)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![
                memory.id,
                memory.start_ms,
                memory.end_ms,
                memory.moment_id,
                memory.application_name,
                memory.bundle_identifier,
                memory.window_title,
                memory.url,
                memory.document,
                memory.summary,
                memory.fingerprint,
                "local"
            ],
        )?;
        Ok(())
    }

    pub fn memories(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: usize,
    ) -> Result<Vec<Memory>, StoreError> {
        if limit == 0 || from_ms > to_ms {
            return Ok(Vec::new());
        }
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT id, start_ms, end_ms, moment_id, application_name, bundle_identifier,
                    window_title, url, document, summary, fingerprint
               FROM memories
              WHERE start_ms <= ?2 AND end_ms >= ?1
              ORDER BY start_ms ASC, id ASC
              LIMIT ?3",
        )?;
        let rows = statement.query_map(
            params![from_ms, to_ms, i64::try_from(limit).unwrap_or(40)],
            memory_from_row,
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn latest_memory(&self) -> Result<Option<Memory>, StoreError> {
        let connection = self.readers.get();
        connection
            .query_row(
                "SELECT id, start_ms, end_ms, moment_id, application_name, bundle_identifier,
                        window_title, url, document, summary, fingerprint
                   FROM memories ORDER BY end_ms DESC, id DESC LIMIT 1",
                [],
                memory_from_row,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn delete_history(&self, from_ms: i64, to_ms: i64) -> Result<usize, StoreError> {
        self.flush_card_cache();
        if from_ms > to_ms {
            return Ok(0);
        }
        let ids: Vec<String> = {
            let connection = self.connection.lock().unwrap();
            let mut statement = connection.prepare(
                "SELECT id FROM moments WHERE captured_at_ms >= ?1 AND captured_at_ms <= ?2",
            )?;
            let rows = statement.query_map(params![from_ms, to_ms], |row| row.get(0))?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        let count = ids.len();
        for id in ids {
            self.delete_moment_and_artifacts(&id)?;
        }
        self.connection.lock().unwrap().execute(
            "DELETE FROM memories WHERE start_ms <= ?2 AND end_ms >= ?1",
            params![from_ms, to_ms],
        )?;
        // A leftover card after the evidence is gone is both a privacy leak
        // and a hallucination source for the next T2 pass.
        self.connection.lock().unwrap().execute(
            "DELETE FROM slot_summaries
              WHERE slot_start_ms <= ?2 AND slot_end_ms > ?1",
            params![from_ms, to_ms],
        )?;
        // Same invariant one layer down: the events say what the user did in
        // the window they just asked to forget, in finer detail than any frame.
        self.connection.lock().unwrap().execute(
            "DELETE FROM input_events
              WHERE at_ms <= ?2 AND MAX(at_ms, COALESCE(end_ms, at_ms)) >= ?1",
            params![from_ms, to_ms],
        )?;
        // And the fourth layer: an R3 tree is a full window's worth of text
        // from inside the forgotten window, attached to no moment, so no
        // frame deletion above can have reached it.
        let edges: Vec<(String, String)> = {
            let connection = self.connection.lock().unwrap();
            let mut statement = connection.prepare(
                "SELECT id, artifact_id FROM edge_snapshots
                  WHERE captured_at_ms >= ?1 AND captured_at_ms <= ?2",
            )?;
            let rows = statement.query_map(params![from_ms, to_ms], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        self.delete_edge_snapshots(&edges)?;
        Ok(count)
    }

    /// Appends a batch of the shim's input observations.
    ///
    /// One transaction for the whole batch: the shim coalesces and ships events
    /// in groups, and a half-stored group is worse than none, because T1 would
    /// then join against a stream whose gap is invisible — reading "the user did
    /// nothing here" off a failed write is exactly the inference this pipeline
    /// exists to avoid.
    ///
    /// # Errors
    ///
    /// Returns an error when the batch cannot be committed.
    pub fn insert_input_events(&self, events: &[InputEventRow]) -> Result<usize, StoreError> {
        if events.is_empty() {
            return Ok(0);
        }
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection.transaction()?;
        {
            let mut statement = transaction.prepare(
                "INSERT INTO input_events
                   (at_ms, end_ms, kind, count, ended_with, command,
                    bundle_identifier, target_json, text, extra_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            )?;
            for event in events {
                statement.execute(params![
                    event.at_ms,
                    event.end_ms,
                    event.kind,
                    event.count,
                    event.ended_with,
                    event.command,
                    event.bundle_identifier,
                    event.target_json,
                    event.text,
                    event.extra_json,
                ])?;
            }
        }
        transaction.commit()?;
        Ok(events.len())
    }

    /// Every observation overlapping `[from_ms, to_ms)`, oldest first.
    ///
    /// Half-open like slot bounds, so consecutive slots partition the stream
    /// without double-counting an instant. A span (`end_ms` set) counts as
    /// present whenever any part of it falls inside the window — a burst that
    /// began before the slot opened is still typing that happened in the slot.
    /// `end_ms` absent makes the row a point at `at_ms`; a nonsensical
    /// `end_ms < at_ms` from a future shim degrades to the same point rather
    /// than vanishing.
    ///
    /// # Errors
    ///
    /// Returns an error when the vault cannot be queried.
    pub fn input_events_between(
        &self,
        from_ms: i64,
        to_ms: i64,
    ) -> Result<Vec<InputEventRow>, StoreError> {
        if from_ms >= to_ms {
            return Ok(Vec::new());
        }
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT at_ms, end_ms, kind, count, ended_with, command,
                    bundle_identifier, target_json, text, extra_json
               FROM input_events
              WHERE at_ms < ?2 AND MAX(at_ms, COALESCE(end_ms, at_ms)) >= ?1
              ORDER BY at_ms ASC, id ASC",
        )?;
        let rows = statement.query_map(params![from_ms, to_ms], |row| {
            Ok(InputEventRow {
                at_ms: row.get(0)?,
                end_ms: row.get(1)?,
                kind: row.get(2)?,
                count: row.get(3)?,
                ended_with: row.get(4)?,
                command: row.get(5)?,
                bundle_identifier: row.get(6)?,
                target_json: row.get(7)?,
                text: row.get(8)?,
                extra_json: row.get(9)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// The acts frozen for a slot, if any were.
    ///
    /// Read only when the live event stream comes back empty: while the events
    /// exist they are the truth, and the frozen copy is a summary of them. After
    /// 48 hours they are gone and this is all that is left.
    ///
    /// # Errors
    ///
    /// Returns an error when the vault cannot be queried.
    pub fn slot_acts(&self, slot_start_ms: i64) -> Result<Option<acts::MaterializedActs>, StoreError> {
        let connection = self.readers.get();
        let raw: Option<Option<String>> = connection
            .query_row(
                "SELECT acts_json FROM slot_summaries WHERE slot_start_ms = ?1",
                params![slot_start_ms],
                |row| row.get(0),
            )
            .optional()?;
        // A row without acts and no row at all are the same answer here; a
        // stored blob this build cannot parse degrades to "no acts" rather than
        // failing a card build.
        Ok(raw
            .flatten()
            .and_then(|json| serde_json::from_str(&json).ok()))
    }

    /// Freezes a sealed slot's acts into `slot_summaries.acts_json`.
    ///
    /// Events are deleted after 48 hours and T1 is computed lazily, so without
    /// this the acts of every slot older than two days would simply vanish —
    /// the card would silently lose the half of itself that says what the user
    /// did, while keeping the half that says what was on screen.
    ///
    /// Idempotent by design: a slot that already has acts is left alone, so the
    /// five-minute sweeper can revisit it forever at the cost of one indexed
    /// read. Returns whether anything was written.
    ///
    /// The caller decides what "sealed" means — it owns the clock.
    ///
    /// # Errors
    ///
    /// Returns an error when the vault cannot be read or written.
    pub fn materialize_slot_acts(
        &self,
        at_ms: i64,
        capture_interval_ms: i64,
    ) -> Result<bool, StoreError> {
        let bounds = self.summary_slot_bounds(at_ms);
        if self.slot_acts(bounds.start_ms)?.is_some() {
            return Ok(false);
        }
        if self
            .input_events_between(bounds.start_ms, bounds.end_ms)?
            .is_empty()
        {
            // Nothing to freeze. Deliberately not written as an empty record:
            // "no events were ever stored" and "the events said nothing" are
            // different claims, and only the second one is a fact.
            return Ok(false);
        }
        let card = self.slot_card(at_ms, capture_interval_ms)?;
        let frozen = acts::MaterializedActs {
            runs: card
                .timeline
                .iter()
                .filter_map(|entry| match entry {
                    slot::TimelineEntry::Run(run) => Some(run),
                    slot::TimelineEntry::Gap(_) => None,
                })
                .filter_map(|run| {
                    Some(acts::MaterializedRun {
                        id: run.moment_id.clone(),
                        acts: run.acts.clone()?,
                    })
                })
                .collect(),
            no_input_ratio: card.facts.no_input_ratio,
        };
        if frozen.runs.is_empty() && frozen.no_input_ratio.is_none() {
            return Ok(false);
        }
        // Plain counts and labels: this cannot fail. If it somehow did, losing
        // the freeze is better than failing the sweep that also freezes others.
        let Ok(json) = serde_json::to_string(&frozen) else {
            return Ok(false);
        };
        self.put_slot_acts(&card, &json)?;
        Ok(true)
    }

    /// Writes the frozen acts, creating the summary row when a model has not
    /// written one yet.
    ///
    /// A row created here carries `degraded` and no title, which is what the day
    /// panel already renders for a slot T2 has not summarised: the panel takes
    /// its state from the live card, and a titleless row for a slot with no
    /// frames is skipped outright. So this cannot conjure a phantom slot, and it
    /// cannot stop T2 from running later.
    ///
    /// The `WHERE acts_json IS NULL` guard makes a concurrent second sweep a
    /// no-op rather than a rewrite.
    fn put_slot_acts(&self, card: &slot::SlotCard, acts_json: &str) -> Result<(), StoreError> {
        let facts_json = serde_json::to_string(&card.facts).unwrap_or_else(|_| "{}".to_owned());
        let evidence_json =
            serde_json::to_string(&card.evidence).unwrap_or_else(|_| "{}".to_owned());
        self.connection.lock().unwrap().execute(
            "INSERT INTO slot_summaries (
                id, slot_start_ms, slot_end_ms, local_day, state, generation,
                schema_version, facts_json, evidence_json, acts_json
             ) VALUES (?1, ?2, ?3, ?4, 'degraded', 1, ?5, ?6, ?7, ?8)
             ON CONFLICT(slot_start_ms) DO UPDATE SET
                acts_json = excluded.acts_json
              WHERE slot_summaries.acts_json IS NULL",
            params![
                Uuid::now_v7().to_string(),
                card.slot_start_ms,
                card.slot_end_ms,
                card.local_day,
                slot::SLOT_SUMMARY_SCHEMA_VERSION,
                facts_json,
                evidence_json,
                acts_json,
            ],
        )?;
        Ok(())
    }

    /// Slot starts in `[from_ms, to_ms)` that hold input events but no frozen
    /// acts yet — the sweeper's work list.
    ///
    /// Answered from the event table rather than from the frames, because the
    /// events are what expires: a slot with no events has nothing to lose.
    ///
    /// # Errors
    ///
    /// Returns an error when the vault cannot be queried.
    pub fn slots_missing_acts(&self, from_ms: i64, to_ms: i64) -> Result<Vec<i64>, StoreError> {
        if from_ms >= to_ms {
            return Ok(Vec::new());
        }
        let events = self.input_events_between(from_ms, to_ms)?;
        // Every slot an observation *touches*, not just the one it started in.
        // A burst that begins at 09:59:58 and ends at 10:00:20 belongs to both,
        // and enqueueing only its start would leave the second slot unfrozen —
        // it would then fail open forever once the events expired, silently
        // dropping acts the user did perform.
        let mut starts: Vec<i64> = Vec::new();
        for event in &events {
            let last_ms = event.end_ms.unwrap_or(event.at_ms).max(event.at_ms);
            let mut cursor = event.at_ms;
            loop {
                let bounds = self.summary_slot_bounds(cursor);
                starts.push(bounds.start_ms);
                // `summary_slot_bounds` always advances, so this terminates on
                // any span; a clock jump cannot spin it.
                if bounds.end_ms <= cursor || bounds.end_ms > last_ms {
                    break;
                }
                cursor = bounds.end_ms;
            }
        }
        starts.sort_unstable();
        starts.dedup();
        let mut due = Vec::new();
        for start in starts {
            if self.slot_acts(start)?.is_none() {
                due.push(start);
            }
        }
        Ok(due)
    }

    /// Drops observations whose span ended before `horizon_ms`.
    ///
    /// The horizon is the vault's retention edge — the oldest frame it still
    /// holds — not a clock deadline. Since the trust model changed
    /// (`docs/event-capture-v2-plan.md` §信任模型变更) the events are content
    /// like any other capture, so they keep the company of the frames they were
    /// recorded beside: what the user did in a stretch survives exactly as long
    /// as what was on screen during it. Markers go too — a `signal_gap` over a
    /// stretch that has no frames left has nothing left to qualify.
    ///
    /// A span is judged by its end, so a burst reaching past the horizon
    /// survives even when it started before it.
    ///
    /// # Errors
    ///
    /// Returns an error when the delete cannot be executed.
    pub fn prune_input_events_before(&self, horizon_ms: i64) -> Result<usize, StoreError> {
        let removed = self.connection.lock().unwrap().execute(
            "DELETE FROM input_events WHERE MAX(at_ms, COALESCE(end_ms, at_ms)) < ?1",
            [horizon_ms],
        )?;
        Ok(removed)
    }

    /// Drops `signal_gap` markers older than [`SIGNAL_MARKER_RETENTION_MS`].
    ///
    /// Markers only. The observations themselves are captured content and
    /// expire with the rest of it, oldest-first, inside
    /// [`Self::enforce_retention`]: the 48h channel that once took the whole
    /// table now takes only the recorder's own bookkeeping. This one still
    /// hangs off the clock because a marker's whole meaning is a deadline — it
    /// says "between here and there, nothing could be seen", and once the cards
    /// for that stretch exist it has said it.
    ///
    /// A span is judged by its end, and the cutoff instant itself is kept.
    ///
    /// # Errors
    ///
    /// Returns an error when the delete cannot be executed.
    pub fn prune_signal_gaps(&self, now_ms: i64) -> Result<usize, StoreError> {
        let cutoff = now_ms.saturating_sub(SIGNAL_MARKER_RETENTION_MS);
        let removed = self.connection.lock().unwrap().execute(
            "DELETE FROM input_events
              WHERE kind = ?2 AND MAX(at_ms, COALESCE(end_ms, at_ms)) < ?1",
            params![cutoff, acts::SIGNAL_GAP_KIND],
        )?;
        Ok(removed)
    }

    /// Stores one R3 edge snapshot: the encrypted tree plus its row.
    ///
    /// No moment, no thumbnail, no OCR job — an edge snapshot is not a frame of
    /// the screen. The artifact is written under
    /// [`EDGE_SNAPSHOT_CONTENT_TYPE`], and a failed row insert takes the
    /// artifact back out with it: an orphaned encrypted file would be
    /// unreachable and unprunable, since pruning walks the rows.
    ///
    /// # Errors
    ///
    /// Returns an error when the artifact cannot be written or the row inserted.
    pub fn insert_edge_snapshot(
        &self,
        captured_at_ms: i64,
        snapshot: &[u8],
    ) -> Result<EdgeSnapshotRow, StoreError> {
        let prepared = ax_compress::prepare_accessibility_artifact(snapshot);
        let artifact_id = self.put_artifact(EDGE_SNAPSHOT_CONTENT_TYPE, &prepared)?;
        let row = EdgeSnapshotRow {
            id: Uuid::now_v7().to_string(),
            captured_at_ms,
            artifact_id,
        };
        let result = self.connection.lock().unwrap().execute(
            "INSERT INTO edge_snapshots (id, captured_at_ms, artifact_id)
             VALUES (?1, ?2, ?3)",
            params![row.id, row.captured_at_ms, row.artifact_id],
        );
        if let Err(error) = result {
            let _ = self.delete_artifact_record_and_file(&row.artifact_id);
            return Err(error.into());
        }
        // A card already cached for this slot was built without this tree.
        self.flush_card_cache();
        Ok(row)
    }

    /// Edge snapshots captured in `[from_ms, to_ms)`, oldest first.
    ///
    /// Half-open like slot bounds and like `input_events_between`, so
    /// consecutive slots partition the stream without one tree landing in two
    /// cards. A snapshot is a point in time — it has no span to overlap with.
    ///
    /// # Errors
    ///
    /// Returns an error when the vault cannot be queried.
    pub fn edge_snapshots_between(
        &self,
        from_ms: i64,
        to_ms: i64,
    ) -> Result<Vec<EdgeSnapshotRow>, StoreError> {
        if from_ms >= to_ms {
            return Ok(Vec::new());
        }
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT id, captured_at_ms, artifact_id
               FROM edge_snapshots
              WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
              ORDER BY captured_at_ms ASC, id ASC",
        )?;
        let rows = statement.query_map(params![from_ms, to_ms], |row| {
            Ok(EdgeSnapshotRow {
                id: row.get(0)?,
                captured_at_ms: row.get(1)?,
                artifact_id: row.get(2)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Drops edge snapshots captured before `horizon_ms`, files and all.
    ///
    /// The same horizon as [`Self::prune_input_events_before`] and for the same
    /// reason: an R3 tree is keyframe content now, not ephemera, so it lives as
    /// long as the frames of its era and goes when they go. It used to share
    /// the events' 48 hours, which was the right answer while the events were
    /// the shortest-lived thing in the vault; now that they are not, following
    /// them would make the trees the *longest*-lived, which is the opposite of
    /// what that rule was for.
    ///
    /// # Errors
    ///
    /// Returns an error when the vault cannot be read or written.
    pub fn prune_edge_snapshots_before(&self, horizon_ms: i64) -> Result<usize, StoreError> {
        let doomed: Vec<(String, String)> = {
            let connection = self.connection.lock().unwrap();
            let mut statement = connection.prepare(
                "SELECT id, artifact_id FROM edge_snapshots WHERE captured_at_ms < ?1",
            )?;
            let rows = statement.query_map([horizon_ms], |row| Ok((row.get(0)?, row.get(1)?)))?;
            rows.collect::<Result<Vec<_>, _>>()?
        };
        if doomed.is_empty() {
            return Ok(0);
        }
        self.delete_edge_snapshots(&doomed)?;
        Ok(doomed.len())
    }

    /// Removes edge snapshot rows and their encrypted files.
    ///
    /// The row goes first: a row pointing at a missing file is a decrypt error
    /// on some later read, while a file with no row is invisible to every
    /// prune and stays on disk forever.
    fn delete_edge_snapshots(&self, rows: &[(String, String)]) -> Result<(), StoreError> {
        self.flush_card_cache();
        {
            let connection = self.connection.lock().unwrap();
            for (id, _) in rows {
                connection.execute("DELETE FROM edge_snapshots WHERE id = ?1", [id])?;
            }
        }
        for (_, artifact_id) in rows {
            self.delete_artifact_record_and_file(artifact_id)?;
        }
        Ok(())
    }

    pub fn audio_segments_sync(&self, session_id: &str) -> Result<Vec<AudioSegment>, StoreError> {
        let connection = self.connection.lock().unwrap();
        let mut statement = connection.prepare(
            "SELECT id, session_id, track, started_at_ms, ended_at_ms, audio_artifact_id
             FROM audio_segments WHERE session_id = ?1 ORDER BY started_at_ms",
        )?;
        let rows = statement.query_map([session_id], |row| {
            let track: String = row.get(2)?;
            Ok(AudioSegment {
                id: row.get(0)?,
                session_id: row.get(1)?,
                track: if track == "microphone" {
                    AudioTrack::Microphone
                } else {
                    AudioTrack::System
                },
                started_at_ms: row.get(3)?,
                ended_at_ms: row.get(4)?,
                audio_artifact_id: row.get(5)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Claims one durable ASR item. Work left `running` by a daemon crash is
    /// eligible again after five minutes.
    ///
    /// # Errors
    ///
    /// Returns an error when the queue transaction cannot be read or committed.
    pub fn claim_audio_transcription(
        &self,
        now_ms: i64,
    ) -> Result<Option<ClaimedAudioTranscription>, StoreError> {
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection.transaction()?;
        transaction.execute(
            "UPDATE audio_segments SET transcription_state = 'pending'
              WHERE transcription_state = 'running'
                AND transcription_updated_at_ms <= ?1",
            [now_ms.saturating_sub(5 * 60 * 1_000)],
        )?;
        let candidate = transaction
            .query_row(
                &format!(
                    "SELECT a.id, a.session_id, a.track, a.started_at_ms, a.ended_at_ms,
                            a.audio_artifact_id, a.transcription_attempts
                       FROM audio_segments a
                      WHERE {AUDIO_CLAIMABLE_PREDICATE}
                  ORDER BY a.started_at_ms, a.id LIMIT 1"),
                [now_ms],
                |row| {
                    let track: String = row.get(2)?;
                    Ok(ClaimedAudioTranscription {
                        segment: AudioSegment {
                            id: row.get(0)?,
                            session_id: row.get(1)?,
                            track: if track == "microphone" {
                                AudioTrack::Microphone
                            } else {
                                AudioTrack::System
                            },
                            started_at_ms: row.get(3)?,
                            ended_at_ms: row.get(4)?,
                            audio_artifact_id: row.get(5)?,
                        },
                        attempts: row.get::<_, u32>(6)?.saturating_add(1),
                    })
                },
            )
            .optional()?;
        if let Some(claimed) = &candidate {
            transaction.execute(
                "UPDATE audio_segments
                    SET transcription_state = 'running',
                        transcription_attempts = transcription_attempts + 1,
                        transcription_updated_at_ms = ?2,
                        transcription_error = NULL
                  WHERE id = ?1",
                params![claimed.segment.id, now_ms],
            )?;
        }
        transaction.commit()?;
        Ok(candidate)
    }

    /// Persists an ASR failure and its next eligible retry time.
    ///
    /// # Errors
    ///
    /// Returns an error when the queue row cannot be updated.
    pub fn fail_audio_transcription(
        &self,
        segment_id: &str,
        error: &str,
        next_attempt_ms: i64,
        now_ms: i64,
    ) -> Result<(), StoreError> {
        self.connection.lock().unwrap().execute(
            "UPDATE audio_segments
                SET transcription_state = 'failed', transcription_error = ?2,
                    transcription_next_attempt_ms = ?3, transcription_updated_at_ms = ?4
              WHERE id = ?1",
            params![segment_id, error, next_attempt_ms, now_ms],
        )?;
        Ok(())
    }

    /// Makes every failed ASR item immediately eligible after a model repair.
    ///
    /// # Errors
    ///
    /// Returns an error when the queue rows cannot be updated.
    pub fn retry_failed_audio_transcriptions(&self, now_ms: i64) -> Result<usize, StoreError> {
        self.connection.lock().unwrap().execute(
            "UPDATE audio_segments
                SET transcription_state = 'pending', transcription_next_attempt_ms = ?1
              WHERE transcription_state = 'failed'",
            [now_ms],
        ).map_err(Into::into)
    }

    /// Whether any audio overlapping `from_ms..=to_ms` is still owed a
    /// transcript.
    ///
    /// The question a summariser asks before writing a card it can never
    /// revise: "is there a transcript still coming for this window?". Overlap
    /// is inclusive at both ends, matching every other audio range query here —
    /// a segment straddling the boundary carries the words spoken inside it.
    ///
    /// `false` also covers "there is no audio here at all", which is what makes
    /// this safe to ask per slot without first asking whether the slot has any
    /// audio.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError`] when the vault cannot be queried.
    pub fn has_untranscribed_audio_between(
        &self,
        from_ms: i64,
        to_ms: i64,
    ) -> Result<bool, StoreError> {
        let connection = self.readers.get();
        let found: Option<i64> = connection
            .query_row(
                &format!(
                    "SELECT 1 FROM audio_segments a
                      WHERE a.started_at_ms <= ?2 AND a.ended_at_ms >= ?1
                        AND {AUDIO_UNTRANSCRIBED_PREDICATE}
                      LIMIT 1"
                ),
                params![from_ms, to_ms],
                |row| row.get(0),
            )
            .optional()?;
        Ok(found.is_some())
    }

    /// Whether transcription is getting anywhere, vault-wide.
    ///
    /// Global on purpose: ASR is one worker with one model behind it, so its
    /// health is not a property of any slot, and a caller sweeping a backlog
    /// should pay for this once rather than per slot.
    ///
    /// "Success" is `transcription_state = 'done'` rather than the presence of
    /// transcript evidence: `done` is written only by
    /// [`Vault::complete_audio_transcription`] (and, at schema 21, to rows that
    /// already had evidence), so it means exactly "the worker returned" —
    /// including the healthy case where what it returned was silence. Keying on
    /// evidence alone would report a perfectly working ASR as never having
    /// succeeded on a quiet machine.
    ///
    /// Both instants are clamped to `now_ms`. A row stamped in the future — a
    /// clock that moved backwards, a vault carried between machines — would
    /// otherwise look eternally fresh to any staleness test downstream.
    ///
    /// # Errors
    ///
    /// Returns [`StoreError`] when the vault cannot be queried.
    pub fn asr_health(&self, now_ms: i64) -> Result<AsrHealth, StoreError> {
        let connection = self.readers.get();
        let last_success_ms: Option<i64> = connection.query_row(
            "SELECT max(transcription_updated_at_ms) FROM audio_segments
              WHERE transcription_state = 'done'",
            [],
            |row| row.get(0),
        )?;
        let last_failure_ms: Option<i64> = connection.query_row(
            "SELECT max(transcription_updated_at_ms) FROM audio_segments
              WHERE transcription_error IS NOT NULL",
            [],
            |row| row.get(0),
        )?;
        // A migrated row (schema 21) carries the column default, 0. Reading
        // that as "succeeded at the epoch" is right: it says nothing about
        // whether ASR works *now*, and every staleness test treats it as stale.
        let (waiting_segments, exhausted_segments) = connection.query_row(
            &format!(
                "SELECT count(*), sum(a.transcription_attempts >= ?1)
                   FROM audio_segments a WHERE {AUDIO_UNTRANSCRIBED_PREDICATE}"
            ),
            [AUDIO_BACKOFF_SATURATION_ATTEMPTS],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, Option<i64>>(1)?.unwrap_or_default(),
                ))
            },
        )?;
        Ok(AsrHealth {
            last_success_ms: last_success_ms.map(|at| at.min(now_ms)),
            last_failure_ms: last_failure_ms.map(|at| at.min(now_ms)),
            waiting_segments: usize::try_from(waiting_segments).unwrap_or_default(),
            exhausted_segments: usize::try_from(exhausted_segments).unwrap_or_default(),
        })
    }

    /// Commits transcript evidence and marks the audio item done atomically.
    /// Replaying a recovered claim is idempotent.
    ///
    /// # Errors
    ///
    /// Returns an error when transcript evidence or queue state cannot be
    /// committed.
    pub fn complete_audio_transcription(
        &self,
        segment: &AudioSegment,
        text: &str,
        model_version: &str,
        now_ms: i64,
    ) -> Result<Option<String>, StoreError> {
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection.transaction()?;
        let existing: Option<String> = transaction.query_row(
            "SELECT id FROM text_evidence
              WHERE audio_segment_id = ?1 AND source = 'transcript'
              ORDER BY id LIMIT 1",
            [&segment.id],
            |row| row.get(0),
        ).optional()?;
        let evidence_id = if text.trim().is_empty() || existing.is_some() {
            None
        } else {
            let id = Uuid::now_v7().to_string();
            transaction.execute(
                "INSERT INTO text_evidence
                 (id, session_id, moment_id, audio_segment_id, source, text, started_at_ms,
                  ended_at_ms, model_version, layout_json)
                 VALUES (?1, ?2, NULL, ?3, 'transcript', ?4, ?5, ?6, ?7, NULL)",
                params![id, segment.session_id, segment.id, text, segment.started_at_ms,
                    segment.ended_at_ms, model_version],
            )?;
            transaction.execute(
                "INSERT INTO evidence_fts (evidence_id, text) VALUES (?1, ?2)",
                params![id, index_text(text)],
            )?;
            Some(id)
        };
        transaction.execute(
            "UPDATE audio_segments
                SET transcription_state = 'done', transcription_error = NULL,
                    transcription_next_attempt_ms = 0, transcription_updated_at_ms = ?2
              WHERE id = ?1",
            params![segment.id, now_ms],
        )?;
        transaction.commit()?;
        Ok(evidence_id)
    }

    pub fn set_favorite(&self, moment_id: &str, favorite: bool) -> Result<(), StoreError> {
        self.connection.lock().unwrap().execute(
            "UPDATE moments SET is_favorite = ?2 WHERE id = ?1",
            params![moment_id, favorite],
        )?;
        if !favorite {
            self.enforce_retention()?;
        }
        Ok(())
    }

    pub fn insert_text_evidence(
        &self,
        session_id: &str,
        moment_id: Option<&str>,
        audio_segment_id: Option<&str>,
        source: &str,
        text: &str,
        started_at_ms: i64,
        ended_at_ms: Option<i64>,
        model_version: &str,
        // Optional JSON array of OCR regions (Vision-normalized boxes).
        layout_json: Option<&str>,
    ) -> Result<String, StoreError> {
        let id = Uuid::now_v7().to_string();
        let connection = self.connection.lock().unwrap();
        connection.execute(
            "INSERT INTO text_evidence
             (id, session_id, moment_id, audio_segment_id, source, text, started_at_ms, ended_at_ms,
              model_version, layout_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                id,
                session_id,
                moment_id,
                audio_segment_id,
                source,
                text,
                started_at_ms,
                ended_at_ms,
                model_version,
                layout_json
            ],
        )?;
        connection.execute(
            "INSERT INTO evidence_fts (evidence_id, text) VALUES (?1, ?2)",
            params![id, index_text(text)],
        )?;
        Ok(id)
    }

    /// Artifact holding this moment's filmstrip thumbnail, if one was built.
    pub fn thumbnail_artifact_id(&self, moment_id: &str) -> Result<Option<String>, StoreError> {
        self.readers
            .get()
            .query_row(
                "SELECT thumbnail_artifact_id FROM moments WHERE id = ?1",
                [moment_id],
                |row| row.get(0),
            )
            .optional()
            .map(Option::flatten)
            .map_err(Into::into)
    }

    /// Stores (or replaces) a moment's thumbnail and returns the artifact id.
    ///
    /// Thumbnails outlive the still they came from: `drop_unpinned_stills`
    /// deletes the full-resolution JPEG once a moment is packed into a cold
    /// GOP, and nothing on the Rust side can decode AV1 to rebuild one.
    pub fn set_thumbnail(&self, moment_id: &str, bytes: &[u8]) -> Result<String, StoreError> {
        let previous = self.thumbnail_artifact_id(moment_id)?;
        let artifact_id = self.put_artifact(THUMBNAIL_CONTENT_TYPE, bytes)?;
        let updated = self.connection.lock().unwrap().execute(
            "UPDATE moments SET thumbnail_artifact_id = ?2 WHERE id = ?1",
            params![moment_id, artifact_id],
        );
        match updated {
            Ok(0) => {
                // The moment was evicted while the thumbnail was encoding.
                let _ = self.delete_artifact_record_and_file(&artifact_id);
                return Err(StoreError::MomentNotFound(moment_id.to_owned()));
            }
            Ok(_) => {}
            Err(error) => {
                let _ = self.delete_artifact_record_and_file(&artifact_id);
                return Err(error.into());
            }
        }
        if let Some(previous) = previous {
            self.delete_artifact_record_and_file(&previous)?;
        }
        Ok(artifact_id)
    }

    /// Returns OCR layout JSON for a moment, if an OCR evidence row stored boxes.
    pub fn ocr_layout_for_moment(&self, moment_id: &str) -> Result<Option<String>, StoreError> {
        let connection = self.connection.lock().unwrap();
        connection
            .query_row(
                "SELECT layout_json FROM text_evidence
                  WHERE moment_id = ?1 AND source = 'ocr' AND layout_json IS NOT NULL
                  ORDER BY started_at_ms DESC, id DESC
                  LIMIT 1",
                [moment_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(Into::into)
    }

    /// OCR text + optional layout JSON for a moment.
    pub fn ocr_evidence_for_moment(
        &self,
        moment_id: &str,
    ) -> Result<Option<(String, Option<String>)>, StoreError> {
        let connection = self.readers.get();
        connection
            .query_row(
                "SELECT text, layout_json FROM text_evidence
                  WHERE moment_id = ?1 AND source = 'ocr'
                  ORDER BY started_at_ms DESC, id DESC
                  LIMIT 1",
                [moment_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn moment_by_id(&self, moment_id: &str) -> Result<Option<Moment>, StoreError> {
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT m.id, m.session_id, m.captured_at_ms, m.image_artifact_id, m.is_favorite,
                    (SELECT group_concat(te.text, '\n') FROM text_evidence te WHERE te.moment_id = m.id AND te.source = 'ocr'),
                    (SELECT group_concat(te.text, '\n')
                       FROM text_evidence te
                       JOIN audio_segments audio ON audio.id = te.audio_segment_id
                      WHERE audio.session_id = m.session_id
                        AND m.captured_at_ms BETWEEN audio.started_at_ms AND audio.ended_at_ms
                        AND te.source = 'transcript'),
                    (SELECT audio.audio_artifact_id
                       FROM audio_segments audio
                      WHERE audio.session_id = m.session_id
                        AND audio.started_at_ms <= m.captured_at_ms + 30000
                        AND audio.ended_at_ms >= m.captured_at_ms - 30000
                      ORDER BY CASE audio.track WHEN 'system' THEN 0 ELSE 1 END,
                        audio.started_at_ms DESC
                      LIMIT 1),
                    (SELECT audio.started_at_ms
                       FROM audio_segments audio
                      WHERE audio.session_id = m.session_id
                        AND audio.started_at_ms <= m.captured_at_ms + 30000
                        AND audio.ended_at_ms >= m.captured_at_ms - 30000
                      ORDER BY CASE audio.track WHEN 'system' THEN 0 ELSE 1 END,
                        audio.started_at_ms DESC
                      LIMIT 1),
                    m.accessibility_artifact_id,
                    m.application_name,
                    m.bundle_identifier,
                    m.window_title,
                    m.url,
                    m.document,
                    m.gop_segment_id,
                    m.gop_index,
                    m.still_origin,
                    (SELECT gs.frame_count FROM gop_segments gs WHERE gs.id = m.gop_segment_id)
             FROM moments m WHERE m.id = ?1",
        )?;
        statement
            .query_row([moment_id], moment_from_row)
            .optional()
            .map_err(Into::into)
    }

    /// Decrypted accessibility snapshot bytes for a moment, if present.
    pub fn accessibility_bytes_for_moment(
        &self,
        moment_id: &str,
    ) -> Result<Option<Vec<u8>>, StoreError> {
        let Some(moment) = self.moment_by_id(moment_id)? else {
            return Ok(None);
        };
        let Some(artifact_id) = moment.accessibility_artifact_id else {
            return Ok(None);
        };
        let payload = self.read_artifact(&artifact_id)?;
        Ok(Some(payload.bytes.clone()))
    }

    /// Exact-text search over every indexed evidence row.
    ///
    /// The query is folded by [`match_query`] so it speaks the same bigram
    /// dialect the index was written in, and so FTS5 operators the user did not
    /// mean to type cannot reach the parser.
    pub fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>, StoreError> {
        self.search_filtered(query, &SearchFilter::default(), limit)
    }

    /// Full-text search narrowed to a time range and an application.
    ///
    /// The narrowing happens **in SQL**, which is a correctness property and
    /// not only a speed one. Ranking then filtering — take the best `n` in the
    /// whole vault, drop the ones outside the range — answers "the best
    /// matches, if any happen to fall in this month" when the question was
    /// "the best matches in this month". A term used often enough to fill the
    /// ranking with recent hits made older ones unreachable: the tool returned
    /// nothing while the evidence sat in the vault.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn search_filtered(
        &self,
        query: &str,
        filter: &SearchFilter,
        limit: usize,
    ) -> Result<Vec<SearchHit>, StoreError> {
        let Some(expression) = match_query(query) else {
            return Ok(Vec::new());
        };
        let connection = self.readers.get();
        let mut statement = connection.prepare(
            "SELECT COALESCE(
                       te.moment_id,
                       (SELECT m.id FROM moments m
                        WHERE m.session_id = te.session_id
                          AND m.captured_at_ms <= te.started_at_ms
                        ORDER BY m.captured_at_ms DESC, m.id ASC
                        LIMIT 1),
                       ''
                    ),
                    te.session_id, te.started_at_ms, te.source, te.text,
                    bm25(evidence_fts)
             FROM evidence_fts
             JOIN text_evidence te ON te.id = evidence_fts.evidence_id
             LEFT JOIN moments frame ON frame.id = te.moment_id
             WHERE evidence_fts MATCH ?1
               AND (?3 IS NULL OR te.started_at_ms >= ?3)
               AND (?4 IS NULL OR te.started_at_ms <= ?4)
               AND (?5 IS NULL OR frame.application_name = ?5 COLLATE NOCASE)
             ORDER BY bm25(evidence_fts), te.started_at_ms DESC, te.id ASC
             LIMIT ?2",
        )?;
        let rows = statement.query_map(
            params![
                expression,
                i64::try_from(limit).unwrap_or(20),
                filter.from_ms,
                filter.to_ms,
                filter.app.as_deref(),
            ],
            |row| {
                Ok(SearchHit {
                    moment_id: row.get(0)?,
                    session_id: row.get(1)?,
                    captured_at_ms: row.get(2)?,
                    source: row.get(3)?,
                    text: row.get(4)?,
                    score: (-row.get::<_, f64>(5)?) as f32,
                })
            },
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn insert_embedding(
        &self,
        evidence_id: &str,
        vector: &[f32],
        model_version: &str,
    ) -> Result<(), StoreError> {
        validate_embedding(vector)?;
        self.connection.lock().unwrap().execute(
            "INSERT OR REPLACE INTO embeddings (evidence_id, vector_json, model_version)
             VALUES (?1, ?2, ?3)",
            params![
                evidence_id,
                serde_json::to_string(vector)
                    .map_err(|error| StoreError::InvalidEmbedding(error.to_string()))?,
                model_version
            ],
        )?;
        Ok(())
    }

    /// Finds evidence recorded with the same embedding adapter as the query.
    ///
    /// Only neighbours at or above [`SEMANTIC_MIN_SIMILARITY`] come back. A
    /// ranked list with no floor is not a search result — it is the whole
    /// corpus in a helpful order — and every caller here presents its output as
    /// matches, to the user or to a model that will cite them.
    ///
    /// V0 performs the cosine scan in Rust. This is intentionally simple and
    /// keeps the storage contract portable until corpus size justifies an ANN
    /// index.
    pub fn semantic_search(
        &self,
        query_vector: &[f32],
        model_version: &str,
        limit: usize,
    ) -> Result<Vec<SearchHit>, StoreError> {
        validate_embedding(query_vector)?;
        let connection = self.connection.lock().unwrap();
        let mut statement = connection.prepare(
            "SELECT COALESCE(
                       te.moment_id,
                       (SELECT m.id FROM moments m
                        WHERE m.session_id = te.session_id
                          AND m.captured_at_ms <= te.started_at_ms
                        ORDER BY m.captured_at_ms DESC, m.id ASC
                        LIMIT 1),
                       ''
                    ),
                    te.session_id, te.started_at_ms, te.source, te.text, e.vector_json
             FROM embeddings e
             JOIN text_evidence te ON te.id = e.evidence_id
             WHERE e.model_version = ?1
             ORDER BY te.started_at_ms DESC, te.id ASC",
        )?;
        let rows = statement.query_map([model_version], |row| {
            Ok((
                SearchHit {
                    moment_id: row.get(0)?,
                    session_id: row.get(1)?,
                    captured_at_ms: row.get(2)?,
                    source: row.get(3)?,
                    text: row.get(4)?,
                    score: 0.0,
                },
                row.get::<_, String>(5)?,
            ))
        })?;

        let mut hits = Vec::new();
        for row in rows {
            let (mut hit, encoded) = row?;
            let vector: Vec<f32> = serde_json::from_str(&encoded)
                .map_err(|error| StoreError::InvalidEmbedding(error.to_string()))?;
            // Old vectors can have another dimension after a model upgrade.
            if vector.len() != query_vector.len() {
                continue;
            }
            let Some(score) = cosine_similarity(query_vector, &vector) else {
                continue;
            };
            if score < SEMANTIC_MIN_SIMILARITY {
                continue;
            }
            hit.score = score;
            hits.push(hit);
        }
        sort_hits(&mut hits);
        hits.truncate(limit);
        Ok(hits)
    }

    pub fn session_text(&self, session_id: &str) -> Result<String, StoreError> {
        let connection = self.connection.lock().unwrap();
        let mut statement = connection.prepare(
            "SELECT source, text FROM text_evidence WHERE session_id = ?1 ORDER BY started_at_ms",
        )?;
        let rows = statement.query_map([session_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        let mut output = String::new();
        for row in rows {
            let (source, text) = row?;
            output.push_str(&source);
            output.push_str(": ");
            output.push_str(&text);
            output.push('\n');
        }
        Ok(output)
    }

    pub fn read_artifact(&self, id: &str) -> Result<ArtifactPayload, StoreError> {
        // Shared lock: many UI reads decrypt at once. Writers take the exclusive
        // side so a put/delete/migrate cannot race a reader mid-file.
        let _artifact_guard = self.artifact_io.read().unwrap();
        let metadata: Option<ArtifactRecordMetadata> = {
            let connection = self.readers.get();
            connection
                .query_row(
                    "SELECT content_type, format_version, wrapped_key, wrapping_nonce
                       FROM artifacts WHERE id = ?1",
                    [id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
                )
                .optional()?
        };
        let (content_type, format_version, wrapped_key, wrapping_nonce) =
            metadata.ok_or_else(|| StoreError::ArtifactNotFound(id.to_owned()))?;
        if format_version < ARTIFACT_FORMAT_VERSION {
            let legacy_key = self
                .legacy_artifact_key
                .lock()
                .unwrap()
                .as_ref()
                .map(|key| Zeroizing::new(**key))
                .ok_or(StoreError::Crypto)?;
            let encrypted = fs::read(self.legacy_artifact_path(id))?;
            let bytes = decrypt_legacy_artifact(&legacy_key, id, &content_type, &encrypted)?;
            return Ok(ArtifactPayload {
                id: id.to_owned(),
                content_type,
                bytes: ax_compress::maybe_zstd_decompress(bytes.to_vec()),
            });
        }
        if format_version != ARTIFACT_FORMAT_VERSION {
            return Err(StoreError::Crypto);
        }
        let wrapped_key = wrapped_key.ok_or(StoreError::Crypto)?;
        let wrapping_nonce = wrapping_nonce.ok_or(StoreError::Crypto)?;
        let encrypted = fs::read(self.artifact_path(id))?;
        let bytes = decrypt_artifact(
            &self.artifact_wrap_key,
            id,
            &content_type,
            &encrypted,
            &wrapped_key,
            &wrapping_nonce,
        )?;
        Ok(ArtifactPayload {
            id: id.to_owned(),
            content_type,
            bytes: ax_compress::maybe_zstd_decompress(bytes.to_vec()),
        })
    }

    fn put_artifact(&self, content_type: &str, bytes: &[u8]) -> Result<String, StoreError> {
        let _artifact_guard = self.artifact_io.write().unwrap();
        let staged = self.stage_artifact_unlocked(content_type, bytes)?;
        let result = self.connection.lock().unwrap().execute(
            "INSERT INTO artifacts (
                 id, content_type, byte_length, format_version, wrapped_key, wrapping_nonce
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                staged.id,
                staged.content_type,
                staged.byte_length,
                ARTIFACT_FORMAT_VERSION,
                staged.wrapped_dek,
                staged.wrapping_nonce,
            ],
        );
        if let Err(error) = result {
            self.discard_staged_artifact(&staged.id);
            return Err(error.into());
        }
        Ok(staged.id)
    }

    /// Encrypt and write the artifact file. The DEK is not in SQL until the
    /// caller inserts `artifacts` in the same transaction as the claim.
    fn stage_artifact_unlocked(
        &self,
        content_type: &str,
        bytes: &[u8],
    ) -> Result<StagedArtifact, StoreError> {
        let id = Uuid::now_v7().to_string();
        let encrypted = encrypt_artifact(&self.artifact_wrap_key, &id, content_type, bytes)?;
        let final_path = self.artifact_path(&id);
        atomic_write_private(&final_path, &encrypted.bytes)?;
        Ok(StagedArtifact {
            id,
            content_type: content_type.to_owned(),
            byte_length: i64::try_from(bytes.len()).unwrap_or(i64::MAX),
            wrapped_dek: encrypted.wrapped_dek,
            wrapping_nonce: encrypted.wrapping_nonce.to_vec(),
        })
    }

    pub(crate) fn discard_staged_artifact(&self, id: &str) {
        let _ = fs::remove_file(self.artifact_path(id));
    }

    /// Drop IVF artifacts whose wrapped DEK never made it into a GOP segment.
    pub fn cleanup_unreferenced_gop_artifacts(&self) -> Result<usize, StoreError> {
        let orphan_ids: Vec<String> = {
            let connection = self.connection.lock().unwrap();
            let mut statement = connection.prepare(
                "SELECT id FROM artifacts
                  WHERE content_type LIKE 'video/x-ivf%'
                    AND id NOT IN (
                        SELECT artifact_id FROM gop_segments WHERE artifact_id IS NOT NULL
                    )",
            )?;
            statement
                .query_map([], |row| row.get(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        for id in &orphan_ids {
            let _ = self.delete_artifact_record_and_file(id);
        }
        Ok(orphan_ids.len())
    }

    /// Re-encrypts legacy artifacts one at a time without blocking Vault startup.
    ///
    /// Callers may run this after the daemon has started accepting requests.
    pub fn migrate_legacy_artifacts(&self) -> Result<usize, StoreError> {
        let artifacts = {
            let connection = self.connection.lock().unwrap();
            let mut statement = connection.prepare(
                "SELECT id, content_type FROM artifacts
                  WHERE format_version < ?1 ORDER BY id",
            )?;
            statement
                .query_map([ARTIFACT_FORMAT_VERSION], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        if artifacts.is_empty() {
            *self.legacy_artifact_key.lock().unwrap() = None;
            return Ok(0);
        }

        let legacy_key = self
            .legacy_artifact_key
            .lock()
            .unwrap()
            .as_ref()
            .map(|key| Zeroizing::new(**key))
            .ok_or(StoreError::Crypto)?;
        let total = artifacts.len();
        for (id, content_type) in artifacts {
            let _artifact_guard = self.artifact_io.write().unwrap();
            let path = self.artifact_path(&id);
            let legacy_path = self.legacy_artifact_path(&id);
            let legacy_encrypted = fs::read(&legacy_path)?;
            let decrypted =
                decrypt_legacy_artifact(&legacy_key, &id, &content_type, &legacy_encrypted)?;
            let replacement =
                encrypt_artifact(&self.artifact_wrap_key, &id, &content_type, &decrypted)?;
            atomic_write_private(&path, &replacement.bytes)?;
            self.connection.lock().unwrap().execute(
                "UPDATE artifacts
                    SET format_version = ?2, wrapped_key = ?3, wrapping_nonce = ?4
                  WHERE id = ?1",
                params![
                    id,
                    ARTIFACT_FORMAT_VERSION,
                    replacement.wrapped_dek,
                    replacement.wrapping_nonce,
                ],
            )?;
            fs::remove_file(legacy_path)?;
        }
        *self.legacy_artifact_key.lock().unwrap() = None;
        Ok(total)
    }

    /// Completes file-level startup work after the daemon is already serving.
    pub fn run_artifact_maintenance(&self) -> Result<usize, StoreError> {
        let migrated = self.migrate_legacy_artifacts()?;
        let _ = self.cleanup_unreferenced_gop_artifacts();
        self.cleanup_orphaned_artifact_files()?;
        Ok(migrated)
    }

    fn delete_artifact_record_and_file(&self, id: &str) -> Result<(), StoreError> {
        self.connection
            .lock()
            .unwrap()
            .execute("DELETE FROM artifacts WHERE id = ?1", [id])?;
        let _artifact_guard = self.artifact_io.write().unwrap();
        match fs::remove_file(self.artifact_path(id)) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        }
    }

    fn cleanup_orphaned_artifact_files(&self) -> Result<(), StoreError> {
        let _artifact_guard = self.artifact_io.write().unwrap();
        for entry in fs::read_dir(&self.artifacts_dir)? {
            let entry = entry?;
            if !entry.file_type()?.is_file() {
                continue;
            }
            let file_name = entry.file_name();
            let Some(file_name) = file_name.to_str() else {
                continue;
            };
            if file_name.starts_with('.')
                && Path::new(file_name)
                    .extension()
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("tmp"))
            {
                fs::remove_file(entry.path())?;
                continue;
            }
            let (id, on_disk_version) = if let Some(id) = file_name.strip_suffix(".arv0") {
                (id, 0_i64)
            } else if let Some(id) = file_name.strip_suffix(".arv1") {
                (id, ARTIFACT_FORMAT_VERSION)
            } else {
                continue;
            };
            let database_version: Option<i64> = self
                .connection
                .lock()
                .unwrap()
                .query_row(
                    "SELECT format_version FROM artifacts WHERE id = ?1",
                    [id],
                    |row| row.get(0),
                )
                .optional()?;
            if database_version != Some(on_disk_version) {
                fs::remove_file(entry.path())?;
            }
        }
        Ok(())
    }

    #[allow(clippy::too_many_lines)]
    /// Total bytes the conversation tables hold, text and reasoning included.
    ///
    /// # Errors
    ///
    /// Returns an error if the query fails.
    pub fn conversation_bytes(&self) -> Result<u64, StoreError> {
        let connection = self.readers.get();
        let used: i64 = connection.query_row(
            "SELECT COALESCE(SUM(
                 LENGTH(CAST(content AS BLOB))
               + LENGTH(CAST(COALESCE(tool_log, '') AS BLOB))
               + LENGTH(CAST(COALESCE(reasoning, '') AS BLOB))
               + LENGTH(CAST(COALESCE(usage_json, '') AS BLOB))
               + ?1
             ), 0) FROM conversation_messages",
            [CONVERSATION_ROW_OVERHEAD_BYTES],
            |row| row.get(0),
        )?;
        Ok(u64::try_from(used).unwrap_or(0))
    }

    /// Drops the least recently used conversations until chat fits its budget.
    ///
    /// The unit is a **whole conversation**, chosen by `updated_at_ms`. Trimming
    /// individual messages was rejected: a thread with its middle removed is
    /// worse than a thread that is gone, because the turns that remain refer to
    /// each other and to evidence that is no longer named, and nothing on screen
    /// says which parts went. A conversation disappearing from the sidebar is
    /// something a person can see and understand.
    ///
    /// The most recently updated conversation is never evicted, so the thread
    /// being written to cannot be deleted underneath its own turn — even if it
    /// alone is over budget, in which case there is nothing better to do.
    ///
    /// # Errors
    ///
    /// Returns an error if a query or delete fails.
    pub fn enforce_conversation_retention(&self) -> Result<Vec<String>, StoreError> {
        self.evict_conversations_until(CONVERSATION_LIMIT_BYTES)
    }

    /// [`Self::enforce_conversation_retention`] against an explicit limit, so a
    /// test can reach the eviction path without writing 256 MB.
    fn evict_conversations_until(&self, limit: u64) -> Result<Vec<String>, StoreError> {
        let mut evicted = Vec::new();
        loop {
            if self.conversation_bytes()? <= limit {
                return Ok(evicted);
            }
            let (oldest, total) = {
                let connection = self.readers.get();
                let total: i64 =
                    connection.query_row("SELECT COUNT(*) FROM conversations", [], |row| {
                        row.get(0)
                    })?;
                let oldest: Option<String> = connection
                    .query_row(
                        "SELECT id FROM conversations ORDER BY updated_at_ms ASC, id ASC LIMIT 1",
                        [],
                        |row| row.get(0),
                    )
                    .optional()?;
                (oldest, total)
            };
            // One conversation left is the floor: it is the one in use.
            let (Some(id), true) = (oldest, total > 1) else {
                return Ok(evicted);
            };
            self.delete_conversation(&id)?;
            evicted.push(id);
        }
    }

    /// Bytes the capture artifacts hold, the counterpart to
    /// [`Self::conversation_bytes`]. The two budgets are separate pools; see
    /// [`CONVERSATION_LIMIT_BYTES`] for why.
    fn artifact_bytes(connection: &Connection) -> Result<i64, StoreError> {
        Ok(connection.query_row(
            "SELECT COALESCE(SUM(byte_length + ?1), 0) FROM artifacts",
            [ARTIFACT_FILE_OVERHEAD_BYTES],
            |row| row.get(0),
        )?)
    }

    // @dec:size-driven-retention — docs/decisions/active/architecture/2026-08-20-size-driven-retention.md
    fn enforce_retention(&self) -> Result<(), StoreError> {
        self.flush_card_cache();
        // Before the size sweep, and outside its early return: a marker's
        // expiry is a promise about time, not about disk, and the size loop
        // below returns immediately whenever the vault is under its limit,
        // which is the normal state. Failure here must not stop the size sweep
        // — a vault over its limit still has to shed frames.
        let now_ms = i64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|elapsed| elapsed.as_millis())
                .unwrap_or_default(),
        )
        .unwrap_or(i64::MAX);
        if let Err(error) = self.prune_signal_gaps(now_ms) {
            eprintln!("signal marker retention failed: {error}");
        }
        loop {
            let max = i64::try_from(self.storage_limit_bytes()).unwrap_or(i64::MAX);
            let mut connection = self.connection.lock().unwrap();
            let used = Self::artifact_bytes(&connection)?;
            let excess = used.saturating_sub(max).max(0);
            if excess == 0 {
                return Ok(());
            }

            let transaction = connection.transaction()?;
            let candidate_pool = {
                let mut statement = transaction.prepare(
                    "SELECT m.id, m.image_artifact_id, m.accessibility_artifact_id,
                            m.thumbnail_artifact_id,
                            COALESCE(image.byte_length + ?1, 0)
                              + COALESCE(accessibility.byte_length + ?1, 0)
                              + COALESCE(thumbnail.byte_length + ?1, 0)
                              + CASE
                                  WHEN m.gop_segment_id IS NOT NULL
                                   AND NOT EXISTS (
                                     SELECT 1 FROM moments favorite
                                      WHERE favorite.gop_segment_id = m.gop_segment_id
                                        AND favorite.is_favorite = 1
                                   )
                                  THEN COALESCE(gop_artifact.byte_length + ?1, 0)
                                    / MAX((
                                        SELECT COUNT(*) FROM moments sibling
                                         WHERE sibling.gop_segment_id = m.gop_segment_id
                                           AND sibling.is_favorite = 0
                                      ), 1)
                                  ELSE 0
                                END
                       FROM moments m
                       LEFT JOIN artifacts image ON image.id = m.image_artifact_id
                       LEFT JOIN artifacts accessibility
                         ON accessibility.id = m.accessibility_artifact_id
                       LEFT JOIN artifacts thumbnail
                         ON thumbnail.id = m.thumbnail_artifact_id
                       LEFT JOIN gop_segments gop ON gop.id = m.gop_segment_id
                       LEFT JOIN artifacts gop_artifact ON gop_artifact.id = gop.artifact_id
                      WHERE m.is_favorite = 0
                        AND (
                          image.id IS NOT NULL
                          OR accessibility.id IS NOT NULL
                          OR m.gop_segment_id IS NULL
                          OR NOT EXISTS (
                            SELECT 1 FROM moments favorite
                             WHERE favorite.gop_segment_id = m.gop_segment_id
                               AND favorite.is_favorite = 1
                          )
                        )
                      ORDER BY m.captured_at_ms ASC, m.id ASC
                      LIMIT ?2",
                )?;
                statement
                    .query_map(
                        params![ARTIFACT_FILE_OVERHEAD_BYTES, RETENTION_BATCH_SIZE],
                        |row| {
                            Ok((
                                row.get::<_, String>(0)?,
                                row.get::<_, Option<String>>(1)?,
                                row.get::<_, Option<String>>(2)?,
                                row.get::<_, Option<String>>(3)?,
                                row.get::<_, i64>(4)?,
                            ))
                        },
                    )?
                    .collect::<Result<Vec<_>, _>>()?
            };
            let mut estimated_reclaim = 0_i64;
            let mut candidates = Vec::new();
            for (moment_id, artifact_id, accessibility_artifact_id, thumbnail_artifact_id, bytes) in
                candidate_pool
            {
                candidates.push((
                    moment_id,
                    artifact_id,
                    accessibility_artifact_id,
                    thumbnail_artifact_id,
                ));
                estimated_reclaim = estimated_reclaim.saturating_add(bytes.max(0));
                if bytes <= 0 || estimated_reclaim >= excess {
                    break;
                }
            }

            let mut gop_artifact_ids = Vec::new();
            for (moment_id, artifact_id, accessibility_artifact_id, thumbnail_artifact_id) in
                &candidates
            {
                transaction.execute(
                    "DELETE FROM evidence_fts WHERE evidence_id IN
                     (SELECT id FROM text_evidence WHERE moment_id = ?1)",
                    [moment_id],
                )?;
                transaction.execute("DELETE FROM gop_frames WHERE moment_id = ?1", [moment_id])?;
                transaction.execute("DELETE FROM moments WHERE id = ?1", [moment_id])?;
                for artifact_id in [
                    artifact_id,
                    accessibility_artifact_id,
                    thumbnail_artifact_id,
                ]
                .into_iter()
                .flatten()
                {
                    transaction.execute("DELETE FROM artifacts WHERE id = ?1", [artifact_id])?;
                }
            }
            let empty_segments: Vec<(String, Option<String>)> = {
                let mut statement = transaction.prepare(
                    "SELECT id, artifact_id FROM gop_segments
                      WHERE id NOT IN (
                        SELECT DISTINCT gop_segment_id FROM moments WHERE gop_segment_id IS NOT NULL
                      )
                      AND id NOT IN (SELECT DISTINCT segment_id FROM gop_frames)",
                )?;
                statement
                    .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
                    .collect::<Result<Vec<_>, _>>()?
            };
            for (segment_id, artifact_id) in &empty_segments {
                transaction.execute("DELETE FROM gop_segments WHERE id = ?1", [segment_id])?;
                if let Some(artifact_id) = artifact_id {
                    transaction.execute("DELETE FROM artifacts WHERE id = ?1", [artifact_id])?;
                    gop_artifact_ids.push(artifact_id.clone());
                }
            }
            let audio_candidates = {
                let mut statement = transaction.prepare(
                    "SELECT audio.id, audio.audio_artifact_id
                       FROM audio_segments audio
                      WHERE NOT EXISTS (
                        SELECT 1 FROM moments m
                         WHERE m.session_id = audio.session_id
                           AND m.captured_at_ms BETWEEN audio.started_at_ms AND audio.ended_at_ms
                      )",
                )?;
                statement
                    .query_map([], |row| {
                        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                    })?
                    .collect::<Result<Vec<_>, _>>()?
            };
            for (segment_id, artifact_id) in &audio_candidates {
                transaction.execute(
                    "DELETE FROM evidence_fts WHERE evidence_id IN
                     (SELECT id FROM text_evidence WHERE audio_segment_id = ?1)",
                    [segment_id],
                )?;
                transaction.execute("DELETE FROM audio_segments WHERE id = ?1", [segment_id])?;
                transaction.execute("DELETE FROM artifacts WHERE id = ?1", [artifact_id])?;
            }
            // The retention edge this pass leaves behind: the oldest frame the
            // vault still holds. The second fact stream and the R3 trees are
            // measured against it rather than against a clock, so what the user
            // did in a stretch survives exactly as long as what was on screen
            // during it.
            //
            // `None` — no frames left at all — means the edge is unknown, and
            // the sweep is skipped rather than guessed. Deleting on the theory
            // that "everything is older than nothing" would take live events on
            // a vault that had merely never captured a frame.
            let retention_horizon_ms: Option<i64> = transaction.query_row(
                "SELECT MIN(captured_at_ms) FROM moments",
                [],
                |row| row.get(0),
            )?;
            let removed_anything = !candidates.is_empty()
                || !gop_artifact_ids.is_empty()
                || !audio_candidates.is_empty();
            transaction.commit()?;
            drop(connection);
            for (_, artifact_id, accessibility_artifact_id, thumbnail_artifact_id) in candidates {
                for artifact_id in [
                    artifact_id,
                    accessibility_artifact_id,
                    thumbnail_artifact_id,
                ]
                .into_iter()
                .flatten()
                {
                    let _ = fs::remove_file(self.artifact_path(&artifact_id));
                }
            }
            for artifact_id in gop_artifact_ids {
                let _ = fs::remove_file(self.artifact_path(&artifact_id));
            }
            for (_, artifact_id) in audio_candidates {
                let _ = fs::remove_file(self.artifact_path(&artifact_id));
            }
            // Outside the transaction because deleting an edge tree deletes an
            // encrypted file, which is not something a rollback could undo.
            let mut swept = 0;
            if let Some(horizon_ms) = retention_horizon_ms {
                swept += self.prune_input_events_before(horizon_ms)?;
                swept += self.prune_edge_snapshots_before(horizon_ms)?;
            }
            if !removed_anything && swept == 0 {
                return Ok(());
            }
        }
    }

    fn artifact_path(&self, id: &str) -> PathBuf {
        self.artifacts_dir.join(format!("{id}.arv1"))
    }

    fn legacy_artifact_path(&self, id: &str) -> PathBuf {
        self.artifacts_dir.join(format!("{id}.arv0"))
    }
}

/// Deterministically combines exact and semantic rankings.
///
/// The returned score is a reciprocal-rank-fusion score, not a BM25 or cosine
/// score. An identical evidence hit appears only once even when both retrieval
/// paths find it.
#[must_use]
pub fn fuse_search_results(
    full_text: Vec<SearchHit>,
    semantic: Vec<SearchHit>,
    limit: usize,
) -> Vec<SearchHit> {
    const RRF_K: f32 = 60.0;
    let mut fused: HashMap<SearchHitKey, (SearchHit, f32)> = HashMap::new();
    for (rank, hit) in full_text.into_iter().enumerate() {
        add_rank(&mut fused, hit, rank, RRF_K);
    }
    for (rank, hit) in semantic.into_iter().enumerate() {
        add_rank(&mut fused, hit, rank, RRF_K);
    }
    let mut hits = fused
        .into_values()
        .map(|(mut hit, score)| {
            hit.score = score;
            hit
        })
        .collect::<Vec<_>>();
    sort_hits(&mut hits);
    hits.truncate(limit);
    hits
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct SearchHitKey {
    moment_id: String,
    session_id: String,
    captured_at_ms: i64,
    source: String,
    text: String,
}

impl From<&SearchHit> for SearchHitKey {
    fn from(hit: &SearchHit) -> Self {
        Self {
            moment_id: hit.moment_id.clone(),
            session_id: hit.session_id.clone(),
            captured_at_ms: hit.captured_at_ms,
            source: hit.source.clone(),
            text: hit.text.clone(),
        }
    }
}

fn add_rank(
    fused: &mut HashMap<SearchHitKey, (SearchHit, f32)>,
    hit: SearchHit,
    rank: usize,
    rrf_k: f32,
) {
    let rank = u16::try_from(rank).map_or(f32::from(u16::MAX), f32::from);
    let increment = 1.0 / (rrf_k + rank + 1.0);
    fused
        .entry(SearchHitKey::from(&hit))
        .and_modify(|(_, score)| *score += increment)
        .or_insert((hit, increment));
}

fn validate_embedding(vector: &[f32]) -> Result<(), StoreError> {
    if vector.is_empty() {
        return Err(StoreError::InvalidEmbedding(
            "vector must not be empty".to_owned(),
        ));
    }
    if vector.iter().any(|value| !value.is_finite()) {
        return Err(StoreError::InvalidEmbedding(
            "vector contains a non-finite value".to_owned(),
        ));
    }
    Ok(())
}

fn cosine_similarity(left: &[f32], right: &[f32]) -> Option<f32> {
    let (mut dot, mut left_norm, mut right_norm) = (0.0_f64, 0.0_f64, 0.0_f64);
    for (&left_value, &right_value) in left.iter().zip(right) {
        let left_value = f64::from(left_value);
        let right_value = f64::from(right_value);
        dot += left_value * right_value;
        left_norm += left_value * left_value;
        right_norm += right_value * right_value;
    }
    if left_norm == 0.0 || right_norm == 0.0 {
        return None;
    }
    Some((dot / (left_norm.sqrt() * right_norm.sqrt())) as f32)
}

/// `LIKE` pattern that prefilters summary rows for [`Vault::find_slot_mentions`].
///
/// Built from the longest whitespace-free run of the query rather than the
/// whole string, because the decision is made later in a folded space that
/// ignores whitespace: searching `qwen3.5: 4b` must still reach the row that
/// stored `qwen3.5:4b`. A prefilter narrower than the decision loses rows
/// silently, so this one is deliberately looser.
///
/// `None` when the query has nothing to match on.
/// Whether a stored entity's `text` contains the searched pattern.
///
/// Reads the value, not the JSON it sits in. `entities_json LIKE ?` also
/// matches the field names serde writes — `"text"`, `"kind"`, `"moment_id"` —
/// so searching for any of those matched every card that had an entity.
const ENTITY_VALUE_MATCH: &str = "EXISTS (SELECT 1 FROM json_each(entities_json) entity \
     WHERE json_extract(entity.value, '$.text') LIKE ?4 ESCAPE '\\')";

/// The same for a thread's name and prose, whose keys are `"name"`, `"prose"`
/// and `"moment_ids"`.
const THREAD_VALUE_MATCH: &str = "EXISTS (SELECT 1 FROM json_each(threads_json) thread \
     WHERE json_extract(thread.value, '$.name') LIKE ?4 ESCAPE '\\' \
        OR json_extract(thread.value, '$.prose') LIKE ?4 ESCAPE '\\')";

fn like_prefilter(query: &str) -> Option<String> {
    let token = query.split_whitespace().max_by_key(|part| part.len())?;
    if token.is_empty() {
        return None;
    }
    let mut pattern = String::with_capacity(token.len() + 2);
    pattern.push('%');
    for character in token.chars() {
        if matches!(character, '\\' | '%' | '_') {
            pattern.push('\\');
        }
        pattern.push(character);
    }
    pattern.push('%');
    Some(pattern)
}

fn sort_hits(hits: &mut [SearchHit]) {
    hits.sort_by(|left, right| {
        right
            .score
            .total_cmp(&left.score)
            .then_with(|| right.captured_at_ms.cmp(&left.captured_at_ms))
            .then_with(|| left.session_id.cmp(&right.session_id))
            .then_with(|| left.moment_id.cmp(&right.moment_id))
            .then_with(|| left.source.cmp(&right.source))
            .then_with(|| left.text.cmp(&right.text))
    });
}

#[async_trait]
impl Store for Vault {
    async fn create_session(&self, started_at_ms: i64) -> Result<Session, CoreError> {
        self.create_session_sync(started_at_ms)
            .map_err(to_core_error)
    }

    async fn end_session(&self, id: &str, ended_at_ms: i64) -> Result<(), CoreError> {
        self.end_session_sync(id, ended_at_ms)
            .map_err(to_core_error)
    }

    async fn sessions(&self) -> Result<Vec<Session>, CoreError> {
        self.sessions_sync().map_err(to_core_error)
    }

    async fn moments(&self, session_id: &str) -> Result<Vec<Moment>, CoreError> {
        self.moments_sync(session_id).map_err(to_core_error)
    }

    async fn audio_segments(&self, session_id: &str) -> Result<Vec<AudioSegment>, CoreError> {
        self.audio_segments_sync(session_id).map_err(to_core_error)
    }
}

fn migrate(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_meta (version INTEGER NOT NULL);
         INSERT INTO schema_meta (version)
           SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_meta);
         CREATE TABLE IF NOT EXISTS sessions (
           id TEXT PRIMARY KEY,
           started_at_ms INTEGER NOT NULL,
           ended_at_ms INTEGER
         );
         CREATE TABLE IF NOT EXISTS artifacts (
           id TEXT PRIMARY KEY,
           content_type TEXT NOT NULL,
           byte_length INTEGER NOT NULL,
           format_version INTEGER NOT NULL DEFAULT 1,
           wrapped_key BLOB,
           wrapping_nonce BLOB
         );
         CREATE TABLE IF NOT EXISTS moments (
           id TEXT PRIMARY KEY,
           session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
           captured_at_ms INTEGER NOT NULL,
           image_artifact_id TEXT NOT NULL REFERENCES artifacts(id),
           is_favorite INTEGER NOT NULL DEFAULT 0,
           accessibility_artifact_id TEXT REFERENCES artifacts(id),
           application_name TEXT,
           bundle_identifier TEXT
         );
         CREATE INDEX IF NOT EXISTS moments_session_time ON moments(session_id, captured_at_ms);
         CREATE TABLE IF NOT EXISTS audio_segments (
           id TEXT PRIMARY KEY,
           session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
           track TEXT NOT NULL,
           started_at_ms INTEGER NOT NULL,
           ended_at_ms INTEGER NOT NULL,
           audio_artifact_id TEXT NOT NULL REFERENCES artifacts(id)
         );
         CREATE TABLE IF NOT EXISTS text_evidence (
           id TEXT PRIMARY KEY,
           session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
           moment_id TEXT REFERENCES moments(id) ON DELETE CASCADE,
           audio_segment_id TEXT REFERENCES audio_segments(id) ON DELETE CASCADE,
           source TEXT NOT NULL,
           text TEXT NOT NULL,
           started_at_ms INTEGER NOT NULL,
           ended_at_ms INTEGER,
           model_version TEXT NOT NULL
         );
         CREATE VIRTUAL TABLE IF NOT EXISTS evidence_fts USING fts5(evidence_id UNINDEXED, text);
         CREATE TABLE IF NOT EXISTS embeddings (
           evidence_id TEXT PRIMARY KEY REFERENCES text_evidence(id) ON DELETE CASCADE,
           vector_json TEXT NOT NULL,
           model_version TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS embeddings_model_version ON embeddings(model_version);
         CREATE TABLE IF NOT EXISTS jobs (
           id TEXT PRIMARY KEY,
           capability TEXT NOT NULL,
           source_id TEXT NOT NULL,
           state TEXT NOT NULL,
           attempts INTEGER NOT NULL DEFAULT 0,
           error TEXT
         );",
    )?;
    // Read before the version is stamped forward. Most steps here are cheap
    // enough to re-run on every open; rebuilding the whole text index is not.
    let from_version = stored_schema_version(connection)?;
    migrate_query_indexes(connection)?;
    migrate_schema_6(connection)?;
    migrate_schema_7(connection)?;
    migrate_legacy_moment_columns(connection)?;
    migrate_schema_8(connection)?;
    migrate_schema_9(connection)?;
    migrate_schema_10(connection)?;
    migrate_schema_11(connection)?;
    migrate_schema_12(connection)?;
    migrate_schema_13(connection)?;
    migrate_schema_14(connection)?;
    migrate_schema_15(connection)?;
    migrate_schema_16(connection)?;
    migrate_schema_18(connection, from_version)?;
    migrate_schema_19(connection)?;
    migrate_schema_20(connection, from_version)?;
    migrate_schema_21(connection)?;
    migrate_schema_22(connection)?;
    migrate_schema_23(connection)?;
    migrate_schema_24(connection)?;
    migrate_schema_25(connection)?;
    migrate_schema_26(connection)?;
    migrate_artifact_columns(connection)?;
    connection.execute("UPDATE schema_meta SET version = ?1", [SCHEMA_VERSION])?;
    Ok(())
}

fn stored_schema_version(connection: &Connection) -> Result<u32, StoreError> {
    let version: Option<i64> = connection
        .query_row("SELECT version FROM schema_meta", [], |row| row.get(0))
        .optional()?;
    Ok(version
        .and_then(|held| u32::try_from(held).ok())
        .unwrap_or(0))
}

const SUMMARY_SLOT_CUTOVER_KEY: &str = "summary_slot_cutover_ms";

fn read_summary_slot_cutover(connection: &Connection) -> Result<Option<i64>, StoreError> {
    connection
        .query_row(
            "SELECT value_int FROM vault_meta WHERE key = ?1",
            [SUMMARY_SLOT_CUTOVER_KEY],
            |row| row.get(0),
        )
        .optional()
        .map_err(StoreError::from)
}

/// The persisted geometry history, normalised so the first segment reaches
/// back to `i64::MIN` — every instant in the vault has to land in exactly one
/// segment, including moments captured before the row that describes them.
fn read_summary_slot_segments(
    connection: &Connection,
) -> Result<Vec<slot::SlotSegment>, StoreError> {
    let mut statement = connection
        .prepare("SELECT from_ms, duration_ms FROM summary_slot_geometry ORDER BY from_ms")?;
    let mut segments: Vec<slot::SlotSegment> = statement
        .query_map([], |row| {
            Ok(slot::SlotSegment::new(row.get(0)?, row.get(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    segments.retain(|segment| segment.duration_ms > 0);
    match segments.first_mut() {
        Some(first) => first.from_ms = i64::MIN,
        None => segments.push(slot::SlotSegment::new(
            i64::MIN,
            slot::CURRENT_SLOT_DURATION_MS,
        )),
    }
    Ok(segments)
}

fn moment_column_names(connection: &Connection) -> Result<Vec<String>, StoreError> {
    let mut statement = connection.prepare("PRAGMA table_info(moments)")?;
    statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(Into::into)
}

fn migrate_legacy_moment_columns(connection: &Connection) -> Result<(), StoreError> {
    let moment_columns = moment_column_names(connection)?;
    if !moment_columns
        .iter()
        .any(|column| column == "accessibility_artifact_id")
    {
        connection.execute(
            "ALTER TABLE moments ADD COLUMN accessibility_artifact_id TEXT REFERENCES artifacts(id)",
            [],
        )?;
    }
    if !moment_columns
        .iter()
        .any(|column| column == "application_name")
    {
        connection.execute("ALTER TABLE moments ADD COLUMN application_name TEXT", [])?;
    }
    if !moment_columns
        .iter()
        .any(|column| column == "bundle_identifier")
    {
        connection.execute("ALTER TABLE moments ADD COLUMN bundle_identifier TEXT", [])?;
    }
    Ok(())
}

fn migrate_artifact_columns(connection: &Connection) -> Result<(), StoreError> {
    let artifact_columns = {
        let mut statement = connection.prepare("PRAGMA table_info(artifacts)")?;
        statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?
    };
    if !artifact_columns
        .iter()
        .any(|column| column == "format_version")
    {
        connection.execute(
            "ALTER TABLE artifacts ADD COLUMN format_version INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }
    if !artifact_columns
        .iter()
        .any(|column| column == "wrapped_key")
    {
        connection.execute("ALTER TABLE artifacts ADD COLUMN wrapped_key BLOB", [])?;
    }
    if !artifact_columns
        .iter()
        .any(|column| column == "wrapping_nonce")
    {
        connection.execute("ALTER TABLE artifacts ADD COLUMN wrapping_nonce BLOB", [])?;
    }
    Ok(())
}

fn is_lock_screen_identity(
    application_name: Option<&str>,
    bundle_identifier: Option<&str>,
) -> bool {
    application_name.is_some_and(|name| name.eq_ignore_ascii_case("loginwindow"))
        || bundle_identifier.is_some_and(|bundle| {
            bundle.eq_ignore_ascii_case("com.apple.loginwindow") || bundle.contains("loginwindow")
        })
}

fn migrate_schema_6(connection: &Connection) -> Result<(), StoreError> {
    let moment_columns = {
        let mut statement = connection.prepare("PRAGMA table_info(moments)")?;
        statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (column, sql) in [
        (
            "gop_segment_id",
            "ALTER TABLE moments ADD COLUMN gop_segment_id TEXT",
        ),
        (
            "gop_index",
            "ALTER TABLE moments ADD COLUMN gop_index INTEGER",
        ),
        (
            "still_origin",
            "ALTER TABLE moments ADD COLUMN still_origin TEXT NOT NULL DEFAULT 'capture'",
        ),
        ("width", "ALTER TABLE moments ADD COLUMN width INTEGER"),
        ("height", "ALTER TABLE moments ADD COLUMN height INTEGER"),
    ] {
        if !moment_columns.iter().any(|name| name == column) {
            connection.execute(sql, [])?;
        }
    }
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS idle_spans (
           id TEXT PRIMARY KEY,
           started_at_ms INTEGER NOT NULL,
           ended_at_ms INTEGER,
           reason TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS gop_segments (
           id TEXT PRIMARY KEY,
           artifact_id TEXT UNIQUE REFERENCES artifacts(id),
           codec TEXT NOT NULL,
           encoder TEXT NOT NULL,
           encoder_version TEXT,
           width INTEGER NOT NULL,
           height INTEGER NOT NULL,
           frame_count INTEGER NOT NULL,
           keyint INTEGER NOT NULL,
           started_at_ms INTEGER NOT NULL,
           ended_at_ms INTEGER NOT NULL,
           status TEXT NOT NULL,
           content_hash TEXT
         );
         CREATE TABLE IF NOT EXISTS gop_frames (
           segment_id TEXT NOT NULL REFERENCES gop_segments(id) ON DELETE CASCADE,
           frame_index INTEGER NOT NULL,
           moment_id TEXT NOT NULL UNIQUE REFERENCES moments(id) ON DELETE CASCADE,
           is_keyframe INTEGER NOT NULL,
           byte_offset INTEGER NOT NULL,
           byte_length INTEGER NOT NULL,
           content_hash TEXT NOT NULL,
           PRIMARY KEY (segment_id, frame_index)
         );
         CREATE TABLE IF NOT EXISTS gop_pack_jobs (
           id TEXT PRIMARY KEY,
           segment_id TEXT REFERENCES gop_segments(id),
           state TEXT NOT NULL,
           attempts INTEGER NOT NULL DEFAULT 0,
           created_at_ms INTEGER NOT NULL,
           updated_at_ms INTEGER NOT NULL,
           heartbeat_at_ms INTEGER,
           payload_json TEXT NOT NULL,
           error TEXT
         );
         CREATE INDEX IF NOT EXISTS moments_gop ON moments(gop_segment_id, gop_index);
         CREATE INDEX IF NOT EXISTS moments_hot_pack
           ON moments(captured_at_ms, gop_segment_id, is_favorite);
         CREATE INDEX IF NOT EXISTS gop_pack_jobs_state ON gop_pack_jobs(state, heartbeat_at_ms);
         CREATE INDEX IF NOT EXISTS idle_spans_open ON idle_spans(ended_at_ms, started_at_ms);",
    )?;
    Ok(())
}

fn table_exists(connection: &Connection, name: &str) -> Result<bool, StoreError> {
    let count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [name],
        |row| row.get(0),
    )?;
    Ok(count > 0)
}

fn table_row_count(connection: &Connection, name: &str) -> Result<i64, StoreError> {
    let sql = format!("SELECT COUNT(*) FROM {name}");
    connection
        .query_row(&sql, [], |row| row.get(0))
        .map_err(Into::into)
}

fn image_artifact_not_null(connection: &Connection) -> Result<bool, StoreError> {
    if !table_exists(connection, "moments")? {
        return Ok(false);
    }
    let mut statement = connection.prepare("PRAGMA table_info(moments)")?;
    Ok(statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(1)?, row.get::<_, i64>(3)?))
        })?
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .any(|(name, notnull)| name == "image_artifact_id" && notnull == 1))
}

fn rebuild_moments_indexes(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE INDEX IF NOT EXISTS moments_session_time ON moments(session_id, captured_at_ms);
         CREATE INDEX IF NOT EXISTS moments_gop ON moments(gop_segment_id, gop_index);
         CREATE INDEX IF NOT EXISTS moments_hot_pack
           ON moments(captured_at_ms, gop_segment_id, is_favorite);
         CREATE INDEX IF NOT EXISTS moments_time_id ON moments(captured_at_ms, id);",
    )?;
    Ok(())
}

fn migrate_schema_7(connection: &Connection) -> Result<(), StoreError> {
    let has_moments = table_exists(connection, "moments")?;
    let has_v7 = table_exists(connection, "moments_v7")?;
    if has_v7 && has_moments {
        let moments_n = table_row_count(connection, "moments")?;
        let v7_n = table_row_count(connection, "moments_v7")?;
        if moments_n == 0 && v7_n > 0 {
            // Crash after DROP moments; migrate() recreated an empty old table.
            connection.execute_batch(
                "PRAGMA foreign_keys = OFF;
                 DROP TABLE moments;
                 ALTER TABLE moments_v7 RENAME TO moments;
                 PRAGMA foreign_keys = ON;",
            )?;
            rebuild_moments_indexes(connection)?;
        } else {
            connection.execute("DROP TABLE moments_v7", [])?;
        }
    } else if has_v7 && !has_moments {
        connection.execute_batch(
            "PRAGMA foreign_keys = OFF;
             ALTER TABLE moments_v7 RENAME TO moments;
             PRAGMA foreign_keys = ON;",
        )?;
        rebuild_moments_indexes(connection)?;
    }

    if !image_artifact_not_null(connection)? {
        return Ok(());
    }
    connection.execute_batch(
        "PRAGMA foreign_keys = OFF;
         CREATE TABLE moments_v7 (
           id TEXT PRIMARY KEY,
           session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
           captured_at_ms INTEGER NOT NULL,
           image_artifact_id TEXT REFERENCES artifacts(id),
           is_favorite INTEGER NOT NULL DEFAULT 0,
           accessibility_artifact_id TEXT REFERENCES artifacts(id),
           application_name TEXT,
           bundle_identifier TEXT,
           gop_segment_id TEXT,
           gop_index INTEGER,
           still_origin TEXT NOT NULL DEFAULT 'capture',
           width INTEGER,
           height INTEGER
         );
         INSERT INTO moments_v7 (
           id, session_id, captured_at_ms, image_artifact_id, is_favorite,
           accessibility_artifact_id, application_name, bundle_identifier,
           gop_segment_id, gop_index, still_origin, width, height
         )
         SELECT id, session_id, captured_at_ms, image_artifact_id, is_favorite,
                accessibility_artifact_id, application_name, bundle_identifier,
                gop_segment_id, gop_index,
                COALESCE(still_origin, 'capture'), width, height
           FROM moments;
         DROP TABLE moments;
         ALTER TABLE moments_v7 RENAME TO moments;
         PRAGMA foreign_keys = ON;",
    )?;
    rebuild_moments_indexes(connection)?;
    Ok(())
}

fn migrate_schema_8(connection: &Connection) -> Result<(), StoreError> {
    let moment_columns = moment_column_names(connection)?;
    for column in ["window_title", "url", "document"] {
        if !moment_columns.iter().any(|name| name == column) {
            connection.execute(&format!("ALTER TABLE moments ADD COLUMN {column} TEXT"), [])?;
        }
    }
    Ok(())
}

fn migrate_schema_9(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS memories (
           id TEXT PRIMARY KEY,
           start_ms INTEGER NOT NULL,
           end_ms INTEGER NOT NULL,
           moment_id TEXT,
           application_name TEXT,
           bundle_identifier TEXT,
           window_title TEXT,
           url TEXT,
           document TEXT,
           summary TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           model_version TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS memories_time ON memories(start_ms, end_ms);
         CREATE INDEX IF NOT EXISTS memories_fingerprint ON memories(fingerprint);",
    )?;
    Ok(())
}

fn migrate_schema_10(connection: &Connection) -> Result<(), StoreError> {
    let mut statement = connection.prepare("PRAGMA table_info(text_evidence)")?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    if !columns.iter().any(|name| name == "layout_json") {
        connection.execute("ALTER TABLE text_evidence ADD COLUMN layout_json TEXT", [])?;
    }
    Ok(())
}

fn trimmed(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|text| !text.is_empty())
}

fn migrate_schema_11(connection: &Connection) -> Result<(), StoreError> {
    // Window-title indexing looks up "have I already recorded this title in
    // this session recently?" on every capture. Without this index that is a
    // full scan of every OCR and transcript row in the vault.
    connection.execute_batch(
        "CREATE INDEX IF NOT EXISTS text_evidence_session_source
           ON text_evidence(session_id, source, started_at_ms);",
    )?;
    Ok(())
}

/// Chat lives in the vault like every other capture: encrypted at rest and
/// removed by the same retention and clear-history paths. A conversation
/// about what you did all day is as revealing as the recording it is about.
fn migrate_schema_13(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS conversations (
           id TEXT PRIMARY KEY,
           title TEXT NOT NULL,
           created_at_ms INTEGER NOT NULL,
           updated_at_ms INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS conversations_updated
           ON conversations(updated_at_ms DESC);
         CREATE TABLE IF NOT EXISTS conversation_messages (
           id TEXT PRIMARY KEY,
           conversation_id TEXT NOT NULL
             REFERENCES conversations(id) ON DELETE CASCADE,
           role TEXT NOT NULL,
           content TEXT NOT NULL,
           tool_log TEXT,
           created_at_ms INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS conversation_messages_thread
           ON conversation_messages(conversation_id, created_at_ms);",
    )?;
    Ok(())
}

fn migrate_schema_12(connection: &Connection) -> Result<(), StoreError> {
    let moment_columns = moment_column_names(connection)?;
    if !moment_columns
        .iter()
        .any(|name| name == "thumbnail_artifact_id")
    {
        connection.execute(
            "ALTER TABLE moments ADD COLUMN thumbnail_artifact_id TEXT REFERENCES artifacts(id)",
            [],
        )?;
    }
    Ok(())
}

/// Slot cards persist independently of the live T1 compute path. T2 output
/// used to vanish when the process exited; the day panel needs it to survive.
fn migrate_schema_14(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS slot_summaries (
           id              TEXT PRIMARY KEY,
           slot_start_ms   INTEGER NOT NULL,
           slot_end_ms     INTEGER NOT NULL,
           local_day       TEXT NOT NULL,
           state           TEXT NOT NULL,
           generation      INTEGER NOT NULL DEFAULT 1,
           schema_version  INTEGER NOT NULL,
           facts_json      TEXT NOT NULL,
           theme_key       TEXT,
           artifacts_json  TEXT,
           title           TEXT,
           bullets_json    TEXT,
           category        TEXT,
           confidence      REAL,
           evidence_json   TEXT NOT NULL,
           producer        TEXT,
           produced_at_ms  INTEGER,
           input_tokens    INTEGER,
           output_tokens   INTEGER,
           latency_ms      INTEGER
         );
         CREATE UNIQUE INDEX IF NOT EXISTS slot_summaries_slot
           ON slot_summaries(slot_start_ms);
         CREATE INDEX IF NOT EXISTS slot_summaries_day
           ON slot_summaries(local_day, slot_start_ms);",
    )?;
    Ok(())
}

/// The v2 card columns: description, per-thread prose with frame citations,
/// verbatim entities, decisions, and honest gaps. Additive so v1 rows keep
/// reading; `bullets_json` stays derived for old readers.
fn migrate_schema_16(connection: &Connection) -> Result<(), StoreError> {
    let mut statement = connection.prepare("PRAGMA table_info(slot_summaries)")?;
    let existing: Vec<String> = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    for column in [
        "description TEXT",
        "threads_json TEXT",
        "entities_json TEXT",
        "decisions_json TEXT",
        "not_captured_json TEXT",
    ] {
        let name = column.split(' ').next().unwrap_or_default();
        if !existing.iter().any(|held| held == name) {
            connection.execute(
                &format!("ALTER TABLE slot_summaries ADD COLUMN {column}"),
                [],
            )?;
        }
    }
    Ok(())
}

/// Rewrites `evidence_fts` in the folded form `index_text` now produces.
///
/// Rows indexed before 17 hold raw text, where a run of Han characters is one
/// token and no substring of it can be searched. 18 refolds again because the
/// run rules changed under it: `々`, `〆` and `〇` joined the run, so a vault
/// stamped 17 has `人々` split across two tokens that the query no longer asks
/// for. Either way nothing recovers the old rows but a rebuild, so it happens
/// once, on the open that finds the older file.
/// Assistant messages gain the state a turn needs to survive being interrupted.
///
/// `status` distinguishes a row that is still being written from one that
/// finished and one that was stopped part-way — before this, a turn that did
/// not reach `done` left nothing at all. `reasoning` keeps the model's thinking
/// beside the answer it produced. `usage_json` keeps the occupancy of the turn
/// that wrote the row, so reopening a thread can show it without inventing a
/// number.
///
/// Purely additive: existing rows read back as `status = NULL`, which means
/// "finished", because every row written before this migration did.
fn migrate_schema_19(connection: &Connection) -> Result<(), StoreError> {
    let mut statement = connection.prepare("PRAGMA table_info(conversation_messages)")?;
    let existing: Vec<String> = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    for column in ["reasoning TEXT", "status TEXT", "usage_json TEXT"] {
        let name = column.split(' ').next().unwrap_or_default();
        if !existing.iter().any(|held| held == name) {
            connection.execute(
                &format!("ALTER TABLE conversation_messages ADD COLUMN {column}"),
                [],
            )?;
        }
    }
    Ok(())
}

/// Freezes the old slot geometry once, at the next half-hour boundary after
/// the final moment captured by a pre-v20 vault. Empty/new vaults deliberately
/// store no marker and use 10-minute slots from their first moment.
fn migrate_schema_20(connection: &Connection, from_version: u32) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS vault_meta (
           key TEXT PRIMARY KEY,
           value_int INTEGER
         );",
    )?;
    if from_version >= 20 || read_summary_slot_cutover(connection)?.is_some() {
        return Ok(());
    }
    let latest: Option<i64> = connection
        .query_row(
            "SELECT MAX(captured_at_ms) FROM moments",
            [],
            |row| row.get(0),
        )?;
    if let Some(latest) = latest {
        connection.execute(
            "INSERT INTO vault_meta (key, value_int) VALUES (?1, ?2)",
            params![
                SUMMARY_SLOT_CUTOVER_KEY,
                slot::next_legacy_slot_boundary(latest),
            ],
        )?;
    }
    Ok(())
}

/// Turns the one-off 30→10-minute cutover into a geometry history the user can
/// extend. Seeded from the marker schema 20 froze, so an upgraded vault reads
/// its old half-hours exactly as it did before slot length was a setting.
fn migrate_schema_22(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS summary_slot_geometry (
           from_ms INTEGER PRIMARY KEY,
           duration_ms INTEGER NOT NULL
         );",
    )?;
    let seeded: i64 =
        connection.query_row("SELECT COUNT(*) FROM summary_slot_geometry", [], |row| {
            row.get(0)
        })?;
    if seeded > 0 {
        return Ok(());
    }
    let mut insert = connection
        .prepare("INSERT INTO summary_slot_geometry (from_ms, duration_ms) VALUES (?1, ?2)")?;
    for segment in slot::legacy_segments(read_summary_slot_cutover(connection)?) {
        insert.execute(params![segment.from_ms, segment.duration_ms])?;
    }
    Ok(())
}

fn migrate_schema_21(connection: &Connection) -> Result<(), StoreError> {
    let mut statement = connection.prepare("PRAGMA table_info(audio_segments)")?;
    let existing: Vec<String> = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    for column in [
        "transcription_state TEXT NOT NULL DEFAULT 'pending'",
        "transcription_attempts INTEGER NOT NULL DEFAULT 0",
        "transcription_error TEXT",
        "transcription_next_attempt_ms INTEGER NOT NULL DEFAULT 0",
        "transcription_updated_at_ms INTEGER NOT NULL DEFAULT 0",
    ] {
        let name = column.split(' ').next().unwrap_or_default();
        if !existing.iter().any(|held| held == name) {
            connection.execute(
                &format!("ALTER TABLE audio_segments ADD COLUMN {column}"),
                [],
            )?;
        }
    }
    connection.execute_batch(
        "UPDATE audio_segments SET transcription_state = 'done'
          WHERE EXISTS (
              SELECT 1 FROM text_evidence te
               WHERE te.audio_segment_id = audio_segments.id AND te.source = 'transcript'
          );
         CREATE INDEX IF NOT EXISTS audio_segments_transcription_queue
           ON audio_segments(transcription_state, transcription_next_attempt_ms, started_at_ms);",
    )?;
    Ok(())
}

/// The second fact stream: what the user *did*, beside what was on screen.
///
/// Rows are the shim's coalesced observations stored as they arrived — `kind`
/// and `target_json` are not parsed here. The index is on `at_ms` alone
/// because every reader asks the same question, "what happened in this
/// window", and both spans and points start there.
///
/// `slot_summaries.acts_json` migrates in the same step even though nothing
/// writes it yet: events expire with the frames around them
/// ([`Vault::prune_input_events_before`]) while T1
/// cards are computed lazily and forever, so the acts a sealed slot derived
/// must have somewhere to be frozen before the events they came from are gone.
///
/// Purely additive; existing rows read back as `acts_json = NULL`, meaning
/// "never materialised".
fn migrate_schema_23(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS input_events (
           id INTEGER PRIMARY KEY,
           at_ms INTEGER NOT NULL,
           end_ms INTEGER,
           kind TEXT NOT NULL,
           count INTEGER,
           ended_with TEXT,
           command TEXT,
           bundle_identifier TEXT,
           target_json TEXT
         );
         CREATE INDEX IF NOT EXISTS input_events_at ON input_events(at_ms);",
    )?;
    let mut statement = connection.prepare("PRAGMA table_info(slot_summaries)")?;
    let existing: Vec<String> = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    if !existing.iter().any(|held| held == "acts_json") {
        connection.execute("ALTER TABLE slot_summaries ADD COLUMN acts_json TEXT", [])?;
    }
    Ok(())
}

/// R3 edge snapshots: accessibility trees captured because the user changed
/// scope, with no moment of their own.
///
/// Deliberately not a column on `moments`: an edge snapshot has no screenshot,
/// no thumbnail and no OCR, and hanging it off a frame would put it inside every
/// frame-shaped retention and export path that treats a moment as a picture of
/// the screen. The index is on `captured_at_ms` because both readers — the slot
/// join and the 48h prune — ask only when.
///
/// Purely additive.
fn migrate_schema_24(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS edge_snapshots (
           id TEXT PRIMARY KEY,
           captured_at_ms INTEGER NOT NULL,
           artifact_id TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS edge_snapshots_at
           ON edge_snapshots(captured_at_ms);",
    )?;
    Ok(())
}

/// Event-capture v2's content columns on `input_events`.
///
/// `text` is the typed run; `extra_json` is every other field the shim's record
/// grew (`application_name`, `window_title`, `source`, `destination`) as one
/// JSON object with only the present keys. Two columns rather than five: the
/// vault stores the input vocabulary without modelling it, so the fields no
/// reader ever filters on travel together, and the next field the shim invents
/// costs a mapping line in the daemon instead of a migration here.
///
/// Purely additive — a schema-24 row reads back with both `NULL`, which is
/// exactly what a pre-v2 shim produced.
fn migrate_schema_25(connection: &Connection) -> Result<(), StoreError> {
    let mut statement = connection.prepare("PRAGMA table_info(input_events)")?;
    let existing: Vec<String> = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    if !existing.iter().any(|held| held == "text") {
        connection.execute("ALTER TABLE input_events ADD COLUMN text TEXT", [])?;
    }
    if !existing.iter().any(|held| held == "extra_json") {
        connection.execute("ALTER TABLE input_events ADD COLUMN extra_json TEXT", [])?;
    }
    Ok(())
}

/// `slot_summaries.details` — the v3 card body, one Markdown document.
///
/// One column, not a set: v3 replaced five structured fields with prose the
/// model writes, and the shape the vault needs to store is "a document". The v1
/// and v2 columns stay exactly where they are; three card shapes now live in
/// this table and `schema_version` is what tells them apart.
///
/// Purely additive — a schema-25 row reads back with `details` `NULL`, which is
/// what every card written before v3 is.
fn migrate_schema_26(connection: &Connection) -> Result<(), StoreError> {
    let mut statement = connection.prepare("PRAGMA table_info(slot_summaries)")?;
    let existing: Vec<String> = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    if !existing.iter().any(|held| held == "details") {
        connection.execute("ALTER TABLE slot_summaries ADD COLUMN details TEXT", [])?;
    }
    Ok(())
}

fn migrate_schema_18(connection: &Connection, from_version: u32) -> Result<(), StoreError> {
    if from_version >= 18 {
        return Ok(());
    }
    let transaction = connection.unchecked_transaction()?;
    transaction.execute("DELETE FROM evidence_fts", [])?;
    {
        let mut read = transaction.prepare("SELECT id, text FROM text_evidence")?;
        let mut write =
            transaction.prepare("INSERT INTO evidence_fts (evidence_id, text) VALUES (?1, ?2)")?;
        let mut rows = read.query([])?;
        while let Some(row) = rows.next()? {
            let id: String = row.get(0)?;
            let text: String = row.get(1)?;
            write.execute(params![id, index_text(&text)])?;
        }
    }
    transaction.commit()?;
    Ok(())
}

/// Document frequencies of screen-text lines and tokens over the user's own
/// slot history — the background corpus for `infoscore`. `kind` 0 is a line
/// dedup key, 1 is a token. `text_df_meta` remembers how far the corpus has
/// been built so maintenance is incremental.
fn migrate_schema_15(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS text_df (
           kind          INTEGER NOT NULL,
           key           TEXT NOT NULL,
           df            INTEGER NOT NULL,
           last_seen_ms  INTEGER NOT NULL,
           PRIMARY KEY (kind, key)
         ) WITHOUT ROWID;
         CREATE TABLE IF NOT EXISTS text_df_meta (
           id            INTEGER PRIMARY KEY CHECK (id = 1),
           watermark_ms  INTEGER NOT NULL,
           slot_count    INTEGER NOT NULL
         );",
    )?;
    Ok(())
}

fn memory_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Memory> {
    Ok(Memory {
        id: row.get(0)?,
        start_ms: row.get(1)?,
        end_ms: row.get(2)?,
        moment_id: row.get(3)?,
        application_name: row.get(4)?,
        bundle_identifier: row.get(5)?,
        window_title: row.get(6)?,
        url: row.get(7)?,
        document: row.get(8)?,
        summary: row.get(9)?,
        fingerprint: row.get(10)?,
    })
}

fn migrate_query_indexes(connection: &Connection) -> Result<(), StoreError> {
    connection.execute_batch(
        "CREATE INDEX IF NOT EXISTS moments_time_id ON moments(captured_at_ms, id);
         CREATE INDEX IF NOT EXISTS text_evidence_moment_source
           ON text_evidence(moment_id, source);
         CREATE INDEX IF NOT EXISTS text_evidence_audio_source
           ON text_evidence(audio_segment_id, source);
         CREATE INDEX IF NOT EXISTS audio_segments_session_time
           ON audio_segments(session_id, started_at_ms, ended_at_ms);",
    )?;
    Ok(())
}

fn moment_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Moment> {
    Ok(Moment {
        id: row.get(0)?,
        session_id: row.get(1)?,
        captured_at_ms: row.get(2)?,
        image_artifact_id: row.get(3)?,
        is_favorite: row.get::<_, i64>(4)? != 0,
        ocr_text: row.get(5)?,
        transcript_text: row.get(6)?,
        audio_artifact_id: row.get(7)?,
        audio_started_at_ms: row.get(8)?,
        accessibility_artifact_id: row.get(9)?,
        application_name: row.get(10)?,
        bundle_identifier: row.get(11)?,
        window_title: row.get(12)?,
        url: row.get(13)?,
        document: row.get(14)?,
        gop: match (
            row.get::<_, Option<String>>(15)?,
            row.get::<_, Option<i64>>(16)?,
        ) {
            (Some(segment_id), Some(index)) => Some(afterray_protocol::GopRef {
                segment_id,
                index: u16::try_from(index).unwrap_or(0),
                keyframe_index: 0,
                frame_count: row
                    .get::<_, Option<i64>>(18)?
                    .and_then(|count| u16::try_from(count).ok())
                    .unwrap_or(0),
                codec: "av01".to_owned(),
            }),
            _ => None,
        },
        still_origin: row
            .get::<_, Option<String>>(17)?
            .unwrap_or_else(|| "capture".to_owned()),
    })
}

fn encrypt_artifact(
    wrapping_key: &[u8; 32],
    id: &str,
    content_type: &str,
    bytes: &[u8],
) -> Result<EncryptedArtifact, StoreError> {
    let mut dek = Zeroizing::new([0_u8; 32]);
    rand::rng().fill_bytes(dek.as_mut());
    let data_cipher = XChaCha20Poly1305::new((&*dek).into());
    let mut data_nonce = [0_u8; NONCE_LENGTH];
    rand::rng().fill_bytes(&mut data_nonce);
    let data_aad = artifact_aad(b"content", id, content_type);
    let ciphertext = data_cipher
        .encrypt(
            XNonce::from_slice(&data_nonce),
            Payload {
                msg: bytes,
                aad: &data_aad,
            },
        )
        .map_err(|_| StoreError::Crypto)?;

    let wrapping_cipher = XChaCha20Poly1305::new(wrapping_key.into());
    let mut wrapping_nonce = [0_u8; NONCE_LENGTH];
    rand::rng().fill_bytes(&mut wrapping_nonce);
    let wrapping_aad = artifact_aad(b"wrapped-dek", id, content_type);
    let wrapped_dek = wrapping_cipher
        .encrypt(
            XNonce::from_slice(&wrapping_nonce),
            Payload {
                msg: &*dek,
                aad: &wrapping_aad,
            },
        )
        .map_err(|_| StoreError::Crypto)?;
    debug_assert_eq!(wrapped_dek.len(), WRAPPED_DEK_LENGTH);

    let mut output = Vec::with_capacity(ARTIFACT_HEADER_LENGTH + ciphertext.len());
    output.extend_from_slice(ARTIFACT_MAGIC);
    output.extend_from_slice(&data_nonce);
    output.extend_from_slice(&ciphertext);
    Ok(EncryptedArtifact {
        bytes: output,
        wrapped_dek,
        wrapping_nonce,
    })
}

struct EncryptedArtifact {
    bytes: Vec<u8>,
    wrapped_dek: Vec<u8>,
    wrapping_nonce: [u8; NONCE_LENGTH],
}

pub(crate) struct StagedArtifact {
    pub id: String,
    pub content_type: String,
    pub byte_length: i64,
    pub wrapped_dek: Vec<u8>,
    pub wrapping_nonce: Vec<u8>,
}

fn decrypt_artifact(
    wrapping_key: &[u8; 32],
    id: &str,
    content_type: &str,
    bytes: &[u8],
    wrapped_dek: &[u8],
    wrapping_nonce: &[u8],
) -> Result<Zeroizing<Vec<u8>>, StoreError> {
    if bytes.len() < ARTIFACT_HEADER_LENGTH + 16
        || &bytes[..4] != ARTIFACT_MAGIC
        || wrapped_dek.len() != WRAPPED_DEK_LENGTH
        || wrapping_nonce.len() != NONCE_LENGTH
    {
        return Err(StoreError::Crypto);
    }
    let wrapping_cipher = XChaCha20Poly1305::new(wrapping_key.into());
    let wrapping_aad = artifact_aad(b"wrapped-dek", id, content_type);
    let mut dek = Zeroizing::new(
        wrapping_cipher
            .decrypt(
                XNonce::from_slice(wrapping_nonce),
                Payload {
                    msg: wrapped_dek,
                    aad: &wrapping_aad,
                },
            )
            .map_err(|_| StoreError::Crypto)?,
    );
    if dek.len() != 32 {
        return Err(StoreError::Crypto);
    }
    let data_cipher = XChaCha20Poly1305::new_from_slice(&dek).map_err(|_| StoreError::Crypto)?;
    let data_aad = artifact_aad(b"content", id, content_type);
    let plaintext = data_cipher
        .decrypt(
            XNonce::from_slice(&bytes[4..ARTIFACT_HEADER_LENGTH]),
            Payload {
                msg: &bytes[ARTIFACT_HEADER_LENGTH..],
                aad: &data_aad,
            },
        )
        .map_err(|_| StoreError::Crypto)?;
    dek.zeroize();
    Ok(Zeroizing::new(plaintext))
}

fn decrypt_legacy_artifact(
    legacy_key: &[u8; 32],
    id: &str,
    content_type: &str,
    bytes: &[u8],
) -> Result<Zeroizing<Vec<u8>>, StoreError> {
    if bytes.len() < 4 + NONCE_LENGTH + 16 || &bytes[..4] != LEGACY_ARTIFACT_MAGIC {
        return Err(StoreError::Crypto);
    }
    let cipher = XChaCha20Poly1305::new(legacy_key.into());
    let aad = format!("{id}:{content_type}");
    let plaintext = cipher
        .decrypt(
            XNonce::from_slice(&bytes[4..4 + NONCE_LENGTH]),
            Payload {
                msg: &bytes[4 + NONCE_LENGTH..],
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| StoreError::Crypto)?;
    Ok(Zeroizing::new(plaintext))
}

fn artifact_aad(purpose: &[u8], id: &str, content_type: &str) -> Vec<u8> {
    let mut aad = Vec::with_capacity(purpose.len() + id.len() + content_type.len() + 16);
    aad.extend_from_slice(b"afterray-artifact-v1\0");
    aad.extend_from_slice(purpose);
    aad.push(0);
    aad.extend_from_slice(id.as_bytes());
    aad.push(0);
    aad.extend_from_slice(content_type.as_bytes());
    aad
}

fn track_name(track: AudioTrack) -> &'static str {
    match track {
        AudioTrack::System => "system",
        AudioTrack::Microphone => "microphone",
    }
}

fn encode_hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(output, "{byte:02x}");
    }
    output
}

fn open_database_with_legacy_migration(
    path: &Path,
    database_key: &[u8; 32],
    legacy_key: &[u8; 32],
) -> Result<Connection, StoreError> {
    let existing_database = path.metadata().is_ok_and(|metadata| metadata.len() > 0);
    match open_keyed_database(path, database_key) {
        Ok(connection) => Ok(connection),
        Err(_derived_error) if existing_database => {
            let legacy_connection =
                open_keyed_database(path, legacy_key).map_err(|_| StoreError::InvalidKey)?;
            legacy_connection.execute_batch(
                "PRAGMA wal_checkpoint(TRUNCATE);
                 PRAGMA journal_mode = DELETE;",
            )?;
            let mut sql = Zeroizing::new(format!(
                "PRAGMA rekey = \"x'{}'\";",
                encode_hex(database_key)
            ));
            let rekey_result = legacy_connection.execute_batch(&sql);
            sql.zeroize();
            rekey_result?;
            drop(legacy_connection);
            open_keyed_database(path, database_key).map_err(|_| StoreError::InvalidKey)
        }
        Err(error) => Err(error),
    }
}

fn open_keyed_database(path: &Path, key: &[u8; 32]) -> Result<Connection, StoreError> {
    let connection = Connection::open(path)?;
    let mut key_pragma = Zeroizing::new(format!("PRAGMA key = \"x'{}'\";", encode_hex(key)));
    let key_result = connection.execute_batch(&key_pragma);
    key_pragma.zeroize();
    key_result?;

    let cipher_version: Option<String> = connection
        .query_row("PRAGMA cipher_version", [], |row| row.get(0))
        .optional()?;
    if cipher_version.as_deref().is_none_or(str::is_empty) {
        return Err(StoreError::InvalidKey);
    }
    connection
        .query_row("SELECT COUNT(*) FROM sqlite_master", [], |row| {
            row.get::<_, i64>(0)
        })
        .map_err(|_| StoreError::InvalidKey)?;
    connection.execute_batch(
        "PRAGMA cipher_memory_security = ON;
         PRAGMA foreign_keys = ON;
         PRAGMA secure_delete = ON;
         PRAGMA temp_store = MEMORY;
         PRAGMA journal_mode = WAL;",
    )?;
    set_database_file_permissions(path)?;
    Ok(connection)
}

fn set_database_file_permissions(path: &Path) -> Result<(), StoreError> {
    set_private_file_permissions(path)?;
    for suffix in ["-wal", "-shm"] {
        let mut sidecar = path.as_os_str().to_os_string();
        sidecar.push(suffix);
        let sidecar = PathBuf::from(sidecar);
        if sidecar.exists() {
            set_private_file_permissions(&sidecar)?;
        }
    }
    Ok(())
}

fn create_private_directory(path: &Path) -> Result<(), StoreError> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

fn set_private_file_permissions(path: &Path) -> Result<(), StoreError> {
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

fn atomic_write_private(path: &Path, bytes: &[u8]) -> Result<(), StoreError> {
    let parent = path.parent().ok_or_else(|| {
        StoreError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "artifact path has no parent directory",
        ))
    })?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| {
            StoreError::Io(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "artifact path has no valid file name",
            ))
        })?;
    let temporary_path = parent.join(format!(".{file_name}.{}.tmp", Uuid::now_v7()));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options.open(&temporary_path)?;
    let write_result = (|| -> Result<(), std::io::Error> {
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary_path, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temporary_path);
    }
    write_result.map_err(StoreError::Io)
}

fn to_core_error(error: StoreError) -> CoreError {
    CoreError::Store(error.to_string())
}

#[must_use]
pub fn default_data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("AfterRay")
}

#[cfg(test)]
mod pipeline_bench;

#[cfg(test)]
mod tests {

    #[test]
    fn new_vault_starts_with_ten_minute_summary_slots() {
        let (_directory, vault) = test_vault(10);
        assert_eq!(
            vault.summary_slot_segments(),
            vec![SlotSegment::new(i64::MIN, CURRENT_SLOT_DURATION_MS)]
        );
        assert_eq!(vault.summary_slot_duration_ms(), CURRENT_SLOT_DURATION_MS);
        let bounds = vault.summary_slot_bounds(1_786_699_244_105);
        assert_eq!(bounds.end_ms - bounds.start_ms, CURRENT_SLOT_DURATION_MS);
    }

    #[test]
    fn chosen_slot_length_survives_reopening_and_leaves_older_slots_alone() {
        let directory = tempfile::tempdir().unwrap();
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        let key = [37_u8; 32];
        let changed_at = 1_786_699_244_105;
        {
            let vault = Vault::open_with_key(config.clone(), key).unwrap();
            let session = vault.create_session_sync(changed_at - 60_000).unwrap();
            vault
                .insert_moment(&session.id, changed_at - 60_000, "image/jpeg", b"frame")
                .unwrap();
            vault
                .set_summary_slot_duration_ms(30 * 60_000, changed_at)
                .unwrap();
        }

        let vault = Vault::open_with_key(config, key).unwrap();
        assert_eq!(vault.summary_slot_duration_ms(), 30 * 60_000);
        let before = vault.summary_slot_bounds(changed_at - 1);
        assert_eq!(before.end_ms, changed_at, "the open slot is clipped");
        assert!(before.end_ms - before.start_ms < CURRENT_SLOT_DURATION_MS);
        let after = vault.summary_slot_bounds(changed_at);
        assert_eq!(after.start_ms, changed_at);
        assert_eq!(
            vault.summary_slot_bounds(after.end_ms).end_ms - after.end_ms,
            30 * 60_000
        );
    }

    #[test]
    fn unoffered_slot_lengths_are_rejected_and_repeats_are_no_ops() {
        let (_directory, vault) = test_vault(10);
        assert!(matches!(
            vault.set_summary_slot_duration_ms(7 * 60_000, 1_786_699_244_105),
            Err(StoreError::InvalidSlotDuration(_))
        ));
        vault
            .set_summary_slot_duration_ms(CURRENT_SLOT_DURATION_MS, 1_786_699_244_105)
            .unwrap();
        assert_eq!(
            vault.summary_slot_segments(),
            vec![SlotSegment::new(i64::MIN, CURRENT_SLOT_DURATION_MS)],
            "asking for the length already in force writes no boundary"
        );
    }

    /// Flipping the control back and forth while nothing is being captured
    /// must not leave a trail of geometries no slot ever used.
    #[test]
    fn empty_geometry_segments_are_unwound_instead_of_stacked() {
        let (_directory, vault) = test_vault(10);
        let at = 1_786_699_244_105;
        vault.set_summary_slot_duration_ms(20 * 60_000, at).unwrap();
        vault
            .set_summary_slot_duration_ms(60 * 60_000, at + 1_000)
            .unwrap();
        assert_eq!(vault.summary_slot_segments().len(), 2);
        vault
            .set_summary_slot_duration_ms(CURRENT_SLOT_DURATION_MS, at + 2_000)
            .unwrap();
        assert_eq!(
            vault.summary_slot_segments(),
            vec![SlotSegment::new(i64::MIN, CURRENT_SLOT_DURATION_MS)]
        );
    }

    #[test]
    fn schema_20_persists_one_contiguous_summary_slot_cutover() {
        let directory = tempfile::tempdir().unwrap();
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        let key = [29_u8; 32];
        let captured_at_ms = 1_786_699_244_105;
        {
            let vault = Vault::open_with_key(config.clone(), key).unwrap();
            let session = vault.create_session_sync(captured_at_ms).unwrap();
            vault
                .insert_moment(&session.id, captured_at_ms, "image/jpeg", b"frame")
                .unwrap();
            let connection = vault.connection.lock().unwrap();
            connection
                .execute_batch(
                    "DELETE FROM vault_meta;
                     DROP TABLE summary_slot_geometry;
                     UPDATE schema_meta SET version = 19;",
                )
                .unwrap();
        }

        let vault = Vault::open_with_key(config, key).unwrap();
        let cutover = next_legacy_slot_boundary(captured_at_ms);
        assert_eq!(
            vault.summary_slot_segments(),
            vec![
                SlotSegment::new(i64::MIN, SLOT_DURATION_MS),
                SlotSegment::new(cutover, CURRENT_SLOT_DURATION_MS),
            ]
        );
        let before = vault.summary_slot_bounds(cutover - 1);
        let after = vault.summary_slot_bounds(cutover);
        assert_eq!(before.end_ms, after.start_ms);
        assert_eq!(before.end_ms - before.start_ms, SLOT_DURATION_MS);
        assert_eq!(after.end_ms - after.start_ms, CURRENT_SLOT_DURATION_MS);
    }

    #[test]
    fn schema_20_upgrade_preserves_legacy_v1_summary_shape_and_half_hour_bounds() {
        let directory = tempfile::tempdir().unwrap();
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        let key = [31_u8; 32];
        let legacy_start = slot_start_for(1_786_699_244_105);
        let captured_at_ms = legacy_start + 60_000;
        {
            let vault = Vault::open_with_key(config.clone(), key).unwrap();
            let session = vault.create_session_sync(captured_at_ms).unwrap();
            vault
                .insert_moment(&session.id, captured_at_ms, "image/jpeg", b"legacy frame")
                .unwrap();
            let card = vault.slot_card(captured_at_ms, 10_000).unwrap();
            assert_eq!(card.slot_start_ms, legacy_start);
            vault
                .put_t2_summary(
                    &card,
                    &T2Card {
                        artifacts: vec!["legacy.rs".into()],
                        title: "Legacy summary".into(),
                        bullets: vec!["Old bullet remains readable".into()],
                        category: Some("coding".into()),
                        confidence: Some(0.8),
                    },
                    "legacy:model",
                    captured_at_ms,
                    Some(42),
                )
                .unwrap();
            let connection = vault.connection.lock().unwrap();
            connection
                .execute(
                    "UPDATE slot_summaries SET slot_end_ms = ?2 WHERE slot_start_ms = ?1",
                    params![legacy_start, legacy_start + SLOT_DURATION_MS],
                )
                .unwrap();
            connection
                .execute_batch(
                    "ALTER TABLE slot_summaries DROP COLUMN description;
                     ALTER TABLE slot_summaries DROP COLUMN threads_json;
                     ALTER TABLE slot_summaries DROP COLUMN entities_json;
                     ALTER TABLE slot_summaries DROP COLUMN decisions_json;
                     ALTER TABLE slot_summaries DROP COLUMN not_captured_json;
                     DELETE FROM vault_meta;
                     DROP TABLE summary_slot_geometry;
                     UPDATE schema_meta SET version = 15;",
                )
                .unwrap();
        }

        let vault = Vault::open_with_key(config, key).unwrap();
        assert_eq!(
            vault.summary_slot_segments(),
            vec![
                SlotSegment::new(i64::MIN, SLOT_DURATION_MS),
                SlotSegment::new(legacy_start + SLOT_DURATION_MS, CURRENT_SLOT_DURATION_MS),
            ]
        );
        let day = vault.day_summary(captured_at_ms, 10_000).unwrap();
        let legacy = day
            .slots
            .iter()
            .find(|slot| slot.slot_start_ms == legacy_start)
            .expect("legacy summary remains in its original slot");
        assert_eq!(legacy.slot_end_ms, legacy_start + SLOT_DURATION_MS);
        assert_eq!(legacy.title.as_deref(), Some("Legacy summary"));
        assert_eq!(
            legacy.bullets.as_deref(),
            Some(["Old bullet remains readable".to_owned()].as_slice())
        );
        assert!(legacy.description.is_none());
        assert!(legacy.threads.is_none());

        let exported = vault.slot_summary_export(captured_at_ms, 10_000).unwrap();
        assert_eq!(
            exported.schema_version,
            Some(LEGACY_SLOT_SUMMARY_SCHEMA_VERSION)
        );
        let summary = exported.summary.expect("legacy structured summary exports");
        assert_eq!(summary["title"], "Legacy summary");
        assert_eq!(summary["bullets"][0], "Old bullet remains readable");
        assert!(summary.get("description").is_none());
    }

    #[test]
    fn writing_v1_after_v2_clears_v2_only_columns() {
        let (_directory, vault) = test_vault(10);
        let bounds = vault.summary_slot_bounds(1_600_000_000_000);
        let session = vault.create_session_sync(bounds.start_ms).unwrap();
        vault
            .insert_moment(
                &session.id,
                bounds.start_ms + 1_000,
                "image/jpeg",
                b"frame",
            )
            .unwrap();
        let card = vault.slot_card(bounds.start_ms, 10_000).unwrap();
        vault
            .put_t2_summary_v2(
                &card,
                &T2CardV2 {
                    title: "New shape".into(),
                    description: "Must be cleared".into(),
                    threads: vec![slot::T2Thread {
                        name: "Thread".into(),
                        prose: "Must also be cleared".into(),
                        moment_ids: Vec::new(),
                    }],
                    ..T2CardV2::default()
                },
                "test",
                bounds.end_ms,
                None,
            )
            .unwrap();
        vault
            .put_t2_summary(
                &card,
                &T2Card {
                    artifacts: Vec::new(),
                    title: "Old shape again".into(),
                    bullets: vec!["Only this bullet remains".into()],
                    category: None,
                    confidence: None,
                },
                "legacy:test",
                bounds.end_ms + 1,
                None,
            )
            .unwrap();

        let row: (i64, Option<String>, Option<String>) = vault
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT schema_version, description, threads_json
                   FROM slot_summaries WHERE slot_start_ms = ?1",
                [bounds.start_ms],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(row, (LEGACY_SLOT_SUMMARY_SCHEMA_VERSION, None, None));
    }

    /// The backlog is what the dashboard's "start now" button promises to
    /// drain, so a count that disagrees with what the packer and the OCR path
    /// actually pick up would make that button lie.
    #[test]
    fn compute_backlog_counts_only_work_that_can_still_be_done() {
        let (_directory, vault) = test_vault(10);
        let policy = PackPolicy {
            hot_window_ms: 0,
            hot_min_stills: 0,
            ocr_grace_ms: 0,
            keyint: 6,
        };
        let now = 1_600_000_000_000;
        let session = vault.create_session_sync(now - 600_000).unwrap();

        // Two stills, one of them already indexed.
        let indexed = vault
            .insert_moment(&session.id, now - 500_000, "image/jpeg", b"pixels")
            .unwrap();
        vault
            .insert_moment(&session.id, now - 400_000, "image/jpeg", b"pixels")
            .unwrap();
        vault
            .insert_text_evidence(
                &session.id,
                Some(&indexed.id),
                None,
                "ocr",
                "hello",
                indexed.captured_at_ms,
                None,
                "test",
                None,
            )
            .unwrap();

        let backlog = vault.compute_backlog(now, &policy).unwrap();
        assert_eq!(
            backlog.unindexed_moments, 1,
            "only the moment without screen text is outstanding"
        );
        // Pinned against the packer's own selection rather than a literal: the
        // number on the button has to be the number the packer will pick up, or
        // pressing start leaves a count that never reaches zero.
        assert_eq!(
            backlog.archive_stills,
            packable_frame_count(
                &vault.list_pack_candidates_read(now, &policy).unwrap(),
                policy.keyint
            ),
            "the archive count must match what the packer would actually pack"
        );
        assert_eq!(backlog.transcripts, 0);

        // A frame captured seconds ago is not neglected, it is in flight.
        vault
            .insert_moment(&session.id, now - 5_000, "image/jpeg", b"pixels")
            .unwrap();
        assert_eq!(
            vault.compute_backlog(now, &policy).unwrap().unindexed_moments,
            1,
            "the grace window keeps in-flight OCR out of the backlog"
        );
    }

    /// The dashboard's "summaries usually take about this long" comes from
    /// here, so the ordering and the `latency_ms IS NOT NULL` filter matter:
    /// a slot with facts but no model pass has no duration to report.
    #[test]
    fn recent_summary_runs_are_newest_first_and_skip_unsummarised_slots() {
        let (_directory, vault) = test_vault(10);
        let mut expected = Vec::new();
        for (index, latency) in [12_000_i64, 205_000, 61_500].into_iter().enumerate() {
            let at = 1_600_000_000_000 + i64::try_from(index).unwrap() * 600_000;
            let bounds = vault.summary_slot_bounds(at);
            let session = vault.create_session_sync(bounds.start_ms).unwrap();
            vault
                .insert_moment(&session.id, bounds.start_ms + 1_000, "image/jpeg", b"pixels")
                .unwrap();
            let card = vault.slot_card(bounds.start_ms, 10_000).unwrap();
            let summary = slot::T2CardV2 {
                title: format!("Pass {index}"),
                description: "Visible description".into(),
                ..slot::T2CardV2::default()
            };
            vault
                .put_t2_summary_v2(&card, &summary, "test", bounds.end_ms, Some(latency))
                .unwrap();
            expected.push((bounds.start_ms, latency));
        }
        // A fourth slot with capture but no summary pass: it must not appear as
        // a zero-duration run and drag the typical figure down.
        let bare = vault.summary_slot_bounds(1_600_000_000_000 + 4 * 600_000);
        let session = vault.create_session_sync(bare.start_ms).unwrap();
        vault
            .insert_moment(&session.id, bare.start_ms + 1_000, "image/jpeg", b"pixels")
            .unwrap();

        let runs = vault.recent_summary_runs(10).unwrap();
        assert_eq!(runs.len(), 3, "only summarised slots have a duration");
        let newest = runs.first().expect("at least one run");
        assert_eq!(newest.slot_start_ms, expected[2].0);
        assert_eq!(newest.latency_ms, expected[2].1);
        assert!(
            runs.windows(2)
                .all(|pair| pair[0].produced_at_ms >= pair[1].produced_at_ms),
            "newest first: {runs:?}"
        );

        assert_eq!(vault.recent_summary_runs(2).unwrap().len(), 2, "limit holds");
    }

    #[test]
    fn slot_summary_export_is_structured_and_excludes_capture_evidence() {
        let (_directory, vault) = test_vault(10);
        let bounds = vault.summary_slot_bounds(1_600_000_000_000);
        let session = vault.create_session_sync(bounds.start_ms).unwrap();
        for offset in [1_000, 20_000, 40_000] {
            vault
                .insert_moment(
                    &session.id,
                    bounds.start_ms + offset,
                    "image/jpeg",
                    b"private pixels",
                )
                .unwrap();
        }
        let card = vault.slot_card(bounds.start_ms, 10_000).unwrap();
        let summary = slot::T2CardV2 {
            title: "Exported parsed card".into(),
            description: "Visible description".into(),
            threads: vec![slot::T2Thread {
                name: "Implementation".into(),
                prose: "Completed the structured export.".into(),
                moment_ids: card.evidence.moment_ids.clone(),
            }],
            decisions: vec!["Keep the export bounded".into()],
            not_captured: vec!["Release result not shown".into()],
            ..slot::T2CardV2::default()
        };
        vault
            .put_t2_summary_v2(&card, &summary, "test", bounds.end_ms, Some(25))
            .unwrap();

        let exported = vault.slot_summary_export(bounds.start_ms, 10_000).unwrap();
        assert_eq!(exported.slot_end_ms, bounds.end_ms);
        // This test writes a v2 card, so the row must claim v2 — the current
        // constant moved to 3 with the Markdown carrier, and a row's version is
        // the shape it was written in, not the newest shape the code knows.
        assert_eq!(
            exported.schema_version,
            Some(V2_SLOT_SUMMARY_SCHEMA_VERSION)
        );
        assert_eq!(exported.generation, Some(1));
        assert!(exported.summary.is_some());
        let json = serde_json::to_string(&exported).unwrap();
        for forbidden in ["ocr", "accessibility", "evidence", "prompt", "completion", "tool_result"] {
            assert!(!json.contains(forbidden), "export leaked {forbidden}: {json}");
        }
    }

    /// Three card shapes now live in `slot_summaries`, and each must come back
    /// as itself: a v3 row exports its Markdown body, a v2 row written beside
    /// it still exports threads, and the day panel sees exactly one `details`.
    #[test]
    fn v3_cards_round_trip_beside_the_v2_rows_already_on_disk() {
        let (_directory, vault) = test_vault(10);
        let bounds = vault.summary_slot_bounds(1_600_000_000_000);
        let session = vault.create_session_sync(bounds.start_ms).unwrap();
        for offset in [1_000_i64, 20_000, 40_000] {
            vault
                .insert_moment(&session.id, bounds.start_ms + offset, "image/jpeg", b"px")
                .unwrap();
        }
        let card = vault.slot_card(bounds.start_ms, 10_000).unwrap();
        let older = vault.summary_slot_bounds(bounds.start_ms - 1);
        let older_session = vault.create_session_sync(older.start_ms).unwrap();
        vault
            .insert_moment(&older_session.id, older.start_ms + 1_000, "image/jpeg", b"px")
            .unwrap();
        let older_card = vault.slot_card(older.start_ms, 10_000).unwrap();
        vault
            .put_t2_summary_v2(
                &older_card,
                &slot::T2CardV2 {
                    title: "The shape before".into(),
                    description: "Written by the JSON contract".into(),
                    threads: vec![slot::T2Thread {
                        name: "Thread".into(),
                        prose: "still readable".into(),
                        moment_ids: Vec::new(),
                    }],
                    ..slot::T2CardV2::default()
                },
                "t2-agent",
                older.end_ms,
                None,
            )
            .unwrap();

        let v3 = slot::T2CardV3 {
            title: "Cut the 0.0.4 release".into(),
            description: "Notarised the DMG and published the appcast.".into(),
            details: "### Notarising\nRan `make release`, waited on `notarytool`.\n\n\
                      ### Appcast\nPublished to R2."
                .into(),
            low_trust: false,
        };
        vault
            .put_t2_summary_v3(&card, &v3, "t2-agent", bounds.end_ms, Some(42))
            .unwrap();

        let exported = vault.slot_summary_export(bounds.start_ms, 10_000).unwrap();
        assert_eq!(exported.schema_version, Some(SLOT_SUMMARY_SCHEMA_VERSION));
        let summary = exported.summary.expect("a v3 card exports");
        assert_eq!(summary["title"], "Cut the 0.0.4 release");
        assert!(summary["details"].as_str().unwrap().contains("notarytool"));
        assert!(
            summary.get("threads").is_none(),
            "a v3 card has no threads to export"
        );
        assert!(
            summary.get("low_trust").is_none(),
            "parse quality is not a stored fact"
        );

        let older_export = vault.slot_summary_export(older.start_ms, 10_000).unwrap();
        assert_eq!(
            older_export.schema_version,
            Some(V2_SLOT_SUMMARY_SCHEMA_VERSION)
        );
        assert_eq!(
            older_export.summary.expect("v2 still exports")["threads"][0]["prose"],
            "still readable"
        );

        let day = vault.day_summary(bounds.start_ms, 10_000).unwrap();
        let row = day
            .slots
            .iter()
            .find(|slot| slot.slot_start_ms == bounds.start_ms)
            .expect("the v3 slot is on the day");
        assert_eq!(row.title.as_deref(), Some("Cut the 0.0.4 release"));
        assert!(row.details.as_deref().unwrap().contains("### Appcast"));
        assert!(row.threads.is_none(), "a v3 row carries no threads");
        assert_eq!(
            row.bullets.as_ref().expect("headings become bullets"),
            &vec!["Notarising".to_owned(), "Appcast".to_owned()],
            "v1 readers keep a usable list without the model writing one"
        );

        // The body is the searchable half of a v3 card: a string that appears
        // only inside it must still find the slot.
        let mentions = vault
            .find_slot_mentions("notarytool", &SearchFilter::default(), 5)
            .unwrap();
        assert_eq!(mentions.len(), 1);
        assert_eq!(mentions[0].slot_start_ms, bounds.start_ms);
        assert!(mentions[0].matched_threads[0].contains("Notarising"));
    }

    /// A vault written by a schema-25 build gains `details` without losing a
    /// row, and the v2 cards it already holds keep reading as v2.
    #[test]
    fn schema_26_adds_details_to_a_v25_vault_without_touching_its_cards() {
        let directory = tempfile::tempdir().unwrap();
        let key = [26_u8; 32];
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        let start_ms = {
            let vault = Vault::open_with_key(config.clone(), key).unwrap();
            let bounds = vault.summary_slot_bounds(1_600_000_000_000);
            let session = vault.create_session_sync(bounds.start_ms).unwrap();
            vault
                .insert_moment(&session.id, bounds.start_ms + 1_000, "image/jpeg", b"px")
                .unwrap();
            let card = vault.slot_card(bounds.start_ms, 10_000).unwrap();
            vault
                .put_t2_summary_v2(
                    &card,
                    &slot::T2CardV2 {
                        title: "Written before v3".into(),
                        description: "Still a v2 row".into(),
                        threads: vec![slot::T2Thread {
                            name: "Work".into(),
                            prose: "kept".into(),
                            moment_ids: Vec::new(),
                        }],
                        ..slot::T2CardV2::default()
                    },
                    "t2-agent",
                    bounds.end_ms,
                    None,
                )
                .unwrap();
            // Put the table back the way schema 25 left it.
            vault
                .connection
                .lock()
                .unwrap()
                .execute_batch(
                    "ALTER TABLE slot_summaries DROP COLUMN details;
                     UPDATE schema_meta SET version = 25;",
                )
                .unwrap();
            bounds.start_ms
        };

        let vault = Vault::open_with_key(config, key).unwrap();
        {
            let connection = vault.connection.lock().unwrap();
            let column: i64 = connection
                .query_row(
                    "SELECT COUNT(*) FROM pragma_table_info('slot_summaries')
                      WHERE name = 'details'",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(column, 1, "the v3 column must come back");
            let version: i64 = connection
                .query_row("SELECT version FROM schema_meta", [], |row| row.get(0))
                .unwrap();
            assert_eq!(version, i64::from(SCHEMA_VERSION));
        }
        let exported = vault.slot_summary_export(start_ms, 10_000).unwrap();
        assert_eq!(
            exported.schema_version,
            Some(V2_SLOT_SUMMARY_SCHEMA_VERSION),
            "an upgrade does not re-label a card it did not rewrite"
        );
        assert_eq!(
            exported.summary.expect("v2 card survives")["threads"][0]["name"],
            "Work"
        );
    }

    /// Conversations were outside every budget: an unbounded growth path, and
    /// reasoning made each row bigger. They now have their own pool, and the
    /// unit of eviction is a whole conversation.
    #[test]
    fn conversation_retention_evicts_whole_threads_oldest_first() {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                ..VaultConfig::default()
            },
            [3_u8; 32],
        )
        .unwrap();

        // Four threads, oldest first, each far past the budget on its own.
        let bulk = "x".repeat(200_000);
        let mut ids = Vec::new();
        for index in 0..4_i64 {
            let id = vault
                .create_conversation(&format!("thread {index}"), 1_000 + index)
                .unwrap();
            for _ in 0..8 {
                vault
                    .append_message(&id, "assistant", &bulk, None, 1_000 + index)
                    .unwrap();
            }
            ids.push(id);
        }
        let before = vault.conversation_bytes().unwrap();
        assert!(before > 0);

        // A budget small enough to bite, applied by the same code path.
        let evicted = vault.evict_conversations_until(before / 3).unwrap();
        assert!(!evicted.is_empty(), "nothing was evicted");
        assert_eq!(evicted[0], ids[0], "the least recently used must go first");

        let left: Vec<String> = vault
            .conversations(100)
            .unwrap()
            .into_iter()
            .map(|conversation| conversation.id)
            .collect();
        assert!(
            left.contains(&ids[3]),
            "the most recent thread must survive: it is the one in use"
        );
        // Whole threads, never half of one.
        for id in &evicted {
            assert!(
                vault.conversation_messages(id).unwrap().is_empty(),
                "an evicted thread left messages behind"
            );
        }
        assert!(vault.conversation_bytes().unwrap() < before);
    }

    /// Tool results are the largest thing a thread holds now that they are
    /// stored, so the chat budget has to see them. They ride in `tool_log`,
    /// which `conversation_bytes` already sums — this is the test that says so
    /// out loud, because a column added to the row and not to the sum is a
    /// budget that quietly stops being a budget.
    #[test]
    fn a_stored_tool_result_counts_against_the_chat_budget() {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                ..VaultConfig::default()
            },
            [4_u8; 32],
        )
        .unwrap();
        let id = vault.create_conversation("thread", 1_000).unwrap();
        vault
            .append_message(&id, "user", "what was I reading", None, 1_000)
            .unwrap();
        let without = vault.conversation_bytes().unwrap();

        let log = format!(
            r#"[{{"name":"get_ocr","args":{{}},"result":"{}","chars":50000}}]"#,
            "x".repeat(50_000)
        );
        vault
            .append_message(&id, "assistant", "you were reading", Some(&log), 1_001)
            .unwrap();
        let with = vault.conversation_bytes().unwrap();

        assert!(
            with >= without + 50_000,
            "a 50 KB result added {} bytes to the accounting",
            with - without
        );
    }

    /// The floor: one conversation is never evicted, even alone and oversized.
    #[test]
    fn conversation_retention_keeps_the_last_thread() {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                ..VaultConfig::default()
            },
            [4_u8; 32],
        )
        .unwrap();
        let id = vault.create_conversation("only", 1).unwrap();
        vault
            .append_message(&id, "assistant", &"y".repeat(100_000), None, 1)
            .unwrap();

        let evicted = vault.evict_conversations_until(1).unwrap();
        assert!(evicted.is_empty());
        assert_eq!(vault.conversations(10).unwrap().len(), 1);
    }
    use super::*;

    fn test_vault(max_storage_gigabytes: u64) -> (tempfile::TempDir, Vault) {
        test_vault_with_storage_limit(max_storage_gigabytes.saturating_mul(1_000_000_000))
    }

    fn test_vault_with_storage_limit(max_storage_bytes: u64) -> (tempfile::TempDir, Vault) {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                max_storage_bytes,
            },
            [7_u8; 32],
        )
        .unwrap();
        (directory, vault)
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn keychain_round_trip_works_without_data_protection_entitlement() {
        let account = format!("afterray-test-{}", Uuid::now_v7());
        let created = create_keychain_key(&account).expect("create vault key");
        let loaded = load_keychain_key(&account).expect("load vault key");
        let _ = remove_file_keychain_item(&account);
        let _ = remove_legacy_keychain_item(&account);
        assert_eq!(*created, *loaded.expect("created key should be readable"));
    }

    #[test]
    fn existing_vault_never_silently_creates_a_replacement_key() {
        struct MissingKeyProvider {
            create_called: std::sync::atomic::AtomicBool,
        }

        impl KeyProvider for MissingKeyProvider {
            fn load(&self) -> Result<Option<VaultKey>, StoreError> {
                Ok(None)
            }

            fn create(&self) -> Result<VaultKey, StoreError> {
                self.create_called
                    .store(true, std::sync::atomic::Ordering::Relaxed);
                Ok(Zeroizing::new([99_u8; 32]))
            }
        }

        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("afterray.sqlite3"), b"existing-vault").unwrap();
        let provider = MissingKeyProvider {
            create_called: std::sync::atomic::AtomicBool::new(false),
        };
        let result = Vault::open(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                ..VaultConfig::default()
            },
            &provider,
        );
        assert!(matches!(result, Err(StoreError::MissingVaultKey)));
        assert!(
            !provider
                .create_called
                .load(std::sync::atomic::Ordering::Relaxed)
        );
    }

    #[test]
    fn encrypted_artifact_round_trip_has_no_plaintext() {
        let (directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 2, "image/jpeg", b"private-screen-text")
            .unwrap();
        let on_disk =
            fs::read(vault.artifact_path(moment.image_artifact_id.as_deref().unwrap())).unwrap();
        assert_eq!(&on_disk[..4], ARTIFACT_MAGIC);
        assert!(
            !on_disk
                .windows(19)
                .any(|window| window == b"private-screen-text")
        );
        let (wrapped_key, wrapping_nonce): (Vec<u8>, Vec<u8>) = vault
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT wrapped_key, wrapping_nonce FROM artifacts WHERE id = ?1",
                [moment.image_artifact_id.as_deref().unwrap()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(wrapped_key.len(), WRAPPED_DEK_LENGTH);
        assert_eq!(wrapping_nonce.len(), NONCE_LENGTH);
        assert!(
            !on_disk
                .windows(wrapped_key.len())
                .any(|window| window == wrapped_key)
        );
        let payload = vault
            .read_artifact(moment.image_artifact_id.as_deref().unwrap())
            .unwrap();
        assert_eq!(payload.bytes, b"private-screen-text");
        drop(directory);
    }

    #[test]
    fn artifact_ciphertext_is_bound_to_immutable_metadata() {
        let (_directory, vault) = test_vault(10);
        let encrypted = encrypt_artifact(
            &vault.artifact_wrap_key,
            "artifact-1",
            "image/jpeg",
            b"secret",
        )
        .unwrap();
        assert!(matches!(
            decrypt_artifact(
                &vault.artifact_wrap_key,
                "artifact-2",
                "image/jpeg",
                &encrypted.bytes,
                &encrypted.wrapped_dek,
                &encrypted.wrapping_nonce,
            ),
            Err(StoreError::Crypto)
        ));
        assert!(matches!(
            decrypt_artifact(
                &vault.artifact_wrap_key,
                "artifact-1",
                "audio/mp4",
                &encrypted.bytes,
                &encrypted.wrapped_dek,
                &encrypted.wrapping_nonce,
            ),
            Err(StoreError::Crypto)
        ));
    }

    #[test]
    fn legacy_database_key_is_rekeyed_to_domain_separated_key() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("afterray.sqlite3");
        let master_key = [19_u8; 32];
        let legacy = Connection::open(&path).unwrap();
        legacy
            .execute_batch(&format!(
                "PRAGMA key = \"x'{}'\";
                 CREATE TABLE legacy_marker (value TEXT NOT NULL);
                 INSERT INTO legacy_marker VALUES ('preserved');",
                encode_hex(&master_key)
            ))
            .unwrap();
        drop(legacy);

        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                ..VaultConfig::default()
            },
            master_key,
        )
        .unwrap();
        let marker: String = vault
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT value FROM legacy_marker", [], |row| row.get(0))
            .unwrap();
        assert_eq!(marker, "preserved");
        drop(vault);

        assert!(open_keyed_database(&path, &master_key).is_err());
        let database_key = blake3::derive_key(DATABASE_KEY_CONTEXT, &master_key);
        assert!(open_keyed_database(&path, &database_key).is_ok());
    }

    #[test]
    fn legacy_artifact_is_migrated_without_plaintext() {
        let directory = tempfile::tempdir().unwrap();
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        let master_key = [23_u8; 32];
        let vault = Vault::open_with_key(config.clone(), master_key).unwrap();
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 2, "image/jpeg", b"original")
            .unwrap();
        let id = moment.image_artifact_id.expect("still");
        let legacy = encrypt_legacy_for_test(&master_key, &id, "image/jpeg", b"legacy-secret");
        fs::remove_file(vault.artifact_path(&id)).unwrap();
        fs::write(vault.legacy_artifact_path(&id), legacy).unwrap();
        vault
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE artifacts
                    SET format_version = 0, wrapped_key = NULL, wrapping_nonce = NULL
                  WHERE id = ?1",
                [&id],
            )
            .unwrap();
        drop(vault);

        let migrated = Vault::open_with_key(config, master_key).unwrap();
        let payload_before_migration = migrated.read_artifact(&id).unwrap();
        assert_eq!(payload_before_migration.bytes, b"legacy-secret");
        assert_eq!(migrated.migrate_legacy_artifacts().unwrap(), 1);
        assert!(!migrated.legacy_artifact_path(&id).exists());
        assert_eq!(
            &fs::read(migrated.artifact_path(&id)).unwrap()[..4],
            ARTIFACT_MAGIC
        );
        let payload = migrated.read_artifact(&id).unwrap();
        assert_eq!(payload.bytes, b"legacy-secret");
    }

    fn encrypt_legacy_for_test(
        key: &[u8; 32],
        id: &str,
        content_type: &str,
        bytes: &[u8],
    ) -> Vec<u8> {
        let cipher = XChaCha20Poly1305::new(key.into());
        let nonce = [31_u8; NONCE_LENGTH];
        let aad = format!("{id}:{content_type}");
        let ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: bytes,
                    aad: aad.as_bytes(),
                },
            )
            .unwrap();
        [LEGACY_ARTIFACT_MAGIC.as_slice(), &nonce, &ciphertext].concat()
    }

    #[test]
    fn timeline_spans_sessions_in_capture_order() {
        let (_directory, vault) = test_vault(10);
        let first_session = vault.create_session_sync(100).unwrap();
        let first = vault
            .insert_moment(&first_session.id, 110, "image/jpeg", b"first")
            .unwrap();
        let second_session = vault.create_session_sync(200).unwrap();
        let second = vault
            .insert_moment(&second_session.id, 210, "image/jpeg", b"second")
            .unwrap();

        let timeline = vault.timeline_sync().unwrap();
        assert_eq!(
            timeline
                .iter()
                .map(|moment| moment.id.as_str())
                .collect::<Vec<_>>(),
            [first.id.as_str(), second.id.as_str()]
        );
        assert_eq!(
            vault
                .timeline_since_sync(200)
                .unwrap()
                .iter()
                .map(|moment| moment.id.as_str())
                .collect::<Vec<_>>(),
            [second.id.as_str()]
        );
    }

    #[test]
    fn orphaned_sessions_close_at_next_start_or_last_moment() {
        let (_directory, vault) = test_vault(10);
        let first_session = vault.create_session_sync(100).unwrap();
        vault
            .insert_moment(&first_session.id, 150, "image/jpeg", b"first")
            .unwrap();
        let second_session = vault.create_session_sync(200).unwrap();
        vault
            .insert_moment(&second_session.id, 250, "image/jpeg", b"second")
            .unwrap();

        assert_eq!(vault.close_orphaned_sessions_sync(300).unwrap(), 2);
        let sessions = vault.sessions_sync().unwrap();
        let first = sessions
            .iter()
            .find(|session| session.id == first_session.id)
            .unwrap();
        let second = sessions
            .iter()
            .find(|session| session.id == second_session.id)
            .unwrap();
        assert_eq!(first.ended_at_ms, Some(200));
        assert_eq!(second.ended_at_ms, Some(250));
        assert_eq!(vault.close_orphaned_sessions_sync(400).unwrap(), 0);
    }

    #[test]
    fn audio_transcription_claims_survive_failure_restart_and_replay() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(100).unwrap();
        let segment = vault.insert_audio_segment(
            &session.id, AudioTrack::Microphone, 200, 300, "audio/mp4", b"audio",
        ).unwrap();

        let first = vault.claim_audio_transcription(1_000).unwrap().unwrap();
        assert_eq!(first.segment.id, segment.id);
        assert_eq!(first.attempts, 1);
        vault.fail_audio_transcription(
            &segment.id, "model unavailable", 2_000, 1_000,
        ).unwrap();
        assert!(vault.claim_audio_transcription(1_999).unwrap().is_none());
        assert_eq!(vault.retry_failed_audio_transcriptions(1_500).unwrap(), 1);

        let second = vault.claim_audio_transcription(1_500).unwrap().unwrap();
        assert_eq!(second.attempts, 2);
        let recovered = vault
            .claim_audio_transcription(1_500 + 5 * 60 * 1_000)
            .unwrap()
            .unwrap();
        assert_eq!(recovered.segment.id, segment.id);
        assert_eq!(recovered.attempts, 3);

        assert!(vault.complete_audio_transcription(
            &segment, "hello world", "test-asr", 400_000,
        ).unwrap().is_some());
        assert!(vault.claim_audio_transcription(500_000).unwrap().is_none());
        assert!(vault.complete_audio_transcription(
            &segment, "duplicate", "test-asr", 500_000,
        ).unwrap().is_none());
        let transcripts = vault.transcripts_in_range(0, 1_000, 10).unwrap();
        assert_eq!(transcripts.len(), 1);
        assert_eq!(transcripts[0].2, "hello world");
    }

    /// The question a summariser asks before sealing a card it can never
    /// revise. Every state the queue can be in has to answer it correctly —
    /// including the one that has no evidence row and never will.
    #[test]
    fn untranscribed_audio_is_only_reported_while_a_transcript_is_still_coming() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(100).unwrap();
        let spoken = vault
            .insert_audio_segment(&session.id, AudioTrack::Microphone, 1_000, 2_000, "audio/mp4", b"a")
            .unwrap();

        assert!(vault.has_untranscribed_audio_between(1_500, 1_600).unwrap());
        assert!(
            vault.has_untranscribed_audio_between(500, 1_000).unwrap(),
            "overlap is inclusive: a segment straddling the boundary holds words spoken inside it"
        );
        assert!(
            !vault.has_untranscribed_audio_between(3_000, 4_000).unwrap(),
            "a window with no audio in it is never waiting on one"
        );

        // In flight right now: the strongest reason there is to wait.
        vault.claim_audio_transcription(1_000).unwrap().unwrap();
        assert!(vault.has_untranscribed_audio_between(1_000, 2_000).unwrap());

        // Sitting out a retry backoff. `claim_audio_transcription` says "not
        // now"; the summariser must still hear "a transcript is coming".
        vault
            .fail_audio_transcription(&spoken.id, "model unavailable", 900_000, 2_000)
            .unwrap();
        assert!(vault.claim_audio_transcription(3_000).unwrap().is_none());
        assert!(vault.has_untranscribed_audio_between(1_000, 2_000).unwrap());

        vault
            .complete_audio_transcription(&spoken, "hello world", "test-asr", 4_000)
            .unwrap();
        assert!(!vault.has_untranscribed_audio_between(1_000, 2_000).unwrap());
    }

    /// Silence completes with no evidence row at all. Read through the
    /// `NOT EXISTS` half alone it would look untranscribed forever, and a
    /// summary waiting on one would wait out its whole cap on every quiet slot.
    #[test]
    fn a_silent_segment_is_not_waiting_for_anything() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(100).unwrap();
        let quiet = vault
            .insert_audio_segment(&session.id, AudioTrack::System, 1_000, 2_000, "audio/mp4", b"a")
            .unwrap();
        assert_eq!(
            vault
                .complete_audio_transcription(&quiet, "   ", "test-asr", 3_000)
                .unwrap(),
            None,
            "an empty transcript writes no evidence"
        );
        assert!(!vault.has_untranscribed_audio_between(1_000, 2_000).unwrap());
        assert_eq!(vault.asr_health(9_000).unwrap().waiting_segments, 0);
        assert_eq!(
            vault.asr_health(9_000).unwrap().last_success_ms,
            Some(3_000),
            "the worker ran and returned; that is a success even with nothing to index"
        );
    }

    #[test]
    fn asr_health_reports_the_last_success_the_last_failure_and_the_pile() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(100).unwrap();

        let empty = vault.asr_health(10_000).unwrap();
        assert_eq!(empty, AsrHealth::default());
        assert_eq!(empty.last_success_ms, None, "never transcribed anything");

        let done = vault
            .insert_audio_segment(&session.id, AudioTrack::Microphone, 100, 200, "audio/mp4", b"a")
            .unwrap();
        let broken = vault
            .insert_audio_segment(&session.id, AudioTrack::Microphone, 300, 400, "audio/mp4", b"b")
            .unwrap();
        vault
            .complete_audio_transcription(&done, "spoken", "test-asr", 5_000)
            .unwrap();
        vault
            .fail_audio_transcription(&broken.id, "worker died", 9_000, 6_000)
            .unwrap();

        let health = vault.asr_health(10_000).unwrap();
        assert_eq!(health.last_success_ms, Some(5_000));
        assert_eq!(health.last_failure_ms, Some(6_000));
        assert_eq!(health.waiting_segments, 1);
        assert_eq!(health.exhausted_segments, 0);

        // Re-claiming clears the error, so the last failure recedes with it.
        vault.claim_audio_transcription(9_000).unwrap().unwrap();
        assert_eq!(vault.asr_health(10_000).unwrap().last_failure_ms, None);

        // A clock that moved backwards must not leave ASR looking eternally
        // fresh: both instants are clamped to the caller's now.
        assert_eq!(vault.asr_health(1_000).unwrap().last_success_ms, Some(1_000));
    }

    /// There is no retry cap in this codebase — segments retry forever — so
    /// "exhausted" is pinned to the one place retrying stops escalating: the
    /// point where `1 << min(attempts, N)` stops growing.
    #[test]
    fn a_segment_is_exhausted_once_its_backoff_stops_growing() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(100).unwrap();
        let segment = vault
            .insert_audio_segment(&session.id, AudioTrack::Microphone, 100, 200, "audio/mp4", b"a")
            .unwrap();

        for attempt in 1..=AUDIO_BACKOFF_SATURATION_ATTEMPTS {
            let claimed = vault.claim_audio_transcription(1_000).unwrap().unwrap();
            assert_eq!(claimed.attempts, attempt);
            vault
                .fail_audio_transcription(&segment.id, "worker died", 1_000, 1_000)
                .unwrap();
            let health = vault.asr_health(2_000).unwrap();
            assert_eq!(health.waiting_segments, 1);
            assert_eq!(
                health.exhausted_segments,
                usize::from(attempt >= AUDIO_BACKOFF_SATURATION_ATTEMPTS),
                "attempt {attempt} of {AUDIO_BACKOFF_SATURATION_ATTEMPTS}"
            );
        }
    }

    #[test]
    fn schema_21_migration_recovers_only_audio_without_a_transcript() {
        let directory = tempfile::tempdir().unwrap();
        let key = [21_u8; 32];
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        let vault = Vault::open_with_key(config.clone(), key).unwrap();
        let session = vault.create_session_sync(100).unwrap();
        let completed = vault
            .insert_audio_segment(
                &session.id,
                AudioTrack::System,
                200,
                300,
                "audio/mp4",
                b"completed",
            )
            .unwrap();
        vault
            .insert_text_evidence(
                &session.id,
                None,
                Some(&completed.id),
                "transcript",
                "already transcribed",
                200,
                Some(300),
                "legacy-asr",
                None,
            )
            .unwrap();
        let pending = vault
            .insert_audio_segment(
                &session.id,
                AudioTrack::Microphone,
                400,
                500,
                "audio/mp4",
                b"pending",
            )
            .unwrap();
        vault
            .connection
            .lock()
            .unwrap()
            .execute_batch(
                "DROP INDEX audio_segments_transcription_queue;
                 ALTER TABLE audio_segments DROP COLUMN transcription_state;
                 ALTER TABLE audio_segments DROP COLUMN transcription_attempts;
                 ALTER TABLE audio_segments DROP COLUMN transcription_error;
                 ALTER TABLE audio_segments DROP COLUMN transcription_next_attempt_ms;
                 ALTER TABLE audio_segments DROP COLUMN transcription_updated_at_ms;
                 UPDATE schema_meta SET version = 20;",
            )
            .unwrap();
        drop(vault);

        let migrated = Vault::open_with_key(config, key).unwrap();
        let claimed = migrated.claim_audio_transcription(1_000).unwrap().unwrap();
        assert_eq!(claimed.segment.id, pending.id);
        assert!(migrated.claim_audio_transcription(1_000).unwrap().is_none());
        let state: String = migrated
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT transcription_state FROM audio_segments WHERE id = ?1",
                [&completed.id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(state, "done");
    }

    #[test]
    fn accessibility_snapshot_attaches_within_two_seconds() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 10_000, "image/jpeg", b"screen")
            .unwrap();
        let artifact = vault
            .attach_accessibility_snapshot(
                &session.id,
                11_500,
                "application/vnd.afterray.ax+json",
                br#"{"root":{"role":"AXWindow"}}"#,
                Some("Xcode"),
                Some("com.apple.dt.Xcode"),
            )
            .unwrap();
        assert!(artifact.is_some());
        let loaded = vault.moments_sync(&session.id).unwrap();
        assert_eq!(loaded[0].id, moment.id);
        assert_eq!(loaded[0].accessibility_artifact_id, artifact);
        assert_eq!(loaded[0].application_name.as_deref(), Some("Xcode"));

        let too_late = vault
            .attach_accessibility_snapshot(
                &session.id,
                12_001,
                "application/vnd.afterray.ax+json",
                b"{}",
                None,
                None,
            )
            .unwrap();
        assert!(too_late.is_none());
    }

    #[test]
    fn accessibility_snapshot_keeps_root_and_zstd_round_trips() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 10_000, "image/jpeg", b"screen")
            .unwrap();
        let snapshot = br#"{
            "application_name":"Chrome",
            "bundle_identifier":"com.google.Chrome",
            "tree_text":{"mode":"unchanged","chain":"c1","seq":4},
            "root":{"role":"AXWindow","children":[{"role":"AXButton","title":"Send"}]}
        }"#;
        let artifact = vault
            .attach_accessibility_snapshot(
                &session.id,
                10_000,
                "application/vnd.afterray.ax+json",
                snapshot,
                Some("Chrome"),
                Some("com.google.Chrome"),
            )
            .unwrap()
            .expect("attached");
        let bytes = vault
            .accessibility_bytes_for_moment(&moment.id)
            .unwrap()
            .expect("artifact readable");
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["root"]["role"], "AXWindow", "OCR/T1 still need root");
        assert_eq!(value["tree_text"]["mode"], "unchanged");
        let on_disk = std::fs::metadata(vault.artifact_path(&artifact))
            .unwrap()
            .len();
        assert!(
            on_disk < u64::try_from(snapshot.len()).unwrap_or(u64::MAX),
            "zstd should shrink the stored AX payload"
        );
    }

    /// The point of the reader pool: a long write transaction must not stall
    /// reads. Before the pool, one mutex serialised the entire store.
    #[test]
    fn reads_proceed_while_a_write_transaction_is_open() {
        let (_directory, vault) = test_vault(100);
        let session = vault.create_session_sync(1_000).unwrap();
        vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"one")
            .unwrap();

        // Hold the writer open on this thread…
        let writer = vault.connection.lock().unwrap();
        let tx = writer.unchecked_transaction().unwrap();
        tx.execute(
            "INSERT INTO text_df (kind, key, df, last_seen_ms) VALUES (9, 'held', 1, 0)",
            [],
        )
        .unwrap();

        // …and read from another. With reads behind the same mutex this
        // deadlocks (single-threaded) — the read must come from the pool.
        let sessions = vault.sessions_sync().unwrap();
        assert_eq!(sessions.len(), 1);
        let rows = vault.slot_moment_rows(0, 10_000).unwrap();
        assert_eq!(rows.len(), 1);
        drop(tx);
        drop(writer);
    }

    /// `query_only` turns a misclassified write into an error, never silent
    /// WAL corruption. This is the guard that makes the pool safe to extend.
    #[test]
    fn reader_connections_refuse_writes() {
        let (_directory, vault) = test_vault(100);
        let reader = vault.readers.get();
        let result = reader.execute("CREATE TABLE should_fail (id INTEGER)", []);
        assert!(result.is_err(), "a pool reader accepted a write");
    }

    /// Filmstrip scrubbing decrypts many artifacts at once. Under a plain
    /// `Mutex` those reads queue; the `RwLock` lets them share a read lock.
    #[test]
    fn concurrent_artifact_reads_do_not_serialize() {
        let (_directory, vault) = test_vault(100);
        let session = vault.create_session_sync(1_000).unwrap();
        let mut ids = Vec::new();
        for i in 0..8 {
            let moment = vault
                .insert_moment(
                    &session.id,
                    1_000 + i * 1_000,
                    "image/jpeg",
                    format!("frame-{i}").as_bytes(),
                )
                .unwrap();
            ids.push(moment.image_artifact_id.expect("still stored"));
        }
        let vault = std::sync::Arc::new(vault);
        std::thread::scope(|scope| {
            for id in &ids {
                let vault = std::sync::Arc::clone(&vault);
                let id = id.clone();
                scope.spawn(move || {
                    let payload = vault.read_artifact(&id).expect("decrypt still");
                    assert!(!payload.bytes.is_empty());
                });
            }
        });
    }

    #[test]
    fn settled_slot_cards_are_cached_until_a_deletion() {
        let (_directory, vault) = test_vault(100);
        // Timestamps far in the past: settled by any wall clock.
        let start = slot_start_for(1_600_000_000_000);
        let session = vault.create_session_sync(start).unwrap();
        vault
            .insert_moment(&session.id, start + 1_000, "image/jpeg", b"one")
            .unwrap();

        let first = vault.slot_card(start, 10_000).unwrap();
        assert_eq!(first.facts.moment_count, 1);
        assert!(
            vault.card_cache.lock().unwrap().contains_key(&start),
            "settled card must enter the cache"
        );

        // A deletion must flush; the rebuilt card reflects the new truth.
        let deleted = vault
            .delete_history(start, start + SLOT_DURATION_MS)
            .unwrap();
        assert_eq!(deleted, 1);
        assert!(
            vault.card_cache.lock().unwrap().is_empty(),
            "deletion left a stale card behind"
        );
        let rebuilt = vault.slot_card(start, 10_000).unwrap();
        assert_eq!(rebuilt.facts.moment_count, 0);
    }

    #[test]
    fn storage_retention_evicts_oldest_moments() {
        let (_directory, vault) = test_vault_with_storage_limit(100);
        let session = vault.create_session_sync(1).unwrap();
        let first = vault
            .insert_moment(&session.id, 1, "image/jpeg", b"one")
            .unwrap();
        let second = vault
            .insert_moment(&session.id, 2, "image/jpeg", b"two")
            .unwrap();
        let third = vault
            .insert_moment(&session.id, 3, "image/jpeg", b"three")
            .unwrap();
        let fourth = vault
            .insert_moment(&session.id, 4, "image/jpeg", b"four")
            .unwrap();
        let moments = vault.moments_sync(&session.id).unwrap();
        let ids = moments
            .iter()
            .map(|moment| moment.id.as_str())
            .collect::<Vec<_>>();
        assert!(!ids.contains(&first.id.as_str()));
        assert!(!ids.contains(&second.id.as_str()));
        assert!(ids.contains(&third.id.as_str()));
        assert!(ids.contains(&fourth.id.as_str()));
        assert!(vault.storage_usage_bytes().unwrap() <= 100);
    }

    #[test]
    fn lowering_storage_limit_prunes_immediately() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let first = vault
            .insert_moment(&session.id, 1, "image/jpeg", b"one")
            .unwrap();
        let second = vault
            .insert_moment(&session.id, 2, "image/jpeg", b"two")
            .unwrap();
        let third = vault
            .insert_moment(&session.id, 3, "image/jpeg", b"three")
            .unwrap();

        vault.set_storage_limit_bytes(100).unwrap();

        let ids = vault
            .moments_sync(&session.id)
            .unwrap()
            .into_iter()
            .map(|moment| moment.id)
            .collect::<Vec<_>>();
        assert!(!ids.contains(&first.id));
        assert!(ids.contains(&second.id));
        assert!(ids.contains(&third.id));
        assert_eq!(vault.storage_limit_bytes(), 100);
        assert!(vault.storage_usage_bytes().unwrap() <= 100);
    }

    #[test]
    fn opening_vault_applies_persisted_storage_limit() {
        let directory = tempfile::tempdir().unwrap();
        let data_dir = directory.path().to_path_buf();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: data_dir.clone(),
                max_storage_bytes: 10_000,
            },
            [7_u8; 32],
        )
        .unwrap();
        let session = vault.create_session_sync(1).unwrap();
        let first = vault
            .insert_moment(&session.id, 1, "image/jpeg", b"one")
            .unwrap();
        vault
            .insert_moment(&session.id, 2, "image/jpeg", b"two")
            .unwrap();
        vault
            .insert_moment(&session.id, 3, "image/jpeg", b"three")
            .unwrap();
        drop(vault);

        let reopened = Vault::open_with_key(
            VaultConfig {
                data_dir,
                max_storage_bytes: 100,
            },
            [7_u8; 32],
        )
        .unwrap();
        let ids = reopened
            .moments_sync(&session.id)
            .unwrap()
            .into_iter()
            .map(|moment| moment.id)
            .collect::<Vec<_>>();
        assert!(!ids.contains(&first.id));
        assert!(reopened.storage_usage_bytes().unwrap() <= 100);
    }

    #[test]
    fn storage_retention_keeps_favorites() {
        let (_directory, vault) = test_vault_with_storage_limit(100);
        let session = vault.create_session_sync(1).unwrap();
        let favorite = vault
            .insert_moment(&session.id, 1, "image/jpeg", b"favorite")
            .unwrap();
        vault.set_favorite(&favorite.id, true).unwrap();
        let removable = vault
            .insert_moment(&session.id, 2, "image/jpeg", b"temporary")
            .unwrap();

        let ids = vault
            .moments_sync(&session.id)
            .unwrap()
            .into_iter()
            .map(|moment| moment.id)
            .collect::<Vec<_>>();
        assert!(ids.contains(&favorite.id));
        assert!(!ids.contains(&removable.id));
    }

    #[test]
    fn retention_keeps_unstarred_moments_when_their_shared_gop_is_pinned() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let first = vault
            .insert_moment(&session.id, 1, "image/jpeg", b"one")
            .unwrap();
        let second = vault
            .insert_moment(&session.id, 2, "image/jpeg", b"two")
            .unwrap();
        let ids = vec![first.id.clone(), second.id.clone()];
        let frames = vec![
            GopCommitFrame {
                index: 0,
                is_keyframe: true,
                byte_offset: 0,
                byte_length: 8,
                content_hash: [1; 32],
            },
            GopCommitFrame {
                index: 1,
                is_keyframe: false,
                byte_offset: 8,
                byte_length: 8,
                content_hash: [2; 32],
            },
        ];
        let segment = vault
            .commit_gop(GopCommitRequest {
                moment_ids: &ids,
                ivf: b"DKIF-fake",
                codec: "av01",
                encoder: "rav1e",
                encoder_version: "test",
                width: 32,
                height: 16,
                keyint: 12,
                started_at_ms: 1,
                ended_at_ms: 2,
                content_hash: "shared",
                frames: &frames,
            })
            .unwrap();
        vault.mark_gop_ready(&segment).unwrap();
        assert_eq!(vault.drop_unpinned_stills(&segment).unwrap(), 2);
        vault.set_favorite(&first.id, true).unwrap();
        let usage = vault.storage_usage_bytes().unwrap();

        vault.set_storage_limit_bytes(usage - 1).unwrap();

        let remaining = vault.moments_sync(&session.id).unwrap();
        assert_eq!(remaining.len(), 2);
        assert!(remaining.iter().any(|moment| moment.id == second.id));
        assert!(vault.storage_usage_bytes().unwrap() > vault.storage_limit_bytes());
    }

    #[test]
    fn semantic_search_uses_cosine_and_matching_model_version() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let first = vault
            .insert_moment(&session.id, 10, "image/jpeg", b"one")
            .unwrap();
        let second = vault
            .insert_moment(&session.id, 20, "image/jpeg", b"two")
            .unwrap();
        let first_evidence = vault
            .insert_text_evidence(
                &session.id,
                Some(&first.id),
                None,
                "ocr",
                "Rust ownership rules",
                10,
                None,
                "ocr-model",
                None,
            )
            .unwrap();
        let second_evidence = vault
            .insert_text_evidence(
                &session.id,
                Some(&second.id),
                None,
                "ocr",
                "weekly planning meeting",
                20,
                None,
                "ocr-model",
                None,
            )
            .unwrap();
        vault
            .insert_embedding(&first_evidence, &[1.0, 0.0], "embedding-model")
            .unwrap();
        // Both sit above SEMANTIC_MIN_SIMILARITY; ordering is what is under
        // test here, and the floor has its own test.
        vault
            .insert_embedding(&second_evidence, &[0.8, 0.6], "embedding-model")
            .unwrap();

        let hits = vault
            .semantic_search(&[0.9, 0.1], "embedding-model", 10)
            .unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].moment_id, first.id);
        assert!(hits[0].score > hits[1].score);
        assert!(
            vault
                .semantic_search(&[0.9, 0.1], "another-model", 10)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn embedding_rejects_empty_and_non_finite_vectors() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let evidence = vault
            .insert_text_evidence(
                &session.id,
                None,
                None,
                "ocr",
                "test",
                1,
                None,
                "ocr-model",
                None,
            )
            .unwrap();
        assert!(matches!(
            vault.insert_embedding(&evidence, &[], "embedding-model"),
            Err(StoreError::InvalidEmbedding(_))
        ));
        assert!(matches!(
            vault.insert_embedding(&evidence, &[f32::NAN], "embedding-model"),
            Err(StoreError::InvalidEmbedding(_))
        ));
    }

    fn ocr_evidence(vault: &Vault, session_id: &str, text: &str, at_ms: i64) -> String {
        vault
            .insert_text_evidence(
                session_id,
                None,
                None,
                "ocr",
                text,
                at_ms,
                None,
                "ocr-model",
                None,
            )
            .unwrap()
    }

    #[test]
    fn chinese_is_searchable_by_substring() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        ocr_evidence(&vault, &session.id, "今天的会议纪要写完了", 1);

        for query in ["会议", "会议纪要", "纪要", "今天的会议", "了"] {
            assert_eq!(
                vault.search(query, 10).unwrap().len(),
                1,
                "`{query}` should have matched"
            );
        }
        // Same characters, wrong order — a phrase of bigrams is still a
        // substring test, not a bag of words.
        assert!(vault.search("纪会", 10).unwrap().is_empty());
        assert!(vault.search("周报", 10).unwrap().is_empty());
    }

    #[test]
    fn a_phrase_cannot_straddle_two_separated_runs() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        ocr_evidence(&vault, &session.id, "开会 议程", 1);

        assert_eq!(vault.search("开会", 10).unwrap().len(), 1);
        assert_eq!(vault.search("议程", 10).unwrap().len(), 1);
        // 会 ends one run and 议 starts the next; they are not a word.
        assert!(vault.search("会议", 10).unwrap().is_empty());
        // A run's last character is still reachable on its own.
        assert_eq!(vault.search("会", 10).unwrap().len(), 1);
    }

    /// `々` stands in for the ideograph before it, so it is part of the word.
    /// While it was Latin, `時々` became `"時"* AND "々"` and matched any row
    /// holding both characters, however far apart.
    #[test]
    fn iteration_marks_only_match_where_they_are_adjacent() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        ocr_evidence(&vault, &session.id, "時計と長々しい話", 1);

        assert!(
            vault.search("時々", 10).unwrap().is_empty(),
            "時 and 々 are both present but never touching"
        );

        ocr_evidence(&vault, &session.id, "時々雨が降る", 2);
        assert_eq!(vault.search("時々", 10).unwrap().len(), 1);
        assert_eq!(vault.search("人々", 10).unwrap().len(), 0);
    }

    /// FTS5 throws the hyphen away when it indexes, so only a phrase carries
    /// the adjacency the user typed. As two AND'd terms, `retry-count` matched
    /// a row with a retry in one sentence and a count in another — and then had
    /// no `retry-count` on screen to highlight.
    #[test]
    fn punctuation_joined_words_have_to_be_adjacent() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        ocr_evidence(
            &vault,
            &session.id,
            "retry the request; the count was wrong",
            1,
        );

        assert!(
            vault.search("retry-count", 10).unwrap().is_empty(),
            "retry and count are both present but a whole clause apart"
        );

        ocr_evidence(&vault, &session.id, "build failed: retry-count exceeded", 2);
        assert_eq!(vault.search("retry-count", 10).unwrap().len(), 1);
        // Typed with a space, they are two terms again, and both rows qualify.
        assert_eq!(vault.search("retry count", 10).unwrap().len(), 2);
    }

    #[test]
    fn fts_syntax_in_a_query_is_matched_not_executed() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        ocr_evidence(&vault, &session.id, "build failed: retry-count exceeded", 1);

        assert_eq!(vault.search("retry-count", 10).unwrap().len(), 1);
        // These used to raise an FTS5 syntax error, which was swallowed and
        // silently turned the search into a semantic guess.
        for query in ["\"unbalanced", "AND", "* OR *", "(build"] {
            vault
                .search(query, 10)
                .unwrap_or_else(|error| panic!("`{query}` failed: {error}"));
        }
    }

    #[test]
    fn semantic_search_drops_neighbours_that_are_merely_nearest() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let near = ocr_evidence(&vault, &session.id, "close enough", 1);
        let far = ocr_evidence(&vault, &session.id, "nothing to do with it", 2);
        vault.insert_embedding(&near, &[1.0, 0.05], "test").unwrap();
        vault.insert_embedding(&far, &[0.0, 1.0], "test").unwrap();

        let hits = vault.semantic_search(&[1.0, 0.0], "test", 10).unwrap();
        assert_eq!(hits.len(), 1, "the far neighbour was still returned");
        assert_eq!(hits[0].text, "close enough");
    }

    #[test]
    fn reopening_an_older_vault_refolds_the_text_index() {
        let directory = tempfile::tempdir().unwrap();
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            max_storage_bytes: 10_000_000_000,
        };

        {
            let vault = Vault::open_with_key(config.clone(), [7_u8; 32]).unwrap();
            let session = vault.create_session_sync(1).unwrap();
            let id = ocr_evidence(&vault, &session.id, "今天的会议纪要", 1);
            // Put the index back the way a pre-17 build wrote it: raw text, one
            // unsplittable token.
            let connection = vault.connection.lock().unwrap();
            connection.execute("DELETE FROM evidence_fts", []).unwrap();
            connection
                .execute(
                    "INSERT INTO evidence_fts (evidence_id, text) VALUES (?1, ?2)",
                    params![id, "今天的会议纪要"],
                )
                .unwrap();
            connection
                .execute("UPDATE schema_meta SET version = 16", [])
                .unwrap();
            drop(connection);
            assert!(
                vault.search("会议", 10).unwrap().is_empty(),
                "the old index was supposed to be unsearchable"
            );
        }

        let vault = Vault::open_with_key(config, [7_u8; 32]).unwrap();
        assert_eq!(vault.search("会议", 10).unwrap().len(), 1);
    }

    /// 17 was folded already, just by rules that left `々` outside the run.
    /// Without the bump those rows keep a fold the query no longer asks for.
    #[test]
    fn a_vault_stamped_seventeen_is_refolded_for_the_new_run_rules() {
        let directory = tempfile::tempdir().unwrap();
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            max_storage_bytes: 10_000_000_000,
        };

        {
            let vault = Vault::open_with_key(config.clone(), [7_u8; 32]).unwrap();
            let session = vault.create_session_sync(1).unwrap();
            let id = ocr_evidence(&vault, &session.id, "時々雨が降る", 1);
            let connection = vault.connection.lock().unwrap();
            connection.execute("DELETE FROM evidence_fts", []).unwrap();
            // What index_text produced while 々 broke the run in two.
            connection
                .execute(
                    "INSERT INTO evidence_fts (evidence_id, text) VALUES (?1, ?2)",
                    params![id, "時 々 雨が が降 降る る "],
                )
                .unwrap();
            connection
                .execute("UPDATE schema_meta SET version = 17", [])
                .unwrap();
            drop(connection);
            assert!(
                vault.search("時々", 10).unwrap().is_empty(),
                "the 17-era fold has no 時々 bigram to find"
            );
        }

        let vault = Vault::open_with_key(config, [7_u8; 32]).unwrap();
        assert_eq!(vault.search("時々", 10).unwrap().len(), 1);
    }

    #[test]
    fn fusion_deduplicates_and_has_deterministic_order() {
        fn hit(id: &str, time: i64) -> SearchHit {
            SearchHit {
                moment_id: id.to_owned(),
                session_id: "session".to_owned(),
                captured_at_ms: time,
                source: "ocr".to_owned(),
                text: format!("text-{id}"),
                score: 0.0,
            }
        }

        let fused = fuse_search_results(
            vec![hit("a", 1), hit("b", 2)],
            vec![hit("b", 2), hit("c", 3)],
            10,
        );
        assert_eq!(fused.len(), 3);
        assert_eq!(fused[0].moment_id, "b");
        assert_eq!(
            fused
                .iter()
                .filter(|candidate| candidate.moment_id == "b")
                .count(),
            1
        );
        // A is rank 1 in FTS while C is rank 2 in semantic search.
        assert_eq!(fused[1].moment_id, "a");
        assert_eq!(fused[2].moment_id, "c");
    }

    #[test]
    fn schema_6_adds_gop_and_idle_tables() {
        let (_directory, vault) = test_vault(10);
        let connection = vault.connection.lock().unwrap();
        let version: i64 = connection
            .query_row("SELECT version FROM schema_meta", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, i64::from(SCHEMA_VERSION));
        let has_idle: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name = 'idle_spans'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let has_gop: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name = 'gop_segments'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(has_idle, 1);
        assert_eq!(has_gop, 1);
        let image_not_null: i64 = {
            let mut statement = connection.prepare("PRAGMA table_info(moments)").unwrap();
            statement
                .query_map([], |row| {
                    Ok((row.get::<_, String>(1)?, row.get::<_, i64>(3)?))
                })
                .unwrap()
                .map(Result::unwrap)
                .find(|(name, _)| name == "image_artifact_id")
                .map(|(_, notnull)| notnull)
                .unwrap()
        };
        assert_eq!(image_not_null, 0);
    }

    /// The exclusion path deletes a moment that has already been captured,
    /// while its OCR job is still in flight. Whichever order the two land in,
    /// none of the excluded app's text may be left searchable.
    #[test]
    fn deleting_a_moment_leaves_no_text_behind() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 2, "image/jpeg", b"frame")
            .unwrap();

        // OCR won the race: the evidence is already indexed when the
        // accessibility snapshot names an excluded app.
        let evidence = vault
            .insert_text_evidence(
                &session.id,
                Some(&moment.id),
                None,
                "ocr",
                "master password vault",
                2,
                None,
                "test",
                None,
            )
            .unwrap();
        vault
            .insert_embedding(&evidence, &[0.1, 0.2], "test")
            .unwrap();
        assert_eq!(vault.search("password", 10).unwrap().len(), 1);

        vault.delete_moment_and_artifacts(&moment.id).unwrap();

        assert!(vault.search("password", 10).unwrap().is_empty());
        let connection = vault.connection.lock().unwrap();
        let evidence_rows: i64 = connection
            .query_row("SELECT COUNT(*) FROM text_evidence", [], |row| row.get(0))
            .unwrap();
        assert_eq!(evidence_rows, 0, "cascade must take the evidence row");
        let fts_rows: i64 = connection
            .query_row("SELECT COUNT(*) FROM evidence_fts", [], |row| row.get(0))
            .unwrap();
        assert_eq!(fts_rows, 0, "a stale FTS row keeps the text searchable");
        let embedding_rows: i64 = connection
            .query_row("SELECT COUNT(*) FROM embeddings", [], |row| row.get(0))
            .unwrap();
        assert_eq!(embedding_rows, 0, "cascade must take the embedding");
    }

    /// The other order: the moment is deleted first and OCR finishes after.
    /// The foreign key is what stops the text from landing, so it has to fail
    /// loudly rather than write an orphan row that nothing will ever clean up.
    #[test]
    fn text_recognized_after_the_moment_was_deleted_is_refused() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 2, "image/jpeg", b"frame")
            .unwrap();
        vault.delete_moment_and_artifacts(&moment.id).unwrap();

        let refused = vault.insert_text_evidence(
            &session.id,
            Some(&moment.id),
            None,
            "ocr",
            "master password vault",
            2,
            None,
            "test",
            None,
        );

        assert!(refused.is_err(), "an orphan OCR row must not be accepted");
        assert!(vault.search("password", 10).unwrap().is_empty());
        let fts_rows: i64 = vault
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM evidence_fts", [], |row| row.get(0))
            .unwrap();
        assert_eq!(fts_rows, 0, "the FTS insert must not run after the failure");
    }

    #[test]
    fn insert_moment_stores_jpeg_dimensions() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x20, 0x01, 0x01, 0x11,
            0x00, 0xFF, 0xD9,
        ];
        let moment = vault
            .insert_moment(&session.id, 2, "image/jpeg", &jpeg)
            .unwrap();
        let (width, height): (Option<i64>, Option<i64>) = vault
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT width, height FROM moments WHERE id = ?1",
                [&moment.id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(width, Some(32));
        assert_eq!(height, Some(16));
    }

    #[test]
    fn idle_spans_open_once_and_close() {
        let (_directory, vault) = test_vault(10);
        let first = vault.begin_idle_span(100, "lock").unwrap();
        let again = vault.begin_idle_span(200, "lock").unwrap();
        assert_eq!(first, again);
        assert_eq!(vault.end_open_idle_spans(300).unwrap(), 1);
        let spans = vault.idle_spans_sync().unwrap();
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].2, Some(300));
        let second = vault.begin_idle_span(400, "sleep").unwrap();
        assert_ne!(first, second);
    }

    #[test]
    fn commit_gop_then_retention_drops_a_live_index() {
        let (_directory, vault) = test_vault(6);
        let session = vault.create_session_sync(1).unwrap();
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x20, 0x01, 0x01, 0x11,
            0x00, 0xFF, 0xD9,
        ];
        let mut ids = Vec::new();
        for index in 0..6 {
            let moment = vault
                .insert_moment(&session.id, 10_000 * i64::from(index), "image/jpeg", &jpeg)
                .unwrap();
            vault
                .insert_text_evidence(
                    &session.id,
                    Some(&moment.id),
                    None,
                    "ocr",
                    "text",
                    10_000 * i64::from(index),
                    None,
                    "ocr",
                    None,
                )
                .unwrap();
            ids.push(moment.id);
        }
        let ivf = b"DKIF\0\0\0\0AV01fake-gop-bytes";
        let frames: Vec<GopCommitFrame> = (0..6)
            .map(|index| GopCommitFrame {
                index,
                is_keyframe: index == 0,
                byte_offset: u32::from(index) * 10,
                byte_length: 10,
                content_hash: [index as u8; 32],
            })
            .collect();
        let segment = vault
            .commit_gop(GopCommitRequest {
                moment_ids: &ids,
                ivf,
                codec: "av01",
                encoder: "rav1e",
                encoder_version: "test",
                width: 32,
                height: 16,
                keyint: 12,
                started_at_ms: 0,
                ended_at_ms: 50_000,
                content_hash: "abc",
                frames: &frames,
            })
            .unwrap();
        let live = vault.live_gop_frames(&segment).unwrap();
        assert_eq!(live.len(), 6);
        let storage_before_new_moment = vault.storage_usage_bytes().unwrap();
        vault
            .set_storage_limit_bytes(storage_before_new_moment)
            .unwrap();
        vault
            .insert_moment(&session.id, 80_000, "image/jpeg", &jpeg)
            .unwrap();
        let remaining = vault.live_gop_frames(&segment).unwrap();
        assert_eq!(remaining.len(), 5);
        assert!(remaining.iter().all(|frame| frame.moment_id != ids[0]));
    }

    #[test]
    fn drop_unpinned_stills_nulls_every_packed_jpeg() {
        let (_directory, vault) = test_vault(20);
        let session = vault.create_session_sync(1).unwrap();
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x20, 0x01, 0x01, 0x11,
            0x00, 0xFF, 0xD9,
        ];
        let mut ids = Vec::new();
        for index in 0..3 {
            let moment = vault
                .insert_moment(&session.id, 10_000 * i64::from(index), "image/jpeg", &jpeg)
                .unwrap();
            ids.push(moment.id);
        }
        let frames: Vec<GopCommitFrame> = (0..3)
            .map(|index| GopCommitFrame {
                index,
                is_keyframe: index == 0,
                byte_offset: u32::from(index) * 8,
                byte_length: 8,
                content_hash: [index as u8; 32],
            })
            .collect();
        let segment = vault
            .commit_gop(GopCommitRequest {
                moment_ids: &ids,
                ivf: b"DKIF-fake",
                codec: "av01",
                encoder: "rav1e",
                encoder_version: "test",
                width: 32,
                height: 16,
                keyint: 12,
                started_at_ms: 0,
                ended_at_ms: 20_000,
                content_hash: "abc",
                frames: &frames,
            })
            .unwrap();
        vault.mark_gop_ready(&segment).unwrap();
        assert_eq!(vault.drop_unpinned_stills(&segment).unwrap(), 3);
        let moments = vault.moments_sync(&session.id).unwrap();
        let by_id: std::collections::HashMap<_, _> = moments
            .into_iter()
            .map(|moment| (moment.id.clone(), moment))
            .collect();
        assert!(by_id[&ids[0]].image_artifact_id.is_none());
        assert!(by_id[&ids[1]].image_artifact_id.is_none());
        assert!(by_id[&ids[2]].image_artifact_id.is_none());
        assert!(by_id[&ids[0]].gop.is_some());
    }

    #[test]
    fn abort_gop_restores_stills_and_deletes_the_segment() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x20, 0x01, 0x01, 0x11,
            0x00, 0xFF, 0xD9,
        ];
        let moment = vault
            .insert_moment(&session.id, 10_000, "image/jpeg", &jpeg)
            .unwrap();
        let still = moment.image_artifact_id.clone().expect("still");
        let frames = [GopCommitFrame {
            index: 0,
            is_keyframe: true,
            byte_offset: 0,
            byte_length: 8,
            content_hash: [1; 32],
        }];
        let segment = vault
            .commit_gop(GopCommitRequest {
                moment_ids: &[moment.id.clone()],
                ivf: b"DKIF-fake",
                codec: "av01",
                encoder: "rav1e",
                encoder_version: "test",
                width: 32,
                height: 16,
                keyint: 1,
                started_at_ms: 10_000,
                ended_at_ms: 10_000,
                content_hash: "abc",
                frames: &frames,
            })
            .unwrap();
        vault.abort_gop(&segment).unwrap();
        let restored = vault.moments_sync(&session.id).unwrap();
        assert_eq!(restored.len(), 1);
        assert_eq!(
            restored[0].image_artifact_id.as_deref(),
            Some(still.as_str())
        );
        assert!(restored[0].gop.is_none());
        assert!(matches!(
            vault.gop_segment(&segment),
            Err(StoreError::GopNotFound(_))
        ));
    }

    #[test]
    fn reconcile_drops_leftover_dual_stills() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x20, 0x01, 0x01, 0x11,
            0x00, 0xFF, 0xD9,
        ];
        let mut ids = Vec::new();
        for index in 0..2 {
            ids.push(
                vault
                    .insert_moment(&session.id, 10_000 * i64::from(index), "image/jpeg", &jpeg)
                    .unwrap()
                    .id,
            );
        }
        let frames: Vec<GopCommitFrame> = (0..2)
            .map(|index| GopCommitFrame {
                index,
                is_keyframe: index == 0,
                byte_offset: u32::from(index) * 8,
                byte_length: 8,
                content_hash: [index as u8; 32],
            })
            .collect();
        let segment = vault
            .commit_gop(GopCommitRequest {
                moment_ids: &ids,
                ivf: b"DKIF-fake",
                codec: "av01",
                encoder: "rav1e",
                encoder_version: "test",
                width: 32,
                height: 16,
                keyint: 12,
                started_at_ms: 0,
                ended_at_ms: 10_000,
                content_hash: "abc",
                frames: &frames,
            })
            .unwrap();
        assert_eq!(
            vault.reconcile_packed_stills().unwrap(),
            0,
            "writing GOP must not drop stills"
        );
        vault.mark_gop_ready(&segment).unwrap();
        assert_eq!(vault.reconcile_packed_stills().unwrap(), 2);
        let moments = vault.moments_sync(&session.id).unwrap();
        assert!(
            moments
                .iter()
                .all(|moment| moment.image_artifact_id.is_none())
        );
        assert!(moments.iter().all(|moment| moment.gop.is_some()));
    }

    #[test]
    fn pack_candidates_skip_hot_loginwindow_and_already_packed() {
        let (_directory, vault) = test_vault(100);
        let session = vault.create_session_sync(1).unwrap();
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x20, 0x01, 0x01, 0x11,
            0x00, 0xFF, 0xD9,
        ];
        let cold = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", &jpeg)
            .unwrap();
        let login = vault
            .insert_moment(&session.id, 2_000, "image/jpeg", &jpeg)
            .unwrap();
        let hot = vault
            .insert_moment(&session.id, 8_000_000, "image/jpeg", &jpeg)
            .unwrap();
        vault
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE moments SET application_name = 'loginwindow',
                        bundle_identifier = 'com.apple.loginwindow'
                  WHERE id = ?1",
                [&login.id],
            )
            .unwrap();
        for moment in [&cold, &login, &hot] {
            vault
                .insert_text_evidence(
                    &session.id,
                    Some(&moment.id),
                    None,
                    "ocr",
                    "text",
                    moment.captured_at_ms,
                    None,
                    "ocr",
                    None,
                )
                .unwrap();
        }
        let policy = PackPolicy {
            hot_window_ms: 7_200_000,
            hot_min_stills: 0,
            ocr_grace_ms: 0,
            keyint: 12,
        };
        let candidates = vault.list_pack_candidates(8_100_000, &policy).unwrap();
        assert_eq!(
            candidates.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(),
            vec![cold.id.as_str()]
        );

        let frames = [GopCommitFrame {
            index: 0,
            is_keyframe: true,
            byte_offset: 0,
            byte_length: 8,
            content_hash: [0; 32],
        }];
        let segment = vault
            .commit_gop(GopCommitRequest {
                moment_ids: &[cold.id.clone()],
                ivf: b"DKIF-fake",
                codec: "av01",
                encoder: "rav1e",
                encoder_version: "test",
                width: 32,
                height: 16,
                keyint: 1,
                started_at_ms: 1_000,
                ended_at_ms: 1_000,
                content_hash: "abc",
                frames: &frames,
            })
            .unwrap();
        vault.drop_unpinned_stills(&segment).unwrap();
        let after_pack = vault.list_pack_candidates(8_100_000, &policy).unwrap();
        assert!(after_pack.is_empty());
    }

    #[test]
    fn commit_gop_stale_does_not_leave_a_dek() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x20, 0x01, 0x01, 0x11,
            0x00, 0xFF, 0xD9,
        ];
        let first = vault
            .insert_moment(&session.id, 10_000, "image/jpeg", &jpeg)
            .unwrap();
        let second = vault
            .insert_moment(&session.id, 20_000, "image/jpeg", &jpeg)
            .unwrap();
        vault
            .connection
            .lock()
            .unwrap()
            .execute("DELETE FROM moments WHERE id = ?1", [&second.id])
            .unwrap();
        let frames = [
            GopCommitFrame {
                index: 0,
                is_keyframe: true,
                byte_offset: 0,
                byte_length: 8,
                content_hash: [1; 32],
            },
            GopCommitFrame {
                index: 1,
                is_keyframe: false,
                byte_offset: 8,
                byte_length: 8,
                content_hash: [2; 32],
            },
        ];
        let error = vault
            .commit_gop(GopCommitRequest {
                moment_ids: &[first.id, second.id],
                ivf: b"DKIF-stale",
                codec: "av01",
                encoder: "rav1e",
                encoder_version: "test",
                width: 32,
                height: 16,
                keyint: 12,
                started_at_ms: 10_000,
                ended_at_ms: 20_000,
                content_hash: "abc",
                frames: &frames,
            })
            .unwrap_err();
        assert!(matches!(error, StoreError::GopStale));
        let ivf_rows: i64 = vault
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM artifacts WHERE content_type LIKE 'video/x-ivf%'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(ivf_rows, 0);
        assert_eq!(vault.cleanup_unreferenced_gop_artifacts().unwrap(), 0);
    }

    #[test]
    fn cleanup_drops_ivf_artifacts_without_a_segment() {
        let (_directory, vault) = test_vault(10);
        let orphan = vault
            .put_artifact("video/x-ivf; codec=av01", b"DKIF-orphan")
            .unwrap();
        assert_eq!(vault.cleanup_unreferenced_gop_artifacts().unwrap(), 1);
        let leftover: i64 = vault
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM artifacts WHERE id = ?1",
                [&orphan],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(leftover, 0);
        assert!(!vault.artifact_path(&orphan).exists());
    }

    #[test]
    fn schema_7_recovers_when_moments_was_emptied_mid_rebuild() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let jpeg = [
            0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x20, 0x01, 0x01, 0x11,
            0x00, 0xFF, 0xD9,
        ];
        let moment = vault
            .insert_moment(&session.id, 10_000, "image/jpeg", &jpeg)
            .unwrap();
        {
            let connection = vault.connection.lock().unwrap();
            connection
                .execute_batch(
                    "PRAGMA foreign_keys = OFF;
                     CREATE TABLE moments_v7 AS SELECT * FROM moments;
                     DELETE FROM moments;
                     PRAGMA foreign_keys = ON;",
                )
                .unwrap();
            migrate_schema_7(&connection).unwrap();
        }
        let restored = vault.moments_sync(&session.id).unwrap();
        assert_eq!(restored.len(), 1);
        assert_eq!(restored[0].id, moment.id);
        assert!(restored[0].image_artifact_id.is_some());
    }

    #[test]
    fn loginwindow_accessibility_deletes_the_moment() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 10, "image/jpeg", b"screen")
            .unwrap();
        let attached = vault
            .attach_accessibility_snapshot(
                &session.id,
                10,
                "application/json",
                b"{}",
                Some("loginwindow"),
                Some("com.apple.loginwindow"),
            )
            .unwrap();
        assert!(attached.is_none());
        assert!(vault.moments_sync(&session.id).unwrap().is_empty());
        let leftover = vault
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM artifacts WHERE id = ?1",
                [moment.image_artifact_id.as_deref().unwrap()],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();
        assert_eq!(leftover, 0);
    }

    #[test]
    fn safari_ax_fixture_attaches_url_to_the_moment() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        vault
            .insert_moment(&session.id, 10_000, "image/jpeg", b"screen")
            .unwrap();
        let snapshot = br#"{
            "application_name": "Safari",
            "bundle_identifier": "com.apple.Safari",
            "window_title": "Example Domain",
            "url": "https://example.com/",
            "root": {
                "role": "AXApplication",
                "children": [{
                    "role": "AXWindow",
                    "title": "Example Domain",
                    "children": [{
                        "role": "AXWebArea",
                        "url": "https://example.com/"
                    }]
                }]
            }
        }"#;
        assert!(
            vault
                .attach_accessibility_snapshot(
                    &session.id,
                    10_000,
                    "application/vnd.afterray.ax+json",
                    snapshot,
                    None,
                    None,
                )
                .unwrap()
                .is_some()
        );
        let moment = &vault.moments_sync(&session.id).unwrap()[0];
        assert_eq!(moment.application_name.as_deref(), Some("Safari"));
        assert_eq!(
            moment.bundle_identifier.as_deref(),
            Some("com.apple.Safari")
        );
        assert_eq!(moment.window_title.as_deref(), Some("Example Domain"));
        assert_eq!(moment.url.as_deref(), Some("https://example.com/"));
        assert!(moment.document.is_none());
    }

    #[test]
    fn chrome_like_tree_url_is_copied_onto_the_moment() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        vault
            .insert_moment(&session.id, 20, "image/jpeg", b"screen")
            .unwrap();
        let snapshot = br#"{
            "application_name": "Google Chrome",
            "bundle_identifier": "com.google.Chrome",
            "root": {
                "role": "AXApplication",
                "children": [{
                    "role": "AXWindow",
                    "title": "Example Domain",
                    "children": [{
                        "role": "AXWebArea",
                        "title": "Example Domain",
                        "url": "https://example.com/"
                    }]
                }]
            }
        }"#;
        vault
            .attach_accessibility_snapshot(
                &session.id,
                20,
                "application/vnd.afterray.ax+json",
                snapshot,
                Some("Google Chrome"),
                Some("com.google.Chrome"),
            )
            .unwrap();
        let moment = &vault.moments_sync(&session.id).unwrap()[0];
        assert_eq!(moment.url.as_deref(), Some("https://example.com/"));
        assert_eq!(moment.window_title.as_deref(), Some("Example Domain"));
    }

    #[test]
    fn private_browsing_snapshot_cannot_attach_a_url_to_the_moment() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        vault
            .insert_moment(&session.id, 20, "image/jpeg", b"screen")
            .unwrap();
        let snapshot = br#"{
            "application_name": "Google Chrome",
            "bundle_identifier": "com.google.Chrome",
            "private_browsing": true,
            "window_title": "Private account",
            "url": "https://private.example/account",
            "root": {
                "role": "AXWindow",
                "children": [{
                    "role": "AXWebArea",
                    "url": "https://private.example/account"
                }]
            }
        }"#;

        vault
            .attach_accessibility_snapshot(
                &session.id,
                20,
                "application/vnd.afterray.ax+json",
                snapshot,
                Some("Google Chrome"),
                Some("com.google.Chrome"),
            )
            .unwrap();

        let moment = &vault.moments_sync(&session.id).unwrap()[0];
        assert_eq!(moment.window_title.as_deref(), Some("Private account"));
        assert!(moment.url.is_none());
    }

    #[test]
    fn activity_spans_merge_consecutive_moments_with_duration() {
        let (_directory, vault) = test_vault(20);
        let session = vault.create_session_sync(1).unwrap();
        let first = vault
            .insert_moment(&session.id, 0, "image/jpeg", b"one")
            .unwrap();
        let second = vault
            .insert_moment(&session.id, 10_000, "image/jpeg", b"two")
            .unwrap();
        let third = vault
            .insert_moment(&session.id, 1_560_000, "image/jpeg", b"three")
            .unwrap();
        let fourth = vault
            .insert_moment(&session.id, 1_570_000, "image/jpeg", b"four")
            .unwrap();
        let safari = br#"{"application_name":"Safari","bundle_identifier":"com.apple.Safari","window_title":"Example Domain","url":"https://example.com/"}"#;
        let xcode = br#"{"application_name":"Xcode","bundle_identifier":"com.apple.dt.Xcode","window_title":"Package.swift","document":"/tmp/Package.swift"}"#;
        vault
            .attach_accessibility_snapshot(
                &session.id,
                0,
                "application/vnd.afterray.ax+json",
                safari,
                None,
                None,
            )
            .unwrap();
        vault
            .attach_accessibility_snapshot(
                &session.id,
                10_000,
                "application/vnd.afterray.ax+json",
                safari,
                None,
                None,
            )
            .unwrap();
        vault
            .attach_accessibility_snapshot(
                &session.id,
                1_560_000,
                "application/vnd.afterray.ax+json",
                safari,
                None,
                None,
            )
            .unwrap();
        vault
            .attach_accessibility_snapshot(
                &session.id,
                1_570_000,
                "application/vnd.afterray.ax+json",
                xcode,
                None,
                None,
            )
            .unwrap();

        let spans = vault.activity_spans(0, 2_000_000, 10).unwrap();
        assert_eq!(spans.len(), 2);
        assert_eq!(spans[0].application_name.as_deref(), Some("Safari"));
        assert_eq!(spans[0].url.as_deref(), Some("https://example.com/"));
        assert_eq!(spans[0].start_ms, 0);
        assert_eq!(spans[0].end_ms, 1_570_000);
        assert_eq!(spans[0].duration_ms, 1_570_000);
        assert_eq!(
            spans[0].moment_ids,
            [first.id.clone(), second.id.clone(), third.id.clone()]
        );
        assert_eq!(spans[1].application_name.as_deref(), Some("Xcode"));
        assert_eq!(
            spans[1].document.as_deref(),
            Some("file:///tmp/Package.swift")
        );
        assert_eq!(spans[1].moment_ids, [fourth.id]);
        assert!(vault.activity_spans(2_000_000, 0, 10).unwrap().is_empty());
    }

    #[test]
    fn ocr_layout_json_is_stored_and_readable() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"screen")
            .unwrap();
        let layout =
            r#"[{"text":"Hello","confidence":0.9,"x":0.1,"y":0.2,"width":0.3,"height":0.05}]"#;
        vault
            .insert_text_evidence(
                &session.id,
                Some(&moment.id),
                None,
                "ocr",
                "Hello",
                1_000,
                None,
                "vision-ocr",
                Some(layout),
            )
            .unwrap();
        let stored = vault.ocr_layout_for_moment(&moment.id).unwrap();
        assert_eq!(stored.as_deref(), Some(layout));
        assert!(vault.ocr_layout_for_moment("missing").unwrap().is_none());
    }

    /// Builds an AX snapshot payload carrying just the activity header fields.
    fn ax_snapshot(window_title: &str, url: Option<&str>) -> Vec<u8> {
        let mut header = serde_json::json!({ "window_title": window_title });
        if let Some(url) = url {
            header["url"] = serde_json::Value::String(url.to_owned());
        }
        serde_json::to_vec(&header).unwrap()
    }

    fn window_evidence_texts(vault: &Vault, session_id: &str) -> Vec<String> {
        let connection = vault.connection.lock().unwrap();
        let mut statement = connection
            .prepare(
                "SELECT text FROM text_evidence
                  WHERE session_id = ?1 AND source = 'window'
                  ORDER BY started_at_ms ASC",
            )
            .unwrap();
        let rows = statement
            .query_map([session_id], |row| row.get::<_, String>(0))
            .unwrap();
        rows.collect::<Result<Vec<_>, _>>().unwrap()
    }

    #[test]
    fn window_titles_are_indexed_and_searchable() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"screen")
            .unwrap();
        vault
            .attach_accessibility_snapshot(
                &session.id,
                1_000,
                "application/json",
                &ax_snapshot("Quarterly roadmap.key", Some("https://example.com/deck")),
                Some("Keynote"),
                Some("com.apple.iWork.Keynote"),
            )
            .unwrap()
            .unwrap();

        assert_eq!(
            window_evidence_texts(&vault, &session.id),
            vec!["Quarterly roadmap.key\nhttps://example.com/deck".to_owned()]
        );

        // The whole point: a title that never appeared as OCR text is findable.
        let hits = vault.search("roadmap", 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].moment_id, moment.id);
        assert_eq!(hits[0].source, WINDOW_EVIDENCE_SOURCE);
    }

    #[test]
    fn repeated_window_titles_are_indexed_once_per_dedupe_window() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        // Capture fires every ~10s; the same window title must not produce a
        // row per frame.
        for step in 0..4_i64 {
            let at = 1_000 + step * 10_000;
            vault
                .insert_moment(&session.id, at, "image/jpeg", b"screen")
                .unwrap();
            vault
                .attach_accessibility_snapshot(
                    &session.id,
                    at,
                    "application/json",
                    &ax_snapshot("Inbox", None),
                    Some("Mail"),
                    Some("com.apple.mail"),
                )
                .unwrap()
                .unwrap();
        }
        assert_eq!(window_evidence_texts(&vault, &session.id).len(), 1);

        // Past the dedupe window the same title is a genuinely new visit.
        let later = 1_000 + WINDOW_TITLE_DEDUPE_MS + 10_000;
        vault
            .insert_moment(&session.id, later, "image/jpeg", b"screen")
            .unwrap();
        vault
            .attach_accessibility_snapshot(
                &session.id,
                later,
                "application/json",
                &ax_snapshot("Inbox", None),
                Some("Mail"),
                Some("com.apple.mail"),
            )
            .unwrap()
            .unwrap();
        assert_eq!(window_evidence_texts(&vault, &session.id).len(), 2);
    }

    #[test]
    fn moments_without_a_window_title_index_nothing() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"screen")
            .unwrap();
        vault
            .attach_accessibility_snapshot(
                &session.id,
                1_000,
                "application/json",
                &ax_snapshot("   ", None),
                Some("Finder"),
                Some("com.apple.finder"),
            )
            .unwrap()
            .unwrap();
        assert!(window_evidence_texts(&vault, &session.id).is_empty());
    }

    #[test]
    fn deleting_a_moment_drops_its_window_evidence_from_fts() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"screen")
            .unwrap();
        vault
            .attach_accessibility_snapshot(
                &session.id,
                1_000,
                "application/json",
                &ax_snapshot("Secret project plan", None),
                Some("Notes"),
                Some("com.apple.Notes"),
            )
            .unwrap()
            .unwrap();
        assert_eq!(vault.search("Secret", 10).unwrap().len(), 1);

        vault.delete_moment_and_artifacts(&moment.id).unwrap();
        assert!(vault.search("Secret", 10).unwrap().is_empty());
    }

    #[test]
    fn thumbnails_round_trip_and_replace_cleanly() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"screen")
            .unwrap();
        assert!(vault.thumbnail_artifact_id(&moment.id).unwrap().is_none());

        let first = vault.set_thumbnail(&moment.id, b"thumb-one").unwrap();
        assert_eq!(
            vault.thumbnail_artifact_id(&moment.id).unwrap().as_deref(),
            Some(first.as_str())
        );
        assert_eq!(vault.read_artifact(&first).unwrap().bytes, b"thumb-one");

        let second = vault.set_thumbnail(&moment.id, b"thumb-two").unwrap();
        assert_ne!(first, second);
        assert_eq!(vault.read_artifact(&second).unwrap().bytes, b"thumb-two");
        // The superseded thumbnail must not linger as an orphan artifact.
        assert!(vault.read_artifact(&first).is_err());
        assert!(!vault.artifact_path(&first).exists());
    }

    #[test]
    fn thumbnails_survive_packing_but_not_deletion() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"screen")
            .unwrap();
        let thumbnail = vault.set_thumbnail(&moment.id, b"thumb").unwrap();

        vault.delete_moment_and_artifacts(&moment.id).unwrap();
        assert!(vault.read_artifact(&thumbnail).is_err());
        assert!(!vault.artifact_path(&thumbnail).exists());
    }

    #[test]
    fn retention_reclaims_thumbnail_artifacts() {
        // The limit is a byte budget, so it has to be small enough that one
        // moment plus its thumbnail already exceeds it; a count would not
        // evict anything here.
        let (_directory, vault) = test_vault_with_storage_limit(
            u64::try_from(ARTIFACT_FILE_OVERHEAD_BYTES).unwrap_or(0) + 64,
        );
        let session = vault.create_session_sync(1).unwrap();
        let evicted = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"old")
            .unwrap();
        let thumbnail = vault.set_thumbnail(&evicted.id, b"thumb").unwrap();
        vault
            .insert_moment(&session.id, 2_000, "image/jpeg", b"new")
            .unwrap();

        vault.enforce_retention().unwrap();
        assert!(vault.read_artifact(&thumbnail).is_err());
        assert!(!vault.artifact_path(&thumbnail).exists());
    }

    /// Upgrading must not cost a user their history.
    ///
    /// Every other migration test starts from an empty vault, which cannot
    /// catch a migration that silently drops or rebuilds rows. This one fills a
    /// vault the way a real one fills up — stills, OCR boxes, transcripts,
    /// audio, favorites, memories, and a moment already packed into a cold GOP
    /// — winds the schema back to 10, and reopens.
    struct SeededVault {
        session_id: String,
        hot_moment: String,
        packed_moment: String,
        still_artifact: String,
    }

    /// Fills a vault the way a real one fills up, then winds the schema back to
    /// 10 so reopening it exercises the upgrade path.
    fn seed_then_downgrade_to_schema_10(config: &VaultConfig, key: [u8; 32]) -> SeededVault {
        let vault = Vault::open_with_key(config.clone(), key).unwrap();
        let session = vault.create_session_sync(1_000).unwrap();

        let hot = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"hot-still-bytes")
            .unwrap();
        vault
            .attach_accessibility_snapshot(
                &session.id,
                1_000,
                "application/json",
                &ax_snapshot("Quarterly roadmap.key", Some("https://example.com/deck")),
                Some("Keynote"),
                Some("com.apple.iWork.Keynote"),
            )
            .unwrap()
            .unwrap();
        vault
            .insert_text_evidence(
                &session.id,
                Some(&hot.id),
                None,
                "ocr",
                "revenue projection",
                1_000,
                None,
                "vision-ocr",
                Some(r#"[{"text":"revenue","confidence":0.9,"x":0.1,"y":0.2,"width":0.3,"height":0.05}]"#),
            )
            .unwrap();
        vault.set_favorite(&hot.id, true).unwrap();

        // A moment that already lives in a cold GOP: its still is gone, so
        // the new delete/retention paths must tolerate the NULL.
        let packed = vault
            .insert_moment(&session.id, 2_000, "image/jpeg", b"packed-still")
            .unwrap();
        vault
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE moments
                    SET image_artifact_id = NULL, gop_segment_id = 'seg-1', gop_index = 3
                  WHERE id = ?1",
                [&packed.id],
            )
            .unwrap();

        vault
            .insert_memory(&Memory {
                id: "mem-upgrade".into(),
                start_ms: 1_000,
                end_ms: 2_000,
                moment_id: Some(hot.id.clone()),
                application_name: Some("Keynote".into()),
                bundle_identifier: Some("com.apple.iWork.Keynote".into()),
                window_title: Some("Quarterly roadmap.key".into()),
                url: None,
                document: None,
                summary: "Reviewed the deck".into(),
                fingerprint: "fp-1".into(),
            })
            .unwrap();

        // Wind the schema back to what a pre-upgrade vault looks like.
        vault
            .connection
            .lock()
            .unwrap()
            .execute_batch(
                "ALTER TABLE moments DROP COLUMN thumbnail_artifact_id;
                 DROP INDEX IF EXISTS text_evidence_session_source;
                 UPDATE schema_meta SET version = 10;",
            )
            .unwrap();

        SeededVault {
            session_id: session.id,
            hot_moment: hot.id,
            packed_moment: packed.id,
            still_artifact: hot.image_artifact_id.clone().unwrap(),
        }
    }

    /// Upgrading must not cost a user their history. Every other migration test
    /// starts from an empty vault, which cannot catch a migration that silently
    /// drops or rebuilds rows.
    #[test]
    fn schema_12_upgrade_preserves_a_populated_vault() {
        let directory = tempfile::tempdir().unwrap();
        let key = [11_u8; 32];
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        let seeded = seed_then_downgrade_to_schema_10(&config, key);

        let vault = Vault::open_with_key(config, key).unwrap();

        let version: i64 = vault
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT version FROM schema_meta", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, i64::from(SCHEMA_VERSION));

        // The two things schema 11 and 12 add.
        let columns = moment_column_names(&vault.connection.lock().unwrap()).unwrap();
        assert!(columns.iter().any(|name| name == "thumbnail_artifact_id"));
        let has_index: bool = vault
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master
                  WHERE type = 'index' AND name = 'text_evidence_session_source'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap()
            > 0;
        assert!(has_index, "schema 11 index missing after upgrade");

        // Nothing was lost.
        let moments = vault.moments_sync(&seeded.session_id).unwrap();
        assert_eq!(moments.len(), 2, "a moment went missing across the upgrade");

        let hot = moments
            .iter()
            .find(|moment| moment.id == seeded.hot_moment)
            .expect("hot moment survived");
        assert_eq!(hot.window_title.as_deref(), Some("Quarterly roadmap.key"));
        assert_eq!(hot.url.as_deref(), Some("https://example.com/deck"));
        assert_eq!(hot.application_name.as_deref(), Some("Keynote"));
        assert!(hot.is_favorite, "favorite flag survived");
        assert_eq!(hot.ocr_text.as_deref(), Some("revenue projection"));

        let packed = moments
            .iter()
            .find(|moment| moment.id == seeded.packed_moment)
            .expect("packed moment survived");
        assert!(packed.image_artifact_id.is_none());
        // Read the raw columns: the segment row itself is not part of this
        // fixture, so `moments_sync` cannot materialise a `GopRef`. What the
        // migration owes us is that the claim on the segment survived.
        let claim: (Option<String>, Option<i64>) = vault
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT gop_segment_id, gop_index FROM moments WHERE id = ?1",
                [&seeded.packed_moment],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(claim, (Some("seg-1".to_owned()), Some(3)));

        // Artifacts still decrypt: the key hierarchy was not disturbed.
        assert_eq!(
            vault.read_artifact(&seeded.still_artifact).unwrap().bytes,
            b"hot-still-bytes"
        );

        // FTS and OCR layout came through intact.
        let hits = vault.search("revenue", 10).unwrap();
        assert!(
            hits.iter().any(|hit| hit.moment_id == seeded.hot_moment),
            "OCR evidence is no longer searchable after the upgrade"
        );
        assert!(
            vault
                .ocr_layout_for_moment(&seeded.hot_moment)
                .unwrap()
                .is_some()
        );
        assert!(
            vault
                .search("roadmap", 10)
                .unwrap()
                .iter()
                .any(|hit| hit.source == WINDOW_EVIDENCE_SOURCE),
            "window-title evidence written before the upgrade is still indexed"
        );

        assert_eq!(vault.memories(0, 10_000, 10).unwrap().len(), 1);

        // And the new column is usable on the migrated vault, including for a
        // moment whose still is already gone.
        let thumbnail = vault
            .set_thumbnail(&seeded.packed_moment, b"thumb")
            .unwrap();
        assert_eq!(vault.read_artifact(&thumbnail).unwrap().bytes, b"thumb");
        vault
            .delete_moment_and_artifacts(&seeded.packed_moment)
            .unwrap();
        assert!(
            !vault.artifact_path(&thumbnail).exists(),
            "thumbnail leaked when a packed moment was deleted"
        );
    }

    #[test]
    fn conversations_round_trip_and_cascade_on_delete() {
        let (_directory, vault) = test_vault(10);
        let id = vault.create_conversation("Untitled", 1_000).unwrap();
        vault
            .append_message(&id, "user", "昨天下午我在干嘛？", None, 1_100)
            .unwrap();
        vault
            .append_message(
                &id,
                "assistant",
                "你在调 GOP 打包。",
                Some(r#"[{"tool":"list_activity"}]"#),
                1_200,
            )
            .unwrap();
        vault.rename_conversation(&id, "昨天下午").unwrap();

        let listed = vault.conversations(10).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].title, "昨天下午");
        assert_eq!(listed[0].message_count, 2);
        assert_eq!(listed[0].updated_at_ms, 1_200, "append bumps updated_at");
        assert_eq!(vault.conversation(&id).unwrap().unwrap().title, "昨天下午");
        assert!(vault.conversation("missing").unwrap().is_none());

        let messages = vault.conversation_messages(&id).unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].role, "user");
        assert!(messages[1].tool_log.is_some(), "tool log survives");

        vault.delete_conversation(&id).unwrap();
        assert!(vault.conversations(10).unwrap().is_empty());
        assert!(
            vault.conversation_messages(&id).unwrap().is_empty(),
            "messages cascade with the conversation"
        );
    }

    #[test]
    fn memories_round_trip_and_delete_with_history() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let moment = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"screen")
            .unwrap();
        vault
            .insert_memory(&Memory {
                id: "mem-1".into(),
                start_ms: 1_000,
                end_ms: 70_000,
                moment_id: Some(moment.id.clone()),
                application_name: Some("Safari".into()),
                bundle_identifier: Some("com.apple.Safari".into()),
                window_title: Some("Example".into()),
                url: Some("https://example.com/".into()),
                document: None,
                summary: "Read example.com in Safari.".into(),
                fingerprint: "abc".into(),
            })
            .unwrap();
        let listed = vault.memories(0, 80_000, 10).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].summary, "Read example.com in Safari.");
        assert_eq!(vault.delete_history(0, 80_000).unwrap(), 1);
        assert!(vault.memories(0, 80_000, 10).unwrap().is_empty());
        assert!(vault.moments_sync(&session.id).unwrap().is_empty());
    }

    #[test]
    fn schema_8_adds_activity_columns_without_resetting_the_vault() {
        let directory = tempfile::tempdir().unwrap();
        let key = [7_u8; 32];
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        let session_id = {
            let vault = Vault::open_with_key(config.clone(), key).unwrap();
            let session = vault.create_session_sync(1).unwrap();
            vault
                .insert_moment(&session.id, 2, "image/jpeg", b"keep")
                .unwrap();
            vault
                .connection
                .lock()
                .unwrap()
                .execute_batch(
                    "ALTER TABLE moments DROP COLUMN window_title;
                     ALTER TABLE moments DROP COLUMN url;
                     ALTER TABLE moments DROP COLUMN document;
                     UPDATE schema_meta SET version = 7;",
                )
                .unwrap();
            session.id
        };
        let vault = Vault::open_with_key(config, key).unwrap();
        let columns = {
            let connection = vault.connection.lock().unwrap();
            let mut statement = connection.prepare("PRAGMA table_info(moments)").unwrap();
            statement
                .query_map([], |row| row.get::<_, String>(1))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap()
        };
        assert!(columns.iter().any(|column| column == "window_title"));
        assert!(columns.iter().any(|column| column == "url"));
        assert!(columns.iter().any(|column| column == "document"));
        let version: i64 = vault
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT version FROM schema_meta", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, i64::from(SCHEMA_VERSION));
        assert_eq!(vault.moments_sync(&session_id).unwrap().len(), 1);
    }

    fn stamp_app(vault: &Vault, moment_id: &str, app: &str, bundle: &str, title: &str) {
        vault
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE moments
                    SET application_name = ?2,
                        bundle_identifier = ?3,
                        window_title = ?4
                  WHERE id = ?1",
                params![moment_id, app, bundle, title],
            )
            .unwrap();
    }

    fn insert_named_moment(
        vault: &Vault,
        session_id: &str,
        at_ms: i64,
        app: &str,
        bundle: &str,
        title: &str,
    ) -> Moment {
        let moment = vault
            .insert_moment(session_id, at_ms, "image/jpeg", b"screen")
            .unwrap();
        stamp_app(vault, &moment.id, app, bundle, title);
        moment
    }

    /// The index over what the summariser already writes.
    ///
    /// v2 cards carry grounded entities and named threads; nothing could ask
    /// across them, so "which stretches touched rav1e" meant reading every
    /// stretch of every day and scanning the prose.
    #[test]
    fn find_slot_mentions_searches_entities_threads_and_titles() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let (day_start, _) = local_day_bounds(1_786_698_000_000);
        let slot_at = slot_start_for(day_start + 10 * 3_600_000);
        for offset in [0_i64, 20_000] {
            insert_named_moment(
                &vault,
                &session.id,
                slot_at + offset,
                "Zed",
                "dev.zed.Zed",
                "gop.rs",
            );
        }
        let card = vault.slot_card(slot_at + 1_000, 10_000).unwrap();
        let frames = card.evidence.moment_ids.clone();
        vault
            .put_t2_summary_v2(
                &card,
                &T2CardV2 {
                    title: "Chased a GOP header bug".into(),
                    description: "The IVF length field was off by one.".into(),
                    threads: vec![T2Thread {
                        name: "rav1e encode".into(),
                        prose: "read the IVF header writer".into(),
                        moment_ids: frames.clone(),
                    }],
                    entities: vec![T2Entity {
                        text: "rav1e".into(),
                        kind: Some("crate".into()),
                        moment_id: frames.first().cloned(),
                    }],
                    decisions: vec!["Keep the length check in the packer".into()],
                    not_captured: vec![],
                    category: Some("coding".into()),
                    confidence: Some(0.8),
                },
                "test",
                slot_at,
                Some(10),
            )
            .unwrap();

        // By entity, by thread prose, and by title.
        for needle in ["rav1e", "IVF header writer", "GOP header"] {
            let hits = vault.find_slot_mentions(needle, &SearchFilter::default(), 10).unwrap();
            assert_eq!(hits.len(), 1, "`{needle}` found {hits:?}");
            assert_eq!(hits[0].slot_start_ms, slot_at);
        }
        let hit = &vault.find_slot_mentions("rav1e", &SearchFilter::default(), 10).unwrap()[0];
        assert_eq!(hit.matched_entities, vec!["rav1e".to_owned()]);
        assert_eq!(hit.moment_ids, frames, "the frames to cite came back");
        assert_eq!(hit.decisions, vec!["Keep the length check in the packer".to_owned()]);

        // Case and spacing fold, an unrelated word does not.
        assert_eq!(vault.find_slot_mentions("RAV1E", &SearchFilter::default(), 10).unwrap().len(), 1);
        assert!(vault.find_slot_mentions("kubernetes", &SearchFilter::default(), 10).unwrap().is_empty());

        // A window that excludes the slot excludes the hit.
        assert!(
            vault
                .find_slot_mentions(
                    "rav1e",
                    &SearchFilter::range(Some(slot_at + 1), None),
                    10,
                )
                .unwrap()
                .is_empty()
        );
    }

    /// The strongest match has to be reachable however old it is.
    ///
    /// Candidates used to be taken newest-first and ranked afterwards, so the
    /// ranking only ever saw the survivors. A project named in passing by
    /// hundreds of recent summaries buried the one old summary that recorded
    /// it as a grounded entity — and no limit, however small, could reach it.
    #[test]
    fn find_slot_mentions_ranks_across_the_whole_range_not_the_newest_page() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let (day_start, _) = local_day_bounds(1_786_698_000_000);

        // Spaced a whole legacy slot apart so each write lands on its own row
        // under either slot geometry; `slot_start_for` would fold ten-minute
        // spacing back onto one slot and overwrite the row under test.
        let oldest = day_start;
        insert_named_moment(&vault, &session.id, oldest, "Zed", "dev.zed.Zed", "tools.rs");
        let card = vault.slot_card(oldest, 10_000).unwrap();
        vault
            .put_t2_summary_v2(
                &card,
                &T2CardV2 {
                    title: "Shipped the recall panel".into(),
                    description: String::new(),
                    threads: vec![],
                    entities: vec![T2Entity {
                        text: "lody".into(),
                        kind: Some("project".into()),
                        moment_id: None,
                    }],
                    decisions: vec![],
                    not_captured: vec![],
                    category: None,
                    confidence: Some(0.9),
                },
                "test",
                oldest,
                None,
            )
            .unwrap();

        // Then 401 newer summaries that only mention it in passing, in prose —
        // more than the candidate window the query is allowed to read.
        for index in 1..=401_i64 {
            let at_ms = day_start + index * SLOT_DURATION_MS;
            insert_named_moment(&vault, &session.id, at_ms, "Zed", "dev.zed.Zed", "notes.md");
            let card = vault.slot_card(at_ms, 10_000).unwrap();
            vault
                .put_t2_summary_v2(
                    &card,
                    &T2CardV2 {
                        title: format!("Unrelated work {index}"),
                        description: String::new(),
                        threads: vec![T2Thread {
                            name: "notes".into(),
                            prose: "mentioned lody in passing".into(),
                            moment_ids: vec![],
                        }],
                        entities: vec![],
                        decisions: vec![],
                        not_captured: vec![],
                        category: None,
                        confidence: Some(0.3),
                    },
                    "test",
                    at_ms,
                    None,
                )
                .unwrap();
        }

        let hits = vault
            .find_slot_mentions("lody", &SearchFilter::default(), 1)
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(
            hits[0].slot_start_ms, oldest,
            "the entity match was buried under newer prose: {hits:?}"
        );
        assert_eq!(hits[0].matched_entities, vec!["lody".to_owned()]);
    }

    /// A field name is not a hit.
    ///
    /// The candidate query ran `LIKE` against the serialised card, so the keys
    /// serde writes — `"text"`, `"kind"`, `"name"`, `"prose"` — matched every
    /// card that had an entity or a thread. `match_slot_mention` discarded them
    /// afterwards, so nothing wrong was ever printed; what they did was fill
    /// the candidate window, which put the real older match out of reach. That
    /// is the same unreachability as ranking after truncation, arriving by a
    /// different road.
    #[test]
    fn find_slot_mentions_does_not_match_the_json_field_names() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let (day_start, _) = local_day_bounds(1_786_698_000_000);

        // The oldest card genuinely records `text` as an entity: a real hit
        // that has to survive everything below.
        let oldest = day_start;
        insert_named_moment(&vault, &session.id, oldest, "Zed", "dev.zed.Zed", "a.rs");
        let card = vault.slot_card(oldest, 10_000).unwrap();
        vault
            .put_t2_summary_v2(
                &card,
                &T2CardV2 {
                    title: "Wrote the parser".into(),
                    description: String::new(),
                    threads: vec![],
                    entities: vec![T2Entity {
                        text: "text".into(),
                        kind: Some("crate".into()),
                        moment_id: None,
                    }],
                    decisions: vec![],
                    not_captured: vec![],
                    category: None,
                    confidence: Some(0.9),
                },
                "test",
                oldest,
                None,
            )
            .unwrap();

        // Then 401 newer cards that mention it nowhere — but whose serialised
        // entities and threads all contain the literal keys.
        for index in 1..=401_i64 {
            let at_ms = day_start + index * SLOT_DURATION_MS;
            insert_named_moment(&vault, &session.id, at_ms, "Zed", "dev.zed.Zed", "b.rs");
            let card = vault.slot_card(at_ms, 10_000).unwrap();
            vault
                .put_t2_summary_v2(
                    &card,
                    &T2CardV2 {
                        title: format!("Unrelated {index}"),
                        description: String::new(),
                        threads: vec![T2Thread {
                            name: "review".into(),
                            prose: "read a diff".into(),
                            moment_ids: vec![],
                        }],
                        entities: vec![T2Entity {
                            text: "rav1e".into(),
                            kind: Some("crate".into()),
                            moment_id: None,
                        }],
                        decisions: vec![],
                        not_captured: vec![],
                        category: None,
                        confidence: Some(0.3),
                    },
                    "test",
                    at_ms,
                    None,
                )
                .unwrap();
        }

        // Every key that appears in the serialised card, searched for by name.
        for key in ["text", "kind", "name", "prose", "moment_ids"] {
            let hits = vault
                .find_slot_mentions(key, &SearchFilter::default(), 20)
                .unwrap();
            let expected: Vec<i64> = if key == "text" { vec![oldest] } else { vec![] };
            assert_eq!(
                hits.iter().map(|hit| hit.slot_start_ms).collect::<Vec<_>>(),
                expected,
                "`{key}` matched field names rather than values"
            );
        }

        // And the real entity is reachable at a limit of one, which it cannot
        // be if four hundred false candidates are read ahead of it.
        let hits = vault
            .find_slot_mentions("text", &SearchFilter::default(), 1)
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].slot_start_ms, oldest);
        assert_eq!(hits[0].matched_entities, vec!["text".to_owned()]);
    }

    /// The matching rule itself, without a database: `LIKE` is the prefilter,
    /// this is the decision, and the two must not disagree about whitespace.
    #[test]
    fn match_slot_mention_folds_whitespace_and_case() {
        let threads = vec![T2Thread {
            name: "worker".into(),
            prose: "swapped the model".into(),
            moment_ids: vec!["m1".into()],
        }];
        let entities = vec![T2Entity {
            text: "qwen3.5:4b".into(),
            kind: None,
            moment_id: Some("m2".into()),
        }];
        let matched = |needle: &str| {
            match_slot_mention(needle, 10, 20, "2026-08-16", Some("Ran a worker"), &threads, &entities, &[])
        };

        let (mention, kind) = matched("Qwen3.5: 4B").expect("folded match");
        assert_eq!(kind, MentionKind::Entity);
        assert_eq!(mention.matched_entities, vec!["qwen3.5:4b".to_owned()]);
        assert_eq!(mention.moment_ids, vec!["m2".to_owned()]);

        // Prose ranks below a verbatim entity, and title below neither.
        assert_eq!(matched("swapped").unwrap().1, MentionKind::Prose);
        assert_eq!(matched("Ran a").unwrap().1, MentionKind::Title);
        assert!(matched("nothing here").is_none());
        assert!(matched("   ").is_none());

        // The prefilter must be no narrower than the decision above.
        assert_eq!(like_prefilter("Qwen3.5: 4B").as_deref(), Some("%Qwen3.5:%"));
        assert_eq!(like_prefilter("100%_sure").as_deref(), Some("%100\\%\\_sure%"));
        assert_eq!(like_prefilter("   "), None);
    }

    #[test]
    fn slot_title_covering_uses_the_rows_own_bounds() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let (day_start, _) = local_day_bounds(1_786_698_000_000);
        let slot_at = slot_start_for(day_start + 10 * 3_600_000);
        insert_named_moment(&vault, &session.id, slot_at, "Zed", "dev.zed.Zed", "gop.rs");
        let card = vault.slot_card(slot_at + 1_000, 10_000).unwrap();
        vault
            .put_t2_summary(
                &card,
                &T2Card {
                    artifacts: vec![],
                    title: "Chased a GOP header bug".into(),
                    bullets: vec![],
                    category: None,
                    confidence: None,
                },
                "test",
                slot_at,
                None,
            )
            .unwrap();

        let (start, title) = vault.slot_title_covering(slot_at + 5_000).unwrap().unwrap();
        assert_eq!(start, card.slot_start_ms);
        assert_eq!(title, "Chased a GOP header bug");
        assert!(vault.slot_title_covering(slot_at - 1).unwrap().is_none());
    }

    #[test]
    fn slot_summaries_round_trip_and_day_summary_keeps_t1_only_slots() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let (day_start, _) = local_day_bounds(1_786_698_000_000);
        let first_slot = slot_start_for(day_start + 10 * 3_600_000);
        let second_slot = first_slot + SLOT_DURATION_MS;
        for (offset, title) in [
            (0_i64, "gop.rs"),
            (20_000, "encoder.rs"),
            (40_000, "ivf.rs"),
        ] {
            insert_named_moment(
                &vault,
                &session.id,
                first_slot + offset,
                "Xcode",
                "com.apple.dt.Xcode",
                title,
            );
        }
        for offset in [0_i64, 20_000, 40_000] {
            insert_named_moment(
                &vault,
                &session.id,
                second_slot + offset,
                "Safari",
                "com.apple.Safari",
                "docs.rs",
            );
        }

        let second_card = vault.slot_card(second_slot + 1_000, 10_000).unwrap();
        vault
            .put_t2_summary(
                &second_card,
                &T2Card {
                    artifacts: vec!["docs.rs".into()],
                    title: "Reading rav1e Config".into(),
                    bullets: vec!["docs.rs for the IVF header".into()],
                    category: Some("reading".into()),
                    confidence: Some(0.7),
                },
                "ollama:qwen",
                second_slot,
                Some(1_200),
            )
            .unwrap();

        let summary = vault.day_summary(first_slot + 1_000, 10_000).unwrap();
        assert_eq!(summary.slots.len(), 2);
        let t1 = summary
            .slots
            .iter()
            .find(|slot| slot.slot_start_ms == first_slot)
            .unwrap();
        assert!(t1.title.is_none(), "T2 never ran on this slot");
        assert!(!t1.facts.apps.is_empty());
        assert_eq!(t1.state, SlotSummaryState::Degraded);
        let t2 = summary
            .slots
            .iter()
            .find(|slot| slot.slot_start_ms == second_slot)
            .unwrap();
        assert_eq!(t2.title.as_deref(), Some("Reading rav1e Config"));
        assert_eq!(t2.state, SlotSummaryState::Done);
        assert_eq!(t2.category.as_deref(), Some("reading"));

        vault
            .put_t2_summary(
                &second_card,
                &T2Card {
                    artifacts: vec!["docs.rs".into()],
                    title: "Second pass".into(),
                    bullets: vec![],
                    category: Some("reading".into()),
                    confidence: Some(0.8),
                },
                "ollama:qwen",
                second_slot + 1,
                Some(800),
            )
            .unwrap();
        let generation: i64 = vault
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT generation FROM slot_summaries WHERE slot_start_ms = ?1",
                [second_slot],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(generation, 2);

        let prev = vault.previous_slot_titles(second_slot + 1, 4).unwrap();
        assert_eq!(
            prev.last().map(|card| card.title.as_str()),
            Some("Second pass")
        );
    }

    #[test]
    fn summary_history_pages_unique_days_with_an_exclusive_cursor() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let (first_day_start, first_day_end) = local_day_bounds(1_786_698_000_000);
        let (second_day_start, second_day_end) = local_day_bounds(first_day_end + 12 * 3_600_000);
        assert!(second_day_start > first_day_start);

        insert_named_moment(
            &vault,
            &session.id,
            first_day_start + 10 * 3_600_000,
            "Xcode",
            "com.apple.dt.Xcode",
            "first.rs",
        );
        insert_named_moment(
            &vault,
            &session.id,
            second_day_start + 10 * 3_600_000,
            "Safari",
            "com.apple.Safari",
            "second.dev",
        );

        let newest = vault
            .summary_history(Some(second_day_end), 1, 10_000)
            .unwrap();
        assert_eq!(newest.days.len(), 1);
        assert_eq!(newest.days[0].day_start_ms, second_day_start);
        assert!(newest.has_more);
        assert_eq!(newest.next_before_ms, Some(second_day_start));
        assert_eq!(newest.total_days, Some(2));

        let older = vault
            .summary_history(newest.next_before_ms, 7, 10_000)
            .unwrap();
        assert_eq!(older.days.len(), 1);
        assert_eq!(older.days[0].day_start_ms, first_day_start);
        assert!(!older.has_more);
        assert_eq!(older.next_before_ms, None);
        assert_eq!(older.total_days, Some(2));
    }

    #[test]
    fn delete_history_removes_slot_summaries_with_the_evidence() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let at = 1_786_698_000_000;
        let slot = slot_start_for(at);
        insert_named_moment(
            &vault,
            &session.id,
            slot + 5_000,
            "Xcode",
            "com.apple.dt.Xcode",
            "gop.rs",
        );
        let card = vault.slot_card(slot + 5_000, 10_000).unwrap();
        vault
            .put_t2_summary(
                &card,
                &T2Card {
                    artifacts: vec![],
                    title: "Should vanish".into(),
                    bullets: vec![],
                    category: None,
                    confidence: None,
                },
                "test",
                slot,
                None,
            )
            .unwrap();
        assert_eq!(
            vault.delete_history(slot, slot + SLOT_DURATION_MS).unwrap(),
            1
        );
        let remaining: i64 = vault
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM slot_summaries", [], |row| row.get(0))
            .unwrap();
        assert_eq!(remaining, 0);
        assert!(vault.day_summary(slot, 10_000).unwrap().slots.is_empty());
    }

    #[test]
    fn schema_12_adds_slot_summaries_without_resetting_the_vault() {
        let directory = tempfile::tempdir().unwrap();
        let key = [7_u8; 32];
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        let session_id = {
            let vault = Vault::open_with_key(config.clone(), key).unwrap();
            let session = vault.create_session_sync(1).unwrap();
            vault
                .insert_moment(&session.id, 2, "image/jpeg", b"keep")
                .unwrap();
            vault
                .connection
                .lock()
                .unwrap()
                .execute_batch(
                    "DROP TABLE slot_summaries;
                     DROP INDEX IF EXISTS slot_summaries_slot;
                     DROP INDEX IF EXISTS slot_summaries_day;
                     UPDATE schema_meta SET version = 11;",
                )
                .unwrap();
            session.id
        };
        let vault = Vault::open_with_key(config, key).unwrap();
        let has_table: i64 = vault
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name = 'slot_summaries'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(has_table, 1);
        let version: i64 = vault
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT version FROM schema_meta", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, i64::from(SCHEMA_VERSION));
        assert_eq!(vault.moments_sync(&session_id).unwrap().len(), 1);
    }

    fn input_event(at_ms: i64, end_ms: Option<i64>, kind: &str) -> InputEventRow {
        InputEventRow {
            at_ms,
            end_ms,
            kind: kind.to_owned(),
            count: None,
            ended_with: None,
            command: None,
            bundle_identifier: None,
            target_json: None,
            text: None,
            extra_json: None,
        }
    }

    /// A two-pane window: a sidebar of short rows and a wide content pane whose
    /// text is long enough to carry the frame past `AX_TEXT_MIN_CHARS` — but
    /// only when both panes are counted together.
    fn two_pane_snapshot(sidebar: &[&str], content: &[&str]) -> Vec<u8> {
        let node = |role: &str, text: &str| {
            serde_json::json!({"role": role, "value": text, "children": []})
        };
        serde_json::to_vec(&serde_json::json!({
            "application_name": "Feishu",
            "bundle_identifier": "com.electron.lark",
            "window_title": "Lody Team",
            "root": {
                "role": "AXWindow",
                "title": "Lark",
                "frame": {"x": 0, "y": 0, "width": 1000, "height": 1000},
                "children": [
                    {
                        "role": "AXGroup",
                        "title": "Conversations",
                        "frame": {"x": 0, "y": 0, "width": 200, "height": 1000},
                        "children": sidebar
                            .iter()
                            .map(|line| node("AXStaticText", line))
                            .collect::<Vec<_>>(),
                    },
                    {
                        "role": "AXGroup",
                        "title": "Chat",
                        "frame": {"x": 200, "y": 0, "width": 800, "height": 1000},
                        "children": content
                            .iter()
                            .map(|line| node("AXStaticText", line))
                            .collect::<Vec<_>>(),
                    }
                ]
            }
        }))
        .unwrap()
    }

    /// The text-source decision and the engaged partition read the same line
    /// vector, and they must stay independent: a frame whose engaged region is
    /// small still uses accessibility text if the *whole* tree is rich enough.
    ///
    /// Get this wrong and partitioning silently demotes a frame to OCR — worse
    /// text, whole-screen scope — for the frames the join works best on.
    #[test]
    fn partitioning_never_flips_a_frames_text_source() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let slot = slot_start_for(1_786_698_000_000) + 60_000;

        // 20 sidebar rows of ~24 chars carry the frame over the 400-char gate;
        // the engaged pane alone holds well under it.
        let sidebar: Vec<String> = (0..20)
            .map(|index| format!("conversation row {index:02} here"))
            .collect();
        let sidebar_refs: Vec<&str> = sidebar.iter().map(String::as_str).collect();
        let content = ["赵亮: shipped the fix", "me: thanks"];
        let engaged_chars: usize = content.iter().map(|line| line.chars().count()).sum();
        assert!(
            engaged_chars < slot::AX_TEXT_MIN_CHARS,
            "the engaged pane must be under the gate for this test to mean anything"
        );
        let snapshot = two_pane_snapshot(&sidebar_refs, &content);
        assert!(
            accessibility_text_lines(&snapshot)
                .iter()
                .map(|line| line.chars().count())
                .sum::<usize>()
                >= slot::AX_TEXT_MIN_CHARS,
            "the whole tree must be over the gate"
        );

        for step in 0..3_i64 {
            let at = slot + step * 10_000;
            let moment = insert_named_moment(
                &vault,
                &session.id,
                at,
                "Feishu",
                "com.electron.lark",
                "Lody Team",
            );
            vault
                .attach_accessibility_snapshot(
                    &session.id,
                    at,
                    "application/json",
                    &snapshot,
                    Some("Feishu"),
                    Some("com.electron.lark"),
                )
                .unwrap()
                .unwrap();
            assert!(!moment.id.is_empty());
        }

        // One click, inside the chat pane: engaged scope is the chat pane.
        let mut click = input_event(slot + 5_000, None, "click");
        click.bundle_identifier = Some("com.electron.lark".to_owned());
        click.target_json = Some(
            r#"{"role":"AXStaticText","label":"赵亮",
                "frame":{"x":300,"y":100,"width":200,"height":20}}"#
                .to_owned(),
        );
        vault.insert_input_events(&[click]).unwrap();

        let card = vault.slot_card(slot + 1_000, 10_000).unwrap();
        let run = card
            .timeline
            .iter()
            .find_map(|entry| match entry {
                slot::TimelineEntry::Run(run) => Some(run),
                slot::TimelineEntry::Gap(_) => None,
            })
            .expect("the slot has a run");

        assert_eq!(
            run.text_source, "ax",
            "the gate counts every line, engaged or not"
        );
        assert_eq!(
            run.lines,
            ["赵亮: shipped the fix", "me: thanks"],
            "only the pane the click landed in"
        );
        assert_eq!(run.peripheral.len(), 20, "the sidebar is visible, not operated");
        assert_eq!(
            card.not_engaged,
            vec![acts::Region {
                label: "Conversations".to_owned(),
                lines: 20,
                engaged: false,
            }]
        );
        let acts = run.acts.as_ref().expect("the slot has events");
        assert_eq!(acts.clicks.len(), 1);
        assert_eq!(acts.clicks[0].label, "赵亮");
        assert_eq!(acts.signal, acts::ActsSignal::Ok);
        assert!(card.facts.no_input_ratio.is_some());
    }

    /// The same slot with its events removed: the card must be the one the
    /// pipeline built before acts existed, sidebar text included.
    #[test]
    fn a_slot_whose_events_are_gone_partitions_nothing() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let slot = slot_start_for(1_786_698_000_000) + 60_000;
        let sidebar: Vec<String> = (0..20)
            .map(|index| format!("conversation row {index:02} here"))
            .collect();
        let sidebar_refs: Vec<&str> = sidebar.iter().map(String::as_str).collect();
        let snapshot = two_pane_snapshot(&sidebar_refs, &["赵亮: shipped the fix", "me: thanks"]);
        for step in 0..3_i64 {
            let at = slot + step * 10_000;
            insert_named_moment(
                &vault,
                &session.id,
                at,
                "Feishu",
                "com.electron.lark",
                "Lody Team",
            );
            vault
                .attach_accessibility_snapshot(
                    &session.id,
                    at,
                    "application/json",
                    &snapshot,
                    Some("Feishu"),
                    Some("com.electron.lark"),
                )
                .unwrap()
                .unwrap();
        }

        let card = vault.slot_card(slot + 1_000, 10_000).unwrap();
        let run = card
            .timeline
            .iter()
            .find_map(|entry| match entry {
                slot::TimelineEntry::Run(run) => Some(run),
                slot::TimelineEntry::Gap(_) => None,
            })
            .expect("the slot has a run");
        assert_eq!(run.text_source, "ax");
        assert_eq!(run.lines.len(), 22, "every line, in tree order");
        assert!(run.peripheral.is_empty());
        assert!(run.acts.is_none());
        assert!(card.not_engaged.is_empty());
        assert_eq!(card.facts.no_input_ratio, None);
    }

    /// Builds a slot of Feishu frames with one click in the chat pane and a
    /// typing burst, and returns its start.
    fn acts_slot(vault: &Vault, session_id: &str) -> i64 {
        // Frames sit a minute into the slot; the caller gets the slot's own
        // start, which is what `slot_acts` and `slots_missing_acts` key on.
        let first_at = slot_start_for(1_786_698_000_000) + 60_000;
        let slot = vault.summary_slot_bounds(first_at).start_ms;
        let sidebar: Vec<String> = (0..20)
            .map(|index| format!("conversation row {index:02} here"))
            .collect();
        let sidebar_refs: Vec<&str> = sidebar.iter().map(String::as_str).collect();
        let snapshot = two_pane_snapshot(&sidebar_refs, &["赵亮: shipped the fix", "me: thanks"]);
        for step in 0..3_i64 {
            let at = first_at + step * 10_000;
            insert_named_moment(
                vault,
                session_id,
                at,
                "Feishu",
                "com.electron.lark",
                "Lody Team",
            );
            vault
                .attach_accessibility_snapshot(
                    session_id,
                    at,
                    "application/json",
                    &snapshot,
                    Some("Feishu"),
                    Some("com.electron.lark"),
                )
                .unwrap()
                .unwrap();
        }
        let mut click = input_event(first_at + 5_000, None, "click");
        click.bundle_identifier = Some("com.electron.lark".to_owned());
        click.target_json = Some(
            r#"{"role":"AXStaticText","label":"赵亮",
                "frame":{"x":300,"y":100,"width":200,"height":20}}"#
                .to_owned(),
        );
        let mut burst = input_event(first_at + 6_000, Some(first_at + 12_000), "burst");
        burst.count = Some(24);
        burst.bundle_identifier = Some("com.electron.lark".to_owned());
        burst.target_json = Some(
            r#"{"role":"AXTextArea","label":"Message",
                "frame":{"x":300,"y":900,"width":400,"height":40}}"#
                .to_owned(),
        );
        vault.insert_input_events(&[click, burst]).unwrap();
        slot
    }

    /// The reason materialisation exists: events are eventually swept — with
    /// the frames of their era, since the trust model changed — and T1 is lazy,
    /// so acts that are not frozen simply disappear from history.
    #[test]
    fn frozen_acts_outlive_the_events_they_came_from() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let slot = acts_slot(&vault, &session.id);

        let live = vault.slot_card(slot + 60_000, 10_000).unwrap();
        let live_run = live
            .timeline
            .iter()
            .find_map(|entry| match entry {
                slot::TimelineEntry::Run(run) => Some(run),
                slot::TimelineEntry::Gap(_) => None,
            })
            .expect("a run");
        let live_acts = live_run.acts.clone().expect("the slot has events");
        assert_eq!(live_acts.keys, 24);
        assert_eq!(live_acts.clicks[0].label, "赵亮");

        assert!(
            vault.materialize_slot_acts(slot + 60_000, 10_000).unwrap(),
            "a slot with events and no frozen acts is work to do"
        );
        vault.flush_card_cache();

        // The retention edge moves past the slot.
        let removed = vault
            .prune_input_events_before(slot + SLOT_DURATION_MS)
            .unwrap();
        assert_eq!(removed, 2);
        assert!(
            vault
                .input_events_between(slot, slot + SLOT_DURATION_MS)
                .unwrap()
                .is_empty()
        );

        let after = vault.slot_card(slot + 60_000, 10_000).unwrap();
        let after_run = after
            .timeline
            .iter()
            .find_map(|entry| match entry {
                slot::TimelineEntry::Run(run) => Some(run),
                slot::TimelineEntry::Gap(_) => None,
            })
            .expect("a run");
        let frozen = after_run
            .acts
            .clone()
            .expect("the frozen copy stands in for the events");
        assert_eq!(frozen, live_acts, "the same acts, minus their source");
        assert_eq!(after.facts.no_input_ratio, live.facts.no_input_ratio);
        // What the freeze does not restore: the partition was computed against
        // rects that no longer exist, so the text is whole again.
        assert!(after_run.peripheral.is_empty());
        assert_eq!(after_run.lines.len(), 22);
        assert!(after.not_engaged.is_empty());
    }

    /// The sweeper revisits every slot every five minutes forever.
    #[test]
    fn freezing_a_slot_twice_changes_nothing() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let slot = acts_slot(&vault, &session.id);

        assert!(vault.materialize_slot_acts(slot + 60_000, 10_000).unwrap());
        let first = vault.slot_acts(slot).unwrap().expect("frozen");
        assert!(
            !vault.materialize_slot_acts(slot + 60_000, 10_000).unwrap(),
            "already frozen"
        );
        assert_eq!(vault.slot_acts(slot).unwrap(), Some(first));

        // And a later T2 card does not erase them.
        let card = vault.slot_card(slot + 60_000, 10_000).unwrap();
        vault
            .put_t2_summary(
                &card,
                &T2Card {
                    artifacts: vec![],
                    title: "Answering 赵亮".into(),
                    bullets: vec![],
                    category: Some("comms".into()),
                    confidence: Some(0.9),
                },
                "test",
                slot,
                None,
            )
            .unwrap();
        assert!(
            vault.slot_acts(slot).unwrap().is_some(),
            "a model writing the card must not drop the acts under it"
        );
        let day = vault.day_summary(slot, 10_000).unwrap();
        assert_eq!(day.slots.len(), 1, "no phantom slot from the acts row");
        assert_eq!(day.slots[0].title.as_deref(), Some("Answering 赵亮"));
    }

    #[test]
    fn a_slot_with_no_events_is_never_frozen() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let at = slot_start_for(1_786_698_000_000) + 60_000;
        let slot = vault.summary_slot_bounds(at).start_ms;
        insert_named_moment(&vault, &session.id, at, "Zed", "dev.zed.Zed", "slot.rs");
        assert!(
            !vault.materialize_slot_acts(at, 10_000).unwrap(),
            "no events stored and events that said nothing are different claims"
        );
        assert_eq!(vault.slot_acts(slot).unwrap(), None);
        assert!(
            vault
                .slots_missing_acts(slot, slot + SLOT_DURATION_MS)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn slots_missing_acts_lists_slots_with_events_until_they_are_frozen() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let slot = acts_slot(&vault, &session.id);
        let window_end = slot + SLOT_DURATION_MS;

        assert_eq!(
            vault.slots_missing_acts(slot, window_end).unwrap(),
            vec![slot]
        );
        vault.materialize_slot_acts(slot + 60_000, 10_000).unwrap();
        assert!(
            vault.slots_missing_acts(slot, window_end).unwrap().is_empty(),
            "frozen slots leave the work list"
        );
    }

    /// A burst that straddles a boundary happened in both slots, so both owe
    /// acts. Enqueueing only the slot it started in would leave the second one
    /// unfrozen, and once the events expired it would fail open forever —
    /// silently dropping typing the user did.
    #[test]
    fn a_span_crossing_a_boundary_enqueues_every_slot_it_touches() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let slot = acts_slot(&vault, &session.id);
        let boundary = vault.summary_slot_bounds(slot).end_ms;

        vault
            .insert_input_events(&[InputEventRow {
                at_ms: boundary - 2_000,
                end_ms: Some(boundary + 20_000),
                kind: "burst".to_owned(),
                count: Some(34),
                ended_with: Some("return".to_owned()),
                command: None,
                bundle_identifier: Some("com.electron.lark".to_owned()),
                target_json: None,
                text: None,
                extra_json: None,
            }])
            .unwrap();

        let due = vault
            .slots_missing_acts(slot, boundary + SLOT_DURATION_MS)
            .unwrap();
        assert!(due.contains(&slot), "the slot the burst began in");
        assert!(
            due.contains(&boundary),
            "the slot it was still typing into: {due:?}"
        );
    }

    /// One privacy invariant, three layers: forgetting a window takes the
    /// frames, the cards, and the acts derived from the events.
    #[test]
    fn deleting_history_takes_the_frozen_acts_with_it() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let slot = acts_slot(&vault, &session.id);
        assert!(vault.materialize_slot_acts(slot + 60_000, 10_000).unwrap());
        assert!(vault.slot_acts(slot).unwrap().is_some());

        vault.delete_history(slot, slot + SLOT_DURATION_MS).unwrap();

        assert_eq!(vault.slot_acts(slot).unwrap(), None);
        assert!(
            vault
                .input_events_between(slot, slot + SLOT_DURATION_MS)
                .unwrap()
                .is_empty()
        );
    }

    /// A window owns an event when the two intervals touch at all: a burst that
    /// started before the slot opened is still typing that happened inside it.
    /// The window is half-open so consecutive slots partition the stream.
    #[test]
    fn input_events_between_returns_every_overlapping_row_in_order() {
        let (_directory, vault) = test_vault(10);
        let rows = vec![
            input_event(999, None, "click"),          // before the window
            input_event(1_000, None, "click"),        // on the lower edge
            input_event(1_999, None, "scroll"),       // last instant inside
            input_event(2_000, None, "click"),        // on the open upper edge
            input_event(500, Some(999), "burst"),     // ends before the window
            input_event(400, Some(1_000), "burst"),   // ends on the lower edge
            input_event(600, Some(1_500), "burst"),   // straddles the opening
            input_event(1_900, Some(2_600), "burst"), // straddles the close
            input_event(2_000, Some(2_600), "burst"), // starts at the close
            input_event(1_200, Some(1_100), "burst"), // nonsense end: a point
        ];
        assert_eq!(vault.insert_input_events(&rows).unwrap(), rows.len());

        let found = vault.input_events_between(1_000, 2_000).unwrap();
        let shape: Vec<(i64, Option<i64>)> = found
            .iter()
            .map(|event| (event.at_ms, event.end_ms))
            .collect();
        assert_eq!(
            shape,
            vec![
                (400, Some(1_000)),
                (600, Some(1_500)),
                (1_000, None),
                (1_200, Some(1_100)),
                (1_900, Some(2_600)),
                (1_999, None),
            ]
        );

        // Half-open: the next slot picks up exactly what this one left.
        let next = vault.input_events_between(2_000, 3_000).unwrap();
        assert_eq!(
            next.iter()
                .map(|event| (event.at_ms, event.end_ms))
                .collect::<Vec<_>>(),
            vec![(1_900, Some(2_600)), (2_000, None), (2_000, Some(2_600))]
        );
        assert!(vault.input_events_between(2_000, 2_000).unwrap().is_empty());
    }

    /// The shim can ship ahead of its reader, and the store is not the layer
    /// that decides what an act means: an unrecognised `kind` must survive the
    /// round trip untouched rather than be rejected or normalised.
    #[test]
    fn input_events_round_trip_unknown_kinds_and_every_field() {
        let (_directory, vault) = test_vault(10);
        let stored = InputEventRow {
            at_ms: 5_000,
            end_ms: Some(7_500),
            kind: "pinch-from-a-newer-shim".to_owned(),
            count: Some(42),
            ended_with: Some("return".to_owned()),
            command: Some("cmd+s".to_owned()),
            bundle_identifier: Some("dev.zed.Zed".to_owned()),
            target_json: Some(
                r#"{"role":"AXTextArea","label":"lib.rs","frame":{"x":1,"y":2,"width":3,"height":4}}"#
                    .to_owned(),
            ),
            text: Some("公司内部的".to_owned()),
            extra_json: Some(
                r#"{"application_name":"Zed","window_title":"lib.rs — afterray"}"#.to_owned(),
            ),
        };
        vault
            .insert_input_events(std::slice::from_ref(&stored))
            .unwrap();
        let found = vault.input_events_between(0, 10_000).unwrap();
        assert_eq!(found, vec![stored]);
        assert_eq!(vault.insert_input_events(&[]).unwrap(), 0);
    }

    /// The 48h channel now carries markers and nothing else. A marker's expiry
    /// is still a promise about time, so it cannot ride the capture path: a
    /// vault that is merely opened — recording stopped, nothing imported — must
    /// shed a stale marker. The observations beside it are content and stay
    /// until the vault's general retention reaches them, which on an
    /// under-limit vault is never.
    #[test]
    fn opening_a_vault_expires_stale_markers_and_keeps_the_observations() {
        let directory = tempfile::tempdir().unwrap();
        let key = [31_u8; 32];
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        let now = i64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis(),
        )
        .unwrap();
        let old = now - SIGNAL_MARKER_RETENTION_MS - 60_000;
        {
            let vault = Vault::open_with_key(config.clone(), key).unwrap();
            vault
                .insert_input_events(&[
                    input_event(old, None, "click"),
                    input_event(old + 1, None, acts::SIGNAL_GAP_KIND),
                    input_event(now - 60_000, None, acts::SIGNAL_GAP_KIND),
                ])
                .unwrap();
            assert_eq!(vault.input_events_between(0, now + 1).unwrap().len(), 3);
        }
        // Reopening runs `enforce_retention`, and nothing else.
        let vault = Vault::open_with_key(config, key).unwrap();
        let kept = vault.input_events_between(0, now + 1).unwrap();
        assert_eq!(
            kept.iter()
                .map(|event| (event.at_ms, event.kind.as_str()))
                .collect::<Vec<_>>(),
            vec![(old, "click"), (now - 60_000, acts::SIGNAL_GAP_KIND)],
            "only the stale marker expires on the clock"
        );
    }

    /// The short channel is for markers, and only for markers: an observation
    /// of the same age is content and stays. Retention is "the last 48 hours",
    /// inclusive of its own edge, and a span is judged by its end.
    #[test]
    fn prune_signal_gaps_takes_markers_only_and_keeps_the_retention_edge() {
        let (_directory, vault) = test_vault(10);
        let now = 1_786_698_000_000;
        let cutoff = now - SIGNAL_MARKER_RETENTION_MS;
        let gap = acts::SIGNAL_GAP_KIND;
        let rows = vec![
            input_event(cutoff - 1, None, gap),
            input_event(cutoff, None, gap),
            input_event(cutoff + 1, None, gap),
            input_event(cutoff - 5_000, Some(cutoff - 1), gap),
            input_event(cutoff - 5_000, Some(cutoff), gap),
            input_event(cutoff - 5_000, None, "click"),
            input_event(cutoff - 5_000, Some(cutoff - 1), "burst"),
        ];
        vault.insert_input_events(&rows).unwrap();

        assert_eq!(vault.prune_signal_gaps(now).unwrap(), 2);
        let remaining = vault.input_events_between(0, now + 1).unwrap();
        assert_eq!(
            remaining
                .iter()
                .map(|event| (event.at_ms, event.end_ms, event.kind.as_str()))
                .collect::<Vec<_>>(),
            vec![
                (cutoff - 5_000, Some(cutoff), gap),
                (cutoff - 5_000, None, "click"),
                (cutoff - 5_000, Some(cutoff - 1), "burst"),
                (cutoff, None, gap),
                (cutoff + 1, None, gap),
            ],
            "the observations of the same age are content, not bookkeeping"
        );
        // Idempotent: nothing left to drop on a second pass at the same instant.
        assert_eq!(vault.prune_signal_gaps(now).unwrap(), 0);
    }

    /// The horizon sweep is the opposite: everything whose span ended before
    /// the vault's oldest surviving frame goes, markers included.
    #[test]
    fn prune_input_events_before_judges_a_span_by_its_end() {
        let (_directory, vault) = test_vault(10);
        let horizon = 1_786_698_000_000;
        let rows = vec![
            input_event(horizon - 1, None, "click"),
            input_event(horizon, None, "click"),
            input_event(horizon - 5_000, Some(horizon - 1), "burst"),
            input_event(horizon - 5_000, Some(horizon), "burst"),
            input_event(horizon - 5_000, None, acts::SIGNAL_GAP_KIND),
        ];
        vault.insert_input_events(&rows).unwrap();

        assert_eq!(vault.prune_input_events_before(horizon).unwrap(), 3);
        assert_eq!(
            vault
                .input_events_between(0, horizon + 1)
                .unwrap()
                .iter()
                .map(|event| (event.at_ms, event.end_ms))
                .collect::<Vec<_>>(),
            vec![(horizon - 5_000, Some(horizon)), (horizon, None)]
        );
        assert_eq!(vault.prune_input_events_before(horizon).unwrap(), 0);
    }

    /// Forgetting a stretch of history must take the events with it: they say
    /// what the user did in that window in finer detail than any frame does —
    /// and since schema 25 that includes what was typed and what the field
    /// held, which is the finest detail the vault has about anything.
    #[test]
    fn delete_history_removes_overlapping_input_events() {
        let (_directory, vault) = test_vault(10);
        let at = 1_786_698_000_000;
        let slot = slot_start_for(at);
        let mut typed = input_event(slot + 5_000, Some(slot + 9_000), "burst");
        typed.text = Some("the build passphrase is".to_owned());
        typed.target_json = Some(r#"{"label":"Message","value":"…"}"#.to_owned());
        typed.extra_json = Some(r#"{"window_title":"Lody Team"}"#.to_owned());
        let rows = vec![
            input_event(slot - 1, None, "click"),
            input_event(slot, None, "click"),
            typed,
            input_event(slot - 5_000, Some(slot + 1_000), "burst"),
            input_event(slot + SLOT_DURATION_MS, None, "click"),
            input_event(slot + SLOT_DURATION_MS + 1, None, "click"),
        ];
        vault.insert_input_events(&rows).unwrap();

        vault.delete_history(slot, slot + SLOT_DURATION_MS).unwrap();

        let remaining = vault.input_events_between(0, at + SLOT_DURATION_MS * 4).unwrap();
        assert_eq!(
            remaining
                .iter()
                .map(|event| (event.at_ms, event.end_ms))
                .collect::<Vec<_>>(),
            vec![
                (slot - 1, None),
                (slot + SLOT_DURATION_MS + 1, None),
            ],
            "only rows entirely outside the deleted window may survive"
        );
        assert!(
            remaining
                .iter()
                .all(|event| event.text.is_none() && event.extra_json.is_none()),
            "no content column may outlive the window it was recorded in"
        );
        let leftover: i64 = vault
            .readers
            .get()
            .query_row(
                "SELECT COUNT(*) FROM input_events WHERE text IS NOT NULL",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(leftover, 0, "checked in SQL, not only through the reader");
    }

    #[test]
    fn schema_23_adds_input_events_to_an_existing_vault() {
        let directory = tempfile::tempdir().unwrap();
        let key = [23_u8; 32];
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        let session_id = {
            let vault = Vault::open_with_key(config.clone(), key).unwrap();
            let session = vault.create_session_sync(1).unwrap();
            vault
                .insert_moment(&session.id, 2, "image/jpeg", b"keep")
                .unwrap();
            vault
                .connection
                .lock()
                .unwrap()
                .execute_batch(
                    "DROP INDEX IF EXISTS input_events_at;
                     DROP TABLE IF EXISTS input_events;
                     ALTER TABLE slot_summaries DROP COLUMN acts_json;
                     UPDATE schema_meta SET version = 22;",
                )
                .unwrap();
            session.id
        };

        let vault = Vault::open_with_key(config, key).unwrap();
        let connection = vault.connection.lock().unwrap();
        let objects: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master
                  WHERE name IN ('input_events', 'input_events_at')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(objects, 2, "table and its index must both come back");
        let version: i64 = connection
            .query_row("SELECT version FROM schema_meta", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, i64::from(SCHEMA_VERSION));
        let acts_column: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('slot_summaries')
                  WHERE name = 'acts_json'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(acts_column, 1);
        drop(connection);
        // The upgrade is additive: what was already there is still there.
        assert_eq!(vault.moments_sync(&session_id).unwrap().len(), 1);
        assert!(vault.input_events_between(0, 10).unwrap().is_empty());
    }

    /// A vault written by a schema-24 build gains the v2 content columns
    /// without losing a row: the events it already holds read back with
    /// `text`/`extra_json` empty, which is exactly what the shim that wrote
    /// them sent.
    #[test]
    fn schema_25_adds_the_v2_content_columns_to_a_v24_vault() {
        let directory = tempfile::tempdir().unwrap();
        let key = [25_u8; 32];
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        // Recent, because reopening a vault also enforces retention.
        let at_ms = i64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis(),
        )
        .unwrap()
            - 60_000;
        {
            let vault = Vault::open_with_key(config.clone(), key).unwrap();
            // Put the table back the way schema 24 left it, rows and all.
            vault
                .connection
                .lock()
                .unwrap()
                .execute_batch(&format!(
                    "ALTER TABLE input_events DROP COLUMN text;
                     ALTER TABLE input_events DROP COLUMN extra_json;
                     INSERT INTO input_events
                       (at_ms, end_ms, kind, count, ended_with, command,
                        bundle_identifier, target_json)
                     VALUES ({at_ms}, NULL, 'click', NULL, NULL, NULL,
                             'dev.zed.Zed', '{{\"label\":\"Run\"}}');
                     UPDATE schema_meta SET version = 24;"
                ))
                .unwrap();
        }

        let vault = Vault::open_with_key(config, key).unwrap();
        {
            let connection = vault.connection.lock().unwrap();
            let columns: i64 = connection
                .query_row(
                    "SELECT COUNT(*) FROM pragma_table_info('input_events')
                      WHERE name IN ('text', 'extra_json')",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(columns, 2, "both content columns must come back");
            let version: i64 = connection
                .query_row("SELECT version FROM schema_meta", [], |row| row.get(0))
                .unwrap();
            assert_eq!(version, i64::from(SCHEMA_VERSION));
        }
        let carried = vault.input_events_between(at_ms - 1, at_ms + 1).unwrap();
        assert_eq!(
            carried,
            vec![InputEventRow {
                at_ms,
                end_ms: None,
                kind: "click".to_owned(),
                count: None,
                ended_with: None,
                command: None,
                bundle_identifier: Some("dev.zed.Zed".to_owned()),
                target_json: Some(r#"{"label":"Run"}"#.to_owned()),
                text: None,
                extra_json: None,
            }],
            "a schema-24 row survives, with the new columns empty"
        );
    }

    /// A batch shaped like the v2 shim's: the typed run in `text`, the field's
    /// value inside `target_json`, and the drag's two ends in `extra_json`.
    /// Every one of them must come back byte-identical — the vault does not
    /// interpret any of it.
    #[test]
    fn a_v2_batch_round_trips_text_value_and_the_extra_fields() {
        let (_directory, vault) = test_vault(10);
        let target_json = r#"{"role":"AXTextField","subrole":"AXSearchField","label":"Message","value":"我们什么时候同意的","secure":false}"#;
        let rows = vec![
            InputEventRow {
                at_ms: 1_000,
                end_ms: Some(4_000),
                kind: "burst".to_owned(),
                count: Some(17),
                ended_with: Some("return".to_owned()),
                command: None,
                bundle_identifier: Some("com.electron.lark".to_owned()),
                target_json: Some(target_json.to_owned()),
                text: Some("wsm tongyini".to_owned()),
                extra_json: None,
            },
            InputEventRow {
                at_ms: 5_000,
                end_ms: None,
                kind: "drag".to_owned(),
                count: None,
                ended_with: None,
                command: None,
                bundle_identifier: Some("com.apple.finder".to_owned()),
                target_json: None,
                text: None,
                extra_json: Some(
                    r#"{"source":{"label":"0817.log"},"destination":{"label":"Archive"}}"#
                        .to_owned(),
                ),
            },
            InputEventRow {
                at_ms: 6_000,
                end_ms: None,
                kind: "window_changed".to_owned(),
                count: None,
                ended_with: None,
                command: None,
                bundle_identifier: Some("dev.zed.Zed".to_owned()),
                target_json: None,
                text: None,
                extra_json: Some(
                    r#"{"application_name":"Zed","window_title":"lib.rs"}"#.to_owned(),
                ),
            },
        ];
        assert_eq!(vault.insert_input_events(&rows).unwrap(), 3);
        assert_eq!(vault.input_events_between(0, 10_000).unwrap(), rows);
    }

    /// Events arrive at interaction rate while T1 reads the same window from
    /// the reader pool. A reader must never see a half-written batch and the
    /// writer must never be blocked out by readers.
    #[test]
    fn input_event_writes_and_reader_pool_queries_do_not_collide() {
        let (_directory, vault) = test_vault(10);
        let vault = std::sync::Arc::new(vault);
        let batches = 40_i64;
        let per_batch = 8_i64;
        let base = 1_700_000_000_000_i64;

        std::thread::scope(|scope| {
            let writer = {
                let vault = std::sync::Arc::clone(&vault);
                scope.spawn(move || {
                    for batch in 0..batches {
                        let rows: Vec<InputEventRow> = (0..per_batch)
                            .map(|index| {
                                let at = base + batch * 1_000 + index;
                                let mut row = input_event(at, Some(at + 10), "burst");
                                row.count = Some(u32::try_from(index).unwrap());
                                row
                            })
                            .collect();
                        assert_eq!(
                            vault.insert_input_events(&rows).unwrap(),
                            usize::try_from(per_batch).unwrap()
                        );
                    }
                })
            };
            for _ in 0..3 {
                let vault = std::sync::Arc::clone(&vault);
                scope.spawn(move || {
                    for _ in 0..60 {
                        let found = vault
                            .input_events_between(base, base + batches * 1_000)
                            .expect("reader query must not fail while a batch commits");
                        // Batches commit whole, so a partial group is never
                        // visible: the count is always a multiple of the batch.
                        assert_eq!(
                            i64::try_from(found.len()).unwrap() % per_batch,
                            0,
                            "reader saw a half-committed batch"
                        );
                        assert!(
                            found.windows(2).all(|pair| pair[0].at_ms <= pair[1].at_ms),
                            "rows must come back ordered by at_ms"
                        );
                    }
                });
            }
            writer.join().unwrap();
        });

        let all = vault
            .input_events_between(base, base + batches * 1_000)
            .unwrap();
        assert_eq!(i64::try_from(all.len()).unwrap(), batches * per_batch);
    }

    // ------------------------------------------------- R3 edge snapshots

    /// An edge snapshot is stored bytes-in / bytes-out, and its window is
    /// half-open on the same rule as slots and events, so one tree can never be
    /// read into two cards.
    #[test]
    fn edge_snapshots_round_trip_within_a_half_open_window() {
        let (_directory, vault) = test_vault(10);
        let tree = two_pane_snapshot(&["sidebar row"], &["赵亮: shipped the fix"]);

        let first = vault.insert_edge_snapshot(1_000, &tree).unwrap();
        let edge = vault.insert_edge_snapshot(1_999, &tree).unwrap();
        let next_slot = vault.insert_edge_snapshot(2_000, &tree).unwrap();

        let found = vault.edge_snapshots_between(1_000, 2_000).unwrap();
        assert_eq!(
            found.iter().map(|row| row.captured_at_ms).collect::<Vec<_>>(),
            vec![1_000, 1_999],
            "the upper bound is open"
        );
        assert_eq!(found[0], first);
        assert_eq!(found[1], edge);
        assert_eq!(
            vault.edge_snapshots_between(2_000, 3_000).unwrap(),
            vec![next_slot.clone()],
            "the next window picks up exactly what this one left"
        );
        assert!(vault.edge_snapshots_between(2_000, 2_000).unwrap().is_empty());

        let payload = vault.read_artifact(&edge.artifact_id).unwrap();
        assert_eq!(payload.bytes, tree, "the encrypted tree decrypts unchanged");
        assert_eq!(payload.content_type, EDGE_SNAPSHOT_CONTENT_TYPE);
    }

    /// Edge snapshots share the events' 48h lifetime, files included: a tree
    /// triggered by an event and outliving it would still say when the user
    /// interacted after the record of the interaction was erased.
    #[test]
    fn prune_edge_snapshots_before_deletes_rows_and_their_artifact_files() {
        let (_directory, vault) = test_vault(10);
        let horizon = 1_786_698_000_000;
        let tree = two_pane_snapshot(&["sidebar row"], &["赵亮: shipped the fix"]);

        let expired = vault.insert_edge_snapshot(horizon - 1, &tree).unwrap();
        let edge = vault.insert_edge_snapshot(horizon, &tree).unwrap();
        let fresh = vault.insert_edge_snapshot(horizon + 1, &tree).unwrap();
        for row in [&expired, &edge, &fresh] {
            assert!(vault.artifact_path(&row.artifact_id).exists());
        }

        assert_eq!(vault.prune_edge_snapshots_before(horizon).unwrap(), 1);

        assert_eq!(
            vault
                .edge_snapshots_between(0, horizon + 2)
                .unwrap()
                .iter()
                .map(|row| row.captured_at_ms)
                .collect::<Vec<_>>(),
            vec![horizon, horizon + 1],
            "the horizon instant itself survives, like the events'"
        );
        assert!(
            !vault.artifact_path(&expired.artifact_id).exists(),
            "the encrypted file must go with the row"
        );
        assert!(matches!(
            vault.read_artifact(&expired.artifact_id),
            Err(StoreError::ArtifactNotFound(_))
        ));
        assert!(vault.artifact_path(&edge.artifact_id).exists());
        // Idempotent: nothing left to drop at the same horizon.
        assert_eq!(vault.prune_edge_snapshots_before(horizon).unwrap(), 0);
    }

    /// Retention unification (`docs/event-capture-v2-plan.md` §信任模型变更):
    /// events and R3 trees are captured content, so the vault's own oldest-first
    /// sweep takes them — and stops exactly at the oldest frame that survived.
    /// Neither stream has a clock deadline of its own any more.
    #[test]
    fn retention_sweeps_events_and_edge_trees_with_the_frames_of_their_era() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let frame = vec![7_u8; 4096];
        let tree = two_pane_snapshot(&["sidebar row"], &["赵亮: shipped the fix"]);

        vault.insert_moment(&session.id, 1_000, "image/jpeg", &frame).unwrap();
        vault.insert_moment(&session.id, 2_000, "image/jpeg", &frame).unwrap();
        // What the vault costs while it holds only the two oldest frames is the
        // limit that will squeeze the two newest ones out.
        let two_frames = vault.storage_usage_bytes().unwrap();
        vault.insert_moment(&session.id, 3_000, "image/jpeg", &frame).unwrap();
        vault.insert_moment(&session.id, 4_000, "image/jpeg", &frame).unwrap();

        let instants = [500_i64, 1_500, 2_500, 3_500, 4_500];
        vault
            .insert_input_events(
                &instants
                    .iter()
                    .map(|at| input_event(*at, None, "click"))
                    .collect::<Vec<_>>(),
            )
            .unwrap();
        let trees: Vec<EdgeSnapshotRow> = instants
            .iter()
            .map(|at| vault.insert_edge_snapshot(*at, &tree).unwrap())
            .collect();

        vault.set_storage_limit_bytes(two_frames).unwrap();

        let survivors = vault.moments_sync(&session.id).unwrap();
        assert!(!survivors.is_empty(), "the sweep must leave a horizon");
        assert!(survivors.len() < 4, "the sweep must have evicted something");
        let horizon = survivors
            .iter()
            .map(|moment| moment.captured_at_ms)
            .min()
            .unwrap();

        assert_eq!(
            vault
                .input_events_between(0, 10_000)
                .unwrap()
                .iter()
                .map(|event| event.at_ms)
                .collect::<Vec<_>>(),
            instants
                .iter()
                .copied()
                .filter(|at| *at >= horizon)
                .collect::<Vec<_>>(),
            "events older than the oldest surviving frame go with it"
        );
        assert_eq!(
            vault
                .edge_snapshots_between(0, 10_000)
                .unwrap()
                .iter()
                .map(|row| row.captured_at_ms)
                .collect::<Vec<_>>(),
            instants
                .iter()
                .copied()
                .filter(|at| *at >= horizon)
                .collect::<Vec<_>>(),
            "and so do the R3 trees of the same era"
        );
        for (at, row) in instants.iter().zip(&trees) {
            assert_eq!(
                vault.artifact_path(&row.artifact_id).exists(),
                *at >= horizon,
                "an expired tree must take its encrypted file with it"
            );
        }
    }

    /// A vault with no frames left has no retention edge to measure against.
    /// Deleting on the theory that "everything is older than nothing" would
    /// take live events off a vault that had simply never captured a frame, so
    /// the sweep skips rather than guesses.
    #[test]
    fn a_vault_with_no_frames_left_sweeps_no_events() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        vault
            .insert_moment(&session.id, 1_000, "image/jpeg", &vec![7_u8; 4096])
            .unwrap();
        vault.insert_input_events(&[input_event(500, None, "click")]).unwrap();

        vault.set_storage_limit_bytes(1).unwrap();

        assert!(vault.moments_sync(&session.id).unwrap().is_empty());
        assert_eq!(
            vault.input_events_between(0, 10_000).unwrap().len(),
            1,
            "no frames means no horizon, and no horizon means no sweep"
        );
    }

    /// One privacy invariant, four layers: forgetting a window takes the frames,
    /// the cards, the acts, and the R3 trees. Edge snapshots hang off no moment,
    /// so no frame deletion can reach them.
    #[test]
    fn delete_history_takes_edge_snapshots_and_their_artifacts() {
        let (_directory, vault) = test_vault(10);
        let slot = slot_start_for(1_786_698_000_000);
        let tree = two_pane_snapshot(&["sidebar row"], &["赵亮: shipped the fix"]);

        let before = vault.insert_edge_snapshot(slot - 1, &tree).unwrap();
        let inside = vault.insert_edge_snapshot(slot + 5_000, &tree).unwrap();
        let after = vault
            .insert_edge_snapshot(slot + SLOT_DURATION_MS + 1, &tree)
            .unwrap();

        vault.delete_history(slot, slot + SLOT_DURATION_MS).unwrap();

        assert_eq!(
            vault
                .edge_snapshots_between(0, slot + SLOT_DURATION_MS * 4)
                .unwrap()
                .iter()
                .map(|row| row.captured_at_ms)
                .collect::<Vec<_>>(),
            vec![before.captured_at_ms, after.captured_at_ms],
            "only trees entirely outside the forgotten window may survive"
        );
        assert!(!vault.artifact_path(&inside.artifact_id).exists());
        assert!(vault.artifact_path(&before.artifact_id).exists());
        assert!(vault.artifact_path(&after.artifact_id).exists());
    }

    /// End to end: a stored edge tree reaches the card as extra engaged text for
    /// the run it fell in, and changes nothing else about that card.
    #[test]
    fn a_stored_edge_snapshot_widens_the_text_of_the_run_it_fell_in() {
        let (_directory, vault) = test_vault(10);
        let session = vault.create_session_sync(1).unwrap();
        let slot = slot_start_for(1_786_698_000_000) + 60_000;
        let sidebar: Vec<String> = (0..20)
            .map(|index| format!("conversation row {index:02} here"))
            .collect();
        let sidebar_refs: Vec<&str> = sidebar.iter().map(String::as_str).collect();
        let heartbeat = two_pane_snapshot(&sidebar_refs, &["赵亮: shipped the fix", "me: thanks"]);
        for step in 0..3_i64 {
            let at = slot + step * 10_000;
            insert_named_moment(
                &vault,
                &session.id,
                at,
                "Feishu",
                "com.electron.lark",
                "Lody Team",
            );
            vault
                .attach_accessibility_snapshot(
                    &session.id,
                    at,
                    "application/json",
                    &heartbeat,
                    Some("Feishu"),
                    Some("com.electron.lark"),
                )
                .unwrap()
                .unwrap();
        }
        let mut click = input_event(slot + 5_000, None, "click");
        click.bundle_identifier = Some("com.electron.lark".to_owned());
        click.target_json = Some(
            r#"{"role":"AXStaticText","label":"赵亮",
                "frame":{"x":300,"y":100,"width":200,"height":20}}"#
                .to_owned(),
        );
        vault.insert_input_events(&[click]).unwrap();
        let before = vault.slot_card(slot + 1_000, 10_000).unwrap();

        // The message that arrived and was read between two heartbeats.
        let edge = two_pane_snapshot(
            &sidebar_refs,
            &[
                "赵亮: shipped the fix",
                "me: thanks",
                "赵亮: staging looks clean",
            ],
        );
        vault.insert_edge_snapshot(slot + 5_000, &edge).unwrap();

        let card = vault.slot_card(slot + 1_000, 10_000).unwrap();
        let run = card
            .timeline
            .iter()
            .find_map(|entry| match entry {
                slot::TimelineEntry::Run(run) => Some(run),
                slot::TimelineEntry::Gap(_) => None,
            })
            .expect("the slot has a run");
        assert_eq!(
            run.lines,
            ["赵亮: shipped the fix", "me: thanks", "赵亮: staging looks clean"],
            "the edge tree's new chat line joins the engaged bucket"
        );
        assert_eq!(
            run.peripheral.len(),
            20,
            "the sidebar the edge tree also saw stays peripheral, not doubled"
        );

        let bare = before
            .timeline
            .iter()
            .find_map(|entry| match entry {
                slot::TimelineEntry::Run(run) => Some(run),
                slot::TimelineEntry::Gap(_) => None,
            })
            .expect("the slot had a run before the edge tree too");
        assert_eq!(card.facts.moment_count, before.facts.moment_count, "3 frames");
        assert_eq!(card.evidence.moment_ids, before.evidence.moment_ids);
        assert_eq!(card.anchor_moment_id, before.anchor_moment_id);
        assert_eq!(run.moment_id, bare.moment_id);
        assert_eq!(run.acts, bare.acts);
    }

    #[test]
    fn schema_24_adds_edge_snapshots_to_an_existing_vault() {
        let directory = tempfile::tempdir().unwrap();
        let key = [24_u8; 32];
        let config = VaultConfig {
            data_dir: directory.path().to_path_buf(),
            ..VaultConfig::default()
        };
        let session_id = {
            let vault = Vault::open_with_key(config.clone(), key).unwrap();
            let session = vault.create_session_sync(1).unwrap();
            vault
                .insert_moment(&session.id, 2, "image/jpeg", b"keep")
                .unwrap();
            vault
                .connection
                .lock()
                .unwrap()
                .execute_batch(
                    "DROP INDEX IF EXISTS edge_snapshots_at;
                     DROP TABLE IF EXISTS edge_snapshots;
                     UPDATE schema_meta SET version = 23;",
                )
                .unwrap();
            session.id
        };

        let vault = Vault::open_with_key(config, key).unwrap();
        {
            let connection = vault.connection.lock().unwrap();
            let objects: i64 = connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master
                      WHERE name IN ('edge_snapshots', 'edge_snapshots_at')",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(objects, 2, "table and its index must both come back");
            let version: i64 = connection
                .query_row("SELECT version FROM schema_meta", [], |row| row.get(0))
                .unwrap();
            assert_eq!(version, i64::from(SCHEMA_VERSION));
        }
        // The upgrade is additive, and the new table is usable straight away.
        assert_eq!(vault.moments_sync(&session_id).unwrap().len(), 1);
        let tree = two_pane_snapshot(&["sidebar row"], &["赵亮: shipped the fix"]);
        vault.insert_edge_snapshot(5_000, &tree).unwrap();
        assert_eq!(vault.edge_snapshots_between(0, 10_000).unwrap().len(), 1);
    }
}

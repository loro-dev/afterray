//! Stopping a turn that is already running.
//!
//! Stop used to be a lie. The app closed its socket; the daemon only noticed at
//! the next token write. During a long tool call, or before a round's first
//! token, nothing was cancelled at all — the model job ran to completion and
//! the vault kept being queried for an answer nobody would read.
//!
//! A token is checked at three places, which between them cover every point a
//! turn can be sitting in: before a round, inside the model call, and around a
//! tool call. Anything cheaper leaves one of those unguarded, and that one is
//! always the slow one.

use tokio::sync::watch;

/// A shared "stop now" flag.
///
/// Cloning shares the flag. Cancelling is idempotent and cannot be undone: a
/// turn that has been told to stop must not be resumable by a later caller.
#[derive(Debug, Clone)]
pub struct CancelToken {
    sender: std::sync::Arc<watch::Sender<bool>>,
}

impl Default for CancelToken {
    fn default() -> Self {
        Self::new()
    }
}

impl CancelToken {
    /// Whether two handles are the same token, not merely equal in state.
    ///
    /// A registry that keys turns by conversation needs this: an entry may only
    /// be removed by the turn that put it there, or a finishing turn takes its
    /// successor's token away with it.
    #[must_use]
    pub fn is_same(&self, other: &Self) -> bool {
        std::sync::Arc::ptr_eq(&self.sender, &other.sender)
    }

    #[must_use]
    pub fn new() -> Self {
        let (sender, _) = watch::channel(false);
        Self {
            sender: std::sync::Arc::new(sender),
        }
    }

    /// A token that is already cancelled, for callers with nothing to cancel.
    #[must_use]
    pub fn cancelled_now() -> Self {
        let token = Self::new();
        token.cancel();
        token
    }

    /// `send_replace`, not `send`: `send` fails when no receiver is alive, and
    /// the common case is exactly that — nothing is waiting yet, and the flag
    /// still has to be set for the next `is_cancelled` to see it.
    pub fn cancel(&self) {
        self.sender.send_replace(true);
    }

    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        *self.sender.borrow()
    }

    /// Resolves once cancelled, immediately if it already is.
    ///
    /// A `watch` rather than a `Notify`: a notification sent between the flag
    /// check and the wait registration would be lost, and the wait would then
    /// hang for the length of whatever it was racing.
    pub async fn cancelled(&self) {
        let mut receiver = self.sender.subscribe();
        if *receiver.borrow_and_update() {
            return;
        }
        let _ = receiver.changed().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn cancelling_is_visible_to_every_clone() {
        let token = CancelToken::new();
        let clone = token.clone();
        assert!(!clone.is_cancelled());
        token.cancel();
        assert!(clone.is_cancelled());
        // And it resolves rather than hanging.
        clone.cancelled().await;
    }

    /// The race the `watch` exists for: cancelling while a waiter is between
    /// checking the flag and registering must still wake it.
    #[tokio::test]
    async fn a_waiter_registered_after_the_cancel_still_wakes() {
        let token = CancelToken::new();
        token.cancel();
        tokio::time::timeout(std::time::Duration::from_secs(1), token.cancelled())
            .await
            .expect("cancelled() hung on an already-cancelled token");
    }

    #[tokio::test]
    async fn a_pending_waiter_wakes_when_cancel_arrives() {
        let token = CancelToken::new();
        let waiter = token.clone();
        let handle = tokio::spawn(async move { waiter.cancelled().await });
        tokio::task::yield_now().await;
        token.cancel();
        tokio::time::timeout(std::time::Duration::from_secs(1), handle)
            .await
            .expect("waiter never woke")
            .unwrap();
    }

    #[test]
    fn cancelling_twice_is_harmless() {
        let token = CancelToken::new();
        token.cancel();
        token.cancel();
        assert!(token.is_cancelled());
        assert!(CancelToken::cancelled_now().is_cancelled());
    }
}

# Shutdown lifecycle

Verified against code 2026-08-20.

Quit is a cross-process drain, not a generic “wait for all tasks”. The authoritative decision is
[bounded shutdown](../docs/decisions/active/architecture/2026-08-20-bounded-shutdown.md).

## Sequence

1. `AfterRayTerminationState.begin` synchronously claims termination. The status item and recall
   overlay disappear, UI pollers/streams stop, and `DaemonSupervisor.beginTermination` prevents
   every later `startIfNeeded` from spawning or reusing a daemon. A repeated AppKit termination
   query receives `.terminateLater` but creates no second cleanup task. The single cleanup task
   runs temporary summary-export cleanup alongside daemon teardown and waits for both before
   replying to AppKit.
2. `UnixSocketDaemonClient.shutdown` uses a 1.5-second receive deadline, separate from the normal
   30-second unary deadline.
3. `afterrayd` writes the JSON ACK completely, then flips `AppState.draining` and wakes the main
   loop. Every already-accepted connection sees the gate; the listener stops accepting.
4. The daemon closes both submit and retry admission, then cancels model downloads, chat turn
   tokens, all `ModelQueue` jobs, persistent MLX workers, socket/maintenance/sweeper tasks, and
   wakes the GOP thread out of sleeps. Tracked disposable tasks/threads get one short aggregate
   join budget; their Tokio blocking work cannot extend process exit beyond the runtime's
   one-second shutdown timeout.
5. The capture scheduler stops. `MacOsCaptureBackend.stop_capture` sends `stop` and waits briefly
   for the shim to flush input events, finish audio, emit `stopped`, and exit. On timeout or I/O
   failure it sends SIGKILL and waits to reap the child. stdout EOF always wakes the consumer;
   without an earlier protocol `stopped`, it is `UnexpectedEof` and takes the failed-recording
   path rather than pretending a helper crash was graceful. After exit 0, the finite stdout
   reader has no local deadline: it may be blocked by the capacity-128 channel while the consumer
   persists an earlier event. A forced/error helper gives that reader only 500 ms before abort.
6. The capture consumer imports every event already ahead of `Stopped`. Only after it finishes
   does `record_stop` flush memory state and close the active vault session. The helper wait has a
   short deadline, but a healthy helper's finite consumer stream, required memory flush, and
   session close have no daemon-local cancellation deadline. A failed helper gets only a 250 ms
   EOF-consumer window, so its error path does not stack another full consumer timeout. The
   supervisor's process escalation remains the final bound if durable I/O itself is wedged.
7. The daemon removes its socket and returns. The app first waits six seconds for this normal
   exit, then gives SIGTERM 1.5 seconds, and finally SIGKILL 0.5 seconds. These waits inspect PID
   liveness or socket removal; they never call `status`.

## Timing logs

App logs record shutdown RPC latency, graceful/SIGTERM/SIGKILL phase outcomes, and total app
shutdown time. Daemon logs record disposable-work cancellation, capture-helper stop, capture and
session close, background join counts/timeouts, and total drain time. There is no loop-level log.

## Tests

- `AfterRayTerminationStateTests.testRepeatedQuitStartsExactlyOneCleanupTask`
- `tests::required_shutdown_work_is_not_cut_off_by_disposable_deadlines` (`afterrayd`)
- `tests::graceful_stopped_drains_slow_final_artifact_before_session_close` (`afterrayd`)
- `tests::failed_helper_consumer_keeps_the_short_recovery_boundary` (`afterrayd`)
- `tests::background_lifecycle_reaps_completed_tasks_and_joins_cancelled_tasks` (`afterrayd`)
- `tests::shutdown_ack_is_fully_written_before_draining_starts` (`afterrayd`)
- `tests::unexpected_capture_eof_takes_the_failed_recording_path` (`afterrayd`)
- `tests::stuck_shim_is_killed_reaped_and_wakes_the_event_consumer`
- `tests::healthy_exit_drains_a_backpressured_reader_through_stopped`
- `tests::stdout_eof_without_protocol_stopped_is_an_error`
- `queue::tests::shutdown_cancels_active_jobs_and_rejects_new_work`
- `queue::tests::retry_waiting_on_jobs_lock_is_rejected_once_shutdown_starts`

# AfterRay GOP decoder helper

One-shot Apple-framework boundary for cold archive maintenance. It reads one
IVF/AV1 GOP from stdin and writes a length-prefixed I420 frame stream to stdout.
The daemon owns encryption and storage; this helper never receives a vault key,
path, artifact id, or user metadata.

- Keep stdout binary-only. Diagnostics go to stderr.
- Reject malformed/truncated IVF before creating a VideoToolbox session.
- The output order must exactly match IVF frame order; the daemon atomically
  maps that order back onto the existing moment ids.
- Build through the root Swift package as `afterray-gop-decoder`; release and
  dev bundle scripts must copy and sign it beside `afterrayd`.

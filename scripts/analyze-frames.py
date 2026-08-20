#!/usr/bin/env python3
"""Frame-rate analysis of an Instruments Time Profiler trace.

    make profile-frames TRACE_IN=/tmp/afterray-ab-HHMMSS.trace

Why not just read CPU%: a saturated main thread reads as ~80% busy whatever
you change, so it cannot tell two configurations apart. Frames can.

How a frame is identified: `CA::Transaction::commit` runs once per display
cycle, so a contiguous run of main-thread samples inside it is one frame, and
the run's length is that frame's CPU cost. **Tolerate no gap when splitting
runs.** Allowing even 2ms merges adjacent frames and reports a third of the
real frame rate — the main thread is inside commit ~90% of the time here, so
the between-frame gap is smaller than the tolerance.

Caveat this cannot escape: sampling infers frames, it does not count them. For
ground truth, run the app itself with AFTERRAY_UI_PERF_LOG=1 and read the
`[afterray-ui-perf]` line, which is measured from the display link.

Phases are detected, not passed in: the window where panel symbols appear is
the panel-open phase.
"""
import xml.etree.ElementTree as ET, collections, statistics, sys

XML = sys.argv[1] if len(sys.argv) > 1 else '/tmp/afterray-timeprofile.xml'
frames = {}; backtraces = {}; tagged = {}; threads = {}; binaries = {}; times = {}

PANEL = ('DaySummaryPanel', 'HistoryList', 'DaySummaryRow', 'DaySummaryHeading')
COMMIT = 'CA::Transaction::commit'


def fkey(el):
    # Every lookup resolves `ref=`: this XML interns repeated elements, and
    # ignoring that silently yields all-zero output.
    if el.get('ref'):
        return frames.get(el.get('ref'))
    name = el.get('name', '?')
    b = el.find('binary'); bn = '?'
    if b is not None:
        bn = binaries.get(b.get('ref'), '?') if b.get('ref') else (b.get('name') or '?')
        if b.get('id') and not b.get('ref'):
            binaries[b.get('id')] = bn
    if el.get('id'):
        frames[el.get('id')] = (name, bn)
    return (name, bn)


def stack(row):
    tb = row.find('tagged-backtrace')          # not a direct child of <row>
    if tb is None:
        return []
    if tb.get('ref'):
        return tagged.get(tb.get('ref'), [])
    b = tb.find('backtrace'); fl = []
    if b is not None:
        if b.get('ref'):
            fl = backtraces.get(b.get('ref'), [])
        else:
            for f in b.findall('frame'):
                k = fkey(f)
                if k:
                    fl.append(k)
            if b.get('id'):
                backtraces[b.get('id')] = fl
    if tb.get('id'):
        tagged[tb.get('id')] = fl
    return fl


rows = []
for _, el in ET.iterparse(XML, events=('end',)):
    if el.tag != 'row':
        continue
    stt = el.find('sample-time'); t = None
    if stt is not None:
        if stt.get('ref'):
            t = times.get(stt.get('ref'))
        else:
            t = int(stt.text or 0)
            if stt.get('id'):
                times[stt.get('id')] = t
    th = el.find('thread'); tid = '?'
    if th is not None:
        tid = threads.get(th.get('ref'), '?') if th.get('ref') else th.get('fmt', '?')
        if th.get('id'):
            threads[th.get('id')] = tid
    names = '\n'.join(n for n, _ in stack(el))
    el.clear()
    if t is None or 'Main Thread' not in tid:
        continue
    rows.append((t, COMMIT in names, any(m in names for m in PANEL)))

if not rows:
    sys.exit('no main-thread samples')
rows.sort()
t0 = rows[0][0]
span = (rows[-1][0] - t0) / 1e9
print(f'main-thread samples={len(rows)}  span={span:.1f}s')

panel_secs = sorted({int((t - t0) / 1e9) for t, _, p in rows if p})
if panel_secs:
    print(f'panel present: {panel_secs[0]}-{panel_secs[-1]}s')


def phase(label, lo, hi):
    win = [(t, c) for t, c, _ in rows if lo <= (t - t0) / 1e9 <= hi]
    runs = []; gaps = []; cur = None; last = None; gap = None
    for t, c in win:
        if c:
            if gap is not None:
                gaps.append((t - gap) / 1e6); gap = None
            if cur is None:
                cur = t
            last = t
        else:
            if cur is not None:
                runs.append((last - cur) / 1e6 + 1); cur = None
            if gap is None:
                gap = t
    if len(runs) < 5:
        print(f'\n{label}: too few frames'); return
    runs_s = sorted(runs)
    period = statistics.median(runs) + (statistics.median(gaps) if gaps else 0)
    print(f'\n=== {label}  ({lo:.1f}-{hi:.1f}s) ===')
    print(f'  frames            : {len(runs)} in {hi - lo:.1f}s  ->  {len(runs) / (hi - lo):.0f} fps')
    print(f'  CPU per frame     : p50 {statistics.median(runs):.0f} ms   '
          f'p95 {runs_s[int(len(runs_s) * .95)]:.0f} ms   max {runs_s[-1]:.0f} ms')
    print(f'  implied period    : {period:.0f} ms   (budget 8.3 ms at 120Hz, 16.7 at 60Hz)')


if panel_secs:
    lo, hi = panel_secs[0] + 1, panel_secs[-1] - 0.3
    phase('PANEL OPEN', lo, hi)
    phase('PANEL CLOSED', panel_secs[-1] + 1.3, span - 2)
else:
    phase('WHOLE RUN', 1, span - 1)

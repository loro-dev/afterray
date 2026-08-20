#!/usr/bin/env python3
"""Summarise an Instruments Time Profiler trace from the command line.

    make profile-app                      # or profile-scrub
    xcrun xctrace export --input /tmp/afterray-app.trace \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
        --output /tmp/tp.xml
    python3 scripts/analyze-trace.py

Reading the trace in the Instruments GUI works too; this exists because the
call tree is the first thing you want and clicking down to it is slow.

Two traps this handles, both of which silently produce all-zero output:
  * xctrace's XML interns repeated elements — a <frame>, <binary>, <thread> or
    <backtrace> may be `<frame ref="12"/>` pointing at an earlier definition.
    Every lookup here resolves refs.
  * the stack lives under <tagged-backtrace><backtrace>, not directly on <row>.

WARNING: a .trace bundle embeds the recorded process's full environment,
including any API tokens in it. Do not share one.
"""
import xml.etree.ElementTree as ET, collections, sys, re

args = [a for a in sys.argv[1:] if not a.startswith('--')]
opts = dict(a.split('=', 1) for a in sys.argv[1:] if a.startswith('--') and '=' in a)
XML = args[0] if args else '/tmp/afterray-timeprofile.xml'
# Window the samples by wall-clock seconds. The reliable A/B is one recording
# with the change made halfway through: same machine, same thermal state, same
# everything except the thing under test.
#     --from=0  --to=10
#     --from=10 --to=20
FROM_NS = float(opts.get('--from', 0)) * 1e9
TO_NS = float(opts.get('--to', 1e9)) * 1e9

frames={}; backtraces={}; tagged={}; threads={}; weights={}; binaries={}; sample_times={}
thread_ns=collections.Counter(); self_ns=collections.Counter(); total_ns=collections.Counter()

def frame_key(el):
    ref=el.get('ref')
    if ref: return frames.get(ref)
    name=el.get('name','?')
    b=el.find('binary')
    binname='?'
    if b is not None:
        if b.get('ref'):
            binname=binaries.get(b.get('ref'),'?')
        else:
            binname=b.get('name') or '?'
            if b.get('id'): binaries[b.get('id')]=binname
    if el.get('id'): frames[el.get('id')]=(name,binname)
    return (name,binname)

def resolve_bt(row):
    tb=row.find('tagged-backtrace')
    if tb is None: return []
    if tb.get('ref'): return tagged.get(tb.get('ref'),[])
    bt=tb.find('backtrace')
    fl=[]
    if bt is not None:
        if bt.get('ref'): fl=backtraces.get(bt.get('ref'),[])
        else:
            for f in bt.findall('frame'):
                k=frame_key(f)
                if k: fl.append(k)
            if bt.get('id'): backtraces[bt.get('id')]=fl
    if tb.get('id'): tagged[tb.get('id')]=fl
    return fl

rows=0
for ev,el in ET.iterparse(XML, events=('end',)):
    if el.tag!='row': continue
    # Definitions must be registered even for rows outside the window: this
    # XML interns repeated elements, so a later row's `ref=` may point at an
    # id first defined by a row we are not counting. Resolve everything, then
    # decide whether to accumulate.
    st=el.find('sample-time'); t_ns=None
    if st is not None:
        if st.get('ref'): t_ns=sample_times.get(st.get('ref'))
        else:
            t_ns=int(st.text or 0)
            if st.get('id'): sample_times[st.get('id')]=t_ns
    t=el.find('thread'); tid='?'
    if t is not None:
        tid = threads.get(t.get('ref'),'?') if t.get('ref') else t.get('fmt','?')
        if t.get('id'): threads[t.get('id')]=tid
    w=el.find('weight'); ns=0
    if w is not None:
        if w.get('ref'): ns=weights.get(w.get('ref'),0)
        else:
            ns=int(w.text or 0); weights[w.get('id')]=ns
    fl=resolve_bt(el)
    el.clear()

    if t_ns is not None and not (FROM_NS <= t_ns <= TO_NS):
        continue
    rows+=1
    thread_ns[tid]+=ns
    if fl:
        self_ns[(tid,fl[0])]+=ns
        for k in set(fl): total_ns[(tid,k)]+=ns

if not any('Main Thread' in t for t in thread_ns):
    sys.exit(f"no Main Thread samples in window {FROM_NS/1e9:g}-{TO_NS/1e9:g}s")
main=[t for t in thread_ns if 'Main Thread' in t][0]
span = (min(TO_NS, 20e9) - FROM_NS) / 1e6
print(f"rows={rows}  window={FROM_NS/1e9:.0f}-{min(TO_NS,20e9)/1e9:.0f}s  main-thread CPU={thread_ns[main]/1e6:.0f} ms ({100*thread_ns[main]/1e6/span:.0f}% of wall)\n")
print("=== SELF time, main thread, top 30 ===")
for (th,k),ns in sorted((kv for kv in self_ns.items() if kv[0][0]==main), key=lambda x:-x[1])[:30]:
    print(f"{ns/1e6:8.1f} ms  {k[1][:20]:20} {k[0][:92]}")

print("\n=== TOTAL (inclusive) time, AfterRay's own symbols, top 30 ===")
own=[(k,ns) for (th,k),ns in total_ns.items() if th==main and k[1]=='AfterRay']
for k,ns in sorted(own,key=lambda x:-x[1])[:30]:
    print(f"{ns/1e6:8.1f} ms  {k[0][:100]}")

print("\n=== 按关键词聚合（inclusive, 去重后取最大代表帧）===")
import re
buckets={'DaySummary/History':r'DaySummary|HistoryList|DaySlot|SummaryPanel',
         'Timeline/Scrub':r'Timeline|Scrub|Playhead|Filmstrip|ScrollFence',
         'OCR text layer':r'Ocr|OCR',
         'Image/YUV/decode':r'YUV|Artifact|Thumbnail|decode|Image',
         'Accessibility':r'Accessibility',
         'Chat':r'Chat'}
for label,pat in buckets.items():
    hits=[(k,ns) for k,ns in own if re.search(pat,k[0])]
    if not hits: 
        print(f"  {0:8.1f} ms  {label}")
        continue
    top=max(hits,key=lambda x:x[1])
    print(f"  {top[1]/1e6:8.1f} ms  {label:20} <- {top[0][0][:70]}")

print("\n=== TOTAL (inclusive), 所有二进制, top 40（跳过纯 main 包装）===")
skip=re.compile(r'AfterRayMain|AfterRayApp_main|^start$|NSApplicationMain|_?main$|RunLoop|__CFRUNLOOP|CFRunLoop|NSEventThread|_pthread|thread_start|DispatchQueue|dispatch_')
allsym=[(k,ns) for (th,k),ns in total_ns.items() if th==main]
for k,ns in sorted(allsym,key=lambda x:-x[1])[:60]:
    if skip.search(k[0]): continue
    print(f"{ns/1e6:8.1f} ms  {k[1][:18]:18} {k[0][:82]}")

print("\n=== self time 按二进制汇总 ===")
byb=collections.Counter()
for (th,k),ns in self_ns.items():
    if th==main: byb[k[1]]+=ns
for b,ns in byb.most_common(12):
    print(f"{ns/1e6:9.1f} ms  {b}")

print("\n=== 文本/排版 与 DisplayList 相关 inclusive ===")
pat=re.compile(r'CoreText|CTLine|CTFrame|typeset|Text|AttributedString|DisplayList|Layout|StyledText|glyph',re.I)
seen=set()
for k,ns in sorted(allsym,key=lambda x:-x[1]):
    if pat.search(k[0]) and k[0] not in seen:
        seen.add(k[0]); print(f"{ns/1e6:8.1f} ms  {k[1][:18]:18} {k[0][:80]}")
        if len(seen)>=18: break

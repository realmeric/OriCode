#!/usr/bin/env python3
# idle.py <top file> <label> <app pid> [pids under it…]: for the app, and for its engine and
# whatever else runs under it taken together, CPU a second (mean, worst, each second over 1%)
# and idle wakeups and context switches a second from top's running counts. top takes its first
# sample before it has a second to compare with, so that one is dropped.
import collections
import re
import sys

path, label, app, under = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]


def number(text):
    found = re.match(r'[0-9.]+', text)
    return float(found.group(0)) if found else 0.0


rows = collections.defaultdict(list)
for line in open(path, errors='replace'):
    fields = line.split()
    # From the right: threads, mem, power, idle wakeups, context switches, CPU. The command may hold spaces.
    if fields and fields[0] in [app] + under and len(fields) >= 8:
        rows[fields[0]].append([number(x) for x in fields[-6:-3]])


def report(name, pids):
    samples = [rows[p][1:] for p in pids if len(rows[p]) > 3]
    if not samples:
        return print(f"[{label}] IDLE {name}: no samples")
    seconds = min(len(s) for s in samples)
    cpu = [sum(s[i][0] for s in samples) for i in range(seconds)]
    switches = [sum(s[i][1] for s in samples) for i in range(seconds)]
    wakeups = [sum(s[i][2] for s in samples) for i in range(seconds)]
    over = [(i, c) for i, c in enumerate(cpu) if c > 1.0]
    spans = max(1, seconds - 1)
    print(f"[{label}] IDLE {name}: {seconds} s, CPU mean {sum(cpu) / seconds:.3f}%, worst {max(cpu):.1f}%, seconds over 1%: {len(over)}"
          + (" (" + ", ".join(f"{i}s {c:.1f}%" for i, c in over[:40]) + ")" if over else "")
          + f"; idle wakeups {(wakeups[-1] - wakeups[0]) / spans:.2f}/s, context switches {(switches[-1] - switches[0]) / spans:.2f}/s")


report("app", [app])
if under:
    report("engine", under)

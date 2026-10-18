#!/usr/bin/env python3
# judge.py <run folder> <full|quick> <runs> [only] [stopped]: reads a run's results.txt, prints
# one row a measure, the median of its runs (least to most) beside its budget from
# Perf/budgets.json, and exits 1 naming each median over its budget and each run that died or gave
# no number, 3 when nothing failed but a measure has no quiet run to judge, 0 when every measure
# was judged and is inside its budget. plan.txt, which perf.sh writes, says how many runs each
# config was to have. A run the machine wasn't quiet for, or whose window never came to the front
# or lost it while idle, is left out, since its numbers are another measure's; `stopped` says
# perf.sh gave up there, and what was measured before is still judged. With --measured in place
# of the verdict it prints what budgets.json records.
import json
import os
import re
import statistics
import sys

folder, mode, asked = sys.argv[1], sys.argv[2], int(sys.argv[3])
only = sys.argv[4] if len(sys.argv) > 4 else '.'
stopped = 'stopped' in sys.argv[5:]
measured = '--measured' in sys.argv[5:]
here = os.path.dirname(os.path.abspath(__file__))
budgets = json.load(open(os.path.join(here, '..', '..', 'Perf', 'budgets.json')))['measures']

FRAME = r'p95 [0-9.]+, worst ([0-9.]+)'
# id, config, the start of its line, the number in it, whether make perf-quick takes it.
MEASURES = [
    ('key.ms', 'keys1', r'KEYS one thread, nothing streaming', r'([0-9.]+) ms inside the key', True),
    ('key.clock.ms', 'keys1', r'KEYS one thread, nothing streaming', r'by the clock ([0-9.]+)', True),
    ('key.frame.ms', 'keys1', r'KEYS one thread, nothing streaming', r'longest frame after a key ([0-9.]+) on average', True),
    ('key.dropped', 'keys1', r'KEYS one thread, nothing streaming', r'frames dropped (\d+)', True),
    ('key.streaming.ms', 'keys1', r'KEYS one thread, its own reply streaming', r'([0-9.]+) ms inside the key', True),
    ('key.streaming.clock.ms', 'keys1', r'KEYS one thread, its own reply streaming', r'by the clock ([0-9.]+)', True),
    ('key.pair.ms', 'keys2', r'KEYS a pair, nothing streaming', r'([0-9.]+) ms inside the key', False),
    ('key.pair.clock.ms', 'keys2', r'KEYS a pair, nothing streaming', r'by the clock ([0-9.]+)', False),
    ('key.pair.streaming.ms', 'keys2', r'KEYS a pair, the other streaming', r'([0-9.]+) ms inside the key', False),
    ('key.pair.streaming.clock.ms', 'keys2', r'KEYS a pair, the other streaming', r'by the clock ([0-9.]+)', False),
    ('stream.delta.ms', 'stream1', r'STREAM into one thread \(100 turns behind\)', r'([0-9.]+) ms a beat', True),
    ('stream.delta.clock.ms', 'stream1', r'STREAM into one thread \(100 turns behind\)', r'by the clock ([0-9.]+) ms inside a delta', True),
    ('stream.over16', 'stream1', r'STREAM into one thread \(100 turns behind\)', r'over 16\.7ms (\d+)', True),
    ('stream.dropped', 'stream1', r'STREAM into one thread \(100 turns behind\)', r'frames dropped (\d+)', True),
    ('stream.empty.over16', 'stream1', r'STREAM into one thread \(0 turns behind\)', r'over 16\.7ms (\d+)', True),
    ('stream.settle.worst.ms', 'stream1', r'SETTLE into one thread \(100 turns behind\)', r'worst frame ([0-9.]+)', True),
    ('stream2.delta.ms', 'stream2', r'STREAM into both of a pair \(100 turns behind\)', r'([0-9.]+) ms a beat', False),
    ('stream2.over16', 'stream2', r'STREAM into both of a pair \(100 turns behind\)', r'over 16\.7ms (\d+)', False),
    ('stream2.dropped', 'stream2', r'STREAM into both of a pair \(100 turns behind\)', r'frames dropped (\d+)', False),
    ('codesettle.ms', 'codesettle', r'CODESETTLE \d', r': ([0-9.]+) ms in 300ms', False),
    ('codesettle.worst.ms', 'codesettle', r'CODESETTLE \d', r'worst frame ([0-9.]+)', False),
    ('scroll.wheel.p95.ms', 'scroll', r'SCROLL one thread, round \d, wheel 90pt', r'p95 ([0-9.]+)', False),
    ('scroll.wheel.dropped', 'scroll', r'SCROLL one thread, round \d, wheel 90pt', r'frames dropped (\d+)', False),
    ('scroll.flick.worst.ms', 'scroll', r'SCROLL one thread, round \d, flick', FRAME, False),
    ('scroll.flick.dropped', 'scroll', r'SCROLL one thread, round \d, flick', r'frames dropped (\d+)', False),
    ('edits.wheel.over8', 'edits', r'EDITS round \d, wheel 40pt', r'over 8\.3ms (\d+)', False),
    ('edits.wheel.p95.ms', 'edits', r'EDITS round \d, wheel 40pt', r'p95 ([0-9.]+)', False),
    ('edits.wheel.dropped', 'edits', r'EDITS round \d, wheel 40pt', r'frames dropped (\d+)', False),
    ('edits.end.ms', 'edits', r'EDITS round \d, back to the end', r'main ([0-9.]+) ms in all', False),
    ('edits.end.p95.ms', 'edits', r'EDITS round \d, back to the end', r'p95 ([0-9.]+)', False),
    ('edits.flick.worst.ms', 'edits', r'EDITS round \d, flick', FRAME, False),
    ('edits.flick.dropped', 'edits', r'EDITS round \d, flick', r'frames dropped (\d+)', False),
    ('switch.worst.ms', 'switch', r'SWITCH \d+ to \w+ \(again\)', r'worst frame ([0-9.]+)', False),
    ('palette.letter.ms', 'palette', r'PALETTE search', r'([0-9.]+) ms inside a letter', True),
    ('palette.letter.clock.ms', 'palette', r'PALETTE search', r'by the clock ([0-9.]+)', True),
    ('palette.letter.frame.ms', 'palette', r'PALETTE search', r'longest frame after a letter ([0-9.]+) on average', True),
    ('palette.open.worst.ms', 'palette', r'PALETTE open', r'worst frame ([0-9.]+)', True),
    ('review.open.worst.ms', 'review', r'open \d+, big, witness', FRAME, False),
    ('review.wheel.worst.ms', 'review', r'REVIEWSCROLL big, witness, 160pt a frame down', FRAME, False),
    ('review.wheel.dropped', 'review', r'REVIEWSCROLL big, witness, 160pt a frame down', r'frames dropped (\d+)', False),
    ('review.flick.worst.ms', 'review', r'REVIEWSCROLL big, witness, flick', FRAME, False),
    ('review.flick.dropped', 'review', r'REVIEWSCROLL big, witness, flick', r'frames dropped (\d+)', False),
    ('review.jwalk.worst.ms', 'jwalk', r'JWALK \d, big, witness', FRAME, False),
    ('review.jwalk.dropped', 'jwalk', r'JWALK \d, big, witness', r'frames dropped (\d+)', False),
    ('review.backstep.witness.off', 'backstep-witness', r'BACKSTEP big, witness, 560pt: \d+ ends', r'off the page in (\d+)', False),
    ('review.backstep.legacy.off', 'backstep-legacy', r'BACKSTEP big, legacy, 560pt: \d+ ends', r'off the page in (\d+)', False),
    ('memory.long.mb', 'mem', r'MEM the long thread open', r'([0-9.]+) MB', False),
    ('memory.threads.mb', 'mem', r'MEM after ten more threads', r'([0-9.]+) MB', False),
    ('memory.review10.mb', 'mem', r'MEM after the review opened and closed ten times', r'\(([+-][0-9.]+) on before\)', False),
    ('launch.warm.ms', 'launch-warm-one', r'LAUNCH', r'window up ([0-9.]+)', False),
    ('launch.fresh.ms', 'launch-fresh-one', r'LAUNCH', r'window up ([0-9.]+)', False),
    ('launch.warm.pair.ms', 'launch-warm-pair', r'LAUNCH', r'window up ([0-9.]+)', False),
    ('launch.footprint.one.mb', 'launch-warm-one', r'FOOTPRINT app', r'Footprint: ([0-9.]+) MB', False),
    ('launch.footprint.pair.mb', 'launch-warm-pair', r'FOOTPRINT app', r'Footprint: ([0-9.]+) MB', False),
    ('launch.footprint.engine.mb', 'launch-warm-one', r'FOOTPRINT child node', r'Footprint: ([0-9.]+) MB', False),
    ('size.app.kb', 'size', r'SIZE app', r'SIZE app (\d+) KB', False),
    ('size.bench.symbols', 'size', r'SIZE app', r'bench symbols in it (\d+)', False),
]
for threads in ('one', 'pair'):
    for state in ('front', 'hidden', 'background'):
        config = f'idle-{state}-{threads}'
        MEASURES += [
            (f'idle.{state}.{threads}.cpu', config, r'IDLE app', r'CPU mean ([0-9.]+)%', False),
            (f'idle.{state}.{threads}.over1', config, r'IDLE app', r'seconds over 1%: (\d+)', False),
            (f'idle.{state}.{threads}.wakeups', config, r'IDLE app', r'idle wakeups ([0-9.]+)/s', False),
            (f'idle.{state}.{threads}.engine.over1', config, r'IDLE engine', r'seconds over 1%: (\d+)', False),
        ]
# Counts of what must never happen: the runs are added up, since a median of three would pass one bad run.
SUMMED = ('review.backstep.witness.off', 'review.backstep.legacy.off')
EARLY = ['earlyj-witness-40', 'earlyj-witness-150', 'earlyj-legacy-40', 'earlyj-legacy-150']

# Every line by config and run. A label is <config>-r<run>, or the config alone where there is one run.
lines, away, unquiet, died, machine = {}, set(), set(), {}, ''
path = os.path.join(folder, 'results.txt')
for line in open(path, errors='replace') if os.path.exists(path) else []:
    found = re.match(r'\[([\w.-]+?)(?:-r(\d+))?\] (.*)', line)
    if not found:
        continue
    config, run, text = found.group(1), found.group(2) or '1', found.group(3)
    if config == 'machine':
        machine = text
    lines.setdefault((config, run), []).append(text)
    if text.startswith('front: app active false'):
        away.add((config, run))
    if text.startswith('not run: the machine'):
        unquiet.add((config, run))
    # The bench died, was killed at its time limit, or a part of it gave up before it measured.
    if re.match(r'run exit|no app|\w+ failed:|\w+: (the composer never|no transcript|the engine isn|no diff read|no page|the keyboard is on no change)|REVIEWSCROLL: the review', text):
        died[(config, run)] = text
    # Idle in front is idle with nobody at the Mac: another app coming forward is someone there.
    if config.startswith('idle-front') and text.startswith('IDLE ') and 'in front:' in text and '"OriCode Perf"' not in text:
        away.add((config, run))


def runs_of(config):
    return sorted(run for (c, run) in lines if c == config)


# How many runs perf.sh meant each config to have. Without the file (a folder from before it) no count is held to.
plan = {}
path = os.path.join(folder, 'plan.txt')
for line in open(path) if os.path.exists(path) else []:
    plan[line.split()[0]] = int(line.split()[1])
# What failed, by config and run: the measures it gave no number for.
failed, lost = {}, []


def values(name, config, start, number):
    """One number a run: the median of the run's lines that carry it. A run that has lines and not this one failed."""
    out = []
    for run in [str(n + 1) for n in range(plan[config])] if config in plan else runs_of(config):
        said = lines.get((config, run))
        if (config, run) in away or (config, run) in unquiet or (said is None and stopped):
            lost.append(name)
            continue
        got = [float(m.group(1)) for text in said or [] if re.match(start, text) for m in [re.search(number, text)] if m]
        if got:
            out.append(statistics.median(got))
        else:
            failed.setdefault((config, run), []).append(name)
    return out


wanted = lambda config: re.search(only, config) or (config.split('-')[0] in ('launch', 'idle', 'size') and re.search(only, config.split('-')[0]))
MEASURES = [m for m in MEASURES if wanted(m[1]) and (m[4] or mode != 'quick') and (not plan or m[1] in plan)]
rows = [(name, values(name, config, start, number), config, quick) for name, config, start, number, quick in MEASURES]
rows = [(name, [sum(got)] if got and name in SUMMED else got, config, quick) for name, got, config, quick in rows]
# The early J has no number but whether the app was still running three seconds after it.
crashed = []
early = [config for config in EARLY if (config in plan if plan else wanted(config))]
for config in early:
    for run in [str(n + 1) for n in range(plan[config])] if plan else runs_of(config):
        said = lines.get((config, run))
        if (config, run) in unquiet or (said is None and stopped):
            lost.append('review.earlyj.crashes')
        elif any('pressing J' in text for text in said or []) or any(text.startswith('run exit') for text in said or []):
            crashed.append(0.0 if any('still running' in text for text in said) else 1.0)
        else:
            failed.setdefault((config, run), []).append('review.earlyj.crashes')
if early:
    rows.append(('review.earlyj.crashes', [sum(crashed)] if crashed else [], 'earlyj', True))
# A run that gave its numbers and then died is still a run that died.
for (config, run), text in sorted(died.items()):
    if config not in EARLY and text.startswith('run exit'):
        failed.setdefault((config, run), [])


def places(numbers):
    """Decimal places for a row, from its middle number, so its least and most read alike."""
    if all(float(n).is_integer() for n in numbers):
        return 0
    middle = abs(statistics.median(numbers))
    return 0 if middle >= 100 else 1 if middle >= 10 else 2 if middle >= 0.1 else 3


def show(value, among=None):
    return f'{value:.{places(among or [value])}f}'


if measured:
    out = {}
    for name, got, _, _ in rows:
        if got:
            out[name] = {'measured': float(show(statistics.median(got), got)), 'range': [float(show(min(got), got)), float(show(max(got), got))], 'runs': len(got), 'values': got}
    print(json.dumps(out, indent=2))
    sys.exit(0)

over, missing, unbudgeted, table = [], [], [], []
for name, got, config, _ in rows:
    budget = budgets.get(name)
    if budget is None:
        unbudgeted.append(name)
        continue
    if not got:
        missing.append(name)
        table.append((name, budget['what'], 'not measured', '', budget, ''))
        continue
    median = statistics.median(got)
    spread = f' ({show(min(got), got)}–{show(max(got), got)})' if len(got) > 1 and min(got) != max(got) else ''
    verdict = 'OVER' if median > budget['budget'] else ''
    if verdict:
        over.append(f"{name}, {budget['what']}: {show(median, got)} {budget['unit']} over its budget of {budget['budget']:g}")
    table.append((name, budget['what'], show(median, got) + spread, f'n={len(got)}', budget, verdict))

print(f"\nOriCode's budget, {mode}, {folder}")
if machine:
    print(machine)
load = os.path.join(folder, 'load.txt')
if os.path.exists(load):
    readings = open(load).read().splitlines()
    busiest = [(float(m.group(2)), m.group(1).strip()) for line in readings for m in re.finditer(r'[:;]\s*([^;:%]+?) ([0-9.]+)%;', line.split('busiest', 1)[-1])]
    loads = [float(m.group(1)) for line in readings for m in [re.search(r'load \{ ([0-9.]+)', line)] if m]
    if busiest and loads:
        top = max(busiest)
        print(f"load before each of {len(readings)} runs: 1-minute average {min(loads):.2f} to {max(loads):.2f}; the busiest process seen was {top[1]} at {top[0]:.0f}% of a core")
    for line in readings:
        if 'NOT QUIET' in line:
            print(line)
print()
width = max((len(row[1]) for row in table), default=10)
for name, what, value, count, budget, verdict in table:
    ceiling = '  ceiling, not a pass' if budget.get('ceiling') else ''
    print(f"{what:{width}s}  {value:>22s} {budget['unit']:5s} {count:5s} budget {budget['budget']:>6g}  {verdict}{ceiling}")
print()
if away:
    print(f"left out, the window wasn't in front throughout: {', '.join(sorted(f'{c} run {r}' for c, r in away))}")
if asked < 3:
    print(f"each measure ran {asked} time{'s' if asked > 1 else ''}, not three: a budget is for the median of three")
if unbudgeted:
    print('no budget in Perf/budgets.json for: ' + ', '.join(unbudgeted))
    sys.exit(2)
for line in over:
    print('OVER BUDGET  ' + line)
for (config, run), names in sorted(failed.items()):
    print(f"FAILED  {config}, run {run}" + (f": {died[(config, run)]}" if (config, run) in died else '') + ('; no number for ' + ', '.join(names) if names else ''))
short = sorted(set(lost) - set(missing))
if short:
    print('judged on fewer runs than asked, the machine or the window having been lost for the rest: ' + ', '.join(short))
if missing:
    print(('the machine was not quiet, so there is no run to judge for: ' if stopped else 'not judged, no run to read for: ') + ', '.join(missing))
if over or failed:
    sys.exit(1)
if missing or stopped:
    sys.exit(3)
print(f'inside the budget: {len(table)} measures')

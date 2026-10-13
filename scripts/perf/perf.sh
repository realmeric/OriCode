#!/bin/zsh
# perf.sh <full|quick>: what make perf and make perf-quick run once OriCode Perf is built. full
# is every measure three times, the launch ten and idle for three minutes in each state, about
# an hour with a window in front; quick is keys, one stream, ⌘K and the early J, three times.
# Each measure is a fresh process. The lines land in a folder of their own under
# ~/Library/Developer/OriCode/perf/runs, and judge.py prints the table and gives the exit code:
# 0 inside every budget, 1 naming each number over its own and each run that died, 3 when nothing
# failed but a measure went unjudged because another process held a core or the bench couldn't
# come to the front. When a core is held the run stops there; what it measured before is judged.
#   PERF_RUNS=1 runs each measure once (the judge then says so); PERF_ONLY=<regex> picks configs.
mode=${1:-full}
BUILD=${BUILD:-$HOME/Library/Developer/OriCode}
export PERF_OUT="$BUILD/perf/runs/$(date +%Y%m%d-%H%M%S)-$mode"
. ${0:A:h}/env.sh
ln -sfn "$OUT" "$BUILD/perf/latest"
runs=${PERF_RUNS:-3}; only=${PERF_ONLY:-.}

[ -d "$APP" ] || { echo "no OriCode Perf at $APP: make perf builds it"; exit 2; }
judge() { python3 $HERE/judge.py "$OUT" $mode $runs "$only"; exit $?; }
# Nothing more is measured once the machine stops being quiet; what was measured before is judged.
unquiet() { echo "$(tail -1 "$OUT/load.txt")"; echo "perf: another process holds a core, so nothing more is measured"; quit; python3 $HERE/judge.py "$OUT" $mode $runs "$only" stopped; exit $?; }

echo "perf: $mode, $runs runs a measure, lines in $OUT"
# A display that sleeps draws no frame, and on battery it sleeps two minutes after the last hand on it.
caffeinate -dim -w $$ &
$HERE/quiet.sh start > /dev/null || unquiet
{
  echo "[machine] $(sysctl -n hw.model), macOS $(sw_vers -productVersion), $(pmset -g batt | head -1 | grep -oE "'.*'"), $(git -C ${0:A:h} rev-parse --short HEAD 2>/dev/null)$(git -C ${0:A:h} diff --quiet 2>/dev/null || echo ' with changes')"
} >> "$OUT/results.txt"

# config|parts|timeout s|environment. The pointer is wherever its owner left it, and a window
# drawn under it is another measure from one drawn beside it, so every config says: a transcript
# or a review that is scrolled has the pointer over it, as a hand on the wheel does, and the rest
# stand clear of it.
quick=(
  "keys1|keys|120|PERF_POINTER=away PERF_PAIR=0"
  "stream1|stream|180|PERF_POINTER=away PERF_PAIR=0"
  "palette|palette|120|PERF_POINTER=away PERF_PAIR=0"
  "earlyj-witness-40|earlyj|120|PERF_POINTER=away PERF_BOOK=big PERF_DESIGN=witness PERF_EARLY=40"
  "earlyj-witness-150|earlyj|120|PERF_POINTER=away PERF_BOOK=big PERF_DESIGN=witness PERF_EARLY=150"
  "earlyj-legacy-40|earlyj|120|PERF_POINTER=away PERF_BOOK=big PERF_DESIGN=legacy PERF_EARLY=40"
  "earlyj-legacy-150|earlyj|120|PERF_POINTER=away PERF_BOOK=big PERF_DESIGN=legacy PERF_EARLY=150"
)
rest=(
  "keys2|keys|120|PERF_POINTER=away PERF_PAIR=1"
  "stream2|stream|180|PERF_POINTER=away PERF_PAIR=1 PERF_BOTH=1"
  "codesettle|codesettle|180|PERF_POINTER=away PERF_PAIR=0"
  "scroll|scroll|180|PERF_POINTER=over PERF_PAIR=0"
  "edits|edits|180|PERF_POINTER=over PERF_PAIR=0 PERF_DESIGN=witness"
  "switch|switch|120|PERF_POINTER=away PERF_PAIR=0"
  "review|review|300|PERF_POINTER=over PERF_BOOK=big PERF_DESIGN=witness"
  "jwalk|jwalk|300|PERF_POINTER=away PERF_BOOK=big PERF_DESIGN=witness"
  "backstep-witness|backstep|300|PERF_POINTER=away PERF_BOOK=big PERF_DESIGN=witness"
  "backstep-legacy|backstep|300|PERF_POINTER=away PERF_BOOK=big PERF_DESIGN=legacy"
  "mem|mem|300|PERF_POINTER=away PERF_DESIGN=witness"
)
configs=($quick); [ $mode = full ] && configs+=($rest)
launches=${PERF_LAUNCHES:-10}
# What this run means to measure, for the judge: a config with fewer runs than this had one die.
{
  for line in $configs; do [[ ${line%%|*} =~ $only ]] && echo "${line%%|*} $runs"; done
  if [ $mode = full ]; then
    [[ launch =~ $only ]] && print -l "launch-warm-one $launches" "launch-fresh-one $launches" "launch-warm-pair 3"
    [[ idle =~ $only ]] && for threads in one pair; do for state in front hidden background; do echo "idle-$state-$threads 1"; done; done
    [[ size =~ $only ]] && echo "size 1"
  fi
} > "$OUT/plan.txt"
for run in $(seq $runs); do
  for line in $configs; do
    parts=("${(@s:|:)line}")
    [[ $parts[1] =~ $only ]] || continue
    $HERE/run.sh "$parts[1]-r$run" "$parts[2]" $parts[3] ${=parts[4]}
    [ $? = 3 ] && unquiet
    echo "$(date +%H:%M:%S) $parts[1] $run of $runs"
    sleep 2
  done
done
[ $mode = full ] || judge

if [[ launch =~ $only || idle =~ $only ]]; then $HERE/seed.sh || exit 2; fi
if [[ launch =~ $only ]]; then
  # The launch, warm and from a fresh copy of the bundle, ten each, and three warm with a pair kept.
  for launch in "one warm $launches" "one fresh $launches" "pair warm 3"; do
    parts=(${=launch})
    $HERE/launch.sh $parts[1] $parts[2] launch-$parts[2]-$parts[1] $parts[3]
    [ $? = 3 ] && unquiet
  done
  echo "$(date +%H:%M:%S) launches"
fi
if [[ idle =~ $only ]]; then
  for threads in one pair; do
    for state in front hidden background; do
      $HERE/idle.sh $threads $state idle-$state-$threads ${PERF_IDLE:-180}
      [ $? = 3 ] && unquiet
      echo "$(date +%H:%M:%S) idle $state $threads"
      sleep 3
    done
  done
fi

# OriCode itself, as make app leaves it: its size on disk, and that none of the bench is in it.
shipped="$BUILD/DerivedData/Build/Products/Release/OriCode.app"
if [ -d "$shipped" ] && [[ size =~ $only ]]; then
  rm -rf "$OUT/size"; mkdir -p "$OUT/size"; cp -R "$shipped" "$OUT/size/"
  $HERE/../prune.sh "$OUT/size/OriCode.app" && codesign --force --deep --sign - "$OUT/size/OriCode.app" 2> /dev/null
  bench=$(strings - "$OUT/size/OriCode.app/Contents/MacOS/OriCode" | grep -c PerfBench)
  [ -d "$shipped.dSYM" ] && bench=$((bench + $(nm "$shipped.dSYM/Contents/Resources/DWARF/OriCode" 2> /dev/null | grep -c PerfBench)))
  echo "[size] SIZE app $(du -sk "$OUT/size/OriCode.app" | cut -f1) KB on disk, binary $(stat -f %z "$OUT/size/OriCode.app/Contents/MacOS/OriCode") bytes, engine $(du -sk "$OUT/size/OriCode.app/Contents/Resources/engine" | cut -f1) KB; bench symbols in it $bench" >> "$OUT/results.txt"
  rm -rf "$OUT/size"
fi
rm -rf "$OUT/fresh"
judge

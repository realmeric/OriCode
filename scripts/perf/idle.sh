#!/bin/zsh
# idle.sh <one|pair> <front|hidden|background> <label> [seconds]: OriCode Perf opened on its
# seeded store and left thirty seconds to settle, then the app, its engine and anything under
# them sampled once a second with top: CPU, context switches, idle wakeups. front: opened and
# left in front. hidden: the app hides itself twelve seconds in. background: opened with open -g,
# its window on screen behind another app's. powermetrics needs sudo, so top it is.
. ${0:A:h}/env.sh
threads=$1; state=$2; label=$3; seconds=${4:-180}
quit
$HERE/keep.sh $threads
$HERE/quiet.sh $label > /dev/null || { echo "[$label] not run: the machine isn't quiet" >> "$OUT/results.txt"; exit 3; }
case $state in
  front) open -n --env PERF_OUT="$OUT" "$APP" ;;
  hidden) open -n --env PERF_OUT="$OUT" --env PERF_HIDE=12 "$APP" ;;
  background) open -n -g --env PERF_OUT="$OUT" "$APP" ;;
esac
sleep 30
pid=$(running | head -1)
[ -n "$pid" ] || { echo "[$label] no app" >> "$OUT/results.txt"; exit 2; }
pids=($pid $(pgrep -P $pid)); for child in $(pgrep -P $pid); do pids+=($(pgrep -P $child)); done
args=(); for p in $pids; do args+=(-pid $p); done
where() { echo "in front: $(lsappinfo info -only name "$(lsappinfo front)" | cut -d= -f2)" }
echo "[$label] IDLE begins, $threads, $state, pids $pids; $(where)" >> "$OUT/results.txt"
top -l $((seconds + 1)) -s 1 $args -stats pid,command,cpu,csw,idlew,power,mem,threads > "$OUT/top-$label.txt"
python3 $HERE/idle.py "$OUT/top-$label.txt" $label $pid $pids[2,-1] >> "$OUT/results.txt"
echo "[$label] IDLE ends; $(where); footprint $(footprint -p $pid 2>/dev/null | grep -oE 'Footprint: [0-9.]+ [A-Z]+' | head -1)" >> "$OUT/results.txt"
quit

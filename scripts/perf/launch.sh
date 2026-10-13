#!/bin/zsh
# launch.sh <one|pair> <warm|fresh> <label> [runs]: opens OriCode Perf as a person does, on its
# seeded store, and the app writes its own launch marks (PerfBench.watchLaunch), in ms since the
# process began. Fifteen seconds in, once V8 has collected for the first time, its footprint and
# its engine's are read from outside, and it is quit with SIGTERM, as ⌘Q would. fresh launches a
# new copy of the bundle each time, which dyld and the code signature have never seen: the nearest
# to cold there is without sudo purge. Exits 3 at the first launch the machine isn't quiet for.
. ${0:A:h}/env.sh
threads=$1; kind=$2; label=$3; runs=${4:-10}
for run in $(seq $runs); do
  tag="$label-r$run"; app="$APP"
  if [ $kind = fresh ]; then rm -rf "$OUT/fresh"; mkdir -p "$OUT/fresh"; cp -R "$APP" "$OUT/fresh/"; app="$OUT/fresh/OriCode Perf.app"; fi
  quit
  $HERE/keep.sh $threads
  $HERE/quiet.sh $tag > /dev/null || { echo "[$tag] not run: the machine isn't quiet" >> "$OUT/results.txt"; exit 3; }
  open -n --env PERF_OUT="$OUT" --env PERF_LAUNCH=$tag "$app"
  for i in $(seq 200); do grep -qF "[$tag] LAUNCH" "$OUT/results.txt" 2>/dev/null && break; sleep 0.1; done
  sleep 15
  pid=$(running | head -1)
  {
    echo "[$tag] FOOTPRINT app $(footprint -p $pid 2>/dev/null | grep -oE 'Footprint: [0-9.]+ [A-Z]+' | head -1)"
    for child in $(pgrep -P $pid); do echo "[$tag] FOOTPRINT child $(ps -o comm= -p $child | sed 's|.*/||') $(footprint -p $child 2>/dev/null | grep -oE 'Footprint: [0-9.]+ [A-Z]+' | head -1)"; done
  } >> "$OUT/results.txt"
  quit
  sleep 2
done

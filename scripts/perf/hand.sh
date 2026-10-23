#!/bin/zsh
# hand.sh [runs]: what make perf's stages don't drive, in OriCode Perf's own window on a store of
# PERF_THREADS threads (300 unless said), its engine up and its menus listening: the drawer, ⌘1–4,
# a click in the drawer, ⌘K, ⌘⇧I, the long thread scrolled and a reply streamed (PerfBench.hand).
# Not judged against a budget: K-318 read it beside v0.4.2's. PERF_TRACE=<template> records each
# run with xctrace attached.
. ${0:A:h}/env.sh
runs=${1:-3}
quit
rm -rf "$HOME/Library/Application Support/OriCode Perf" "$HOME/Library/Logs/OriCode Perf"
defaults delete $ID 2>/dev/null
perl -e 'alarm shift; exec @ARGV' 180 open -n -W --env XCTestConfigurationFilePath=/dev/null --env PERF_OUT="$OUT" --env PERF_BENCH=seed --env PERF_PARTS=seed --env PERF_THREADS=${PERF_THREADS:-300} "$APP"
for run in $(seq $runs); do
  quit
  $HERE/quiet.sh hand-r$run > /dev/null || { echo "[hand-r$run] not run: the machine isn't quiet" >> "$OUT/results.txt"; exit 3; }
  open -n --env PERF_OUT="$OUT" --env PERF_HAND=hand-r$run "$APP"
  sleep 1
  pid=$(running | head -1)
  [ -n "$PERF_TRACE" ] && xcrun xctrace record --quiet --template "$PERF_TRACE" --attach $pid --output "$OUT/hand-r$run.trace" --time-limit 150s > /dev/null 2>&1 &
  for i in $(seq 1500); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
  wait
done
quit
grep -F HANDSUM "$OUT/results.txt"

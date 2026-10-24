#!/bin/zsh
# run.sh <label> <parts> [timeout s] [KEY=VALUE …]: OriCode Perf as a fresh process with the
# bench's parts driving it in a window in front. The app's own model boots nothing (the test
# host's switch), so the only engine up is one a part asks for. Exits 3 when the machine isn't quiet.
. ${0:A:h}/env.sh
label=$1; parts=$2; limit=${3:-240}
[ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" = $ID ] || { echo "no OriCode Perf at $APP: make perf builds it"; exit 2; }
$HERE/quiet.sh $label > /dev/null || { echo "[$label] not run: the machine isn't quiet" >> "$OUT/results.txt"; exit 3; }
envs=()
for pair in "${@:4}"; do envs+=(--env "$pair"); done
# PERF_STAGE=1 from the caller puts a live four-agent run in the thread keys and stream type into.
[ -n "$PERF_STAGE" ] && envs+=(--env PERF_STAGE=$PERF_STAGE)
perl -e 'alarm shift; exec @ARGV' $limit open -n -W --env XCTestConfigurationFilePath=/dev/null --env PERF_OUT="$OUT" --env PERF_BENCH="$label" --env PERF_PARTS="$parts" $envs --stdout "$OUT/run.log" --stderr "$OUT/run.log" "$APP"
code=$?
[ $code = 0 ] || echo "[$label] run exit $code" >> "$OUT/results.txt"
pkill -9 -f "OriCode Perf.app/Contents/MacOS" 2>/dev/null
true

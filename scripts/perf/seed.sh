#!/bin/zsh
# seed.sh: empties OriCode Perf's own store and defaults, then has the app write twelve threads
# into it, the 100-turn one open and a 25-turn one beside it. kept.txt gets their ids, which
# keep.sh writes back before each launch.
. ${0:A:h}/env.sh
quit
rm -rf "$HOME/Library/Application Support/OriCode Perf" "$HOME/Library/Logs/OriCode Perf"
defaults delete $ID 2>/dev/null
perl -e 'alarm shift; exec @ARGV' 120 open -n -W --env XCTestConfigurationFilePath=/dev/null --env PERF_OUT="$OUT" --env PERF_BENCH=seed --env PERF_PARTS=seed --env PERF_PAIR=1 "$APP"
line=$(grep -F "[seed] seed:" "$OUT/results.txt" | tail -1)
echo "$line" | grep -oE 'selectedProject [^ ]+ selectedChat [^ ]+ besideChat [^ ]+' > "$OUT/kept.txt"
[ -s "$OUT/kept.txt" ] || { echo "the store wasn't seeded"; exit 2; }

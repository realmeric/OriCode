# Sourced by every script here: where OriCode Perf is built, and where a run's lines go.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
BUILD=${BUILD:-$HOME/Library/Developer/OriCode.noindex}
APP="$BUILD/DerivedData/Build/Products/Release/OriCode Perf.app"
ID=com.realmeric.oricode.perf
# One folder a run, PERF_OUT, which the bench writes results.txt into; perf.sh makes it.
OUT=${PERF_OUT:-$BUILD/perf/latest}
HERE=${0:A:h}
mkdir -p "$OUT"
# The bench's own processes and no other build's.
running() { pgrep -f "OriCode Perf.app/Contents/MacOS" }
quit() {
  for pid in $(running); do kill -TERM $pid 2>/dev/null; done
  for i in $(seq 80); do running > /dev/null || break; sleep 0.1; done
  pkill -9 -f "OriCode Perf.app/Contents/MacOS" 2>/dev/null
  true
}

#!/bin/zsh
# quiet.sh <label>: the machine's load before a run, written to load.txt beside the label. A
# number taken while another process holds a core says nothing about OriCode, so this waits,
# two minutes at most, while one does or Spotlight is indexing, and exits 3 if it still is.
. ${0:A:h}/env.sh
for try in $(seq 12); do
  busiest=$(top -l 2 -s 2 -n 6 -o cpu -stats command,cpu | awk '/^COMMAND/{n++} n==2 && !/^COMMAND/ && $1!="top"{print $NF" "$0}' | sort -rn | head -4 | awk '{c=$1; $1=""; sub(/ [0-9.]+$/,""); printf "%s %.0f%%;", $0, c}')
  top1=$(echo "$busiest" | grep -oE '[0-9]+%' | head -1 | tr -d %)
  mds=$(ps -A -o %cpu=,comm= | awk '/mds_stores|mdworker/{s+=$1} END{printf "%.0f", s}')
  if [ "${top1:-0}" -lt 90 ] && [ "${mds:-0}" -lt 30 ]; then break; fi
  sleep 10
done
note=""
[ "${top1:-0}" -ge 90 ] && note=" NOT QUIET: a process holds a core"
[ "${mds:-0}" -ge 30 ] && note="$note NOT QUIET: Spotlight indexing ${mds}%"
echo "[$1] $(date +%H:%M:%S) load $(sysctl -n vm.loadavg) busiest:$busiest spotlight ${mds}%$note" | tee -a "$OUT/load.txt"
[ -z "$note" ] || exit 3

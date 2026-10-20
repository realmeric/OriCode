#!/bin/zsh
# under.sh NAME: exits 0 when this shell runs under a process whose executable is NAME, as an
# agent's shell runs under the OriCode its thread is in, and 1 when it doesn't.
pid=$$
while (( pid > 1 )); do
  [[ "$(ps -o comm= -p $pid)" == */"$1" ]] && exit 0
  pid=$(ps -o ppid= -p $pid | tr -d ' ')
  [[ -n $pid ]] || break
done
exit 1

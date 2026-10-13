#!/bin/zsh
# watch.sh: takes the pictures the bench asks for. A part names a window and a file in
# shoot-now and waits; this answers with screencapture of that window, until watcher-stop is
# there. Run it beside run.sh when a card's frames are to be looked at; they land in shots/.
. ${0:A:h}/env.sh
cd "$OUT"
rm -f watcher-stop shoot-now; touch watching
while [ ! -f watcher-stop ]; do
  if [ -f shoot-now ]; then
    read wid file < shoot-now
    screencapture -x -o -l "$wid" "$file" 2>> watch.log || screencapture -x "$file" 2>> watch.log
    rm -f shoot-now
  fi
  perl -e 'select(undef,undef,undef,0.03)'
done
rm -f watcher-stop watching

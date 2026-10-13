#!/bin/zsh
# keep.sh <one|pair>: the seeded store's open thread, alone or with the one beside it, written
# into OriCode Perf's defaults as a quit would have left them.
. ${0:A:h}/env.sh
read _ project _ chat _ beside < "$OUT/kept.txt"
defaults write $ID selectedProject "$project"; defaults write $ID selectedChat "$chat"
if [ "$1" = pair ]; then defaults write $ID besideChat "$beside"; else defaults delete $ID besideChat 2>/dev/null; fi
defaults write $ID drawerPinned -bool false
defaults write $ID notify -bool false
true

#!/bin/zsh
# scripts/dmg.sh <app> <dmg>: the disk image a download opens, OriCode beside a link to
# Applications over dmg/background.tiff, laid out by dmg/settings.py, and signed as
# scripts/sign.sh signs the app. make release notarizes and staples it after. dmgbuild runs from
# a venv of its own in ~/Library/Developer/OriCode.noindex/dmgbuild, made here the first time.
set -euo pipefail
app=${1:A}
dmg=${2:A}
here=${0:A:h}/..
venv=$HOME/Library/Developer/OriCode.noindex/dmgbuild

[[ -x $venv/bin/dmgbuild ]] || { python3 -m venv "$venv" && "$venv/bin/pip" install -q dmgbuild }
rm -f "$dmg"
"$venv/bin/dmgbuild" -s "$here/dmg/settings.py" -D app="$app" -D dir="$here/dmg" OriCode "$dmg"

developer=$(security find-identity -v -p codesigning | awk -F'"' '/"Developer ID Application: / { print $2; exit }')
if [[ -n $developer ]]; then
  codesign --force --sign "$developer" --timestamp "$dmg"
elif security find-identity -p codesigning | grep -q '"OriCode"'; then
  codesign --force --sign OriCode "$dmg"
fi
print "Built ${dmg:t}"

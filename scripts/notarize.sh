#!/bin/zsh
# scripts/notarize.sh <app or dmg>: sends a build scripts/export.sh signed with Developer ID, or
# the disk image scripts/dmg.sh made of it, to Apple's notary service through notarytool's
# keychain profile OriCode, waits for it, and staples the ticket to it, so it opens without
# Gatekeeper's warning even offline. make release runs it on the app before zipping for Sparkle,
# and on OriCode.dmg. A rejection stops it with the issues the notary's log names.
set -euo pipefail
app=${1:A}
if [[ $app == *.dmg ]]; then
  submission=$app
else
  submission=$(mktemp -d)/${app:t:r}.zip
  ditto -c -k --keepParent "$app" "$submission"
fi
result=$(xcrun notarytool submit "$submission" --keychain-profile OriCode --wait --output-format json) || true
[[ $submission == $app ]] || rm -rf "${submission:h}"
id=$(print -r -- "$result" | plutil -extract id raw -o - - 2>/dev/null) || { print -u2 "notarytool didn't take the submission: $result"; exit 1 }
notary_status=$(print -r -- "$result" | plutil -extract status raw -o - -)
if [[ $notary_status != Accepted ]]; then
  print -u2 "Notarization $id came back $notary_status:"
  xcrun notarytool log "$id" --keychain-profile OriCode |
    node -e 'const log = JSON.parse(require("fs").readFileSync(0, "utf8")); console.error(log.statusSummary); for (const i of log.issues ?? []) console.error(`${i.severity} ${i.path}: ${i.message}`)'
  exit 1
fi
xcrun stapler staple -q "$app"
xcrun stapler validate -q "$app"
print "Notarized as $id and stapled"

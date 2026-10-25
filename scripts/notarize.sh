#!/bin/zsh
# scripts/notarize.sh <app>: sends a build scripts/sign.sh signed with Developer ID to Apple's
# notary service through notarytool's keychain profile OriCode, waits for it, and staples the
# ticket to the app, so it opens without Gatekeeper's warning even offline. make release runs it
# before zipping for Sparkle. A rejection stops it with the issues the notary's log names.
set -euo pipefail
app=${1:A}
zip=$(mktemp -d)/${app:t:r}.zip

ditto -c -k --keepParent "$app" "$zip"
result=$(xcrun notarytool submit "$zip" --keychain-profile OriCode --wait --output-format json) || true
rm -rf "${zip:h}"
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

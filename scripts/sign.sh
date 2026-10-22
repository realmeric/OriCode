#!/bin/zsh
# scripts/sign.sh <app>: signs a pruned build the way make app and make release ship it. With a
# Developer ID Application identity in the keychain, that's what signs, with the hardened runtime
# and a secure timestamp, which notarization asks for; without one, the OriCode certificate
# (K-134) and then ad hoc, with neither, as before there was a Developer ID. Inside-out rather
# than --deep: every Mach-O in the bundle and every bundle holding code, deepest first, so each
# is sealed after what's inside it and the app last. No entitlements: nothing OriCode does needs
# one under the hardened runtime (K-306).
set -euo pipefail
app=${1:A}

developer=$(security find-identity -v -p codesigning | awk -F'"' '/"Developer ID Application: / { print $2; exit }')
if [[ -n $developer ]]; then
  identity=$developer
  flags=(--options runtime --timestamp)
elif security find-identity -p codesigning | grep -q '"OriCode"'; then
  identity=OriCode
  flags=()
else
  identity=-
  flags=()
fi

# A ticket notarize.sh stapled to an earlier build names that build's signature, not this one's.
rm -f "$app/Contents/CodeResources"

# A fat binary's slices come as lines of their own, "path (for architecture arm64):", and go.
machos=("${(@f)$(find "$app" -type f -print0 | xargs -0 file -N --mime-type -F $'\t' |
  awk -F'\t' '$2 ~ /mach-binary/ && $1 !~ / \(for architecture [^)]*\):$/ { print $1 }')}")
typeset -U code=($machos)
for file in $machos; do
  [[ $file =~ '^(.*\.(app|appex|xpc|framework|bundle|plugin))/(Contents/MacOS|Versions/[^/]+)/[^/]+$' ]] && code+=($match[1])
done
code+=($app)

for item in "${(@f)$(for p in $code; do print -r -- "${#${p//[^\/]}} $p"; done | sort -rn | cut -d' ' -f2-)}"; do
  codesign --force --sign "$identity" $flags "$item"
done
codesign --verify --strict --deep "$app"
print "Signed with $identity"

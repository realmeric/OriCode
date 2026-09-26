#!/bin/zsh
# make release: the Release build, signed with the OriCode certificate, published as a GitHub
# release and offered to every installed OriCode through appcast.xml on main. The version is
# project.yml's MARKETING_VERSION and the notes are its CHANGELOG.md entry, both committed first.
set -euo pipefail
cd "${0:A:h}/.."

version=$(awk -F'"' '/MARKETING_VERSION: "/ {print $2; exit}' project.yml)
system=$(awk -F'"' '/macOS: "/ {print $2; exit}' project.yml)
tag="v$version"
# Numbered by the commits on main, which only goes up, so Sparkle can tell which build is newer.
build=$(git rev-list --count HEAD)
derived="$HOME/Library/Developer/OriCode/DerivedData"
app="$derived/Build/Products/Release/OriCode.app"
sparkle="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
out="$HOME/Library/Developer/OriCode/release"
zip="$out/OriCode-$version.zip"
url="https://github.com/realmeric/OriCode/releases/download/$tag/OriCode-$version.zip"

fail() { print -u2 "$1"; exit 1 }

# Built from main exactly as GitHub has it, so the tag and the appcast name what people get.
[[ -z "$(git status --porcelain)" ]] || fail "Commit first: a release is built from main as it is."
[[ "$(git branch --show-current)" == main ]] || fail "Releases come from main."
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "Push main first, or pull what's on GitHub."
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "$tag is already tagged."
security find-identity -p codesigning | grep -q '"OriCode"' || fail "The OriCode certificate isn't in this Mac's keychain (K-134)."

# The version's CHANGELOG entry: everything under its heading, up to the next one.
heading=$(awk -v h="## $tag " 'index($0, h) == 1 { sub(/^## /, ""); print; exit }' CHANGELOG.md)
notes=$(awk -v h="## $tag " 'index($0, h) == 1 { on = 1; next } /^## / { on = 0 } on' CHANGELOG.md | sed '/./,$!d')
[[ -n "$heading" && -n "$notes" ]] || fail "CHANGELOG.md has no entry for $tag."

xcodebuild -project OriCode.xcodeproj -scheme OriCode -configuration Release -destination platform=macOS,arch=arm64 \
  -derivedDataPath "$derived" -skipPackagePluginValidation -quiet CURRENT_PROJECT_VERSION="$build" build
scripts/prune.sh "$app"
codesign --force --deep --sign OriCode "$app"
codesign --verify --deep --strict "$app"
rm -rf "$out" && mkdir -p "$out"
ditto -c -k --keepParent "$app" "$zip"
# sparkle:edSignature="…" length="…", from the EdDSA key in the login keychain.
signature=$("$sparkle/sign_update" "$zip")

git tag -a "$tag" -m "$heading"
git push -q origin "$tag"
prerelease=()
[[ "$version" == *-* ]] && prerelease=(--prerelease)
gh release create "$tag" "$zip" --verify-tag --title "OriCode $heading" --notes "$notes" "${prerelease[@]}"

# Only the newest release is offered; its notes go as plain text, which the update circle shows.
plain=$(print -r -- "$notes" | sed -E 's/^- /• /')
cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>OriCode</title>
    <item>
      <title>$version</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$system</sparkle:minimumSystemVersion>
      <description sparkle:descriptionFormat="plain-text"><![CDATA[$plain]]></description>
      <enclosure url="$url" $signature type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
git add appcast.xml
git commit -q -m "Offer $version to installed OriCode"
git push -q origin main
print "Released $tag: $url"

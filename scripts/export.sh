#!/bin/zsh
# scripts/export.sh <build number>: the Release build as make app and make release ship it. It's
# archived signed for development, pruned (scripts/prune.sh), and exported by Xcode for Developer
# ID, which signs every piece of code inside-out with the hardened runtime and embeds the Developer
# ID profile that authorizes OriCode's iCloud and push entitlements (KANBAN-phone.md, P-2); Xcode
# makes or renews that profile itself, from the team signed into it. Prints the app's path.
set -euo pipefail
cd "${0:A:h}/.."
derived=${DERIVED:-$HOME/Library/Developer/OriCode/DerivedData}
out=${OUT:-$HOME/Library/Developer/OriCode/export}
archive=$out/OriCode.xcarchive

rm -rf "$out"
xcodebuild -project OriCode.xcodeproj -scheme OriCode -configuration Release -destination generic/platform=macOS \
  -derivedDataPath "$derived" -skipPackagePluginValidation -allowProvisioningUpdates -quiet \
  CURRENT_PROJECT_VERSION="$1" archive -archivePath "$archive"
scripts/prune.sh "$archive/Products/Applications/OriCode.app"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist scripts/developer-id.plist \
  -exportPath "$out" -allowProvisioningUpdates -quiet
codesign --verify --strict --deep "$out/OriCode.app"
print -r -- "$out/OriCode.app"

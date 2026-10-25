#!/bin/zsh
# scripts/phone-beta.sh [export]: OriCode Phone's Release build archived and uploaded to App Store
# Connect for TestFlight, signed for distribution by Xcode from the team signed into it. The build
# number is the commits on the branch, so each upload is newer than the last. With `export` it stops
# at an .ipa in $OUT instead of uploading. Needs the app's record in App Store Connect
# (com.realmeric.oricode.phone); Meriç runs it, in Terminal, like make release.
set -euo pipefail
cd "${0:A:h}/.."
derived=${DERIVED:-$HOME/Library/Developer/OriCode.noindex/DerivedData}
out=${OUT:-$HOME/Library/Developer/OriCode.noindex/phone-beta}
archive=$out/OriCodePhone.xcarchive
destination=${1:-upload}
[[ $destination == export || $destination == upload ]] || { print -u2 "phone-beta.sh [export]"; exit 2 }

rm -rf "$out" && mkdir -p "$out"
xcodebuild -project OriCode.xcodeproj -scheme "OriCode Phone" -configuration Release -destination generic/platform=iOS \
  -derivedDataPath "$derived" -skipPackagePluginValidation -allowProvisioningUpdates -quiet \
  CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" archive -archivePath "$archive"
cat > "$out/options.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$destination</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>422F85XX9Z</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/options.plist" -exportPath "$out" -allowProvisioningUpdates -quiet
print "OriCode Phone $(git rev-list --count HEAD): $([[ $destination == upload ]] && print "uploaded for TestFlight" || print "$out")"

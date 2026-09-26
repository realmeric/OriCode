#!/bin/zsh
# scripts/prune.sh <app>: takes out of a Release build what its packages ship and OriCode never
# uses. make app and make release run it between xcodebuild and codesign. It can't be a build
# phase: Xcode embeds Sparkle and copies Highlightr's bundle outside the phases, and on an
# incremental build it put them back after the phase had run.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
app=$1

# Sparkle's XPC services are for sandboxed apps: it only reaches for them when the Info.plist
# sets SUEnableInstallerLauncherService or SUEnableDownloaderService, and OriCode's sets neither,
# so it downloads in process and installs through Autoupdate and Updater.app, which stay. The nibs
# are its own update windows, which Updates.swift replaces, and every string in its translations
# is keyed by its English text, which is what Sparkle falls back to.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$sparkle/XPCServices" "$sparkle/Versions/B/XPCServices" "$sparkle"/Versions/B/Resources/{*.nib,*.lproj}(N)

# Highlightr's themes but atom-one-dark, which CodeHighlighter uses, and pojoaque, which
# Highlightr() loads first and returns nil without.
highlightr="$app/Contents/Resources/Highlightr_Highlightr.bundle/Contents/Resources"
find "$highlightr" -name '*.css' ! -name atom-one-dark.min.css ! -name pojoaque.min.css -delete

# highlight.js with only the languages CodeHighlighter.language(forExtension:) names, and diff,
# shell and plaintext, which Markdown fences name and it passes through. Each language in
# highlight.min.js is its own part after a "/*! `swift` grammar compiled" comment, registering
# itself, so a language goes with its part; a kept one that isn't there fails the build, as it
# would after a Highlightr update that changes the file's shape.
node -e '
const fs = require("fs");
const [file, ...keep] = process.argv.slice(1);
const [core, ...languages] = fs.readFileSync(file, "utf8").split(/(?=\/\*! `[\w-]+` grammar compiled)/);
const kept = languages.filter((part) => keep.includes(part.match(/`([\w-]+)`/)[1]));
if (kept.length != keep.length) throw new Error(`highlight.min.js has ${kept.length} of the ${keep.length} languages OriCode keeps`);
fs.writeFileSync(file, core + kept.join(""));
' "$highlightr/highlight.min.js" \
  swift typescript javascript python ruby go rust java kotlin c cpp objectivec csharp php \
  json yaml ini markdown bash xml css sql makefile dockerfile diff shell plaintext

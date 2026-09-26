export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)

# Builds live outside the checkout: Documents is synced by iCloud, whose
# FinderInfo xattrs make codesign refuse the bundle.
BUILD := $(HOME)/Library/Developer/OriCode
DERIVED := $(BUILD)/DerivedData
# The Debug build is OriCode Molten, which runs beside the installed OriCode.
DEBUG_APP := $(DERIVED)/Build/Products/Debug/OriCode Molten.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/OriCode.app
# Signed with the OriCode certificate where this Mac has it, so every release keeps the same
# designated requirement and macOS knows it for the same app; ad hoc where it doesn't.
SIGN := $(shell security find-identity -p codesigning 2>/dev/null | grep -q '"OriCode"' && echo OriCode || echo -)
# Numbered by the commits on main, which only goes up, so Sparkle can tell which build is newer.
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
ENGINE_SOURCES := $(wildcard engine/*.ts engine/package.json engine/package-lock.json)

.PHONY: run engine test app release project icon

# A SIGTERM quits OriCode the way ⌘Q does, marking the threads still working, which takes a
# moment; `open` before it has gone would only bring the quitting app forward. Five seconds at most.
gone = for i in $$(seq 50); do pgrep -x "$(1)" >/dev/null || break; sleep 0.1; done

# XcodeGen lists source files explicitly, so regenerate on every build. SwiftTerm runs a package
# plugin, which a command-line build refuses unless validation is skipped.
project:
	xcodegen generate --quiet

run: project
	xcodebuild -project OriCode.xcodeproj -scheme OriCode -configuration Debug -destination platform=macOS,arch=arm64 -derivedDataPath $(DERIVED) -skipPackagePluginValidation -quiet build
	-pkill -x "OriCode Molten"; $(call gone,OriCode Molten)
	open "$(DEBUG_APP)"

engine: $(BUILD)/engine/.stamp

# Staged for the app: no dev tools, no platform binaries (the app runs the user's own claude),
# no peer dependencies, which sdk.mjs never imports, and none of the SDK's files but sdk.mjs
# that it needs; the import at the end fails the build if a new SDK does need one.
$(BUILD)/engine/.stamp: $(ENGINE_SOURCES)
	@if [ -f engine/package.json ]; then \
		set -e; \
		( cd engine && { [ -d node_modules ] || npm ci --silent; } && npx tsc --noEmit -p . ); \
		rm -rf $(BUILD)/engine && mkdir -p $(BUILD)/engine; \
		cp engine/*.ts engine/package.json engine/package-lock.json $(BUILD)/engine/; \
		cd $(BUILD)/engine && npm ci --omit=dev --omit=optional --omit=peer --silent; \
		( cd node_modules/@anthropic-ai/claude-agent-sdk && rm -f bridge.* browser-sdk.* extractFromBunfs.* *.d.ts README.md ); \
		node --input-type=module -e "await import('@anthropic-ai/claude-agent-sdk')"; \
	else mkdir -p $(BUILD)/engine; fi
	@touch $@

test: project engine
	cd engine && node --test test/*.test.ts
	xcodebuild -project OriCode.xcodeproj -scheme OriCode -destination platform=macOS,arch=arm64 -derivedDataPath $(DERIVED) -skipPackagePluginValidation -quiet test

app: project
	xcodebuild -project OriCode.xcodeproj -scheme OriCode -configuration Release -destination platform=macOS,arch=arm64 -derivedDataPath $(DERIVED) -skipPackagePluginValidation -quiet CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) build
	scripts/prune.sh $(RELEASE_APP)
	codesign --force --deep --sign $(SIGN) $(RELEASE_APP)
	-pkill -x OriCode; $(call gone,OriCode)
	rm -rf /Applications/OriCode.app
	cp -R $(RELEASE_APP) /Applications/OriCode.app

# A release on GitHub, offered to every installed OriCode through appcast.xml (scripts/release.sh).
# Meriç runs it, in Terminal, once the version's CHANGELOG entry is committed and pushed.
release: project
	scripts/release.sh

# The app icons are RaysMark on a squircle, OriCode's and OriCode Molten's; re-render them whenever the mark changes.
icon:
	mkdir -p $(BUILD)/icon
	swiftc -O -o $(BUILD)/icon/render scripts/icon/main.swift App/RaysMark.swift
	$(BUILD)/icon/render App/Assets.xcassets/AppIcon.appiconset
	$(BUILD)/icon/render App/Assets.xcassets/AppIconMolten.appiconset molten

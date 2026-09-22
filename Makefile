export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)

# Builds live outside the checkout: Documents is synced by iCloud, whose
# FinderInfo xattrs make codesign refuse the bundle.
BUILD := $(HOME)/Library/Developer/OriCode
DERIVED := $(BUILD)/DerivedData
DEBUG_APP := $(DERIVED)/Build/Products/Debug/OriCode.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/OriCode.app
ENGINE_SOURCES := $(wildcard engine/*.ts engine/package.json engine/package-lock.json)

.PHONY: run engine test app project

# XcodeGen lists source files explicitly, so regenerate on every build.
project:
	xcodegen generate --quiet

run: project
	xcodebuild -project OriCode.xcodeproj -scheme OriCode -configuration Debug -destination platform=macOS,arch=arm64 -derivedDataPath $(DERIVED) -quiet build
	-pkill -x OriCode; sleep 0.3
	open $(DEBUG_APP)

engine: $(BUILD)/engine/.stamp

$(BUILD)/engine/.stamp: $(ENGINE_SOURCES)
	@if [ -f engine/package.json ]; then \
		set -e; \
		( cd engine && { [ -d node_modules ] || npm ci --silent; } && npx tsc --noEmit -p . ); \
		rm -rf $(BUILD)/engine && mkdir -p $(BUILD)/engine; \
		cp engine/*.ts engine/package.json engine/package-lock.json $(BUILD)/engine/; \
		cd $(BUILD)/engine && npm ci --omit=dev --omit=optional --silent; \
	else mkdir -p $(BUILD)/engine; fi
	@touch $@

test: project engine
	cd engine && node --test test/*.test.ts
	xcodebuild -project OriCode.xcodeproj -scheme OriCode -destination platform=macOS,arch=arm64 -derivedDataPath $(DERIVED) -quiet test

app: project
	xcodebuild -project OriCode.xcodeproj -scheme OriCode -configuration Release -destination platform=macOS,arch=arm64 -derivedDataPath $(DERIVED) -quiet build
	codesign --force --deep --sign - $(RELEASE_APP)
	-pkill -x OriCode; sleep 0.3
	rm -rf /Applications/OriCode.app
	cp -R $(RELEASE_APP) /Applications/OriCode.app

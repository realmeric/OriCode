export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)

# Builds live outside the checkout: Documents is synced by iCloud, whose
# FinderInfo xattrs make codesign refuse the bundle. The .noindex suffix keeps
# Spotlight out, or every build wakes mdworker and appstoreagent to scan the new apps.
BUILD := $(HOME)/Library/Developer/OriCode.noindex
DERIVED := $(BUILD)/DerivedData
# The Debug build is OriCode Molten, which runs beside the installed OriCode. A branch built
# beside main names its own, `make run DEBUG_NAME="OriCode Bridge" DEBUG_ID=com.realmeric.oricode.bridge
# BUILD=~/Library/Developer/OriCode.noindex/phone`, so the two never share a store or an engine.
DEBUG_NAME := OriCode Molten
DEBUG_ID := com.realmeric.oricode.molten
DEBUG_APP := $(DERIVED)/Build/Products/Debug/$(DEBUG_NAME).app
XCODE := xcodebuild -project OriCode.xcodeproj -derivedDataPath $(DERIVED) -skipPackagePluginValidation -allowProvisioningUpdates -allowProvisioningDeviceRegistration ORICODE_DEBUG_NAME="$(DEBUG_NAME)" ORICODE_DEBUG_ID=$(DEBUG_ID) ORICODE_BUILD=$(BUILD)
# Exported for Developer ID by scripts/export.sh.
RELEASE_APP := $(BUILD)/export/OriCode.app
# OriCode with the bench compiled in (Perf/), which make perf measures; never installed.
PERF_APP := $(DERIVED)/Build/Products/Release/OriCode Perf.app
# Numbered by the commits on main, which only goes up, so Sparkle can tell which build is newer.
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
ENGINE_SOURCES := $(wildcard engine/*.ts engine/package.json engine/package-lock.json)

.PHONY: run engine test app release project icon perf perf-quick perf-build phone phone-device
# The phone (KANBAN-phone.md). Debug talks to CloudKit's Development environment, as Bridge does;
# CONFIG=Release talks to Production, as the installed OriCode does.
CONFIG := Debug
PHONE_SIM := OriCode iPhone 17
PHONE_SIM_APP := $(DERIVED)/Build/Products/$(CONFIG)-iphonesimulator/OriCodePhone.app
PHONE_DEVICE_APP := $(DERIVED)/Build/Products/$(CONFIG)-iphoneos/OriCodePhone.app

# A SIGTERM quits OriCode the way ⌘Q does, marking the threads still working, which takes a
# moment; `open` before it has gone would only bring the quitting app forward. Five seconds at most.
gone = for i in $$(seq 50); do pgrep -x "$(1)" >/dev/null || break; sleep 0.1; done

# XcodeGen lists source files explicitly, so regenerate on every build. SwiftTerm runs a package
# plugin, which a command-line build refuses unless validation is skipped.
project:
	xcodegen generate --quiet

# A thread in Molten that ran it would quit the Molten it runs in and end its own turn, so from
# there it builds and stops, saying so.
run: project
	$(XCODE) -scheme OriCode -configuration Debug -destination platform=macOS,arch=arm64 -quiet build
	@if scripts/under.sh "$(DEBUG_NAME)"; then echo "Built, not opened: this runs inside $(DEBUG_NAME), which make run would quit, ending this thread. Check the change in the test host, as a card's live check does, or leave make run to the user." >&2; exit 2; fi
	-pkill -x "$(DEBUG_NAME)"; $(call gone,$(DEBUG_NAME))
	open "$(DEBUG_APP)"

engine: $(BUILD)/engine/.stamp

# Builds the phone for the simulator, an iPhone 17 made the first time, and opens it there.
phone: project
	xcrun simctl list devices | grep -q "$(PHONE_SIM) (" || xcrun simctl create "$(PHONE_SIM)" com.apple.CoreSimulator.SimDeviceType.iPhone-17
	$(XCODE) -scheme "OriCode Phone" -configuration $(CONFIG) -destination "platform=iOS Simulator,name=$(PHONE_SIM)" -quiet build
	-xcrun simctl boot "$(PHONE_SIM)"
	xcrun simctl install "$(PHONE_SIM)" "$(PHONE_SIM_APP)"
	xcrun simctl launch "$(PHONE_SIM)" com.realmeric.oricode.phone

# Builds the phone for Meriç's iPhone, signed by Xcode, and installs it on the first iPhone
# devicectl sees, connected or on the same network once paired with Xcode.
phone-device: project
	$(XCODE) -scheme "OriCode Phone" -configuration $(CONFIG) -destination generic/platform=iOS -quiet build
	xcrun devicectl list devices -q -j $(BUILD)/devices.json
	device=$$(python3 -c 'import json, sys; print(next((d["identifier"] for d in json.load(open(sys.argv[1]))["result"]["devices"] if d["hardwareProperties"].get("deviceType") == "iPhone" and d["hardwareProperties"].get("reality") == "physical"), ""))' $(BUILD)/devices.json); \
	[ -n "$$device" ] || { echo "No iPhone: connect it, or pair it with Xcode in Window > Devices and Simulators." >&2; exit 1; }; \
	xcrun devicectl device install app --device $$device "$(PHONE_DEVICE_APP)" && \
	xcrun devicectl device process launch --device $$device com.realmeric.oricode.phone

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
	swift test --package-path Link --scratch-path $(BUILD)/link -q
	$(XCODE) -scheme OriCode -destination platform=macOS,arch=arm64 -quiet test

# Signed as make release signs it, so what Meriç grants this build holds for the release's, and
# not notarized, since it installs on this Mac alone.
app: project
	DERIVED=$(DERIVED) OUT=$(BUILD)/export scripts/export.sh $(BUILD_NUMBER)
	-pkill -x OriCode; $(call gone,OriCode)
	rm -rf /Applications/OriCode.app
	cp -R $(RELEASE_APP) /Applications/OriCode.app

# The budget (rule 6). OriCode Perf is built as make app builds OriCode, with the bench in it, and
# scripts/perf/perf.sh drives it in a window in front: every measure three times, the launch ten,
# idle for three minutes in each state, about an hour in all. It prints the table and perf.sh
# exits 1 naming each number over its budget in Perf/budgets.json and each run that died, which
# make shows as Error 1. When another process holds a core it stops there, judges what it had
# measured and, if none of that failed, exits 3 naming what went unjudged. OriCode itself is built
# beside it, for its size on disk and to see the bench isn't in it. Not in make test: it needs
# a window in front, a 60 Hz display and a Mac nobody is using.
perf-build: project
	$(XCODE) -scheme "OriCode Perf" -configuration Release -destination platform=macOS,arch=arm64 -quiet build
	scripts/prune.sh "$(PERF_APP)"
	codesign --force --deep --sign - "$(PERF_APP)"

perf: perf-build
	$(XCODE) -scheme OriCode -configuration Release -destination platform=macOS,arch=arm64 -quiet build
	BUILD=$(BUILD) scripts/perf/perf.sh full

# The parts a card can run while it works: keys, one stream, ⌘K and the early J, three runs each.
perf-quick: perf-build
	BUILD=$(BUILD) scripts/perf/perf.sh quick

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
	$(BUILD)/icon/render Phone/Assets.xcassets/AppIcon.appiconset phone

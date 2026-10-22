# Archive and upload to App Store Connect (TestFlight); see docs/releases.md.
#   make archive VERSION=0.1.0 BUILD=1000 TEAM=<TEAM_ID>
VERSION ?=
BUILD ?=
TEAM ?=
ARCHIVE := build/mob-ios.xcarchive

.PHONY: archive test

archive:
	@test -n "$(VERSION)" && test -n "$(BUILD)" && test -n "$(TEAM)" || { echo 'Usage: make archive VERSION=X.Y.Z BUILD=N TEAM=<TEAM_ID>' >&2; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo 'Working tree is not clean.' >&2; exit 1; }
	rm -rf $(ARCHIVE) build/export
	xcodebuild -project mob-ios.xcodeproj -scheme mob-ios -configuration Release \
	  -destination 'generic/platform=iOS' -archivePath $(ARCHIVE) \
	  DEVELOPMENT_TEAM=$(TEAM) MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD) \
	  -allowProvisioningUpdates archive
	xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportOptionsPlist ExportOptions.plist \
	  -exportPath build/export -allowProvisioningUpdates

test:
	xcodebuild -project mob-ios.xcodeproj -scheme mob-ios \
	  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:mob-iosTests test

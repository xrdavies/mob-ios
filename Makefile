# iOS app tasks; see docs/releases.md.
#   make version                       show the version, the last release tag and the next versions
#   make release-patch                 next patch version (also release-minor, release-major):
#                                      confirm, commit the version, tag it, push both
#   make release VERSION=v0.1.0        the same with an explicit version
#   make archive TEAM=<TEAM_ID>        archive the tagged commit and upload it to App Store Connect
#   make archive TEAM=<TEAM_ID> BUILD=1000001   re-upload the same version with a higher build number
TEAM ?=
BUILD ?=
ARCHIVE := build/mob-ios.xcarchive

.PHONY: archive test version release release-patch release-minor release-major release-test

version:
	node .github/release/version.mjs

release-patch release-minor release-major:
	node .github/release/tag.mjs $(@:release-%=%)

release: export RELEASE_TAG = $(VERSION)
release:
	node .github/release/tag.mjs "$$RELEASE_TAG"

release-test:
	node --test .github/release/*.test.mjs

archive:
	@test -n "$(TEAM)" || { echo 'Usage: make archive TEAM=<TEAM_ID> [BUILD=N]' >&2; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo 'Working tree is not clean.' >&2; exit 1; }
	@git describe --exact-match --tags --match 'v*' HEAD >/dev/null 2>&1 || { echo 'HEAD is not a release tag; run make release-patch (or -minor, -major) first.' >&2; exit 1; }
	@node .github/release/version.mjs --check "$$(git describe --exact-match --tags --match 'v*' HEAD)"
	rm -rf $(ARCHIVE) build/export
	xcodebuild -project mob-ios.xcodeproj -scheme mob-ios -configuration Release \
	  -destination 'generic/platform=iOS' -archivePath $(ARCHIVE) \
	  DEVELOPMENT_TEAM=$(TEAM) $(if $(BUILD),CURRENT_PROJECT_VERSION=$(BUILD)) \
	  -allowProvisioningUpdates archive
	xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportOptionsPlist ExportOptions.plist \
	  -exportPath build/export -allowProvisioningUpdates

test:
	xcodebuild -project mob-ios.xcodeproj -scheme mob-ios \
	  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:mob-iosTests test

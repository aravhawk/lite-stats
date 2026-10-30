APP = Lite Stats
BUNDLE_ID = com.aravhawk.lite-stats

BUILD_PATH = $(PWD)/build
APP_PATH = "$(BUILD_PATH)/$(APP).app"
ZIP_PATH = "$(BUILD_PATH)/$(APP).zip"

.SILENT: archive notarize sign prepare-dmg prepare-dSYM clean next-version check history open
.PHONY: build archive notarize sign prepare-dmg prepare-dSYM clean next-version check history open

build: clean next-version archive notarize sign prepare-dmg prepare-dSYM open

# --- MAIN WORKFLOW FUNCTIONS --- #

archive: clean
	osascript -e 'display notification "Exporting application archive..." with title "Build Lite Stats"'
	echo "Exporting application archive..."

	xcodebuild \
		-scheme "$(APP)" \
		-destination 'platform=macOS,arch=arm64' \
		-configuration Release archive \
		-archivePath "$(BUILD_PATH)/$(APP).xcarchive"

	echo "Application built, starting the export archive..."

	xcodebuild -exportArchive \
		-exportOptionsPlist "$(PWD)/exportOptions.plist" \
		-archivePath "$(BUILD_PATH)/$(APP).xcarchive" \
		-exportPath "$(BUILD_PATH)"

	ditto -c -k --keepParent $(APP_PATH) $(ZIP_PATH)

	echo "Project archived successfully"

notarize:
	osascript -e 'display notification "Submitting app for notarization..." with title "Build Lite Stats"'
	echo "Submitting app for notarization..."

	xcrun notarytool submit --keychain-profile "AC_PASSWORD" --wait $(ZIP_PATH)

	echo "Lite Stats successfully notarized"

sign:
	osascript -e 'display notification "Stapling Lite Stats..." with title "Build Lite Stats"'
	echo "Going to staple an application..."

	xcrun stapler staple $(APP_PATH)
	spctl -a -t exec -vvv $(APP_PATH)

	osascript -e 'display notification "Lite Stats successfully stapled" with title "Build Lite Stats"'
	echo "Lite Stats successfully stapled"

# create-dmg v1.3.0, fetched at an exact commit (content-addressed, so it can't change under us) into a fresh directory
CREATE_DMG_COMMIT = a2b71d0fda6d0df2a86dc7f67082d4d73e84c59f

prepare-dmg:
	set -e; \
	TMP=$$(mktemp -d); \
	trap 'rm -rf "$$TMP"' EXIT; \
	git -C "$$TMP" init -q create-dmg; \
	git -C "$$TMP/create-dmg" fetch -q --depth 1 https://github.com/create-dmg/create-dmg.git $(CREATE_DMG_COMMIT); \
	git -C "$$TMP/create-dmg" checkout -q FETCH_HEAD; \
	test "$$(git -C "$$TMP/create-dmg" rev-parse HEAD)" = "$(CREATE_DMG_COMMIT)"; \
	rm -f "$(PWD)/$(APP).dmg"; \
	"$$TMP/create-dmg/create-dmg" \
		--volname "$(APP)" \
		--background "./Stats/Supporting Files/background.png" \
		--window-pos 200 120 \
		--window-size 500 320 \
		--icon-size 80 \
		--icon "$(APP).app" 125 175 \
		--hide-extension "$(APP).app" \
		--app-drop-link 375 175 \
		--no-internet-enable \
		"$(PWD)/$(APP).dmg" \
		$(APP_PATH)

# the app inside the final image must still carry a valid, notarized signature
	set -e; \
	MNT=$$(mktemp -d); \
	hdiutil attach -quiet -readonly -nobrowse -mountpoint "$$MNT" "$(PWD)/$(APP).dmg"; \
	trap 'hdiutil detach -quiet "$$MNT"' EXIT; \
	codesign --verify --deep --strict "$$MNT/$(APP).app"; \
	spctl -a -t exec "$$MNT/$(APP).app"

prepare-dSYM:
	echo "Zipping dSYMs..."
	cd "$(BUILD_PATH)/$(APP).xcarchive/dSYMs" && zip -r "$(PWD)/dSYMs.zip" .
	echo "Created zip with dSYMs"

# --- HELPERS --- #

clean:
	rm -rf "$(BUILD_PATH)"
	rm -f "$(PWD)/dSYMs.zip" "$(PWD)/$(APP).dmg"

next-version:
	versionNumber=$$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$(PWD)/Stats/Supporting Files/Info.plist") ;\
	echo "Actual version is: $$versionNumber" ;\
	versionNumber=$$((versionNumber + 1)) ;\
	echo "Next version is: $$versionNumber" ;\
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$versionNumber" "$(PWD)/Stats/Supporting Files/Info.plist" ;\

# usage: make check ID=<submission id>
check:
	xcrun notarytool log "$(ID)" --keychain-profile "AC_PASSWORD"

history:
	xcrun notarytool history --keychain-profile "AC_PASSWORD"

open:
	osascript -e 'display notification "Lite Stats signed and ready for distribution" with title "Build Lite Stats"'
	echo "Opening working folder..."
	open "$(PWD)"

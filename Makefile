SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
.SILENT:

INSTALLER_SIGN_IDENTITY := 16480CA444F481F8DEAF9421FAD2CCE590FC54E4
OVERLAY_CONFIG := Config/Overlay.xcconfig
OVERLAY_SETTING := ./scripts/overlay_setting.sh
BASE_PACKAGE_IDENTIFIER := $(shell $(OVERLAY_SETTING) OVERLAY_BASE_PACKAGE_IDENTIFIER)
DEVELOPMENT_TEAM := $(shell $(OVERLAY_SETTING) OVERLAY_DEVELOPMENT_TEAM)
MACOS_SYSTEM_PROFILE_SPECIFIER := $(shell $(OVERLAY_SETTING) OVERLAY_MACOS_SYSTEM_PROFILE_SPECIFIER)
MACOS_STANDALONE_PROFILE_SPECIFIER := $(shell $(OVERLAY_SETTING) OVERLAY_MACOS_STANDALONE_PROFILE_SPECIFIER)
OVERLAY_HELPER_PLIST := HelperService/LaunchDaemons/HelperService.plist
SFM_SYSTEM_EXPORT_PLIST := build/SFM.System-Export.plist
SFM_SYSTEM_DISTRIBUTION_ARM64 := build/SFM.System-distribution-arm64.xml
SFM_SYSTEM_DISTRIBUTION_X86_64 := build/SFM.System-distribution-x86_64.xml
SFM_SYSTEM_DISTRIBUTION_UNIVERSAL := build/SFM.System-distribution-universal.xml

$(SFM_SYSTEM_EXPORT_PLIST): SFM.System/Export.plist.in $(OVERLAY_CONFIG)
	mkdir -p build
	sed \
		-e 's|__BASE_PACKAGE_IDENTIFIER__|$(BASE_PACKAGE_IDENTIFIER)|g' \
		-e 's|__MACOS_SYSTEM_PROFILE_SPECIFIER__|$(MACOS_SYSTEM_PROFILE_SPECIFIER)|g' \
		-e 's|__MACOS_STANDALONE_PROFILE_SPECIFIER__|$(MACOS_STANDALONE_PROFILE_SPECIFIER)|g' \
		"$<" > "$@"

$(SFM_SYSTEM_DISTRIBUTION_ARM64): SFM.System/distribution.xml.in $(OVERLAY_CONFIG)
	mkdir -p build
	sed \
		-e 's|__BASE_PACKAGE_IDENTIFIER__|$(BASE_PACKAGE_IDENTIFIER)|g' \
		-e 's|__HOST_ARCHITECTURES__|arm64|g' \
		-e 's|__COMPONENT_PKG__|component-arm64.pkg|g' \
		"$<" > "$@"

$(SFM_SYSTEM_DISTRIBUTION_X86_64): SFM.System/distribution.xml.in $(OVERLAY_CONFIG)
	mkdir -p build
	sed \
		-e 's|__BASE_PACKAGE_IDENTIFIER__|$(BASE_PACKAGE_IDENTIFIER)|g' \
		-e 's|__HOST_ARCHITECTURES__|x86_64|g' \
		-e 's|__COMPONENT_PKG__|component-x86_64.pkg|g' \
		"$<" > "$@"

$(SFM_SYSTEM_DISTRIBUTION_UNIVERSAL): SFM.System/distribution.xml.in $(OVERLAY_CONFIG)
	mkdir -p build
	sed \
		-e 's|__BASE_PACKAGE_IDENTIFIER__|$(BASE_PACKAGE_IDENTIFIER)|g' \
		-e 's|__HOST_ARCHITECTURES__|arm64,x86_64|g' \
		-e 's|__COMPONENT_PKG__|component-universal.pkg|g' \
		"$<" > "$@"

build_all: build_ios build_macos build_tvos

build_ios:
	xcodebuild build -scheme SFI -configuration Debug -destination 'generic/platform=iOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

build_macos:
	xcodebuild build -scheme SFM -configuration Debug -destination 'generic/platform=macOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

build_macos_standalone: $(OVERLAY_HELPER_PLIST)
	xcodebuild build -scheme SFM.System -configuration Debug -destination 'generic/platform=macOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

build_tvos:
	xcodebuild build -scheme SFT -configuration Debug -destination 'generic/platform=tvOS' | xcbeautify | grep -A 10 -e "Build Succeeded" -e "BUILD FAILED" -e "❌"

release: release_ios release_macos release_tvos

release_ios: archive_ios upload_ios

archive_ios:
	rm -rf build/SFI.xcarchive
	xcodebuild archive -scheme SFI -configuration Release -destination 'generic/platform=iOS' -archivePath build/SFI.xcarchive -allowProvisioningUpdates | xcbeautify | grep -A 10 -e "Archive Succeeded" -e "ARCHIVE FAILED" -e "❌"

upload_ios:
	xcodebuild -exportArchive -archivePath build/SFI.xcarchive -exportOptionsPlist SFI/Upload.plist -allowProvisioningUpdates

release_macos: archive_macos upload_macos

archive_macos:
	rm -rf build/SFM.xcarchive
	xcodebuild archive -scheme SFM -configuration Release -archivePath build/SFM.xcarchive -allowProvisioningUpdates | xcbeautify | grep -A 10 -e "Archive Succeeded" -e "ARCHIVE FAILED" -e "❌"

upload_macos:
	xcodebuild -exportArchive -archivePath build/SFM.xcarchive -exportOptionsPlist SFI/Upload.plist -allowProvisioningUpdates

release_tvos: archive_tvos upload_tvos

archive_tvos:
	rm -rf build/SFT.xcarchive
	xcodebuild archive -scheme SFT -configuration Release -archivePath build/SFT.xcarchive -allowProvisioningUpdates | xcbeautify | grep -A 10 -e "Archive Succeeded" -e "ARCHIVE FAILED" -e "❌"

upload_tvos:
	xcodebuild -exportArchive -archivePath build/SFT.xcarchive -exportOptionsPlist SFI/Upload.plist -allowProvisioningUpdates

release_macos_standalone: release_macos_dmg release_macos_pkg

# Archive commands
archive_macos_standalone_apple: $(OVERLAY_HELPER_PLIST)
	rm -rf build/SFM.System-arm64.xcarchive
	xcodebuild archive -scheme SFM.System -configuration Release -archivePath build/SFM.System-arm64.xcarchive -derivedDataPath build/SFM.System-arm64.dd ARCHS=arm64 -allowProvisioningUpdates | xcbeautify | grep -A 10 -e "Archive Succeeded" -e "ARCHIVE FAILED" -e "❌"

archive_macos_standalone_intel: $(OVERLAY_HELPER_PLIST)
	rm -rf build/SFM.System-x86_64.xcarchive
	xcodebuild archive -scheme SFM.System -configuration Release -archivePath build/SFM.System-x86_64.xcarchive -derivedDataPath build/SFM.System-x86_64.dd ARCHS=x86_64 -allowProvisioningUpdates | xcbeautify | grep -A 10 -e "Archive Succeeded" -e "ARCHIVE FAILED" -e "❌"

archive_macos_standalone_universal: $(OVERLAY_HELPER_PLIST)
	rm -rf build/SFM.System-universal.xcarchive
	xcodebuild archive -scheme SFM.System -configuration Release -archivePath build/SFM.System-universal.xcarchive -derivedDataPath build/SFM.System-universal.dd -allowProvisioningUpdates | xcbeautify | grep -A 10 -e "Archive Succeeded" -e "ARCHIVE FAILED" -e "❌"

archive_macos_standalone: archive_macos_standalone_apple archive_macos_standalone_intel archive_macos_standalone_universal

# Export commands
export_macos_standalone_apple: $(SFM_SYSTEM_EXPORT_PLIST)
	rm -rf build/SFM.System-arm64
	xcodebuild -exportArchive -archivePath build/SFM.System-arm64.xcarchive -exportOptionsPlist $(SFM_SYSTEM_EXPORT_PLIST) -exportPath build/SFM.System-arm64 -allowProvisioningUpdates

export_macos_standalone_intel: $(SFM_SYSTEM_EXPORT_PLIST)
	rm -rf build/SFM.System-x86_64
	xcodebuild -exportArchive -archivePath build/SFM.System-x86_64.xcarchive -exportOptionsPlist $(SFM_SYSTEM_EXPORT_PLIST) -exportPath build/SFM.System-x86_64 -allowProvisioningUpdates

export_macos_standalone_universal: $(SFM_SYSTEM_EXPORT_PLIST)
	rm -rf build/SFM.System-universal
	xcodebuild -exportArchive -archivePath build/SFM.System-universal.xcarchive -exportOptionsPlist $(SFM_SYSTEM_EXPORT_PLIST) -exportPath build/SFM.System-universal -allowProvisioningUpdates

# DMG commands
build_macos_dmg_apple: archive_macos_standalone_apple export_macos_standalone_apple
	rm -f build/SFM-Apple.dmg
	create-dmg \
		--volname "sing-box" \
		--volicon "build/SFM.System-arm64/SFM.app/Contents/Resources/AppIcon.icns" \
		--icon "SFM.app" 0 0 \
		--hide-extension "SFM.app" \
		--app-drop-link 0 0 \
		--skip-jenkins \
		"build/SFM-Apple.dmg" "build/SFM.System-arm64/SFM.app"

build_macos_dmg_intel: archive_macos_standalone_intel export_macos_standalone_intel
	rm -f build/SFM-Intel.dmg
	create-dmg \
		--volname "sing-box" \
		--volicon "build/SFM.System-x86_64/SFM.app/Contents/Resources/AppIcon.icns" \
		--icon "SFM.app" 0 0 \
		--hide-extension "SFM.app" \
		--app-drop-link 0 0 \
		--skip-jenkins \
		"build/SFM-Intel.dmg" "build/SFM.System-x86_64/SFM.app"

build_macos_dmg_universal: archive_macos_standalone_universal export_macos_standalone_universal
	rm -f build/SFM-Universal.dmg
	create-dmg \
		--volname "sing-box" \
		--volicon "build/SFM.System-universal/SFM.app/Contents/Resources/AppIcon.icns" \
		--icon "SFM.app" 0 0 \
		--hide-extension "SFM.app" \
		--app-drop-link 0 0 \
		--skip-jenkins \
		"build/SFM-Universal.dmg" "build/SFM.System-universal/SFM.app"

build_macos_dmg: build_macos_dmg_apple build_macos_dmg_intel build_macos_dmg_universal

# DMG notarize commands
notarize_macos_dmg_apple:
	xcrun notarytool submit "build/SFM-Apple.dmg" --wait --keychain-profile "notarytool-password"
	xcrun stapler staple "build/SFM-Apple.dmg"

notarize_macos_dmg_intel:
	xcrun notarytool submit "build/SFM-Intel.dmg" --wait --keychain-profile "notarytool-password"
	xcrun stapler staple "build/SFM-Intel.dmg"

notarize_macos_dmg_universal:
	xcrun notarytool submit "build/SFM-Universal.dmg" --wait --keychain-profile "notarytool-password"
	xcrun stapler staple "build/SFM-Universal.dmg"

notarize_macos_dmg: notarize_macos_dmg_apple notarize_macos_dmg_intel notarize_macos_dmg_universal

# DMG release commands
release_macos_dmg_apple: build_macos_dmg_apple notarize_macos_dmg_apple
release_macos_dmg_intel: build_macos_dmg_intel notarize_macos_dmg_intel
release_macos_dmg_universal: build_macos_dmg_universal notarize_macos_dmg_universal
release_macos_dmg: release_macos_dmg_apple release_macos_dmg_intel release_macos_dmg_universal

# PKG commands
build_macos_pkg_apple: archive_macos_standalone_apple export_macos_standalone_apple $(SFM_SYSTEM_DISTRIBUTION_ARM64)
	rm -f build/SFM-Apple.pkg
	rm -rf build/pkgroot-arm64
	mkdir -p build/pkgroot-arm64
	ditto "build/SFM.System-arm64/SFM.app" "build/pkgroot-arm64/SFM.app"
	pkgbuild --root "build/pkgroot-arm64" \
		--component-plist SFM.System/component.plist \
		--identifier $(BASE_PACKAGE_IDENTIFIER).standalone \
		--install-location /Applications \
		--min-os-version 13.0 \
		--compression latest \
		build/component-arm64.pkg
	productbuild --distribution $(SFM_SYSTEM_DISTRIBUTION_ARM64) \
		--package-path build \
		--resources SFM.System/Resources \
		--sign "$(INSTALLER_SIGN_IDENTITY)" \
		build/SFM-Apple.pkg
	rm -rf build/pkgroot-arm64
	rm -f build/component-arm64.pkg

build_macos_pkg_intel: archive_macos_standalone_intel export_macos_standalone_intel $(SFM_SYSTEM_DISTRIBUTION_X86_64)
	rm -f build/SFM-Intel.pkg
	rm -rf build/pkgroot-x86_64
	mkdir -p build/pkgroot-x86_64
	ditto "build/SFM.System-x86_64/SFM.app" "build/pkgroot-x86_64/SFM.app"
	pkgbuild --root "build/pkgroot-x86_64" \
		--component-plist SFM.System/component.plist \
		--identifier $(BASE_PACKAGE_IDENTIFIER).standalone \
		--install-location /Applications \
		--min-os-version 13.0 \
		--compression latest \
		build/component-x86_64.pkg
	productbuild --distribution $(SFM_SYSTEM_DISTRIBUTION_X86_64) \
		--package-path build \
		--resources SFM.System/Resources \
		--sign "$(INSTALLER_SIGN_IDENTITY)" \
		build/SFM-Intel.pkg
	rm -rf build/pkgroot-x86_64
	rm -f build/component-x86_64.pkg

build_macos_pkg_universal: archive_macos_standalone_universal export_macos_standalone_universal $(SFM_SYSTEM_DISTRIBUTION_UNIVERSAL)
	rm -f build/SFM-Universal.pkg
	rm -rf build/pkgroot-universal
	mkdir -p build/pkgroot-universal
	ditto "build/SFM.System-universal/SFM.app" "build/pkgroot-universal/SFM.app"
	pkgbuild --root "build/pkgroot-universal" \
		--component-plist SFM.System/component.plist \
		--identifier $(BASE_PACKAGE_IDENTIFIER).standalone \
		--install-location /Applications \
		--min-os-version 13.0 \
		--compression latest \
		build/component-universal.pkg
	productbuild --distribution $(SFM_SYSTEM_DISTRIBUTION_UNIVERSAL) \
		--package-path build \
		--resources SFM.System/Resources \
		--sign "$(INSTALLER_SIGN_IDENTITY)" \
		build/SFM-Universal.pkg
	rm -rf build/pkgroot-universal
	rm -f build/component-universal.pkg

build_macos_pkg: build_macos_pkg_apple build_macos_pkg_intel build_macos_pkg_universal

# PKG notarize commands
notarize_macos_pkg_apple:
	xcrun notarytool submit build/SFM-Apple.pkg --wait --keychain-profile "notarytool-password"
	xcrun stapler staple build/SFM-Apple.pkg

notarize_macos_pkg_intel:
	xcrun notarytool submit build/SFM-Intel.pkg --wait --keychain-profile "notarytool-password"
	xcrun stapler staple build/SFM-Intel.pkg

notarize_macos_pkg_universal:
	xcrun notarytool submit build/SFM-Universal.pkg --wait --keychain-profile "notarytool-password"
	xcrun stapler staple build/SFM-Universal.pkg

notarize_macos_pkg: notarize_macos_pkg_apple notarize_macos_pkg_intel notarize_macos_pkg_universal

# PKG release commands
release_macos_pkg_apple: build_macos_pkg_apple notarize_macos_pkg_apple
release_macos_pkg_intel: build_macos_pkg_intel notarize_macos_pkg_intel
release_macos_pkg_universal: build_macos_pkg_universal notarize_macos_pkg_universal
release_macos_pkg: release_macos_pkg_apple release_macos_pkg_intel release_macos_pkg_universal

fmt:
	swiftformat .

fmt_install:
	brew install swiftformat

lint:
	swiftlint

lint_install:
	brew install swiftlint

dmg_install:
	brew install create-dmg

clean:
	rm -rf build/SFI.xcarchive
	rm -rf build/SFM.xcarchive
	rm -rf build/SFT.xcarchive
	rm -rf build/SFM.System-arm64.xcarchive
	rm -rf build/SFM.System-x86_64.xcarchive
	rm -rf build/SFM.System-universal.xcarchive
	rm -rf build/SFM.System-arm64
	rm -rf build/SFM.System-x86_64
	rm -rf build/SFM.System-universal
	rm -rf build/SFM.System-arm64.dd
	rm -rf build/SFM.System-x86_64.dd
	rm -rf build/SFM.System-universal.dd
	rm -f build/SFM-Apple.dmg build/SFM-Intel.dmg build/SFM-Universal.dmg
	rm -f build/SFM-Apple.pkg build/SFM-Intel.pkg build/SFM-Universal.pkg
$(OVERLAY_HELPER_PLIST): HelperService/LaunchDaemons/HelperService.plist.in $(OVERLAY_CONFIG) $(OVERLAY_SETTING)
	mkdir -p HelperService/LaunchDaemons
	sed \
		-e 's|__BASE_PACKAGE_IDENTIFIER__|$(BASE_PACKAGE_IDENTIFIER)|g' \
		-e 's|__DEVELOPMENT_TEAM__|$(DEVELOPMENT_TEAM)|g' \
		"$<" > "$@"

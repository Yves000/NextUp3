include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = NUPrefs

# Same arm64e class_ro signing constraint as the tweak (see the parent Makefile);
# unset here it takes Settings down when the pane loads. Inherited through the
# aggregate build, probed again so a standalone build in this directory is safe.
NU_PTRAUTH_CFLAGS ?= $(shell $(TARGET_CC) -x objective-c -fsyntax-only -fno-ptrauth-objc-class-ro /dev/null >/dev/null 2>&1 && echo -fno-ptrauth-objc-class-ro)

# NUPrefs.m is shared with the tweak: it provides NUPrefsPublishState, so a toggle
# publishes the notify-state token from Settings' own process. -I.. resolves its
# header in the repo root.
NUPrefs_FILES = NUPrefsRootListController.m NUPrefsHeaderView.m NUPrefsCells.m ../NUPrefs.m
NUPrefs_INSTALL_PATH = /Library/PreferenceBundles
NUPrefs_FRAMEWORKS = UIKit
NUPrefs_PRIVATE_FRAMEWORKS = Preferences
NUPrefs_CFLAGS = -fobjc-arc -I.. $(NU_PTRAUTH_CFLAGS)
# -framework Preferences needs a stub to link against, and the current Xcode SDK
# (TARGET `latest`) ships no private stubs — so point the linker at a theos SDK
# carrying Preferences.tbd. Any iOS 1x SDK works: the tbd covers arm64/arm64e and
# the PSListController ABI is stable across the deployed range. Defaults to the
# newest installed one; override NUPREFS_PRIVATE_SDK to pin a specific SDK.
NUPREFS_PRIVATE_SDK ?= $(lastword $(sort $(wildcard $(THEOS)/sdks/iPhoneOS1[0-9]*.sdk)))
ifeq ($(NUPREFS_PRIVATE_SDK),)
$(error No iPhoneOS 1x SDK found in $(THEOS)/sdks — install one (github.com/theos/sdks) or set NUPREFS_PRIVATE_SDK)
endif
NUPrefs_LDFLAGS = -F$(NUPREFS_PRIVATE_SDK)/System/Library/PrivateFrameworks

include $(THEOS_MAKE_PATH)/bundle.mk

# The header prints the bundle's CFBundleVersion, so control is its single source.
# The deb rules export THEOS_PACKAGE_BASE_VERSION; a bare `make` reads control directly.
NUPREFS_VERSION := $(or $(THEOS_PACKAGE_BASE_VERSION),$(shell grep -i "^Version:" ../control | cut -d' ' -f2-))

# PreferenceLoader looks for entry plists under Library/PreferenceLoader/Preferences.
# The package scheme relocates this staging path, so nothing here is variant-specific.
internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp Resources/entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/NUPrefs.plist$(ECHO_END)
# The custom SF Symbol catalog (the GitHub mark on the Source Code row) compiles straight into
# the pane's own bundle, so -imageNamed:inBundle:withConfiguration: finds it there. It has to be
# a symbol and not a PNG: Preferences rasterises an image row icon at a size of its own choosing,
# where a symbol is drawn by UIKit at the row's own metric. actool insists on
# --output-partial-info-plist; the file is discarded, and must NOT be aimed at the bundle's real
# Info.plist, which theos has already staged.
	$(ECHO_NOTHING)xcrun actool NUSymbols.xcassets \
		--compile $(THEOS_STAGING_DIR)/Library/PreferenceBundles/NUPrefs.bundle \
		--platform iphoneos --minimum-deployment-target 14.2 \
		--target-device iphone --target-device ipad \
		--output-partial-info-plist $(THEOS_OBJ_DIR)/actool-partial.plist >/dev/null$(ECHO_END)
	$(ECHO_NOTHING)plutil -replace CFBundleVersion -string "$(NUPREFS_VERSION)" \
		$(THEOS_STAGING_DIR)/Library/PreferenceBundles/NUPrefs.bundle/Info.plist$(ECHO_END)

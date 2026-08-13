# The three variants differ only in deployment target and package scheme; hooks
# are gated at runtime (NUIOSMajor()), so the sources are identical in all three.
ifeq ($(ROOTFUL),1)
# Classic jailbreak (libhooker). No package scheme — Theos then emits iphoneos-arm.
export TARGET := iphone:clang:latest:14.2
export ARCHS  := arm64 arm64e
else ifeq ($(ROOTLESS),1)
# palera1n / Dopamine Procursus bootstrap, ElleKit.
export TARGET := iphone:clang:latest:15.0
export ARCHS  := arm64 arm64e
export THEOS_PACKAGE_SCHEME := rootless
else
export TARGET := iphone:clang:latest:15.0
export ARCHS  := arm64 arm64e
export THEOS_PACKAGE_SCHEME := roothide
endif

INSTALL_TARGET_PROCESSES = MediaRemoteUI Music Podcasts SpringBoard YouTubeMusic YouTube Spotify

include $(THEOS)/makefiles/common.mk

# arm64e: clang 17 signs the class_ro pointer of every Objective-C class, and
# only libobjc from iOS 17 on authenticates that slot. Older runtimes dereference
# the signed pointer as-is, so the injected process dies in readClass() while dyld
# maps the tweak. Probed rather than hardcoded — clangs that reject the flag do
# not emit the signing either.
NU_PTRAUTH_CFLAGS := $(shell $(TARGET_CC) -x objective-c -fsyntax-only -fno-ptrauth-objc-class-ro /dev/null >/dev/null 2>&1 && echo -fno-ptrauth-objc-class-ro)
export NU_PTRAUTH_CFLAGS

TWEAK_NAME = NextUp3
NextUp3_FILES = \
	hooks/NUHooksMusicProvider.x \
	hooks/NUHooksPodcastProvider.x \
	hooks/NUHooksYouTubeMusicProvider.x \
	hooks/NUHooksYouTubeProvider.x \
	hooks/NUHooksSpotifyProvider.x \
	hooks/NUHooksNowPlaying.x \
	hooks/NUHooksControlCenterLegacy.x \
	hooks/NUHooksControlCenter18.x \
	hooks/NUHooksControlCenter26.x \
	hooks/NUHooksDynamicIsland17.x \
	hooks/NUHooksDynamicIsland16.x \
	hooks/NUHooksSpringBoard.x \
	hooks/NUHooksLockScreen15.x \
	hooks/NUHooksLockScreen14.x \
	hooks/NUHooksLockScreen18.x \
	hooks/NUHooksTCC.x \
	NUHooksShared.m NULogFile.m NUProviderBase.m NUMusicProvider.m NUPodcastProvider.m NUYouTubeMusicProvider.m NUYouTubeProvider.m NUSpotifyProvider.m NUNextUpManager.m NUNextUpRowView.m NUPrefs.m
# LIGHTMESSAGING_TIMEOUT (ms) bounds the sync mach round-trip in
# LMConnectionSendTwoWay. Without it the display's main-thread query blocks
# forever against a suspended app, whose runloop never services the port, and
# SpringBoard hangs until the watchdog resprings.
NextUp3_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Ivendor/LightMessaging -DLIGHTMESSAGING_USE_ROCKETBOOTSTRAP=0 -DLIGHTMESSAGING_TIMEOUT=250 $(NU_PTRAUTH_CFLAGS)
NextUp3_FRAMEWORKS = UIKit CoreGraphics QuartzCore ImageIO

include $(THEOS_MAKE_PATH)/tweak.mk

# Settings pane; inherits TARGET and the package scheme from the variant block.
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

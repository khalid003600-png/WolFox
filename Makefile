ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = WolFox
WolFox_FILES = \
	Tweak/Entry.mm \
	Tweak/Runtime/Hooking.mm \
	Tweak/Runtime/Availability.mm \
	Tweak/Runtime/AvailabilityRuntime.mm \
	Tweak/Runtime/Preferences.mm \
	Tweak/Runtime/Localization.mm \
	Tweak/UI/Assets.mm \
	Tweak/UI/Notice.mm \
	Tweak/UI/OverlayButtonHost.mm \
	Tweak/UI/OverlayButtonLayout.mm \
	Tweak/Features/Ads/AdsHooks.mm \
	Tweak/Features/Ads/PromoHooks.mm \
	Tweak/Features/SponsorBlock/SponsorClient.mm \
	Tweak/Features/SponsorBlock/SponsorPreferences.mm \
	Tweak/Features/SponsorBlock/SponsorHooks.mm \
	Tweak/Features/SponsorBlock/DeArrow.mm \
	Tweak/Features/SponsorBlock/SponsorMenu.mm \
	Tweak/Features/Downloads/StreamResolver.mm \
	Tweak/Features/Downloads/SABRDownloader.mm \
	Tweak/Features/Downloads/DirectDownloader.mm \
	Tweak/Features/Downloads/FFmpegMuxer.mm \
	Tweak/Features/Downloads/WolFoxBackupManager.mm \
	Tweak/Features/Downloads/WolFoxMediaImporter.mm \
	Tweak/Features/Downloads/MediaArtwork.mm \
	Tweak/Features/Downloads/DownloadLog.mm \
	Tweak/Features/Downloads/DownloadProgressView.mm \
	Tweak/Features/Downloads/DownloadCoordinator.mm \
	Tweak/Features/Downloads/DownloadSponsor.mm \
	Tweak/Features/Downloads/DownloadHooks.mm \
	Tweak/Features/Downloads/PlaylistDownloader.mm \
	Tweak/Features/Downloads/WolFoxDownloadPlayerController.mm \
	Tweak/Features/Downloads/WolFoxAudioPlayerController.mm \
	Tweak/Features/Downloads/GlobalDownloadMiniPlayer.mm \
	Tweak/Features/Appearance/OLEDHooks.mm \
	Tweak/Features/Appearance/StartupHooks.mm \
	Tweak/Features/Appearance/PremiumLogoHooks.mm \
	Tweak/Features/Queue/QueueHooks.mm \
	Tweak/Features/Playback/BackgroundPlaybackHooks.mm \
	Tweak/Features/Playback/PiPControls.mm \
	Tweak/Features/Playback/PlaybackFixHooks.mm \
	Tweak/Features/Playback/PlaybackHeartbeat.mm \
	Tweak/Features/Playback/ChallengeSolver.mm \
	Tweak/Features/Playback/SpeedControls.mm \
	Tweak/Features/Playback/LoopControls.mm \
	Tweak/Features/Playback/QualityButton.mm \
	Tweak/Features/Playback/FullscreenControls.mm \
	Tweak/Features/Playback/NotchSafeVideo.mm \
	Tweak/Features/Playback/PreviousNextSeek.mm \
	Tweak/Features/Playback/AutoplayControls.mm \
	Tweak/Features/Playback/CaptionControls.mm \
	Tweak/Features/Playback/TranscriptExport.mm \
	Tweak/Features/Playback/SleepTimerControls.mm \
	Tweak/Features/Playback/DoubleTapHooks.mm \
	Tweak/Features/Playback/VideoZoom.mm \
	Tweak/Features/Playback/ProgressBarStyle.mm \
	Tweak/Features/Streaming/StreamingHooks.mm \
	Tweak/Features/Streaming/TVClient.mm \
	Tweak/Features/Streaming/HLSPlayback.mm \
	Tweak/Features/Interface/HomeTabs.mm \
	Tweak/UI/ExtraDim.mm \
	Tweak/Features/Playback/RemoteSkip.mm \
	Tweak/Features/Shorts/ShortsHooks.mm \
	Tweak/Features/Shorts/ShortsFeedFilter.mm \
	Tweak/Features/Shorts/ShortsSessionLimit.mm \
	Tweak/Features/Shorts/ShortsStartup.mm \
	Tweak/Features/Shorts/ShortsPinch.mm \
	Tweak/Features/Shorts/ShortsPiP.mm \
	Tweak/Features/Compatibility/SideloadCompatibility.mm \
	Tweak/Features/Compatibility/CastCompatibility.mm \
	Tweak/Features/Onboarding/FirstLaunch.mm \
	Tweak/Features/Navigation/TabBarHooks.mm \
	Tweak/Features/Navigation/DuoTabBar.mm \
	Vendor/DuoKit/DuoKit.m \
	Vendor/DuoKit/DuoMirroredTabBar.m \
	Vendor/DuoKit/DuoDeskPosture.m \
	Tweak/Features/Playback/DuoDeskPlayer.mm \
	Tweak/Features/Playback/DuoStatusBar.mm \
	Tweak/Features/Navigation/GlassChrome.mm \
	Tweak/Features/Navigation/GlassSheets.mm \
	Tweak/Features/Playback/PlayerGlass.mm \
	Tweak/Features/Navigation/NavigationBehaviorHooks.mm \
	Tweak/Features/Gestures/PlayerGestures.mm \
	Tweak/Features/Interface/OverlayVisibilityHooks.mm \
	Tweak/Features/Interface/ContentVisibilityHooks.mm \
	Tweak/Features/Interface/ActionBarModel.mm \
	Tweak/Features/Interface/AiSList.mm \
	Tweak/Features/Interface/AiSListReport.mm \
	Tweak/Features/Interface/LinkCleaning.mm \
	Tweak/Features/Interface/HapticHooks.mm \
	Tweak/Features/Interface/MiscellaneousHooks.mm \
	Tweak/Features/Interface/CopyCommentHooks.mm \
	Tweak/Features/Interface/ProfilePictureViewer.mm \
	Tweak/Features/Interface/PostImageSaver.mm \
	Tweak/Features/Interface/NativeShareHooks.mm \
	Tweak/Features/Interface/ReturnDislike.mm \
	Tweak/Features/Interface/NavigationVisibility.mm \
	Tweak/Settings/SettingsEntry.mm \
	Tweak/Settings/NativeSettingsEntry.mm \
	Tweak/Settings/WolFoxRootOptionsController.mm \
	Tweak/Settings/WolFoxSettingsPages.mm \
	Tweak/Settings/WolFoxSettingsSearch.mm \
	Tweak/Settings/WolFoxTabEditorController.mm \
	Tweak/Settings/WolFoxActionBarLayoutView.mm \
	Tweak/Settings/WolFoxButtonLayoutView.mm \
	Tweak/Settings/WolFoxDownloadsController.mm

WolFox_CFLAGS = -fobjc-arc -Wall -Wextra -Werror=return-type
WolFox_CFLAGS += -DWOLFOX_COMBINED_SABR=1
WolFox_CFLAGS += -DWOLFOX_VERSION_STRING=\"$(shell awk '/^Version:/ {print $$2}' $(THEOS_PROJECT_DIR)/control)\"
WolFox_CFLAGS += -Wno-module-import-in-extern-c
WolFox_CFLAGS += -I$(THEOS_PROJECT_DIR)/Vendor/FFmpeg/include
WolFox_CFLAGS += -I$(THEOS_PROJECT_DIR)/Vendor/DuoKit
WolFox_CCFLAGS = -std=c++17
WolFox_FRAMEWORKS = Foundation UIKit JavaScriptCore AVFoundation AVKit AudioToolbox Photos QuartzCore MediaPlayer Security SystemConfiguration UniformTypeIdentifiers VideoToolbox CoreMedia CoreGraphics CoreVideo ImageIO
WolFox_LIBRARIES = z icucore
WolFox_LDFLAGS = -Wl,-install_name,@rpath/WolFox.dylib
WolFox_LDFLAGS += $(THEOS_PROJECT_DIR)/Vendor/FFmpeg/lib/libavformat.a
WolFox_LDFLAGS += $(THEOS_PROJECT_DIR)/Vendor/FFmpeg/lib/libavcodec.a
WolFox_LDFLAGS += $(THEOS_PROJECT_DIR)/Vendor/FFmpeg/lib/libavutil.a
WolFox_LDFLAGS += $(THEOS_PROJECT_DIR)/Vendor/FFmpeg/lib/libswscale.a
WolFox_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/library.mk

after-all::
	@mkdir -p "$(THEOS_PROJECT_DIR)/dist"
	@cp "$(THEOS_OBJ_DIR)/WolFox.dylib" "$(THEOS_PROJECT_DIR)/dist/WolFox.dylib"

after-stage::
	@mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries" "$(THEOS_STAGING_DIR)/Library/Application Support"
	@rm -rf "$(THEOS_STAGING_DIR)/Library/Application Support/YTKACE.bundle"
	@rm -f "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/YTKACE.dylib" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/YTKACE.plist"
	@cp -R "$(THEOS_PROJECT_DIR)/Resources/WolFox.bundle" "$(THEOS_STAGING_DIR)/Library/Application Support/WolFox.bundle"
	@cp "$(THEOS_PROJECT_DIR)/WolFox.plist" "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/WolFox.plist"

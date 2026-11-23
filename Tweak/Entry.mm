#import "WolFox.h"
#import "Features/Downloads/SABRDownloader.h"
#import "Features/Downloads/DownloadLog.h"
#import "Features/SponsorBlock/DeArrow.h"
#import "Runtime/Preferences.h"

#import <UIKit/UIKit.h>

#ifndef WOLFOX_COMBINED_SABR
#define WOLFOX_COMBINED_SABR 0
#endif

NSString * const WolFoxVersion = @WOLFOX_VERSION_STRING;

static void WolFoxInstallModules(void) {
    WolFoxInstallSideloadCompatibilityHooks();
    WolFoxInstallCastCompatibilityHooks();
    WolFoxInstallAdsHooks();
    WolFoxInstallPromoHooks();
    WolFoxInstallSponsorBlockHooks();
    WolFoxInstallDeArrow();
    WolFoxInstallOLEDHooks();
    WolFoxInstallStartupHooks();
    WolFoxInstallPremiumLogoHooks();
    WolFoxInstallBackgroundPlaybackHooks();
    WolFoxInstallSpeedHooks();
    WolFoxInstallLoopHooks();
    WolFoxInstallQualityButtonHooks();
    WolFoxInstallFullscreenHooks();
    WolFoxInstallPreviousNextSeekHooks();
    WolFoxInstallSponsorMenu();
    WolFoxInstallLinkCleaningHooks();
    WolFoxInstallHapticHooks();
    WolFoxInstallAutoplayHooks();
    WolFoxInstallCaptionHooks();
    WolFoxInstallTranscriptHooks();
    WolFoxInstallSleepTimerHooks();
    WolFoxInstallPiPHooks();
    WolFoxInstallPlaybackFixHooks();
    WolFoxInstallDownloadHooks();
    WolFoxSABRRestoreSeed();
    WolFoxRestorePlayerRequest();
    WolFoxInstallPlaylistDownloaderHooks();
    WolFoxInstallFeedDownloadHooks();
    WolFoxInstallQueueHooks();
    WolFoxInstallGlobalDownloadMiniPlayer();
    WolFoxInstallDoubleTapHooks();
    WolFoxInstallVideoZoomHooks();
    WolFoxInstallShortsLimitHooks();
    WolFoxInstallShortsStartupHooks();
    WolFoxInstallShortsPinchHooks();
    WolFoxInstallShortsPiPHooks();
    WolFoxInstallProgressBarHooks();
    WolFoxInstallStreamingHooks();
    WolFoxInstallHLSPlaybackHooks();
    WolFoxInstallShortsHooks();
    WolFoxInstallShortsFeedFilterHooks();
    WolFoxInstallTabBarHooks();
    WolFoxInstallDuoTabBarHooks();
    WolFoxInstallDuoDeskPlayerHooks();
    WolFoxInstallDuoStatusBarHooks();
    WolFoxInstallNavigationBehaviorHooks();
    WolFoxInstallPlayerGestureHooks();
    WolFoxInstallOverlayVisibilityHooks();
    WolFoxInstallContentVisibilityHooks();
    WolFoxInstallNavigationVisibilityHooks();
    WolFoxInstallMiscellaneousHooks();
    WolFoxInstallCopyCommentHooks();
    WolFoxInstallProfilePictureHooks();
    WolFoxInstallPostImageSaverHooks();
    WolFoxInstallNativeShareHooks();
    WolFoxInstallReturnDislikeHooks();
    WolFoxInstallSettingsEntryHooks();
    WolFoxInstallNativeSettingsHooks();
}

__attribute__((constructor))
static void WolFoxEntryPoint(void) {
    @autoreleasepool {
        WolFoxClearDownloadLog();
        WolFoxRegisterDefaults();
        WolFoxScheduleFirstLaunch();
        WolFoxInstallModules();
    }
}

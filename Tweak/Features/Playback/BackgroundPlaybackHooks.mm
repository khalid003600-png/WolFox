#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

static IMP OriginalPlayableInBackground;
static IMP OriginalMLPlayableInBackground;
static IMP OriginalBackgroundEnabled;
static IMP OriginalPlayableInPiP;

static BOOL WolFoxBackgroundBoolean(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(WolFoxBackgroundPlaybackKey)) {
        return YES;
    }

    IMP original = NULL;
    if ([NSStringFromSelector(selector) isEqualToString:@"isPlayableInBackground"]) {
        original = OriginalPlayableInBackground;
    } else if ([NSStringFromSelector(selector) isEqualToString:@"playableInBackground"]) {
        original = OriginalMLPlayableInBackground;
    } else {
        original = OriginalBackgroundEnabled;
    }
    return original == NULL
        ? NO
        : ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static BOOL WolFoxPlayableInPiP(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(WolFoxBackgroundPlaybackKey) || WolFoxFeatureEnabled(WolFoxPiPKey)) return YES;
    return OriginalPlayableInPiP != NULL &&
        ((BOOL (*)(id, SEL))OriginalPlayableInPiP)(receiver, selector);
}

void WolFoxInstallBackgroundPlaybackHooks(void) {
    WolFoxInstallInstanceHook(@"YTIPlayabilityStatus",
                              @"isPlayableInPictureInPicture",
                              (IMP)WolFoxPlayableInPiP,
                              &OriginalPlayableInPiP);
    WolFoxInstallInstanceHook(@"YTIPlayabilityStatus",
                              @"isPlayableInBackground",
                              (IMP)WolFoxBackgroundBoolean,
                              &OriginalPlayableInBackground);
    WolFoxInstallInstanceHook(@"MLVideo",
                              @"playableInBackground",
                              (IMP)WolFoxBackgroundBoolean,
                              &OriginalMLPlayableInBackground);
    if (!WolFoxInstallInstanceHook(
            @"YTIBackgroundOfflineSettingCategoryEntryRenderer",
            @"isBackgroundEnabled",
            (IMP)WolFoxBackgroundBoolean,
            &OriginalBackgroundEnabled)) {
        WolFoxAddInstanceMethod(
            @"YTIBackgroundOfflineSettingCategoryEntryRenderer",
            @"isBackgroundEnabled",
            (IMP)WolFoxBackgroundBoolean,
            "B@:"
        );
    }
}

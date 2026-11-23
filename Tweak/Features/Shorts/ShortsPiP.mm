#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/WolFoxDownloadPlayerController.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const WolFoxShortsPiPKey = @"YTKACE.Preference.Shorts.PiPDisabled";

static IMP WolFoxShortsOrigAllowed;
static IMP WolFoxShortsOrigEligible;
static IMP WolFoxShortsOrigCanEnable;
static IMP WolFoxOrigSetWatchViewLayout;

static NSString *const WolFoxMiniplayerPiPKey = @"YTKACE.Preference.Playback.MiniplayerPiPDisabled";
static __weak id WolFoxWatchLayer;

static void WolFoxSetWatchViewLayout(id self, SEL _cmd, long long layout) {
    ((void (*)(id, SEL, long long))WolFoxOrigSetWatchViewLayout)(self, _cmd, layout);
    WolFoxWatchLayer = self;
    WolFoxDebugLog(@"pip", @"watch layout=%lld", layout);
}

// The watch page is collapsed into the miniplayer.
static BOOL WolFoxMiniplayerBlocksPiP(void) {
    if (!WolFoxFeatureEnabled(WolFoxMiniplayerPiPKey)) return NO;
    id layer = WolFoxWatchLayer;
    SEL expanded = NSSelectorFromString(@"isWatchExpanded");
    if (layer == nil || ![layer respondsToSelector:expanded]) return NO;
    BOOL blocked = !((BOOL (*)(id, SEL))objc_msgSend)(layer, expanded);
    WolFoxDebugLog(@"pip", @"miniplayer block=%@", blocked ? @"YES" : @"NO");
    return blocked;
}

static id WolFoxShortsPiPOwner(id controller) {
    Ivar ivar = class_getInstanceVariable(object_getClass(controller), "_delegate");
    if (ivar == NULL) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (type == NULL || type[0] != '@') return nil;
    return object_getIvar(controller, ivar);
}

static BOOL WolFoxLibraryOwnsPiP(void) {
    WolFoxDownloadPlaybackSession *session = WolFoxDownloadPlaybackSession.existingSession;
    return session.currentURL != nil && session.player.rate != 0.0f;
}

static BOOL WolFoxShortsBlocksPiP(id controller) {
    if (WolFoxLibraryOwnsPiP()) return YES;
    if (WolFoxMiniplayerBlocksPiP()) return YES;
    if (!WolFoxFeatureEnabled(WolFoxShortsPiPKey)) return NO;
    SEL parentSel = NSSelectorFromString(@"parentResponder");
    id current = WolFoxShortsPiPOwner(controller);
    for (NSUInteger depth = 0; current != nil && depth < 10; depth++) {
        NSString *name = NSStringFromClass([current class]);
        if ([name containsString:@"Reel"] || [name containsString:@"Shorts"] ||
            WolFoxPlayerIsShorts(current)) {
            return YES;
        }
        if (![current respondsToSelector:parentSel]) break;
        current = ((id (*)(id, SEL))objc_msgSend)(current, parentSel);
    }
    return NO;
}

// YouTube says no to PiP for free accounts outside the US; with YTKACE PiP
// on, every video that isn't blocked above can use it.
static BOOL WolFoxShortsAllowed(id self, SEL _cmd) {
    if (WolFoxShortsBlocksPiP(self)) return NO;
    if (WolFoxFeatureEnabled(WolFoxPiPKey)) return YES;
    return ((BOOL (*)(id, SEL))WolFoxShortsOrigAllowed)(self, _cmd);
}

static BOOL WolFoxShortsEligible(id self, SEL _cmd) {
    if (WolFoxShortsBlocksPiP(self)) return NO;
    BOOL eligible = ((BOOL (*)(id, SEL))WolFoxShortsOrigEligible)(self, _cmd);
    if (!eligible && (WolFoxFeatureEnabled(WolFoxBackgroundPlaybackKey) || WolFoxFeatureEnabled(WolFoxPiPKey))) return YES;
    return eligible;
}

static BOOL WolFoxShortsCanEnable(id self, SEL _cmd) {
    if (WolFoxShortsBlocksPiP(self)) return NO;
    if (WolFoxFeatureEnabled(WolFoxPiPKey)) return YES;
    return ((BOOL (*)(id, SEL))WolFoxShortsOrigCanEnable)(self, _cmd);
}

void WolFoxInstallShortsPiPHooks(void) {
    NSString *pipClass = @"YTPlayerPIPController";
    WolFoxInstallInstanceHook(pipClass, @"isPictureInPictureAllowed",
        (IMP)WolFoxShortsAllowed, &WolFoxShortsOrigAllowed);
    WolFoxInstallInstanceHook(pipClass, @"isEligibleForPictureInPicture",
        (IMP)WolFoxShortsEligible, &WolFoxShortsOrigEligible);
    WolFoxInstallInstanceHook(pipClass, @"canEnablePictureInPicture",
        (IMP)WolFoxShortsCanEnable, &WolFoxShortsOrigCanEnable);
    WolFoxInstallInstanceHook(@"YTWatchLayerViewController", @"setWatchViewLayout:",
        (IMP)WolFoxSetWatchViewLayout, &WolFoxOrigSetWatchViewLayout);
}

#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const WolFoxOpenPausedKey =
    @"YTKACE.Preference.Playback.OpenPaused";
static NSString *const WolFoxAutoplayOffKey =
    @"YTKACE.Preference.Playback.AutoplayDisabled";

static IMP OriginalPlayAutoplay;
static IMP OriginalTriggerPendingAutoplay;
static IMP OriginalAdvanceToNext;
static IMP OriginalShouldAutonav;
static IMP OriginalSetWatchTransitionStartup;
static IMP OriginalInsertOrUpdateSingle;
static IMP OriginalSetSingleWatchTransition;


static NSString *WolFoxLastPausedVideo;

static NSTimeInterval WolFoxLastTouchTime;
static NSTimeInterval WolFoxUserNextTime;
static NSString *WolFoxUserNextOrigin;
static IMP OriginalSendEvent;


static int WolFoxTransitionInt(id transition, NSString *name);

static void WolFoxPauseNow(id player) {
    if (player == nil) return;
    SEL pause = NSSelectorFromString(@"pause");
    if (![player respondsToSelector:pause]) return;
    ((void (*)(id, SEL))objc_msgSend)(player, pause);
}

void WolFoxOpenPausedVideoActivated(id player) {
    WolFoxApplyPreferredCaptionLanguage(player);
    if (!WolFoxFeatureEnabled(WolFoxOpenPausedKey)) return;
    NSString *videoID = nil;
    SEL getter = NSSelectorFromString(@"currentVideoID");
    if ([player respondsToSelector:getter]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(player, getter);
        if ([value isKindOfClass:NSString.class]) videoID = value;
    }
    if (videoID.length != 0 &&
        [videoID isEqualToString:WolFoxLastPausedVideo]) {
        return;
    }
    WolFoxLastPausedVideo = [videoID copy];

    __weak id weakPlayer = player;
    WolFoxPauseNow(player);
    const double delays[] = { 0.0, 0.15, 0.4, 0.8, 1.4 };
    for (size_t index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[index] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WolFoxPauseNow(weakPlayer);
        });
    }
}

static BOOL WolFoxAutoplaySuppressed(void) {
    return WolFoxFeatureEnabled(WolFoxAutoplayOffKey);
}

static void WolFoxPlayAutoplay(id receiver, SEL selector) {
    if (WolFoxAutoplaySuppressed()) return;
    if (OriginalPlayAutoplay != NULL) {
        ((void (*)(id, SEL))OriginalPlayAutoplay)(receiver, selector);
    }
}

static void WolFoxTriggerPendingAutoplay(id receiver, SEL selector) {
    if (WolFoxAutoplaySuppressed()) return;
    if (OriginalTriggerPendingAutoplay != NULL) {
        ((void (*)(id, SEL))OriginalTriggerPendingAutoplay)(receiver, selector);
    }
}

static void WolFoxAdvanceToNext(id receiver, SEL selector, BOOL autoplay,
                                BOOL internalTransition, id unplayableVideoID) {
    if (WolFoxAutoplaySuppressed() && autoplay) return;
    if (OriginalAdvanceToNext != NULL) {
        ((void (*)(id, SEL, BOOL, BOOL, id))OriginalAdvanceToNext)(
            receiver, selector, autoplay, internalTransition, unplayableVideoID);
    }
}








static BOOL WolFoxShouldAutonav(id receiver, SEL selector) {
    if (WolFoxAutoplaySuppressed()) return NO;
    return OriginalShouldAutonav != NULL
        ? ((BOOL (*)(id, SEL))OriginalShouldAutonav)(receiver, selector) : NO;
}


static int WolFoxTransitionInt(id transition, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![transition respondsToSelector:selector]) return -999;
    return ((int (*)(id, SEL))objc_msgSend)(transition, selector);
}





static void WolFoxSendEvent(id receiver, SEL selector, UIEvent *event) {
    if (event.type == UIEventTypeTouches) {
        WolFoxLastTouchTime = CACurrentMediaTime();
    }
    if (OriginalSendEvent != NULL) {
        ((void (*)(id, SEL, id))OriginalSendEvent)(receiver, selector, event);
    }
}

static const int WolFoxAutoAdvanceSource = 6;
static const NSTimeInterval WolFoxUserNextWindow = 2.0;
static const NSTimeInterval WolFoxTouchGraceWindow = 0.6;

static void WolFoxNoteUserNextRequiringTouch(NSString *origin,
                                            BOOL requiresTouch) {
    const NSTimeInterval now = CACurrentMediaTime();
    if (requiresTouch &&
        (WolFoxLastTouchTime == 0 || now - WolFoxLastTouchTime > 1.5)) {
        return;
    }
    WolFoxUserNextTime = now;
    WolFoxUserNextOrigin = origin;
}

static void WolFoxNoteUserNext(NSString *origin) {
    WolFoxNoteUserNextRequiringTouch(origin, NO);
}

static BOOL WolFoxShouldDropTransition(id transition) {
    if (transition == nil) return NO;
    const int source = WolFoxTransitionInt(transition, @"watchEndpointSource");
    const NSTimeInterval now = CACurrentMediaTime();
    const NSTimeInterval sinceTouch =
        WolFoxLastTouchTime != 0 ? now - WolFoxLastTouchTime : -1;
    const NSTimeInterval sinceUserNext =
        WolFoxUserNextTime != 0 ? now - WolFoxUserNextTime : -1;

    const BOOL userAsked =
        (sinceUserNext >= 0 && sinceUserNext <= WolFoxUserNextWindow) ||
        (sinceTouch >= 0 && sinceTouch <= WolFoxTouchGraceWindow);
    return WolFoxAutoplaySuppressed() &&
        source == WolFoxAutoAdvanceSource && !userAsked;
}

static void WolFoxSetWatchTransitionStartup(id receiver, SEL selector,
                                            id transition, BOOL onAppStartup) {
    if (!onAppStartup &&
        WolFoxShouldDropTransition(transition)) {
        return;
    }
    if (OriginalSetWatchTransitionStartup != NULL) {
        ((void (*)(id, SEL, id, BOOL))OriginalSetWatchTransitionStartup)(
            receiver, selector, transition, onAppStartup);
    }
}

static void WolFoxInsertOrUpdateSingle(id receiver, SEL selector,
                                       id transition) {
    if (WolFoxShouldDropTransition(transition)) return;
    if (OriginalInsertOrUpdateSingle != NULL) {
        ((void (*)(id, SEL, id))OriginalInsertOrUpdateSingle)(
            receiver, selector, transition);
    }
}

static void WolFoxSetSingleWatchTransition(id receiver, SEL selector,
                                           id transition) {
    if (WolFoxShouldDropTransition(transition)) return;
    if (OriginalSetSingleWatchTransition != NULL) {
        ((void (*)(id, SEL, id))OriginalSetSingleWatchTransition)(
            receiver, selector, transition);
    }
}

static IMP OriginalUserNext[8];

static long long WolFoxUserNextRemote(id receiver, SEL selector, id command) {
    WolFoxNoteUserNext(@"remoteNextTrack");
    return OriginalUserNext[7] != NULL
        ? ((long long (*)(id, SEL, id))OriginalUserNext[7])(receiver, selector,
                                                            command)
        : 0;
}

static void WolFoxUserNextSender0(id receiver, SEL selector, id sender) {
    WolFoxNoteUserNext(@"overlayNext");
    if (OriginalUserNext[0] != NULL) {
        ((void (*)(id, SEL, id))OriginalUserNext[0])(receiver, selector, sender);
    }
}

static void WolFoxUserNextSender1(id receiver, SEL selector, id sender) {
    WolFoxNoteUserNext(@"controlsNext");
    if (OriginalUserNext[1] != NULL) {
        ((void (*)(id, SEL, id))OriginalUserNext[1])(receiver, selector, sender);
    }
}

static void WolFoxUserNextVoid5(id receiver, SEL selector) {
    WolFoxNoteUserNext(@"playerBarNext");
    if (OriginalUserNext[5] != NULL) {
        ((void (*)(id, SEL))OriginalUserNext[5])(receiver, selector);
    }
}

static void WolFoxUserNextVoid6(id receiver, SEL selector) {
    WolFoxNoteUserNext(@"lockscreenNext");
    if (OriginalUserNext[6] != NULL) {
        ((void (*)(id, SEL))OriginalUserNext[6])(receiver, selector);
    }
}

static void WolFoxUserNextVoid2(id receiver, SEL selector) {
    WolFoxNoteUserNext(@"miniplayerNext");
    if (OriginalUserNext[2] != NULL) {
        ((void (*)(id, SEL))OriginalUserNext[2])(receiver, selector);
    }
}

static void WolFoxUserNextPanel(id receiver, SEL selector,
                                unsigned long long index) {
    WolFoxNoteUserNextRequiringTouch(@"panelSelect", YES);
    if (OriginalUserNext[3] != NULL) {
        ((void (*)(id, SEL, unsigned long long))OriginalUserNext[3])(
            receiver, selector, index);
    }
}

static void WolFoxUserNextEndpoint(id receiver, SEL selector, id endpoint) {
    WolFoxNoteUserNext(@"nextFromEndpoint");
    if (OriginalUserNext[4] != NULL) {
        ((void (*)(id, SEL, id))OriginalUserNext[4])(receiver, selector,
                                                     endpoint);
    }
}

void WolFoxInstallAutoplayHooks(void) {
    WolFoxInstallInstanceHook(@"YTWatchFlowController", @"playAutoplay",
                              (IMP)WolFoxPlayAutoplay, &OriginalPlayAutoplay);
    WolFoxInstallInstanceHook(@"YTQueueController", @"triggerPendingAutoplay",
                              (IMP)WolFoxTriggerPendingAutoplay,
                              &OriginalTriggerPendingAutoplay);
    WolFoxInstallInstanceHook(
        @"YTQueueController",
        @"advanceToNextWithAutoplay:isPlaybackControllerInternalTransition:"
         "unplayableVideoID:",
        (IMP)WolFoxAdvanceToNext, &OriginalAdvanceToNext);
    WolFoxInstallInstanceHook(@"YTWatchPlaybackController",
                              @"shouldAutonavToNextVideo",
                              (IMP)WolFoxShouldAutonav, &OriginalShouldAutonav);

    NSString *const layer = @"YTWatchLayerViewController";
    WolFoxInstallInstanceHook(layer, @"setWatchTransition:onAppStartup:",
                              (IMP)WolFoxSetWatchTransitionStartup,
                              &OriginalSetWatchTransitionStartup);
    WolFoxInstallInstanceHook(layer, @"insertOrUpdateSingleWatchTransition:",
                              (IMP)WolFoxInsertOrUpdateSingle,
                              &OriginalInsertOrUpdateSingle);
    WolFoxInstallInstanceHook(layer, @"setSingleWatchTransition:",
                              (IMP)WolFoxSetSingleWatchTransition,
                              &OriginalSetSingleWatchTransition);
    WolFoxInstallInstanceHook(@"UIApplication", @"sendEvent:",
                              (IMP)WolFoxSendEvent, &OriginalSendEvent);

    WolFoxInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"didPressNext:",
        (IMP)WolFoxUserNextSender0, &OriginalUserNext[0]);
    WolFoxInstallInstanceHook(
        @"YTMainAppControlsOverlayView", @"didPressNext:",
        (IMP)WolFoxUserNextSender1, &OriginalUserNext[1]);
    WolFoxInstallInstanceHook(
        @"YTWatchFloatingMiniplayerViewController", @"didTapNext",
        (IMP)WolFoxUserNextVoid2, &OriginalUserNext[2]);
    WolFoxInstallInstanceHook(
        @"YTPlaylistPanelController", @"didSelectEntryAtIndex:",
        (IMP)WolFoxUserNextPanel, &OriginalUserNext[3]);
    WolFoxInstallInstanceHook(
        @"YTWatchPreviousController",
        @"handleNextButtonWithFromNavigationEndpoint:",
        (IMP)WolFoxUserNextEndpoint, &OriginalUserNext[4]);
    WolFoxInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"didPressPlayerBarNext",
        (IMP)WolFoxUserNextVoid5, &OriginalUserNext[5]);
    WolFoxInstallInstanceHook(
        @"YTWatchController", @"didPressNextTrackLockscreenButton",
        (IMP)WolFoxUserNextVoid6, &OriginalUserNext[6]);
    WolFoxInstallInstanceHook(
        @"YTRemoteCommandHandler", @"handleNextTrackCommand:",
        (IMP)WolFoxUserNextRemote, &OriginalUserNext[7]);
}

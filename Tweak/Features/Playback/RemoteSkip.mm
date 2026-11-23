#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString *const WolFoxRemoteSkipKey = @"YTKACE.Preference.Playback.RemoteSkip";
static IMP OriginalRemoteSetEnabled;
static BOOL WolFoxRemoteTargetsAdded;

static NSInteger WolFoxRemoteSkipInterval(void) {
    if (!WolFoxMasterEnabled()) return 0;
    NSInteger value = [WolFoxPreferenceObject(WolFoxRemoteSkipKey) integerValue];
    return value > 0 ? value : 0;
}

static id WolFoxRemotePlayer(UIViewController *controller, NSUInteger depth) {
    if (controller == nil || depth > 14) return nil;
    if ([NSStringFromClass(controller.class) isEqualToString:@"YTPlayerViewController"]) {
        SEL current = NSSelectorFromString(@"currentVideoID");
        id value = [controller respondsToSelector:current]
            ? ((id (*)(id, SEL))objc_msgSend)(controller, current) : nil;
        if ([value isKindOfClass:NSString.class] && [value length] != 0) return controller;
    }
    for (UIViewController *child in controller.childViewControllers) {
        id found = WolFoxRemotePlayer(child, depth + 1);
        if (found != nil) return found;
    }
    return WolFoxRemotePlayer(controller.presentedViewController, depth + 1);
}

static MPRemoteCommandHandlerStatus WolFoxRemoteSkip(double direction) {
    NSInteger interval = WolFoxRemoteSkipInterval();
    if (interval <= 0) return MPRemoteCommandHandlerStatusCommandFailed;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            id player = WolFoxRemotePlayer(window.rootViewController, 0);
            SEL timeSel = NSSelectorFromString(@"currentVideoMediaTime");
            SEL totalSel = NSSelectorFromString(@"currentVideoTotalMediaTime");
            SEL seekSel = NSSelectorFromString(@"seekToTime:");
            if (player == nil || ![player respondsToSelector:timeSel] || ![player respondsToSelector:seekSel]) continue;
            double time = ((double (*)(id, SEL))objc_msgSend)(player, timeSel) + direction * (double)interval;
            double total = [player respondsToSelector:totalSel]
                ? ((double (*)(id, SEL))objc_msgSend)(player, totalSel) : 0.0;
            if (total > 1.0) time = MIN(time, total - 0.5);
            ((void (*)(id, SEL, double))objc_msgSend)(player, seekSel, MAX(0.0, time));
            return MPRemoteCommandHandlerStatusSuccess;
        }
    }
    return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
}

static BOOL WolFoxIsTrackCommand(id command) {
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    return command == center.nextTrackCommand || command == center.previousTrackCommand;
}

static void WolFoxRemoteSetEnabled(id receiver, SEL selector, BOOL enabled) {
    if (WolFoxRemoteSkipInterval() > 0) {
        MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
        if (WolFoxIsTrackCommand(receiver)) enabled = NO;
        else if (receiver == center.skipForwardCommand || receiver == center.skipBackwardCommand) enabled = YES;
    }
    ((void (*)(id, SEL, BOOL))OriginalRemoteSetEnabled)(receiver, selector, enabled);
}

static void WolFoxConfigureRemoteSkip(void) {
    NSInteger interval = WolFoxRemoteSkipInterval();
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    if (interval > 0 && !WolFoxRemoteTargetsAdded) {
        WolFoxRemoteTargetsAdded = YES;
        [center.skipForwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
            return WolFoxRemoteSkip(1.0);
        }];
        [center.skipBackwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
            return WolFoxRemoteSkip(-1.0);
        }];
    }
    if (!WolFoxRemoteTargetsAdded) return;
    center.skipForwardCommand.preferredIntervals = @[@(MAX(interval, 1))];
    center.skipBackwardCommand.preferredIntervals = @[@(MAX(interval, 1))];
    center.skipForwardCommand.enabled = interval > 0;
    center.skipBackwardCommand.enabled = interval > 0;
    if (interval > 0) {
        center.nextTrackCommand.enabled = NO;
        center.previousTrackCommand.enabled = NO;
    }
}

__attribute__((constructor)) static void WolFoxInstallRemoteSkip(void) {
    __block BOOL installed = NO;
    void (^install)(void) = ^{
        if (installed) {
            WolFoxConfigureRemoteSkip();
            return;
        }
        if (WolFoxRemoteSkipInterval() <= 0) return;
        installed = YES;
        WolFoxInstallInstanceHook(@"MPRemoteCommand", @"setEnabled:",
                                  (IMP)WolFoxRemoteSetEnabled, &OriginalRemoteSetEnabled);
        WolFoxConfigureRemoteSkip();
    };
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), install);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:WolFoxPreferencesDidChangeNotification object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) {
        install();
    }];
}

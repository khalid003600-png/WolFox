#import "../../WolFox.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Notice.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const WolFoxShortsLimitKey = @"YTKACE.Preference.Shorts.LimitEnabled";
static NSString * const WolFoxShortsLimitCountKey = @"YTKACE.Preference.Shorts.LimitCount";

static NSMutableOrderedSet<NSString *> *WolFoxShortsSeen;
static BOOL WolFoxShortsBlocked;
static id WolFoxShortsLimitObserver;

static NSInteger WolFoxShortsLimitValue(void) {
    NSInteger value = [NSUserDefaults.standardUserDefaults
        integerForKey:WolFoxShortsLimitCountKey];
    if (value < 1) value = 20;
    return MIN(value, 500);
}

BOOL WolFoxShortsLimitReached(void) {
    return WolFoxShortsBlocked;
}

static UIViewController *WolFoxReelRootController(UIViewController *controller,
                                                  NSUInteger depth) {
    if (controller == nil || depth > 6) return nil;
    SEL active = NSSelectorFromString(@"activeReelPlaybackVideoID");
    if ([controller respondsToSelector:active]) return controller;
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = WolFoxReelRootController(child, depth + 1);
        if (found != nil) return found;
    }
    return WolFoxReelRootController(controller.presentedViewController, depth + 1);
}

static UIViewController *WolFoxActiveReelController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isHidden) continue;
            UIViewController *found = WolFoxReelRootController(window.rootViewController, 0);
            if (found != nil) return found;
        }
    }
    return nil;
}

static UIScrollView *WolFoxReelPager(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 8) return nil;
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UIScrollView.class]) {
            UIScrollView *candidate = (UIScrollView *)child;
            if (CGRectGetHeight(candidate.bounds) > 200.0 &&
                candidate.contentSize.height > CGRectGetHeight(candidate.bounds)) {
                return candidate;
            }
        }
        UIScrollView *found = WolFoxReelPager(child, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static void WolFoxApplyShortsBlock(UIViewController *reel) {
    UIScrollView *pager = WolFoxReelPager(reel.view, 0);
    if (pager == nil) return;
    if (!pager.scrollEnabled) return;
    pager.scrollEnabled = NO;
}

static void WolFoxNoteShort(NSString *videoID, UIViewController *reel) {
    if (videoID.length == 0) return;
    if (WolFoxShortsSeen == nil) WolFoxShortsSeen = [NSMutableOrderedSet orderedSet];
    const NSUInteger before = WolFoxShortsSeen.count;
    [WolFoxShortsSeen addObject:videoID];
    if (WolFoxShortsSeen.count == before) return;

    const NSInteger limit = WolFoxShortsLimitValue();
    if ((NSInteger)WolFoxShortsSeen.count < limit) return;

    const BOOL announce = !WolFoxShortsBlocked;
    WolFoxShortsBlocked = YES;
    WolFoxApplyShortsBlock(reel);
    if (announce) {
        WolFoxShowNotice([NSString stringWithFormat:
            WolFoxLocalized(@"Shorts limit reached (%ld). Restart YouTube to reset."),
            (long)limit]);
    }
}

static void WolFoxShortsLimitTick(void) {
    if (!WolFoxFeatureEnabled(WolFoxShortsLimitKey)) return;
    static NSTimeInterval last = 0.0;
    const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - last < 0.4) return;
    last = now;

    UIViewController *reel = WolFoxActiveReelController();
    if (reel == nil) return;
    SEL active = NSSelectorFromString(@"activeReelPlaybackVideoID");
    id value = ((id (*)(id, SEL))objc_msgSend)(reel, active);
    if (![value isKindOfClass:NSString.class] || [value length] == 0) return;

    if (WolFoxShortsBlocked) {
        WolFoxApplyShortsBlock(reel);
        return;
    }
    WolFoxNoteShort(value, reel);
}

void WolFoxInstallShortsLimitHooks(void) {
    if (WolFoxShortsLimitObserver != nil) return;
    WolFoxShortsLimitObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:@"WolFoxPlaybackTimeDidChange"
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
                    WolFoxShortsLimitTick();
                }];
}

#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const WolFoxShortsPinchKey =
    @"YTKACE.Preference.Shorts.PinchFullscreen";

static IMP OriginalDidPinch;
static IMP OriginalReelWillDisappear;

static BOOL WolFoxShortsImmersive;

static id WolFoxPinchSend(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static id WolFoxAppViewController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *root = window.rootViewController;
            if ([root respondsToSelector:NSSelectorFromString(@"hidePivotBar")]) {
                return root;
            }
        }
    }
    return nil;
}

static const void *WolFoxPinchAlphaKey = &WolFoxPinchAlphaKey;

static void WolFoxFadeOverlaySubviews(UIView *overlay, BOOL hidden) {
    for (UIView *subview in overlay.subviews) {
        if (hidden) {
            if (objc_getAssociatedObject(subview, WolFoxPinchAlphaKey) == nil) {
                objc_setAssociatedObject(subview, WolFoxPinchAlphaKey,
                                         @(subview.alpha),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            subview.alpha = 0.0;
        } else {
            NSNumber *saved = objc_getAssociatedObject(subview,
                                                       WolFoxPinchAlphaKey);
            if (saved != nil) {
                subview.alpha = saved.doubleValue;
                objc_setAssociatedObject(subview, WolFoxPinchAlphaKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

static void WolFoxSettleOverlay(UIView *overlay) {
    if (overlay == nil) return;
    __weak UIView *weakOverlay = overlay;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strong = weakOverlay;
        if (strong == nil) return;
        [strong setNeedsLayout];
        [strong layoutIfNeeded];
        for (UIView *subview in strong.subviews) {
            [subview setNeedsLayout];
            [subview layoutIfNeeded];
        }
    });
}

static UIView *WolFoxReelOverlay(UIViewController *shorts) {
    id content = WolFoxPinchSend(shorts, @"contentView") ?: shorts.view;
    id overlay = WolFoxPinchSend(content, @"playbackOverlay");
    return [overlay isKindOfClass:UIView.class] ? overlay : nil;
}

static void WolFoxSetShortsImmersive(BOOL immersive, UIViewController *shorts) {
    if (immersive == WolFoxShortsImmersive) return;
    WolFoxShortsImmersive = immersive;

    id app = WolFoxAppViewController();
    SEL toggle = NSSelectorFromString(immersive ? @"hidePivotBar" : @"showPivotBar");
    if ([app respondsToSelector:toggle]) {
        ((void (*)(id, SEL))objc_msgSend)(app, toggle);
    }
    UIView *overlay = WolFoxReelOverlay(shorts);
    if (overlay == nil) return;
    [UIView animateWithDuration:0.2 animations:^{
        WolFoxFadeOverlaySubviews(overlay, immersive);
    } completion:^(BOOL finished) {
        (void)finished;
        if (!immersive) WolFoxSettleOverlay(overlay);
    }];
}

static UIViewController *WolFoxShortsControllerForPlayerView(id playerView) {
    id delegate = WolFoxPinchSend(playerView, @"playerViewDelegate");
    id parent = WolFoxPinchSend(delegate, @"parentViewController");
    if (![parent isKindOfClass:UIViewController.class]) return nil;
    Class shortsClass = NSClassFromString(@"YTShortsPlayerViewController");
    Class reelClass = NSClassFromString(@"YTReelPlayerViewController");
    if ((shortsClass != Nil && [parent isKindOfClass:shortsClass]) ||
        (reelClass != Nil && [parent isKindOfClass:reelClass])) {
        return parent;
    }
    return nil;
}

static void WolFoxDidPinch(id receiver, SEL selector, id recognizer) {
    if (OriginalDidPinch != NULL) {
        ((void (*)(id, SEL, id))OriginalDidPinch)(receiver, selector, recognizer);
    }
    if (!WolFoxFeatureEnabled(WolFoxShortsPinchKey)) return;
    if (![recognizer isKindOfClass:UIPinchGestureRecognizer.class]) return;

    UIPinchGestureRecognizer *pinch = recognizer;
    if (pinch.state != UIGestureRecognizerStateChanged &&
        pinch.state != UIGestureRecognizerStateEnded) {
        return;
    }
    UIViewController *shorts = WolFoxShortsControllerForPlayerView(receiver);
    if (shorts == nil) return;

    if (pinch.scale > 1.05) {
        WolFoxSetShortsImmersive(YES, shorts);
    } else if (pinch.scale < 0.95) {
        WolFoxSetShortsImmersive(NO, shorts);
    }
}

static void WolFoxReelWillDisappear(id receiver, SEL selector, BOOL animated) {
    if (WolFoxShortsImmersive) {
        WolFoxShortsImmersive = NO;
        id app = WolFoxAppViewController();
        SEL show = NSSelectorFromString(@"showPivotBar");
        if ([app respondsToSelector:show]) {
            ((void (*)(id, SEL))objc_msgSend)(app, show);
        }
        UIView *overlay = WolFoxReelOverlay(receiver);
        if (overlay != nil) {
            WolFoxFadeOverlaySubviews(overlay, NO);
            WolFoxSettleOverlay(overlay);
        }
    }
    if (OriginalReelWillDisappear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalReelWillDisappear)(
            receiver, selector, animated);
    }
}

static IMP OriginalShowPivotBar;

static void WolFoxShowPivotBar(id receiver, SEL selector) {
    if (WolFoxShortsPivotShowBlocked()) {
        UIWindow *window = [receiver respondsToSelector:@selector(view)] ? [(UIViewController *)receiver view].window : nil;
        if (WolFoxShortsContainerForView(window, window) != nil) {
            return;
        }
        WolFoxSetShortsNewFullscreen(nil, NO);
        return;
    }
    if (OriginalShowPivotBar != NULL) ((void (*)(id, SEL))OriginalShowPivotBar)(receiver, selector);
}

static IMP OriginalReelRootWillDisappear;

static void WolFoxReelRootWillDisappear(id receiver, SEL selector, BOOL animated) {
    if (WolFoxShortsNewFullscreenActive()) {
        WolFoxSetShortsNewFullscreen(nil, NO);
    }
    if (OriginalReelRootWillDisappear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalReelRootWillDisappear)(receiver, selector, animated);
    }
}

void WolFoxInstallShortsPinchHooks(void) {
    WolFoxInstallInstanceHook(@"YTAppViewController", @"showPivotBar",
                              (IMP)WolFoxShowPivotBar, &OriginalShowPivotBar);
    WolFoxInstallInstanceHook(@"YTReelWatchRootViewController", @"viewWillDisappear:",
                              (IMP)WolFoxReelRootWillDisappear, &OriginalReelRootWillDisappear);
    WolFoxInstallInstanceHook(@"YTPlayerView", @"didPinch:",
                              (IMP)WolFoxDidPinch, &OriginalDidPinch);
    WolFoxInstallInstanceHook(@"YTReelPlayerViewController",
                              @"viewWillDisappear:",
                              (IMP)WolFoxReelWillDisappear,
                              &OriginalReelWillDisappear);
}

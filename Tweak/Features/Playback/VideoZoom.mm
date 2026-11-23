#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static IMP WolFoxZoomOrigBegin;
static IMP WolFoxZoomOrigZoom;
static IMP WolFoxZoomOrigEnd;
static IMP WolFoxZoomOrigMaxState;
static IMP WolFoxZoomOrigLayout;
static BOOL WolFoxZoomReleasing;
static BOOL WolFoxZoomResyncPending;
static const double WolFoxZoomUnlimitedMax = 50.0;

static NSInteger WolFoxZoomMode(void) {
    id stored = WolFoxPreferenceObject(@"YTKACE.Preference.Playback.VideoZoom");
    return [stored respondsToSelector:@selector(integerValue)] ? [stored integerValue] : 0;
}

static double WolFoxZoomDouble(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return NAN;
    return ((double (*)(id, SEL))objc_msgSend)(object, selector);
}

static void WolFoxZoomSetDouble(id object, NSString *name, double value) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, double))objc_msgSend)(object, selector, value);
}

static void WolFoxZoomCall(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL))objc_msgSend)(object, selector);
}

static double WolFoxZoomFillFactor(id controller) {
    static Ivar ivar;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Ivar found = class_getInstanceVariable(object_getClass(controller), "_snappedZoomFactor");
        const char *type = found != NULL ? ivar_getTypeEncoding(found) : NULL;
        if (type != NULL && strcmp(type, "d") == 0) ivar = found;
    });
    if (ivar == NULL) return NAN;
    return *(double *)((uint8_t *)(__bridge void *)controller + ivar_getOffset(ivar));
}

static void WolFoxZoomBegin(id self, SEL _cmd, CGPoint point) {
    if (WolFoxZoomMode() == 2) {
        WolFoxZoomSetDouble(self, @"setMaxFreeZoomFactor:", WolFoxZoomUnlimitedMax);
        WolFoxZoomSetDouble(self, @"setMaxFreeZoomLimit:", WolFoxZoomUnlimitedMax * 1.2);
    }
    ((void (*)(id, SEL, CGPoint))WolFoxZoomOrigBegin)(self, _cmd, point);
}

static void WolFoxZoomDidZoom(id self, SEL _cmd, double zoom, BOOL twoFinger) {
    if (zoom > 1.0 && WolFoxZoomMode() == 1) {
        const double fill = WolFoxZoomFillFactor(self);
        const double current = WolFoxZoomDouble(self, @"videoZoomFactor");
        if (fill >= 1.0 && current > 0.0) {
            if (current >= fill) {
                zoom = 1.0;
            } else if (current * zoom > fill) {
                zoom = fill / current;
            }
        }
    }
    ((void (*)(id, SEL, double, BOOL))WolFoxZoomOrigZoom)(self, _cmd, zoom, twoFinger);
}

static void WolFoxZoomEnd(id self, SEL _cmd) {
    WolFoxZoomReleasing = YES;
    ((void (*)(id, SEL))WolFoxZoomOrigEnd)(self, _cmd);
    WolFoxZoomReleasing = NO;
}

static void WolFoxZoomMaxState(id self, SEL _cmd) {
    if (WolFoxZoomMode() != 2 || !WolFoxZoomReleasing) {
        ((void (*)(id, SEL))WolFoxZoomOrigMaxState)(self, _cmd);
        return;
    }
    const double current = WolFoxZoomDouble(self, @"videoZoomFactor");
    if (current <= WolFoxZoomUnlimitedMax) return;
    WolFoxZoomSetDouble(self, @"setVideoZoomFactor:", WolFoxZoomUnlimitedMax);
    WolFoxZoomSetDouble(self, @"updateRenderingViewFrameWithAnimationDuration:", 0.25);
}

static void WolFoxZoomLayout(id self, SEL _cmd, int layout) {
    ((void (*)(id, SEL, int))WolFoxZoomOrigLayout)(self, _cmd, layout);
    if (WolFoxZoomDouble(self, @"videoZoomFactor") <= 1.001 || WolFoxZoomResyncPending) return;
    WolFoxZoomResyncPending = YES;
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        WolFoxZoomResyncPending = NO;
        id strongSelf = weakSelf;
        if (strongSelf == nil) return;
        WolFoxZoomCall(strongSelf, @"resetVideoFrameToOriginalState");
    });
}

void WolFoxInstallVideoZoomHooks(void) {
    NSString *zoomClass = @"YTVideoFreeZoomOverlayController";
    WolFoxInstallInstanceHook(zoomClass, @"freeZoomViewPinchDidBeginAtPoint:",
                              (IMP)WolFoxZoomBegin, &WolFoxZoomOrigBegin);
    WolFoxInstallInstanceHook(zoomClass, @"freeZoomViewDidZoom:isTwoFingerZoom:",
                              (IMP)WolFoxZoomDidZoom, &WolFoxZoomOrigZoom);
    WolFoxInstallInstanceHook(zoomClass, @"freeZoomViewPinchDidEnd",
                              (IMP)WolFoxZoomEnd, &WolFoxZoomOrigEnd);
    WolFoxInstallInstanceHook(zoomClass, @"resetVideoFrameToMaxFreeState",
                              (IMP)WolFoxZoomMaxState, &WolFoxZoomOrigMaxState);
    WolFoxInstallInstanceHook(zoomClass, @"freeZoomViewDidSetPlayerViewLayout:",
                              (IMP)WolFoxZoomLayout, &WolFoxZoomOrigLayout);
}

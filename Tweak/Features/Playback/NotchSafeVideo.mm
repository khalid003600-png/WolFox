#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// In landscape fullscreen, YouTube sizes the video to the whole screen, so a
// wide video (about 2:1 and up) runs under the notch or Dynamic Island. This
// narrows the video view to the safe area while it would be covered. Zooming
// to fill still fills the whole screen.

static NSString *const WolFoxNotchSafeKey = @"YTKACE.Preference.Player.NotchSafeVideo";

// The safe area is wider than the notch itself; this much of it is still
// clear of the Dynamic Island, so the video can use it.
static const CGFloat WolFoxNotchSlack = 21.5;

static IMP OriginalPlayerLayout;
static IMP OriginalPlayerSetAspectRatio;
static IMP OriginalFreeZoomPinch;
static IMP OriginalFreeZoomSnapLabel;
static IMP OriginalHAMPinchBegan;
static IMP OriginalAVPinchBegan;

static char WolFoxAspectKey;
static char WolFoxBaseFrameKey;
static char WolFoxFittedKey;

// Set while the user has zoomed with a pinch. Cleared when YouTube snaps back
// to the original size or a new video starts.
static BOOL WolFoxUserZoomed;
static __weak UIView *WolFoxActivePlayer;

static id WolFoxNotchValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static BOOL WolFoxNotchBool(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL WolFoxFramesMatch(CGRect a, CGRect b) {
    return fabs(a.origin.x - b.origin.x) < 0.5 && fabs(a.origin.y - b.origin.y) < 0.5 &&
        fabs(a.size.width - b.size.width) < 0.5 && fabs(a.size.height - b.size.height) < 0.5;
}

static UIView *WolFoxPlayerForVideo(UIView *video) {
    UIView *view = video.superview;
    for (int depth = 0; view != nil && depth < 3; depth++, view = view.superview) {
        if ([NSStringFromClass(view.class) isEqualToString:@"YTPlayerView"]) return view;
    }
    return nil;
}

// The frame to use instead of the one YouTube gives the video, or the same
// frame when the video isn't covered.
static CGRect WolFoxNotchFrame(UIView *player, UIView *video, CGRect base) {
    if (player == nil || !WolFoxFeatureEnabled(WolFoxNotchSafeKey)) return base;
    UIWindow *window = player.window;
    if (window == nil || WolFoxUserZoomed || WolFoxNotchBool(player, @"zoomToFill") ||
        !CGAffineTransformIsIdentity(video.transform)) {
        return base;
    }
    CGRect inWindow = [player convertRect:player.bounds toView:nil];
    UIEdgeInsets safe = player.safeAreaInsets;
    CGFloat side = MAX(safe.left, safe.right);
    double aspect = [objc_getAssociatedObject(player, &WolFoxAspectKey) doubleValue];
    // Fullscreen landscape only: with a side panel open the player is narrower.
    if (player.bounds.size.width <= player.bounds.size.height ||
        !WolFoxFramesMatch(inWindow, window.bounds) ||
        side <= 0.0 || aspect <= 0.0 || base.size.height <= 0.0) {
        return base;
    }
    // YouTube zooms by growing this frame; only the normal, unzoomed frame
    // fills the player exactly.
    UIView *container = video.superview;
    if (container == nil || !WolFoxFramesMatch(base, container.bounds)) return base;
    CGFloat width = base.size.width - 2.0 * side + WolFoxNotchSlack;
    CGFloat shown = MIN(base.size.width, aspect * base.size.height);
    if (shown <= width + 0.5) return base;
    return CGRectMake(CGRectGetMidX(base) - width / 2.0, base.origin.y, width, base.size.height);
}

static NSMapTable<Class, NSValue *> *WolFoxVideoSetFrameOriginals;

static void WolFoxVideoSetFrame(UIView *video, SEL selector, CGRect frame) {
    IMP original = NULL;
    for (Class cls = object_getClass(video); cls != Nil && original == NULL; cls = class_getSuperclass(cls)) {
        original = (IMP)[[WolFoxVideoSetFrameOriginals objectForKey:cls] pointerValue];
    }
    if (original == NULL) return;
    UIView *player = WolFoxPlayerForVideo(video);
    CGRect adjusted = WolFoxNotchFrame(player, video, frame);
    BOOL fitted = !WolFoxFramesMatch(adjusted, frame);
    BOOL wasFitted = objc_getAssociatedObject(video, &WolFoxFittedKey) != nil;
    objc_setAssociatedObject(video, &WolFoxBaseFrameKey, [NSValue valueWithCGRect:frame],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(video, &WolFoxFittedKey, fitted ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (fitted) WolFoxActivePlayer = player;
    if (fitted != wasFitted) {
        WolFoxDebugLog(@"notch", @"%@ video frame=%@ base=%@", fitted ? @"fitted" : @"restored",
                       NSStringFromCGRect(adjusted), NSStringFromCGRect(frame));
    }
    ((void (*)(id, SEL, CGRect))original)(video, selector, adjusted);
}

// Hooks setFrame: on the class YouTube uses for the video, the first time it
// shows up. YouTube sets that frame from more than one place.
static void WolFoxHookVideoClass(Class cls) {
    if (cls == Nil) return;
    if (WolFoxVideoSetFrameOriginals == nil) {
        WolFoxVideoSetFrameOriginals = [NSMapTable strongToStrongObjectsMapTable];
    }
    if ([WolFoxVideoSetFrameOriginals objectForKey:cls] != nil) return;
    SEL selector = @selector(setFrame:);
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) return;
    IMP original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, (IMP)WolFoxVideoSetFrame, method_getTypeEncoding(method))) {
        Method own = class_getInstanceMethod(cls, selector);
        if (method_getImplementation(own) == (IMP)WolFoxVideoSetFrame) return;
        method_setImplementation(own, (IMP)WolFoxVideoSetFrame);
    }
    [WolFoxVideoSetFrameOriginals setObject:[NSValue valueWithPointer:(const void *)original] forKey:cls];
    WolFoxDebugLog(@"notch", @"hooked %@", NSStringFromClass(cls));
}

// Runs the video's frame through the check again, from the frame YouTube
// last gave it.
static void WolFoxRefitVideo(UIView *player) {
    UIView *video = WolFoxNotchValue(player, @"renderingView");
    if (![video isKindOfClass:UIView.class]) return;
    WolFoxHookVideoClass(object_getClass(video));
    NSValue *base = objc_getAssociatedObject(video, &WolFoxBaseFrameKey);
    video.frame = base != nil ? base.CGRectValue : video.frame;
}

static void WolFoxPlayerLayout(UIView *receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalPlayerLayout)(receiver, selector);
    if (WolFoxFeatureEnabled(WolFoxNotchSafeKey) || WolFoxVideoSetFrameOriginals.count != 0) {
        WolFoxRefitVideo(receiver);
    }
}

static void WolFoxPlayerSetAspectRatio(UIView *receiver, SEL selector, CGFloat aspectRatio) {
    ((void (*)(id, SEL, CGFloat))OriginalPlayerSetAspectRatio)(receiver, selector, aspectRatio);
    NSNumber *previous = objc_getAssociatedObject(receiver, &WolFoxAspectKey);
    if (previous == nil || fabs(previous.doubleValue - aspectRatio) > 0.001) {
        // A new video starts at its normal size.
        WolFoxUserZoomed = NO;
    }
    objc_setAssociatedObject(receiver, &WolFoxAspectKey, @(aspectRatio),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [receiver setNeedsLayout];
}

static void WolFoxStartUserZoom(void) {
    if (WolFoxUserZoomed) return;
    WolFoxUserZoomed = YES;
    UIView *player = WolFoxActivePlayer;
    if (player != nil) WolFoxRefitVideo(player);
}

static void WolFoxFreeZoomPinch(id receiver, SEL selector, id recognizer) {
    if (WolFoxFeatureEnabled(WolFoxNotchSafeKey)) WolFoxStartUserZoom();
    ((void (*)(id, SEL, id))OriginalFreeZoomPinch)(receiver, selector, recognizer);
}

static void WolFoxFreeZoomSnapLabel(id receiver, SEL selector, NSInteger state) {
    if (state == 0 && WolFoxUserZoomed) {
        // Back to the original size.
        WolFoxUserZoomed = NO;
        UIView *player = WolFoxActivePlayer;
        if (player != nil) WolFoxRefitVideo(player);
    }
    ((void (*)(id, SEL, NSInteger))OriginalFreeZoomSnapLabel)(receiver, selector, state);
}

static void WolFoxHAMPinchBegan(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(WolFoxNotchSafeKey)) WolFoxStartUserZoom();
    ((void (*)(id, SEL))OriginalHAMPinchBegan)(receiver, selector);
}

static void WolFoxAVPinchBegan(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(WolFoxNotchSafeKey)) WolFoxStartUserZoom();
    ((void (*)(id, SEL))OriginalAVPinchBegan)(receiver, selector);
}

__attribute__((constructor)) static void WolFoxInstallNotchSafeVideo(void) {
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return;
    WolFoxInstallInstanceHook(@"YTPlayerView", @"layoutSubviews",
                              (IMP)WolFoxPlayerLayout, &OriginalPlayerLayout);
    WolFoxInstallInstanceHook(@"YTPlayerView", @"setAspectRatio:",
                              (IMP)WolFoxPlayerSetAspectRatio, &OriginalPlayerSetAspectRatio);
    WolFoxInstallInstanceHook(@"YTVideoFreeZoomOverlayView", @"didRecognizePinch:",
                              (IMP)WolFoxFreeZoomPinch, &OriginalFreeZoomPinch);
    WolFoxInstallInstanceHook(@"YTVideoFreeZoomOverlayView", @"showLabelForSnapState:",
                              (IMP)WolFoxFreeZoomSnapLabel, &OriginalFreeZoomSnapLabel);
    WolFoxInstallInstanceHook(@"MLHAMSBDLSampleBufferRenderingView", @"handlePinchBegan",
                              (IMP)WolFoxHAMPinchBegan, &OriginalHAMPinchBegan);
    WolFoxInstallInstanceHook(@"MLAVPlayerLayerView", @"handlePinchBegan",
                              (IMP)WolFoxAVPinchBegan, &OriginalAVPinchBegan);
}

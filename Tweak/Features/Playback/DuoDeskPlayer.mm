// Desk (laptop) posture on the iPhone Duo: the video on the half above the
// crease and the controls on the half below, the way Netflix and the TV app
// lay out. YouTube centers its full-screen video on the whole screen, which
// puts the picture and the play controls across the crease.
//
// After YouTube lays out its player, the video container stops at the crease
// and the half below shows a mirrored, blurred live copy of the picture
// (DuoKit's DUOUpdateDeskReflection). After YouTube lays out its controls, the
// top row moves to just below the crease and the play row to the middle of the
// space between the crease and the progress bar, which is already at the
// bottom. Only a player that spans the crease changes; book posture, flat and
// closed keep YouTube's layout.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DuoKit.h"
#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

NSString * const WolFoxDuoDeskSplitKey = @"YTKACE.Preference.Player.DuoDeskSplit";

static const void *WolFoxDeskShiftedKey = &WolFoxDeskShiftedKey;

// The crease in `view`'s coordinates when the split applies to it: desk
// posture, the setting on, and the view spanning the crease.
static CGRect WolFoxDeskFold(UIView *view) {
    if (!WolFoxFeatureEnabled(WolFoxDuoDeskSplitKey)) return CGRectNull;
    CGRect fold = DUODeskPostureFold(view);
    if (CGRectIsNull(fold)) return CGRectNull;
    CGRect bounds = view.bounds;
    BOOL spans = CGRectGetMinY(fold) > CGRectGetMinY(bounds) + 100.0 &&
                 CGRectGetMaxY(fold) < CGRectGetMaxY(bounds) - 100.0;
    return spans ? fold : CGRectNull;
}

#pragma mark - Video

// The player's first subview clips the video renderer (it holds
// MLHAMSBDLSampleBufferRenderingView); the controls overlay is a later sibling.
static UIView *WolFoxVideoContainer(UIView *player) {
    for (UIView *subview in player.subviews) {
        for (UIView *inner in subview.subviews) {
            if ([NSStringFromClass(inner.class) containsString:@"SampleBufferRenderingView"]) return subview;
        }
    }
    return nil;
}

// Swiping down on full-screen video leaves full screen. YouTube's own swipe
// drags the video with the finger and animates it back into the watch page,
// which fights the split in the laptop posture (the picture jumped around on
// release). In that posture a downward swipe anywhere on the player presses
// YouTube's exit-full-screen button instead, and YouTube's drag is held back:
// every other pan on the player waits for this one to fail, and it fails at
// once unless the swipe is downward and the split applies.
static UIControl *WolFoxExitFullscreenButton(UIView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"YTEnterExitFullscreenButtonView"]) {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:view];
        while (queue.count) {
            UIView *current = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([current isKindOfClass:UIControl.class]) return (UIControl *)current;
            [queue addObjectsFromArray:current.subviews];
        }
        return nil;
    }
    for (UIView *subview in view.subviews) {
        UIControl *button = WolFoxExitFullscreenButton(subview);
        if (button != nil) return button;
    }
    return nil;
}

static CGRect WolFoxDeskFold(UIView *view);

@interface WolFoxDeskSwipe : NSObject <UIGestureRecognizerDelegate>
@end

@implementation WolFoxDeskSwipe
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)recognizer;
    if (CGRectIsNull(WolFoxDeskFold(pan.view))) return NO;
    CGPoint velocity = [pan velocityInView:pan.view];
    return velocity.y > 0.0 && velocity.y > fabs(velocity.x);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return [other isKindOfClass:UIPanGestureRecognizer.class];
}

- (void)swiped:(UIPanGestureRecognizer *)pan {
    if (pan.state != UIGestureRecognizerStateBegan) return;
    UIControl *button = WolFoxExitFullscreenButton(pan.view);
    WolFoxDebugLog(@"duo-desk", @"swipe down: exit button %@", button != nil ? @"pressed" : @"not found");
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}
@end

static const void *WolFoxDeskSwipeKey = &WolFoxDeskSwipeKey;

static void WolFoxInstallDeskSwipe(UIView *player) {
    if (objc_getAssociatedObject(player, WolFoxDeskSwipeKey) != nil) return;
    static WolFoxDeskSwipe *handler;
    if (handler == nil) handler = [WolFoxDeskSwipe new];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:handler action:@selector(swiped:)];
    pan.delegate = handler;
    pan.maximumNumberOfTouches = 1;
    [player addGestureRecognizer:pan];
    objc_setAssociatedObject(player, WolFoxDeskSwipeKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WolFoxSetVideoFrame(UIView *container, CGRect frame) {
    if (!CGRectEqualToRect(container.frame, frame)) container.frame = frame;
    for (UIView *renderer in container.subviews) {
        if (!CGRectEqualToRect(renderer.frame, container.bounds)) renderer.frame = container.bounds;
    }
}

static IMP WolFoxOrigPlayerLayout;

void WolFoxDuoStatusBarPlayerLayout(UIView *player);

static void WolFoxPlayerLayout(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))WolFoxOrigPlayerLayout)(self, _cmd);
    WolFoxDuoStatusBarPlayerLayout(self);
    DUOObserveHinge(self);
    UIView *container = WolFoxVideoContainer(self);
    if (container == nil) return;
    CGRect fold = WolFoxDeskFold(self);
    BOOL shifted = [objc_getAssociatedObject(container, WolFoxDeskShiftedKey) boolValue];
    if (CGRectIsNull(fold)) {
        if (shifted) {
            WolFoxSetVideoFrame(container, self.bounds);
            objc_setAssociatedObject(container, WolFoxDeskShiftedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        DUOUpdateDeskReflection(self, container, CGRectNull);
        return;
    }
    WolFoxInstallDeskSwipe(self);
    CGRect top = CGRectMake(0.0, 0.0, CGRectGetWidth(self.bounds), CGRectGetMinY(fold));
    objc_setAssociatedObject(container, WolFoxDeskShiftedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // If YouTube moves the video container anyway (its origin leaves the
    // player's top-left), keep its position but the top-half size, so the
    // picture does not jump to the crease.
    BOOL youTubeMoving = fabs(CGRectGetMinX(container.frame)) > 0.5 ||
                         fabs(CGRectGetMinY(container.frame)) > 0.5;
    if (youTubeMoving) {
        top.origin = container.frame.origin;
        WolFoxSetVideoFrame(container, top);
        DUOUpdateDeskReflection(self, container, CGRectNull);
        return;
    }
    WolFoxSetVideoFrame(container, top);
    DUOUpdateDeskReflection(self, container, fold);
}

#pragma mark - Controls

// Top of YouTube's progress bar in `view`'s coordinates, or the view's bottom.
static CGFloat WolFoxPlayerBarTop(UIView *view) {
    UIView *overlay = view.superview;
    for (UIView *sibling in overlay.subviews) {
        if ([NSStringFromClass(sibling.class) isEqualToString:@"YTInlinePlayerBarContainerView"] && !sibling.hidden) {
            return CGRectGetMinY([overlay convertRect:sibling.frame toView:view]);
        }
    }
    return CGRectGetMaxY(view.bounds);
}

// Called last from OverlayButtonHost.mm's layoutSubviews hook on the controls
// overlay (YTKACE hooks a method once).
void WolFoxDuoDeskControlsLayout(UIView *self) {
    if (!DUOIsDuo()) return;
    DUOObserveHinge(self);
    CGRect fold = WolFoxDeskFold(self);
    if (CGRectIsNull(fold)) return;
    // YouTube lays these out again on its next pass, so they are moved on
    // every pass while the posture lasts.
    CGFloat lowerTop = CGRectGetMaxY(fold);
    CGFloat lowerBottom = MAX(lowerTop + 60.0, WolFoxPlayerBarTop(self));
    CGFloat middle = CGRectGetMidY(self.bounds);
    for (UIView *subview in self.subviews) {
        CGRect frame = subview.frame;
        BOOL fullSize = CGRectGetWidth(frame) >= CGRectGetWidth(self.bounds) &&
                        CGRectGetHeight(frame) >= CGRectGetHeight(self.bounds);
        if (CGRectIsEmpty(frame) || fullSize) {
            continue;
        }
        if (CGRectGetMinY(frame) >= lowerTop) continue;
        if (fabs(CGRectGetMidY(frame) - middle) < 80.0) {
            // The play row, centered on the screen: center it in the lower half.
            frame.origin.y = (lowerTop + lowerBottom - CGRectGetHeight(frame)) * 0.5;
        } else if (CGRectGetMaxY(frame) <= CGRectGetMinY(fold)) {
            // The top row and title: move them just below the crease.
            frame.origin.y += lowerTop;
        } else {
            continue;
        }
        subview.frame = frame;
    }
}

void WolFoxInstallDuoDeskPlayerHooks(void) {
    if (!DUOIsDuo()) return;
    WolFoxInstallInstanceHook(@"YTPlayerView", @"layoutSubviews",
                              (IMP)WolFoxPlayerLayout, &WolFoxOrigPlayerLayout);
}

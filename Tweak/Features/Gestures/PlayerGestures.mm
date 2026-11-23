#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../Downloads/DownloadLog.h"

#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalOverlayDidMoveToWindow;
static IMP OriginalMoreVideosDisabled;
static IMP OriginalSetRelatedVideosView;
static const void *WolFoxEdgePanAssociation = &WolFoxEdgePanAssociation;
static const void *WolFoxGestureSurfaceAssociation =
    &WolFoxGestureSurfaceAssociation;
static const void *WolFoxLongPressAssociation = &WolFoxLongPressAssociation;
static const void *WolFoxGestureInitialAssociation = &WolFoxGestureInitialAssociation;
static const void *WolFoxTouchDownAssociation = &WolFoxTouchDownAssociation;
static const void *WolFoxGestureSecondaryInitialAssociation =
    &WolFoxGestureSecondaryInitialAssociation;
static const void *WolFoxGestureActionAssociation = &WolFoxGestureActionAssociation;
static const void *WolFoxIndicatorAssociation = &WolFoxIndicatorAssociation;
static const void *WolFoxIndicatorIconAssociation = &WolFoxIndicatorIconAssociation;
static const void *WolFoxIndicatorTrackAssociation = &WolFoxIndicatorTrackAssociation;
static const void *WolFoxIndicatorFillAssociation = &WolFoxIndicatorFillAssociation;
static const void *WolFoxIndicatorLabelAssociation = &WolFoxIndicatorLabelAssociation;
static const void *WolFoxVolumeViewAssociation = &WolFoxVolumeViewAssociation;
extern BOOL WolFoxHoldSpeedActive(void);
static const void *WolFoxSeekIndicatorAssociation = &WolFoxSeekIndicatorAssociation;
static const void *WolFoxSeekIconAssociation = &WolFoxSeekIconAssociation;
static const void *WolFoxSeekLabelAssociation = &WolFoxSeekLabelAssociation;

// The screen the player is on. On the iPhone Duo UIScreen.mainScreen is the
// outer screen even while the app runs unfolded on the inner one, so setting
// its brightness changed the screen that's off.
static UIScreen *WolFoxScreenForView(UIView *view) {
    return view.window.windowScene.screen ?: UIScreen.mainScreen;
}

@interface WolFoxPriorityPanGestureRecognizer : UIPanGestureRecognizer
@end

@implementation WolFoxPriorityPanGestureRecognizer

- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)preventedGestureRecognizer {
    return YES;
}

- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)preventingGestureRecognizer {
    return NO;
}

@end

@interface WolFoxGestureCoordinator : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedCoordinator;
@property(nonatomic, strong) NSTimer *seekTimer;
@property(nonatomic, weak) UIResponder *seekTarget;
@property(nonatomic, weak) UIView *seekView;
@property(nonatomic, assign) double seekTime;
@property(nonatomic, assign) NSInteger seekDirection;
@property(nonatomic, weak) id scrubOverlay;
@property(nonatomic, weak) id scrubController;
- (void)handleEdgePan:(UIPanGestureRecognizer *)recognizer;
- (void)handleHold:(UILongPressGestureRecognizer *)recognizer;
- (void)handleTwoFingerTap:(UITapGestureRecognizer *)recognizer;
@end

@implementation WolFoxGestureCoordinator

+ (instancetype)sharedCoordinator {
    static WolFoxGestureCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [WolFoxGestureCoordinator new];
    });
    return coordinator;
}

- (UISlider *)volumeSliderInView:(UIView *)view {
    MPVolumeView *volumeView =
        objc_getAssociatedObject(view, WolFoxVolumeViewAssociation);
    if (volumeView == nil) {
        volumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-100, -100, 1, 1)];
        volumeView.alpha = 0.01;
        [view addSubview:volumeView];
        objc_setAssociatedObject(view,
                                 WolFoxVolumeViewAssociation,
                                 volumeView,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIView *subview in volumeView.subviews) {
        if ([subview isKindOfClass:UISlider.class]) {
            return (UISlider *)subview;
        }
    }
    return nil;
}

static void WolFoxStyleGestureIndicator(UIView *indicator, CGFloat alpha, CGFloat radius, CGFloat glassRadius) {
    indicator.layer.cornerRadius = glassRadius;
    if (WolFoxApplyGlassBackground(indicator, YES)) return;
    indicator.backgroundColor = [UIColor colorWithWhite:0.0 alpha:alpha];
    indicator.layer.cornerRadius = radius;
}

- (UIView *)indicatorInView:(UIView *)view {
    UIView *indicator = objc_getAssociatedObject(view, WolFoxIndicatorAssociation);
    if (indicator != nil) {
        return indicator;
    }

    indicator = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 200.0, 50.0)];
    indicator.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
    indicator.layer.cornerRadius = 10.0;
    indicator.clipsToBounds = YES;
    indicator.userInteractionEnabled = NO;
    indicator.alpha = 0.0;

    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(15.0, 12.0, 26.0, 26.0)];
    icon.tintColor = UIColor.whiteColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [indicator addSubview:icon];

    UIView *track = [[UIView alloc] initWithFrame:CGRectMake(50.0, 18.0, 130.0, 3.0)];
    track.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
    track.layer.cornerRadius = 1.5;
    [indicator addSubview:track];

    UIView *fill = [[UIView alloc] initWithFrame:CGRectMake(50.0, 18.0, 0.0, 3.0)];
    fill.backgroundColor = UIColor.whiteColor;
    fill.layer.cornerRadius = 1.5;
    [indicator addSubview:fill];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(50.0, 25.0, 130.0, 20.0)];
    label.textColor = UIColor.whiteColor;
    label.alpha = 0.8;
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentRight;
    [indicator addSubview:label];

    [view addSubview:indicator];
    objc_setAssociatedObject(view,
                             WolFoxIndicatorAssociation,
                             indicator,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, WolFoxIndicatorIconAssociation, icon,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, WolFoxIndicatorTrackAssociation, track,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, WolFoxIndicatorFillAssociation, fill,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, WolFoxIndicatorLabelAssociation, label,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return indicator;
}

- (UIView *)seekIndicatorInView:(UIView *)view {
    UIView *indicator = objc_getAssociatedObject(view, WolFoxSeekIndicatorAssociation);
    if (indicator != nil) return indicator;
    indicator = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 120.0, 120.0)];
    indicator.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.75];
    indicator.layer.cornerRadius = 12.0;
    indicator.clipsToBounds = YES;
    indicator.userInteractionEnabled = NO;
    indicator.alpha = 0.0;
    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(35.0, 25.0, 50.0, 50.0)];
    icon.tintColor = UIColor.whiteColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [indicator addSubview:icon];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 80.0, 120.0, 30.0)];
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont boldSystemFontOfSize:18.0];
    label.textAlignment = NSTextAlignmentCenter;
    [indicator addSubview:label];
    [view addSubview:indicator];
    objc_setAssociatedObject(view, WolFoxSeekIndicatorAssociation, indicator,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, WolFoxSeekIconAssociation, icon,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, WolFoxSeekLabelAssociation, label,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return indicator;
}

- (BOOL)isEdgePan:(UIGestureRecognizer *)recognizer {
    return recognizer == objc_getAssociatedObject(recognizer.view,
                                                   WolFoxEdgePanAssociation);
}

- (UIViewController *)playerControllerForView:(UIView *)view {
    UIResponder *responder = view;
    while (responder != nil) {
        if ([NSStringFromClass(responder.class)
                isEqualToString:@"YTPlayerViewController"] &&
            [responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

- (BOOL)isFullscreenPlayerSurface:(UIView *)view {
    UIViewController *controller = [self playerControllerForView:view];
    for (NSString *name in @[
        @"isFullscreen",
        @"isFullScreen",
        @"isFullscreenPlayer",
        @"isFullScreenPresented",
        @"isFullScreenMode",
        @"fullscreenMode",
        @"fullScreenMode"
    ]) {
        SEL selector = NSSelectorFromString(name);
        if (controller != nil && [controller respondsToSelector:selector] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(controller, selector)) {
            return YES;
        }
    }

    UIWindow *window = view.window;
    if (window == nil || CGRectIsEmpty(view.bounds)) return NO;
    CGRect frame = [view convertRect:view.bounds toView:window];
    CGRect bounds = window.bounds;
    if (CGRectIsEmpty(bounds)) return NO;
    CGFloat widthRatio = CGRectGetWidth(frame) / CGRectGetWidth(bounds);
    CGFloat heightRatio = CGRectGetHeight(frame) / CGRectGetHeight(bounds);
    return widthRatio >= 0.82 && heightRatio >= 0.82;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if (gestureRecognizer == objc_getAssociatedObject(gestureRecognizer.view,
                                                       WolFoxLongPressAssociation)) {
        return NO;
    }
    UIGestureRecognizer *edgePan = nil;
    if ([self isEdgePan:gestureRecognizer]) {
        edgePan = gestureRecognizer;
    } else if ([self isEdgePan:other]) {
        edgePan = other;
    }
    if (edgePan != nil) return NO;
    return YES;
}

// The pan only starts after the finger has moved a bit; remember where it
// touched down so swipe to seek measures the whole travel.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if ([gestureRecognizer isKindOfClass:UIPanGestureRecognizer.class]) {
        objc_setAssociatedObject(gestureRecognizer, WolFoxTouchDownAssociation,
            [NSValue valueWithCGPoint:[touch locationInView:gestureRecognizer.view]],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Gestures.LandscapeOnly")) {
        const CGSize screen = gestureRecognizer.view.window.bounds.size;
        if (screen.height > 0.0 && screen.width <= screen.height) return NO;
    }
    if ([self isEdgePan:gestureRecognizer]) {
        if (!WolFoxMasterEnabled()) return NO;
        UIView *view = gestureRecognizer.view;
        NSInteger surface = [objc_getAssociatedObject(
            gestureRecognizer, WolFoxGestureSurfaceAssociation) integerValue];
        CGPoint location = [gestureRecognizer locationInView:view];
        CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer
            velocityInView:view];
        if (surface != 1) return NO;
        CGRect activeBounds = view.bounds;
        if (CGRectIsEmpty(activeBounds) || CGRectIsNull(activeBounds)) return NO;
        if (fabs(velocity.y) <= fabs(velocity.x)) {
            if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Gestures.SwipeToSeek")) return NO;
            if (WolFoxHoldSpeedActive()) return NO;
            if ([self videoIsZoomedInView:view]) return NO;
            // keep the progress bar's own scrubbing and the miniplayer's drag
            if (location.y > CGRectGetHeight(activeBounds) * 0.75) return NO;
            UIWindow *window = view.window;
            if (window == nil ||
                CGRectGetWidth([view convertRect:activeBounds toView:window]) <
                    CGRectGetWidth(window.bounds) * 0.5) return NO;
            objc_setAssociatedObject(gestureRecognizer, WolFoxGestureActionAssociation,
                                     @4, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return YES;
        }
        double storedArea = [WolFoxPreferenceObject(
            @"YTKACE.Preference.Gestures.ActivationArea") doubleValue];
        double areaPercent = storedArea > 0.0 ? storedArea : 20.0;
        CGFloat edge = CGRectGetWidth(activeBounds) *
            MIN(0.5, MAX(0.1, areaPercent / 100.0));
        BOOL left = location.x >= CGRectGetMinX(activeBounds) &&
            location.x <= CGRectGetMinX(activeBounds) + edge;
        BOOL right = location.x <= CGRectGetMaxX(activeBounds) &&
            location.x >= CGRectGetMaxX(activeBounds) - edge;
        if (!left && !right) return NO;
        NSString *key = left
            ? @"YTKACE.Preference.Gestures.LeftAction"
            : @"YTKACE.Preference.Gestures.RightAction";
        NSInteger action = [WolFoxPreferenceObject(key) integerValue];
        objc_setAssociatedObject(gestureRecognizer,
                                 WolFoxGestureActionAssociation,
                                 @(action),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return action >= 1 && action <= 3;
    }
    if (![gestureRecognizer isKindOfClass:UILongPressGestureRecognizer.class]) {
        return YES;
    }
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Gestures.HoldToSeek")) {
        return NO;
    }
    UIView *view = gestureRecognizer.view;
    CGPoint location = [gestureRecognizer locationInView:view];
    CGRect bounds = view.bounds;
    return location.x > CGRectGetWidth(bounds) * 0.2 &&
        location.x < CGRectGetWidth(bounds) * 0.8 &&
        location.y > CGRectGetHeight(bounds) * 0.15 &&
        location.y < CGRectGetHeight(bounds) * 0.85;
}

- (void)layoutIndicator:(UIView *)indicator inView:(UIView *)view {
    NSInteger size = [WolFoxPreferenceObject(
        @"YTKACE.Preference.Gestures.HUDSize") integerValue];
    CGSize dimensions = CGSizeMake(200.0, 50.0);
    if (size == 0) dimensions = CGSizeMake(164.0, 44.0);
    if (size == 2) dimensions = CGSizeMake(236.0, 58.0);
    indicator.bounds = (CGRect){CGPointZero, dimensions};

    UIEdgeInsets safe = view.safeAreaInsets;
    NSInteger position = [WolFoxPreferenceObject(
        @"YTKACE.Preference.Gestures.HUDPosition") integerValue];
    CGFloat centerY = safe.top + dimensions.height * 0.5 + 18.0;
    if (position == 1) {
        centerY = CGRectGetMidY(view.bounds);
    } else if (position == 2) {
        centerY = CGRectGetHeight(view.bounds) - safe.bottom -
            dimensions.height * 0.5 - 24.0;
    }
    centerY = MIN(CGRectGetHeight(view.bounds) - dimensions.height * 0.5,
                  MAX(dimensions.height * 0.5, centerY));
    indicator.center = CGPointMake(CGRectGetMidX(view.bounds), centerY);
    WolFoxStyleGestureIndicator(indicator, 0.65, 10.0, dimensions.height * 0.5);

    UIImageView *icon = objc_getAssociatedObject(view, WolFoxIndicatorIconAssociation);
    UIView *track = objc_getAssociatedObject(view, WolFoxIndicatorTrackAssociation);
    UIView *fill = objc_getAssociatedObject(view, WolFoxIndicatorFillAssociation);
    UILabel *label = objc_getAssociatedObject(view, WolFoxIndicatorLabelAssociation);
    CGFloat scale = dimensions.height / 50.0;
    icon.frame = CGRectMake(15.0 * scale, 12.0 * scale,
                            26.0 * scale, 26.0 * scale);
    CGFloat trackX = 50.0 * scale;
    CGFloat trackWidth = dimensions.width - trackX - 20.0 * scale;
    track.frame = CGRectMake(trackX, 18.0 * scale, trackWidth, 3.0);
    CGRect fillFrame = fill.frame;
    fillFrame.origin = CGPointMake(trackX, 18.0 * scale);
    fillFrame.size.height = 3.0;
    fill.frame = fillFrame;
    label.frame = CGRectMake(trackX, 25.0 * scale, trackWidth, 20.0 * scale);
    label.font = [UIFont systemFontOfSize:12.0 * scale weight:UIFontWeightMedium];
}

- (void)updateIndicatorInView:(UIView *)view value:(double)value volume:(BOOL)volume {
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Gestures.HUDEnabled")) return;
    UIView *indicator = [self indicatorInView:view];
    UIImageView *icon = objc_getAssociatedObject(view, WolFoxIndicatorIconAssociation);
    UIView *fill = objc_getAssociatedObject(view, WolFoxIndicatorFillAssociation);
    UILabel *label = objc_getAssociatedObject(view, WolFoxIndicatorLabelAssociation);
    NSString *symbol = nil;
    if (volume) {
        if (value <= 0.01) symbol = @"speaker.slash.fill";
        else if (value <= 0.33) symbol = @"speaker.1.fill";
        else if (value <= 0.66) symbol = @"speaker.2.fill";
        else symbol = @"speaker.3.fill";
    } else {
        symbol = value <= 0.4 ? @"sun.min.fill" : @"sun.max.fill";
    }
    icon.image = [[UIImage systemImageNamed:symbol]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [self layoutIndicator:indicator inView:view];
    CGRect frame = fill.frame;
    frame.size.width = (indicator.bounds.size.width - frame.origin.x -
                        20.0 * (indicator.bounds.size.height / 50.0)) * value;
    fill.frame = frame;
    label.text = [NSString stringWithFormat:@"%d%%", (int)lround(value * 100.0)];
    [view bringSubviewToFront:indicator];
}

- (void)showSeekIndicatorInView:(UIView *)view time:(double)time forward:(BOOL)forward {
    UIView *indicator = [self seekIndicatorInView:view];
    WolFoxStyleGestureIndicator(indicator, 0.75, 12.0, 28.0);
    UIImageView *icon = objc_getAssociatedObject(view, WolFoxSeekIconAssociation);
    UILabel *label = objc_getAssociatedObject(view, WolFoxSeekLabelAssociation);
    icon.image = [[UIImage systemImageNamed:forward ? @"goforward" : @"gobackward"]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    NSInteger seconds = MAX(0, (NSInteger)llround(time));
    label.text = seconds >= 3600
        ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(seconds / 3600),
              (long)(seconds / 60 % 60), (long)(seconds % 60)]
        : [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
    indicator.center = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
    [view bringSubviewToFront:indicator];
    [UIView animateWithDuration:0.2 animations:^{ indicator.alpha = 1.0; }];
}

- (void)seekTarget:(id)target toTime:(double)time {
    SEL detailed = NSSelectorFromString(@"didSeekToTime:toleranceBefore:toleranceAfter:");
    SEL simple = NSSelectorFromString(@"seekToTime:");
    if ([target respondsToSelector:detailed]) {
        ((void (*)(id, SEL, double, double, double))objc_msgSend)(target, detailed, time, 0.0, 0.0);
    } else if ([target respondsToSelector:simple]) {
        ((void (*)(id, SEL, double))objc_msgSend)(target, simple, time);
    }
}

// Seconds a swipe across the whole video covers; 0 means the whole video.
static double WolFoxSwipeSeekRange(void) {
    id stored = WolFoxPreferenceObject(@"YTKACE.Preference.Gestures.SwipeSeekRange");
    return [stored respondsToSelector:@selector(doubleValue)] ? [stored doubleValue] : 90.0;
}

static UIView *WolFoxFindView(UIView *view, Class cls, NSUInteger depth) {
    if (view == nil || depth > 12) return nil;
    if ([view isKindOfClass:cls]) return view;
    for (UIView *child in view.subviews) {
        UIView *found = WolFoxFindView(child, cls, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

// The player bar (YTInlinePlayerBarContainerView) owns the fine scrubber.
// The overlay controller shows the storyboard preview over the video while
// the progress bar is dragged; tell it about the swipe the same way.
static id WolFoxScrubController(UIView *view) {
    Class overlayClass = NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController");
    for (UIResponder *responder = view; responder != nil; responder = responder.nextResponder) {
        if (overlayClass != Nil && [responder isKindOfClass:overlayClass]) return responder;
    }
    return nil;
}

// Dragging the bar grows its dot (2) and shrinks it back (1) after.
static void WolFoxScrubDotScale(id bar, long long scale) {
    SEL selector = NSSelectorFromString(@"setScrubberDotDecorationScale:");
    if (![bar respondsToSelector:selector]) return;
    [UIView animateWithDuration:0.2 animations:^{
        ((void (*)(id, SEL, long long))objc_msgSend)(bar, selector, scale);
    }];
}

static id WolFoxScrubberOverlay(UIView *view) {
    Class overlayClass = NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController");
    Class barClass = NSClassFromString(@"YTInlinePlayerBarContainerView");
    if (barClass == Nil) return nil;
    for (UIResponder *responder = view; responder != nil; responder = responder.nextResponder) {
        if (overlayClass != Nil && [responder isKindOfClass:overlayClass]) {
            return WolFoxFindView(((UIViewController *)responder).viewIfLoaded, barClass, 0);
        }
    }
    return WolFoxFindView(view, barClass, 0);
}

// Drives the player bar the way dragging the progress bar does, so YouTube's
// own time pill and preview follow the finger. Ending the scrub only hides
// them; the seek is ours.
static BOOL WolFoxScrubberCanSeek(id bar) {
    return [bar respondsToSelector:NSSelectorFromString(@"didStartScrubbing")] &&
        [bar respondsToSelector:NSSelectorFromString(@"didScrubToPoint:withTime:")] &&
        [bar respondsToSelector:NSSelectorFromString(@"didEndScrubbing")] &&
        [bar respondsToSelector:NSSelectorFromString(@"scrubXForScrubRange:")];
}

static void WolFoxScrubBarToTime(id bar, double time, double total) {
    const double fraction = total > 0.0 ? MIN(1.0, MAX(0.0, time / total)) : 0.0;
    const double x = ((double (*)(id, SEL, double))objc_msgSend)(bar, NSSelectorFromString(@"scrubXForScrubRange:"), fraction);
    ((void (*)(id, SEL, CGPoint, double))objc_msgSend)(bar, NSSelectorFromString(@"didScrubToPoint:withTime:"),
                                                        (CGPoint){x, 0.0}, time);
}

// A zoomed video pans with a horizontal drag, so swipe to seek stays out.
- (BOOL)videoIsZoomedInView:(UIView *)view {
    SEL zoom = NSSelectorFromString(@"videoZoomFactor");
    SEL minimum = NSSelectorFromString(@"minFreeZoomFactor");
    for (UIResponder *responder = view; responder != nil; responder = responder.nextResponder) {
        id zoomController = nil;
        SEL free = NSSelectorFromString(@"videoFreeZoomOverlayController");
        if ([responder respondsToSelector:free]) {
            zoomController = ((id (*)(id, SEL))objc_msgSend)(responder, free);
        }
        for (id candidate in @[responder, zoomController ?: NSNull.null]) {
            if (candidate == NSNull.null || ![candidate respondsToSelector:zoom]) continue;
            double factor = ((double (*)(id, SEL))objc_msgSend)(candidate, zoom);
            double floor = [candidate respondsToSelector:minimum]
                ? ((double (*)(id, SEL))objc_msgSend)(candidate, minimum) : 1.0;
            return factor > MAX(1.0, floor) + 0.01;
        }
    }
    return NO;
}

// Swipe left or right across the video. The target is always the start time
// plus the finger's travel, so moving back returns exactly where you started.
- (void)handleSwipeSeek:(UIPanGestureRecognizer *)recognizer {
    UIView *view = recognizer.view;
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        self.seekTarget = [self seekResponderForView:view];
        self.seekView = view;
        id overlay = WolFoxScrubberOverlay(view);
        self.scrubOverlay = WolFoxScrubberCanSeek(overlay) ? overlay : nil;
        id controller = WolFoxScrubController(view);
        self.scrubController = [controller respondsToSelector:NSSelectorFromString(@"didScrubPlayerBarToTime:")] ? controller : nil;
        double start = round([self doubleFromResponder:self.seekTarget
                                             selectors:@[@"currentVideoMediaTime", @"mediaTime"]]);
        objc_setAssociatedObject(recognizer, WolFoxGestureInitialAssociation, @(start),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // The overlay first: starting its preview resets the bar, so the bar
        // has to start after it to keep its dot and fill following the finger.
        SEL startPreview = NSSelectorFromString(@"didStartPlayerBarScrubbingWithGestureOriginatingInPlayerBar:");
        if ([self.scrubController respondsToSelector:startPreview]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(self.scrubController, startPreview, YES);
        }
        if (self.scrubOverlay != nil) {
            ((void (*)(id, SEL))objc_msgSend)(self.scrubOverlay, NSSelectorFromString(@"didStartScrubbing"));
            WolFoxScrubDotScale(self.scrubOverlay, 2);
        }
    }
    id target = self.seekTarget;
    if (target == nil) return;
    const double start = [objc_getAssociatedObject(recognizer, WolFoxGestureInitialAssociation) doubleValue];
    NSValue *down = objc_getAssociatedObject(recognizer, WolFoxTouchDownAssociation);
    const CGFloat translation = down != nil
        ? [recognizer locationInView:view].x - down.CGPointValue.x
        : [recognizer translationInView:view].x;
    const double maximum = [self doubleFromResponder:target selectors:@[
        @"maximumSeekableTime", @"currentVideoTotalMediaTime", @"currentVideoTotalTime"]];
    const double range = WolFoxSwipeSeekRange() > 0.0 || maximum <= 0.0
        ? MAX(10.0, WolFoxSwipeSeekRange()) : maximum;
    double time = start + translation / MAX(200.0, CGRectGetWidth(view.bounds)) * range;
    time = MAX([self doubleFromResponder:target selectors:@[@"minimumSeekableTime"]], time);
    if (maximum > 0.0) time = MIN(maximum - 1.0, time);
    time = MAX(0.0, time);
    id overlay = self.scrubOverlay;
    if (recognizer.state == UIGestureRecognizerStateBegan ||
        recognizer.state == UIGestureRecognizerStateChanged) {
        if (self.scrubController != nil) {
            ((void (*)(id, SEL, double))objc_msgSend)(self.scrubController,
                NSSelectorFromString(@"didScrubPlayerBarToTime:"), time);
        }
        if (overlay != nil) {
            WolFoxScrubBarToTime(overlay, time, maximum);
        } else {
            [self showSeekIndicatorInView:view time:time forward:translation >= 0.0];
        }
        return;
    }
    const BOOL seeks = recognizer.state == UIGestureRecognizerStateEnded && fabs(time - start) >= 1.0;
    if (overlay != nil) {
        if (!seeks) WolFoxScrubBarToTime(overlay, start, maximum);
        ((void (*)(id, SEL))objc_msgSend)(overlay, NSSelectorFromString(@"didEndScrubbing"));
        WolFoxScrubDotScale(overlay, 1);
    } else {
        UIView *indicator = [self seekIndicatorInView:view];
        [UIView animateWithDuration:0.3 delay:0.3
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ indicator.alpha = 0.0; } completion:nil];
    }
    SEL endPreview = NSSelectorFromString(@"didEndPlayerBarScrubbingWithGestureOriginatingInPlayerBar:withSeekCancelled:seekSource:");
    if ([self.scrubController respondsToSelector:endPreview]) {
        // Cancelled, so YouTube only hides the preview; the seek below is ours.
        ((void (*)(id, SEL, BOOL, BOOL, int))objc_msgSend)(self.scrubController, endPreview, YES, YES, 0);
    }
    self.scrubController = nil;
    if (seeks) [self seekTarget:target toTime:time];
    WolFoxDebugLog(@"gestures", @"swipe seek %.0f -> %.0f scrubber=%d", start, time, overlay != nil);
    self.seekTarget = nil;
    self.seekView = nil;
    self.scrubOverlay = nil;
    objc_setAssociatedObject(recognizer, WolFoxGestureActionAssociation, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)handleEdgePan:(UIPanGestureRecognizer *)recognizer {
    UIView *view = recognizer.view;
    NSInteger action = [objc_getAssociatedObject(
        recognizer, WolFoxGestureActionAssociation) integerValue];
    if (action == 4) {
        [self handleSwipeSeek:recognizer];
        return;
    }
    BOOL volume = action == 2;
    BOOL both = action == 3;
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        double start = volume
            ? AVAudioSession.sharedInstance.outputVolume
            : WolFoxScreenForView(view).brightness;
        objc_setAssociatedObject(recognizer,
                                 WolFoxGestureInitialAssociation,
                                 @(start),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (both) {
            objc_setAssociatedObject(
                recognizer, WolFoxGestureSecondaryInitialAssociation,
                @(AVAudioSession.sharedInstance.outputVolume),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (WolFoxFeatureEnabled(@"YTKACE.Preference.Gestures.HUDEnabled")) {
            [self updateIndicatorInView:view value:start volume:volume];
            UIView *indicator = [self indicatorInView:view];
            [UIView animateWithDuration:0.15 animations:^{ indicator.alpha = 1.0; }];
        }
    }
    if (recognizer.state == UIGestureRecognizerStateChanged) {
        double start = [objc_getAssociatedObject(recognizer,
            WolFoxGestureInitialAssociation) doubleValue];
        CGFloat height = MAX(180.0, CGRectGetHeight(view.bounds) * 0.72);
        CGFloat translation = [recognizer translationInView:view].y;
        double value = MIN(1.0, MAX(0.0, start - translation / height));
        if (volume) {
            UISlider *slider = [self volumeSliderInView:view];
            [slider setValue:(float)value animated:NO];
            [slider sendActionsForControlEvents:UIControlEventValueChanged];
        } else {
            WolFoxScreenForView(view).brightness = value;
            if (both) {
                double volumeStart = [objc_getAssociatedObject(
                    recognizer, WolFoxGestureSecondaryInitialAssociation)
                    doubleValue];
                double volumeValue = MIN(1.0, MAX(
                    0.0, volumeStart - translation / height));
                UISlider *slider = [self volumeSliderInView:view];
                [slider setValue:(float)volumeValue animated:NO];
                [slider sendActionsForControlEvents:UIControlEventValueChanged];
            }
        }
        if (WolFoxFeatureEnabled(@"YTKACE.Preference.Gestures.HUDEnabled")) {
            [self updateIndicatorInView:view value:value volume:volume];
        }
    }
    if (recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled) {
        if (WolFoxFeatureEnabled(@"YTKACE.Preference.Gestures.HUDEnabled")) {
            UIView *indicator = [self indicatorInView:view];
            [UIView animateWithDuration:0.22
                                  delay:0.45
                                options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{ indicator.alpha = 0.0; }
                             completion:nil];
        }
        objc_setAssociatedObject(recognizer, WolFoxGestureActionAssociation,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(
            recognizer, WolFoxGestureSecondaryInitialAssociation,
            nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (volume || both) [self removeVolumeViewFromView:view];
    }
}

// A volume view on screen hides the system volume HUD, so only keep ours
// around while the gesture is changing the volume.
- (void)removeVolumeViewFromView:(UIView *)view {
    __weak UIView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strong = weakView;
        if (strong == nil) return;
        for (UIGestureRecognizer *recognizer in strong.gestureRecognizers) {
            if (recognizer.state == UIGestureRecognizerStateBegan ||
                recognizer.state == UIGestureRecognizerStateChanged) return;
        }
        MPVolumeView *volumeView = objc_getAssociatedObject(strong, WolFoxVolumeViewAssociation);
        [volumeView removeFromSuperview];
        objc_setAssociatedObject(strong, WolFoxVolumeViewAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

- (double)seekStep {
    double value = [NSUserDefaults.standardUserDefaults
        doubleForKey:@"YTKACE.Preference.Gestures.HoldSeekSeconds"];
    return MIN(60.0, MAX(1.0, value > 0.0 ? value : 10.0));
}

- (UIResponder *)seekResponderForView:(UIView *)view {
    UIResponder *responder = view;
    while (responder != nil) {
        BOOL hasTime =
            [responder respondsToSelector:NSSelectorFromString(@"currentVideoMediaTime")] ||
            [responder respondsToSelector:NSSelectorFromString(@"mediaTime")];
        BOOL canSeek =
            [responder respondsToSelector:NSSelectorFromString(@"seekToTime:")] ||
            [responder respondsToSelector:
                NSSelectorFromString(@"didSeekToTime:toleranceBefore:toleranceAfter:")];
        if (hasTime && canSeek) {
            return responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

- (double)doubleFromResponder:(id)responder selectors:(NSArray<NSString *> *)names {
    for (NSString *name in names) {
        SEL selector = NSSelectorFromString(name);
        if ([responder respondsToSelector:selector]) {
            return ((double (*)(id, SEL))objc_msgSend)(responder, selector);
        }
    }
    return 0.0;
}

- (void)performSeek {
    id target = self.seekTarget;
    if (target == nil) {
        [self.seekTimer invalidate];
        self.seekTimer = nil;
        return;
    }

    self.seekTime += self.seekStep * self.seekDirection;
    double minimum = [self doubleFromResponder:target
                                     selectors:@[@"minimumSeekableTime"]];
    double maximum = [self doubleFromResponder:target
                                     selectors:@[
                                         @"maximumSeekableTime",
                                         @"currentVideoTotalTime",
                                         @"currentVideoDuration"
                                     ]];
    self.seekTime = MAX(minimum, self.seekTime);
    if (maximum > minimum) {
        self.seekTime = MIN(maximum, self.seekTime);
    }

    SEL detailed =
        NSSelectorFromString(@"didSeekToTime:toleranceBefore:toleranceAfter:");
    SEL simple = NSSelectorFromString(@"seekToTime:");
    if ([target respondsToSelector:detailed]) {
        ((void (*)(id, SEL, double, double, double))objc_msgSend)(
            target, detailed, self.seekTime, 0.0, 0.0
        );
    } else if ([target respondsToSelector:simple]) {
        ((void (*)(id, SEL, double))objc_msgSend)(
            target, simple, self.seekTime
        );
    }

    UIView *indicator = [self seekIndicatorInView:self.seekView];
    WolFoxStyleGestureIndicator(indicator, 0.75, 12.0, 28.0);
    UIImageView *icon = objc_getAssociatedObject(self.seekView, WolFoxSeekIconAssociation);
    UILabel *label = objc_getAssociatedObject(self.seekView, WolFoxSeekLabelAssociation);
    NSString *symbol = self.seekDirection < 0 ? @"gobackward" : @"goforward";
    icon.image = [[UIImage systemImageNamed:symbol]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    NSInteger seconds = MAX(0, (NSInteger)llround(self.seekTime));
    label.text = [NSString stringWithFormat:@"%ld:%02ld",
                  (long)(seconds / 60), (long)(seconds % 60)];
    indicator.center = CGPointMake(CGRectGetMidX(self.seekView.bounds),
                                   CGRectGetMidY(self.seekView.bounds));
    [self.seekView bringSubviewToFront:indicator];
    [UIView animateWithDuration:0.2 animations:^{ indicator.alpha = 1.0; }];
}

- (void)handleTwoFingerTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded ||
        !WolFoxFeatureEnabled(@"YTKACE.Preference.Gestures.TwoFingerTap")) return;
    SEL toggle = NSSelectorFromString(@"didTogglePlayPause");
    for (UIResponder *responder = recognizer.view; responder != nil; responder = responder.nextResponder) {
        if ([responder respondsToSelector:toggle]) {
            ((void (*)(id, SEL))objc_msgSend)(responder, toggle);
            return;
        }
    }
}

- (void)handleHold:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        UIView *view = recognizer.view;
        self.seekTarget = [self seekResponderForView:view];
        if (self.seekTarget == nil) {
            return;
        }
        self.seekView = view;
        CGPoint location = [recognizer locationInView:view];
        self.seekDirection =
            location.x < CGRectGetMidX(view.bounds) ? -1 : 1;
        self.seekTime = [self doubleFromResponder:self.seekTarget
                                       selectors:@[
                                           @"currentVideoMediaTime",
                                           @"mediaTime"
                                       ]];
        [self performSeek];
        __weak WolFoxGestureCoordinator *weakSelf = self;
        self.seekTimer =
            [NSTimer scheduledTimerWithTimeInterval:0.1
                                           repeats:YES
                                             block:^(NSTimer *timer) {
            (void)timer;
            [weakSelf performSeek];
        }];
    } else if (recognizer.state == UIGestureRecognizerStateEnded ||
               recognizer.state == UIGestureRecognizerStateCancelled ||
               recognizer.state == UIGestureRecognizerStateFailed) {
        [self.seekTimer invalidate];
        self.seekTimer = nil;
        UIView *indicator = [self seekIndicatorInView:self.seekView];
        [UIView animateWithDuration:0.3
                              delay:0.5
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            indicator.alpha = 0.0;
        } completion:nil];
        self.seekTarget = nil;
        self.seekView = nil;
    }
}

@end

static void WolFoxAttachPlayerGestures(UIView *playerView,
                                       NSInteger surface) {
    if (![playerView isKindOfClass:UIView.class]) return;
    UIGestureRecognizer *existing = objc_getAssociatedObject(
        playerView, WolFoxEdgePanAssociation);
    if (existing != nil) return;

    UIPanGestureRecognizer *edgePan =
        [[WolFoxPriorityPanGestureRecognizer alloc]
            initWithTarget:WolFoxGestureCoordinator.sharedCoordinator
                    action:@selector(handleEdgePan:)];
    edgePan.maximumNumberOfTouches = 1;
    edgePan.cancelsTouchesInView = YES;
    edgePan.delaysTouchesBegan = NO;
    edgePan.delaysTouchesEnded = NO;
    edgePan.delegate = WolFoxGestureCoordinator.sharedCoordinator;
    objc_setAssociatedObject(edgePan,
                             WolFoxGestureSurfaceAssociation,
                             @(surface),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [playerView addGestureRecognizer:edgePan];
    objc_setAssociatedObject(playerView,
                             WolFoxEdgePanAssociation,
                             edgePan,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (UIGestureRecognizer *native in [playerView.gestureRecognizers copy]) {
        if (native != edgePan &&
            [native isKindOfClass:UIPanGestureRecognizer.class]) {
            [native requireGestureRecognizerToFail:edgePan];
        }
    }

    UILongPressGestureRecognizer *hold =
        [[UILongPressGestureRecognizer alloc]
            initWithTarget:WolFoxGestureCoordinator.sharedCoordinator
                    action:@selector(handleHold:)];
    hold.minimumPressDuration = 0.5;
    hold.cancelsTouchesInView = YES;
    hold.delegate = WolFoxGestureCoordinator.sharedCoordinator;
    [playerView addGestureRecognizer:hold];
    UITapGestureRecognizer *twoFinger =
        [[UITapGestureRecognizer alloc]
            initWithTarget:WolFoxGestureCoordinator.sharedCoordinator
                    action:@selector(handleTwoFingerTap:)];
    twoFinger.numberOfTouchesRequired = 2;
    twoFinger.cancelsTouchesInView = YES;
    [playerView addGestureRecognizer:twoFinger];
    objc_setAssociatedObject(playerView,
                             WolFoxLongPressAssociation,
                             hold,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WolFoxOverlayDidMoveToWindow(UIView *receiver, SEL selector) {
    if (OriginalOverlayDidMoveToWindow != NULL) {
        ((void (*)(id, SEL))OriginalOverlayDidMoveToWindow)(receiver, selector);
    }
    WolFoxAttachPlayerGestures(receiver, 1);
}

static BOOL WolFoxHiddenMoreVideosDisabled(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.MoreVideosHidden")) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))OriginalMoreVideosDisabled)(receiver, selector);
}

static void WolFoxHiddenSetRelatedVideosView(id receiver, SEL selector,
                                             UIView *relatedVideosView) {
    ((void (*)(id, SEL, UIView *))OriginalSetRelatedVideosView)(
        receiver, selector, relatedVideosView);
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.MoreVideosHidden")) {
        relatedVideosView.hidden = YES;
    }
}

void WolFoxInstallPlayerGestureHooks(void) {
    WolFoxInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayView",
        @"didMoveToWindow",
        (IMP)WolFoxOverlayDidMoveToWindow,
        &OriginalOverlayDidMoveToWindow
    );
    WolFoxInstallInstanceHook(
        @"YTFullscreenEngagementOverlayView",
        @"setRelatedVideosView:",
        (IMP)WolFoxHiddenSetRelatedVideosView,
        &OriginalSetRelatedVideosView
    );
    WolFoxInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController",
        @"shouldEnableRelatedVideos",
        (IMP)WolFoxHiddenMoreVideosDisabled, &OriginalMoreVideosDisabled
    );
}

#import "OverlayButtonHost.h"
#import "OverlayButtonLayout.h"
#import "Assets.h"
#import "../Features/Downloads/DownloadLog.h"
#import "../WolFox.h"
#import "../Runtime/Hooking.h"
#import "../Runtime/Preferences.h"

#import <math.h>
#import <objc/runtime.h>
#import <objc/message.h>

static IMP OriginalControlsOverlayLayout;
static IMP OriginalControlsSetOverlayVisible;
static IMP OriginalControlsSetControlsVisible;
static IMP OriginalVideoSetOverlayVisible;
static IMP OriginalVideoSetControlsVisible;
static IMP OriginalControlsSetHidden;
static IMP OriginalPlayerBarHitTest;
static NSHashTable<UIStackView *> *WolFoxBottomStacks;
static NSHashTable<UIStackView *> *WolFoxFullscreenStacks;
static IMP OriginalFullscreenActionsHitTest;
static const void *WolFoxOverlayStackAssociation = &WolFoxOverlayStackAssociation;
static const void *WolFoxOverlayTrailingAssociation = &WolFoxOverlayTrailingAssociation;
static const void *WolFoxOverlayAlignmentAssociation = &WolFoxOverlayAlignmentAssociation;
static const void *WolFoxOverlayZoneStacksAssociation = &WolFoxOverlayZoneStacksAssociation;
static const void *WolFoxOverlayGroupAssociation = &WolFoxOverlayGroupAssociation;
static const void *WolFoxOverlayPlacedAssociation = &WolFoxOverlayPlacedAssociation;
static const void *WolFoxTopSlotsAssociation = &WolFoxTopSlotsAssociation;
static const void *WolFoxOverlayMadeAssociation = &WolFoxOverlayMadeAssociation;
static const void *WolFoxOverlayAnchorAssociation = &WolFoxOverlayAnchorAssociation;
static const void *WolFoxOverlayOwnerAssociation = &WolFoxOverlayOwnerAssociation;
static const void *WolFoxOverlayRetryAssociation = &WolFoxOverlayRetryAssociation;
static NSString *WolFoxCurrentOverlayGroup;
static NSMutableArray<NSDictionary *> *WolFoxOverlayConfigurators;
static BOOL WolFoxNativeControlsVisible = YES;

static void WolFoxFindSettingsControlInView(UIView *view,
                                            UIView *excluded,
                                            UIView *coordinateView,
                                            UIView **best,
                                            CGFloat *bestScore) {
    if (view == excluded || [view isDescendantOfView:excluded] ||
        view.hidden || view.alpha < 0.05) {
        return;
    }
    NSString *hint = [[NSString stringWithFormat:@"%@ %@ %@",
        view.accessibilityIdentifier ?: @"", view.accessibilityLabel ?: @"",
        NSStringFromClass(view.class)] lowercaseString];
    if (([view isKindOfClass:UIControl.class] ||
         [view isKindOfClass:UIImageView.class]) &&
        ([hint containsString:@"settings"] || [hint containsString:@"gear"]) &&
        !CGRectIsEmpty(view.bounds)) {
        CGRect frame = [view convertRect:view.bounds toView:coordinateView];
        CGFloat width = CGRectGetWidth(coordinateView.bounds);
        CGFloat height = CGRectGetHeight(coordinateView.bounds);
        CGFloat centerX = CGRectGetMidX(frame);
        CGFloat centerY = CGRectGetMidY(frame);
        if (isfinite(centerX) && isfinite(centerY) &&
            centerX > width * 0.55 && centerY < height * 0.35 &&
            CGRectIntersectsRect(frame, coordinateView.bounds)) {
            CGFloat score = centerX - centerY * 0.2;
            if (*best == nil || score > *bestScore) {
                *best = view;
                *bestScore = score;
            }
        }
    }
    for (UIView *subview in view.subviews) {
        WolFoxFindSettingsControlInView(subview, excluded, coordinateView,
                                        best, bestScore);
    }
}

static BOOL WolFoxIsTopTrailingControl(UIView *view, UIView *overlay) {
    CGRect frame = [view convertRect:view.bounds toView:overlay];
    CGFloat width = CGRectGetWidth(overlay.bounds);
    CGFloat height = CGRectGetHeight(overlay.bounds);
    CGFloat centerX = CGRectGetMidX(frame);
    CGFloat centerY = CGRectGetMidY(frame);
    return isfinite(centerX) && isfinite(centerY) &&
        centerX > width * 0.55 && centerY < height * 0.35 &&
        CGRectIntersectsRect(frame, overlay.bounds);
}

static UIView *WolFoxOverflowControl(UIView *overlay) {
    SEL selector = NSSelectorFromString(@"overflowButton");
    if (![overlay respondsToSelector:selector]) return nil;
    UIView *button = ((id (*)(id, SEL))objc_msgSend)(overlay, selector);
    if (![button isKindOfClass:UIView.class] || button.hidden ||
        button.alpha < 0.05 || CGRectIsEmpty(button.bounds)) {
        return nil;
    }
    return WolFoxIsTopTrailingControl(button, overlay) ? button : nil;
}

static UIView *WolFoxFindSettingsControl(UIView *overlay, UIView *excluded) {
    UIView *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    WolFoxFindSettingsControlInView(overlay, excluded, overlay,
                                    &best, &bestScore);
    if (best == nil && overlay.window != nil) {
        WolFoxFindSettingsControlInView(overlay.window, excluded, overlay,
                                        &best, &bestScore);
    }
    return best;
}

static NSMutableDictionary *WolFoxAlignmentState(UIView *overlay) {
    NSMutableDictionary *state = objc_getAssociatedObject(
        overlay, WolFoxOverlayAlignmentAssociation);
    if (state == nil) {
        state = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(overlay, WolFoxOverlayAlignmentAssociation,
                                 state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static UIView *WolFoxFindIdentified(UIView *view, NSString *identifier, NSArray<UIView *> *skip, int depth);
static BOOL WolFoxViewShown(UIView *view);

// Rightmost of YouTube's top buttons, only when they are reordered.
static UIView *WolFoxRightmostNativeTop(UIView *overlay, UIView *skip) {
    if ([WolFoxNativeTopOrder() isEqualToArray:WolFoxNativeTopDefaultOrder()]) return nil;
    UIView *best = nil;
    CGFloat bestX = -CGFLOAT_MAX;
    NSArray *skipped = skip != nil ? @[skip] : @[];
    for (NSString *identifier in WolFoxNativeTopIdentifiers().allValues) {
        UIView *view = WolFoxFindIdentified(overlay, identifier, skipped, 0);
        if (view == nil || !WolFoxViewShown(view)) continue;
        const CGFloat maxX = CGRectGetMaxX([view convertRect:view.bounds toView:overlay]);
        if (maxX > bestX) {
            bestX = maxX;
            best = view;
        }
    }
    return best;
}

static BOOL WolFoxAlignOverlayStack(UIView *overlay, UIStackView *stack) {
    NSLayoutConstraint *trailing = objc_getAssociatedObject(
        overlay, WolFoxOverlayTrailingAssociation);
    if (trailing == nil) return NO;

    NSMutableDictionary *state = WolFoxAlignmentState(overlay);
    CGSize size = overlay.bounds.size;
    CGSize oldSize = [state[@"size"] CGSizeValue];
    if (fabs(size.width - oldSize.width) > 1.0 ||
        fabs(size.height - oldSize.height) > 1.0) {
        [state removeAllObjects];
        state[@"size"] = [NSValue valueWithCGSize:size];
    }
    UIWindow *window = overlay.window;
    CGSize windowSize = window != nil ? window.bounds.size : CGSizeZero;
    BOOL fillsLandscapeWindow = windowSize.width > windowSize.height &&
        CGRectGetWidth(overlay.bounds) >= windowSize.width * 0.94;
    CGFloat constant = fillsLandscapeWindow ? -20.0 : -8.0;
    NSNumber *previous = state[@"constant"];
    BOOL hasGearAlignment = [state[@"hasGearAlignment"] boolValue];
    UIView *gear = WolFoxOverflowControl(overlay) ?:
        WolFoxFindSettingsControl(overlay, stack);
    // With YouTube's top buttons reordered the gear may not be last; line up
    // under whichever is rightmost.
    UIView *rightmost = WolFoxRightmostNativeTop(overlay, stack);
    if (rightmost != nil) gear = rightmost;
    // Our own buttons can be last in the top row too.
    NSDictionary *zoneStacks = objc_getAssociatedObject(overlay, WolFoxOverlayZoneStacksAssociation);
    NSArray *spread = objc_getAssociatedObject(zoneStacks[WolFoxOverlayZoneTop], WolFoxTopSlotsAssociation);
    NSValue *lastSlot = [spread.firstObject lastObject];
    if (gear != nil) {
        CGRect frame = [gear.superview convertRect:gear.frame toView:overlay];
        if (lastSlot != nil && CGRectGetMidX(lastSlot.CGRectValue) > CGRectGetMidX(frame)) frame = lastSlot.CGRectValue;
        CGFloat safeTrailing = CGRectGetMaxX(overlay.safeAreaLayoutGuide.layoutFrame);
        CGFloat center = CGRectGetMidX(frame);
        if (isfinite(center) && center > 0.0 && safeTrailing > 0.0) {
            constant = MIN(20.0, MAX(-160.0,
                center + 20.0 - safeTrailing));
            hasGearAlignment = YES;
            state[@"hasGearAlignment"] = @YES;
        }
    } else if (hasGearAlignment && previous != nil) {
        constant = previous.doubleValue;
    }

    NSUInteger stable = [state[@"stable"] unsignedIntegerValue];
    if (previous != nil && fabs(previous.doubleValue - constant) < 0.5) {
        stable += 1;
    } else {
        stable = 1;
    }
    state[@"constant"] = @(constant);
    state[@"stable"] = @(stable);
    [UIView performWithoutAnimation:^{
        trailing.constant = constant;
    }];

    BOOL ready = hasGearAlignment || stable >= 2;
    state[@"ready"] = @(ready);
    if (!ready) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [overlay setNeedsLayout];
        });
    }
    return ready;
}

static BOOL WolFoxKeepControlsVisible(void) {
    return WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.AlwaysShowControls") ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.AlwaysShowControls");
}

static void WolFoxSetHostedControlsHidden(UIView *view, BOOL hidden) {
    if ([view.accessibilityIdentifier isEqualToString:@"WolFoxOverlayControls"]) {
        BOOL visible = !hidden;
        view.userInteractionEnabled = visible;
        if (visible) {
            [view.superview setNeedsLayout];
        }
        NSTimeInterval duration = [UIView inheritedAnimationDuration];
        if (duration <= 0.0 || duration > 1.0) duration = 0.20;
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseInOut |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            view.alpha = visible ? 1.0 : 0.0;
        } completion:nil];
        return;
    }
    for (UIView *subview in view.subviews) {
        WolFoxSetHostedControlsHidden(subview, hidden);
    }
}

static void WolFoxUpdateHostedVisibility(UIView *receiver, BOOL visible) {
    WolFoxNativeControlsVisible = visible;
    WolFoxSetHostedControlsHidden(receiver, !visible);
}

static void WolFoxControlsSetOverlayVisible(UIView *receiver, SEL selector, BOOL visible) {
    visible = visible || WolFoxKeepControlsVisible();
    if (OriginalControlsSetOverlayVisible != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalControlsSetOverlayVisible)(receiver, selector, visible);
    }
    WolFoxUpdateHostedVisibility(receiver, visible);
}

static void WolFoxControlsSetControlsVisible(UIView *receiver, SEL selector, BOOL visible) {
    visible = visible || WolFoxKeepControlsVisible();
    if (OriginalControlsSetControlsVisible != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalControlsSetControlsVisible)(receiver, selector, visible);
    }
    WolFoxUpdateHostedVisibility(receiver, visible);
}

static void WolFoxVideoSetOverlayVisible(UIView *receiver, SEL selector, BOOL visible) {
    visible = visible || WolFoxKeepControlsVisible();
    if (OriginalVideoSetOverlayVisible != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalVideoSetOverlayVisible)(receiver, selector, visible);
    }
    WolFoxUpdateHostedVisibility(receiver, visible);
}

static void WolFoxVideoSetControlsVisible(UIView *receiver, SEL selector, BOOL visible) {
    visible = visible || WolFoxKeepControlsVisible();
    if (OriginalVideoSetControlsVisible != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalVideoSetControlsVisible)(receiver, selector, visible);
    }
    WolFoxUpdateHostedVisibility(receiver, visible);
}

static void WolFoxControlsSetHidden(UIView *receiver, SEL selector, BOOL hidden) {
    hidden = hidden && !WolFoxKeepControlsVisible();
    if (OriginalControlsSetHidden != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalControlsSetHidden)(receiver, selector, hidden);
    }
    WolFoxUpdateHostedVisibility(receiver, !hidden);
}

static UIStackView *WolFoxStackForOverlay(UIView *overlay) {
    UIStackView *stack = objc_getAssociatedObject(overlay, WolFoxOverlayStackAssociation);
    if (stack != nil) {
        return stack;
    }

    stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.distribution = UIStackViewDistributionFill;
    // 40pt buttons 48pt apart, like YouTube's top row above it.
    stack.spacing = 8.0;
    stack.layoutMargins = UIEdgeInsetsZero;
    stack.layoutMarginsRelativeArrangement = YES;
    stack.backgroundColor = UIColor.clearColor;
    stack.alpha = WolFoxNativeControlsVisible ? 1.0 : 0.0;
    stack.userInteractionEnabled = WolFoxNativeControlsVisible;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.accessibilityIdentifier = @"WolFoxOverlayControls";

    [overlay addSubview:stack];
    NSLayoutConstraint *trailing =
        [stack.trailingAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.trailingAnchor
                                             constant:-10.0];
    [NSLayoutConstraint activateConstraints:@[
        trailing,
        [stack.topAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.topAnchor constant:50.0],
        [stack.heightAnchor constraintEqualToConstant:40.0]
    ]];
    objc_setAssociatedObject(overlay, WolFoxOverlayTrailingAssociation,
                             trailing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlay,
                             WolFoxOverlayStackAssociation,
                             stack,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return stack;
}

static UIView *WolFoxPlayerBarHitTest(UIView *receiver, SEL selector, CGPoint point, UIEvent *event);
static UIView *WolFoxFullscreenActionsHitTest(UIView *receiver, SEL selector, CGPoint point, UIEvent *event);

// Spans YouTube's buttons when ours sit between them; only our buttons take taps.
@interface WolFoxPassThroughStackView : UIStackView
@end

@implementation WolFoxPassThroughStackView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

// The left column: top to bottom, starting a new column to the right when
// it runs out of height. A group (speed's three buttons) stays in one column.
// Not a UIStackView: its constraints can only make one line and would fight
// the wrapping forever. It answers the few UIStackView calls the rows get and
// places its buttons itself.
@interface WolFoxColumnStackView : UIView
@property(nonatomic, assign) CGFloat maximumHeight;
@property(nonatomic, assign) CGFloat spacing;
@property(nonatomic, assign) UILayoutConstraintAxis axis;
@property(nonatomic, assign) UIStackViewAlignment alignment;
@property(nonatomic, assign) UIStackViewDistribution distribution;
@property(nonatomic, strong) NSMutableArray<UIView *> *items;
- (NSArray<UIView *> *)arrangedSubviews;
- (void)addArrangedSubview:(UIView *)view;
- (void)insertArrangedSubview:(UIView *)view atIndex:(NSUInteger)index;
- (void)removeArrangedSubview:(UIView *)view;
- (void)setCustomSpacing:(CGFloat)spacing afterView:(UIView *)view;
- (CGFloat)customSpacingAfterView:(UIView *)view;
- (CGSize)columnSize;
@end

@implementation WolFoxColumnStackView

// Our buttons are 40pt square; text ones (quality, speed) get wider.
static CGSize WolFoxColumnButtonSize(UIView *view) {
    const CGSize intrinsic = view.intrinsicContentSize;
    const CGFloat width = intrinsic.width > 0.0 && intrinsic.width != UIViewNoIntrinsicMetric ? intrinsic.width : 40.0;
    return CGSizeMake(ceil(MAX(40.0, width)), 40.0);
}

- (NSMutableArray<UIView *> *)items {
    if (_items == nil) _items = [NSMutableArray array];
    return _items;
}

- (NSArray<UIView *> *)arrangedSubviews { return [self.items copy]; }

- (void)insertArrangedSubview:(UIView *)view atIndex:(NSUInteger)index {
    if (view == nil) return;
    [self.items removeObject:view];
    [self.items insertObject:view atIndex:MIN(index, self.items.count)];
    // placed by frame here; stack rows turn this off again when they take it
    view.translatesAutoresizingMaskIntoConstraints = YES;
    if (view.superview != self) [self addSubview:view];
    [self setNeedsLayout];
}

- (void)addArrangedSubview:(UIView *)view { [self insertArrangedSubview:view atIndex:self.items.count]; }

- (void)removeArrangedSubview:(UIView *)view {
    [self.items removeObject:view];
    [self setNeedsLayout];
}

- (void)willRemoveSubview:(UIView *)subview {
    [super willRemoveSubview:subview];
    [self.items removeObject:subview];
}

- (void)setCustomSpacing:(CGFloat)spacing afterView:(UIView *)view {}
- (CGFloat)customSpacingAfterView:(UIView *)view { return UIStackViewSpacingUseDefault; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

- (NSArray<NSValue *> *)columnFrames:(CGSize *)total {
    NSMutableArray<NSArray<UIView *> *> *groups = [NSMutableArray array];
    id current = nil;
    for (UIView *view in self.items) {
        if (view.hidden) continue;
        id group = objc_getAssociatedObject(view, (__bridge const void *)WolFoxColumnStackView.class) ?: view;
        if (groups.count == 0 || ![group isEqual:current]) {
            [groups addObject:@[view]];
            current = group;
        } else {
            groups[groups.count - 1] = [groups.lastObject arrayByAddingObject:view];
        }
    }
    const CGFloat limit = self.maximumHeight > 0.0 ? self.maximumHeight : CGFLOAT_MAX;
    // Each group goes in the first column with room for it, so a short
    // button fills the gap under a group that had to start a new column.
    NSMutableArray<NSMutableArray<NSArray<UIView *> *> *> *columns = [NSMutableArray array];
    NSMutableArray<NSNumber *> *used = [NSMutableArray array];
    for (NSArray<UIView *> *group in groups) {
        CGFloat groupHeight = 0.0;
        for (UIView *view in group) groupHeight += WolFoxColumnButtonSize(view).height + (groupHeight > 0.0 ? self.spacing : 0.0);
        NSUInteger target = NSNotFound;
        for (NSUInteger index = 0; index < columns.count; index++) {
            if (used[index].doubleValue + self.spacing + groupHeight <= limit) { target = index; break; }
        }
        if (target == NSNotFound) {
            [columns addObject:[NSMutableArray array]];
            [used addObject:@(-self.spacing)];
            target = columns.count - 1;
        }
        [columns[target] addObject:group];
        used[target] = @(used[target].doubleValue + self.spacing + groupHeight);
    }
    // Frames in the views' own order.
    NSMapTable<UIView *, NSValue *> *placed = [NSMapTable strongToStrongObjectsMapTable];
    CGFloat x = 0.0, height = 0.0;
    for (NSArray<NSArray<UIView *> *> *column in columns) {
        CGFloat columnWidth = 0.0;
        for (NSArray<UIView *> *group in column) {
            for (UIView *view in group) columnWidth = MAX(columnWidth, WolFoxColumnButtonSize(view).width);
        }
        CGFloat y = 0.0;
        for (NSArray<UIView *> *group in column) {
            for (UIView *view in group) {
                const CGSize size = WolFoxColumnButtonSize(view);
                [placed setObject:[NSValue valueWithCGRect:CGRectMake(x + round((columnWidth - size.width) * 0.5), y,
                                                                      size.width, size.height)] forKey:view];
                y += size.height + self.spacing;
            }
        }
        height = MAX(height, y - self.spacing);
        x += columnWidth + self.spacing;
    }
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    for (NSArray<UIView *> *group in groups) {
        for (UIView *view in group) [frames addObject:[placed objectForKey:view]];
    }
    if (total != NULL) *total = CGSizeMake(columns.count == 0 ? 0.0 : x - self.spacing, height);
    return frames;
}

- (CGSize)columnSize {
    CGSize size = CGSizeZero;
    [self columnFrames:&size];
    return size;
}

- (CGSize)systemLayoutSizeFittingSize:(CGSize)target {
    return [self columnSize];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    NSArray<NSValue *> *frames = [self columnFrames:NULL];
    NSUInteger index = 0;
    for (UIView *view in self.items) {
        if (view.hidden || index >= frames.count) continue;
        const CGRect frame = frames[index++].CGRectValue;
        if (!CGRectEqualToRect(view.frame, frame)) view.frame = frame;
    }
}

@end

static UIStackView *WolFoxNewZoneStackOfClass(UIView *overlay, Class cls) {
    UIStackView *stack = [cls new];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.distribution = UIStackViewDistributionFill;
    stack.spacing = 7.0;
    stack.backgroundColor = UIColor.clearColor;
    stack.alpha = WolFoxNativeControlsVisible ? 1.0 : 0.0;
    stack.userInteractionEnabled = WolFoxNativeControlsVisible;
    stack.translatesAutoresizingMaskIntoConstraints = YES;
    stack.accessibilityIdentifier = @"WolFoxOverlayControls";
    stack.hidden = YES;
    [overlay addSubview:stack];
    return stack;
}

static UIStackView *WolFoxNewZoneStack(UIView *overlay) {
    return WolFoxNewZoneStackOfClass(overlay, UIStackView.class);
}

// One row per zone: the old row under YouTube's buttons, plus one placed in
// YouTube's top row and one next to the fullscreen button.
static NSDictionary<NSString *, UIStackView *> *WolFoxZoneStacks(UIView *overlay) {
    NSDictionary *stacks = objc_getAssociatedObject(overlay, WolFoxOverlayZoneStacksAssociation);
    if (stacks != nil) return stacks;
    stacks = @{
        WolFoxOverlayZoneBelow: WolFoxStackForOverlay(overlay),
        WolFoxOverlayZoneTop: WolFoxNewZoneStackOfClass(overlay, WolFoxPassThroughStackView.class),
        WolFoxOverlayZoneBottom: WolFoxNewZoneStack(overlay),
        WolFoxOverlayZoneFullscreen: WolFoxNewZoneStackOfClass(overlay, WolFoxPassThroughStackView.class),
        WolFoxOverlayZoneLeft: WolFoxNewZoneStackOfClass(overlay, WolFoxColumnStackView.class)
    };
    if (WolFoxFullscreenStacks == nil) {
        WolFoxFullscreenStacks = [NSHashTable weakObjectsHashTable];
        WolFoxInstallInstanceHook(@"YTFullscreenActionsView", @"hitTest:withEvent:",
                                  (IMP)WolFoxFullscreenActionsHitTest, &OriginalFullscreenActionsHitTest);
    }
    ((UIStackView *)stacks[WolFoxOverlayZoneTop]).spacing = 8.0;
    UIStackView *left = stacks[WolFoxOverlayZoneLeft];
    left.axis = UILayoutConstraintAxisVertical;
    left.spacing = 8.0;
    [WolFoxFullscreenStacks addObject:stacks[WolFoxOverlayZoneFullscreen]];
    if (WolFoxBottomStacks == nil) {
        WolFoxBottomStacks = [NSHashTable weakObjectsHashTable];
        WolFoxInstallInstanceHook(@"YTInlinePlayerBarContainerView", @"hitTest:withEvent:",
                                  (IMP)WolFoxPlayerBarHitTest, &OriginalPlayerBarHitTest);
    }
    [WolFoxBottomStacks addObject:stacks[WolFoxOverlayZoneBottom]];
    objc_setAssociatedObject(overlay, WolFoxOverlayZoneStacksAssociation, stacks,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (UIStackView *row in stacks.allValues) {
        objc_setAssociatedObject(row, WolFoxOverlayOwnerAssociation, overlay, OBJC_ASSOCIATION_ASSIGN);
    }
    return stacks;
}

// YouTube's player bar sits over the controls overlay and takes touches
// there; hand taps on our bottom row back to our buttons.
static UIView *WolFoxPlayerBarHitTest(UIView *receiver, SEL selector, CGPoint point, UIEvent *event) {
    for (UIStackView *stack in WolFoxBottomStacks.allObjects) {
        if (stack.hidden || stack.alpha < 0.05 || !stack.userInteractionEnabled || stack.window != receiver.window) continue;
        UIView *hit = [stack hitTest:[receiver convertPoint:point toView:stack] withEvent:event];
        if (hit != nil && hit != stack) return hit;
    }
    return ((UIView *(*)(id, SEL, CGPoint, UIEvent *))OriginalPlayerBarHitTest)(receiver, selector, point, event);
}

// YouTube's fullscreen bar can sit over our row there; hand taps on it back.
static UIView *WolFoxFullscreenActionsHitTest(UIView *receiver, SEL selector, CGPoint point, UIEvent *event) {
    for (UIStackView *stack in WolFoxFullscreenStacks.allObjects) {
        if (stack.hidden || stack.alpha < 0.05 || !stack.userInteractionEnabled || stack.window != receiver.window) continue;
        UIView *hit = [stack hitTest:[receiver convertPoint:point toView:stack] withEvent:event];
        if (hit != nil && hit != stack) return hit;
    }
    return OriginalFullscreenActionsHitTest != NULL
        ? ((UIView *(*)(id, SEL, CGPoint, UIEvent *))OriginalFullscreenActionsHitTest)(receiver, selector, point, event)
        : nil;
}

static BOOL WolFoxStackHasVisibleButton(UIStackView *stack) {
    for (UIView *view in stack.arrangedSubviews) {
        if (!view.hidden) return YES;
    }
    return NO;
}

// Keep each row in the saved left-to-right order. A group can have more than
// one button (speed has three); those keep their own order.
static void WolFoxSortZoneStack(UIStackView *stack, NSString *zone) {
    NSArray<NSString *> *order = WolFoxOverlayZoneOrder(zone);
    NSArray<UIView *> *current = stack.arrangedSubviews;
    // Within a group: the order the buttons were made in, flipped in the left
    // column so it reads + 1x - from the top.
    const BOOL column = [zone isEqualToString:WolFoxOverlayZoneLeft];
    NSArray<UIView *> *sorted = [current sortedArrayWithOptions:NSSortStable
                                                usingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        NSUInteger left = [order indexOfObject:objc_getAssociatedObject(a, WolFoxOverlayGroupAssociation) ?: @""];
        NSUInteger right = [order indexOfObject:objc_getAssociatedObject(b, WolFoxOverlayGroupAssociation) ?: @""];
        if (left != right) return left < right ? NSOrderedAscending : NSOrderedDescending;
        NSUInteger madeA = [objc_getAssociatedObject(a, WolFoxOverlayMadeAssociation) unsignedIntegerValue];
        NSUInteger madeB = [objc_getAssociatedObject(b, WolFoxOverlayMadeAssociation) unsignedIntegerValue];
        if (madeA == madeB) return NSOrderedSame;
        return (madeA < madeB) != column ? NSOrderedAscending : NSOrderedDescending;
    }];
    for (UIView *view in sorted) {
        objc_setAssociatedObject(view, (__bridge const void *)WolFoxColumnStackView.class,
                                 objc_getAssociatedObject(view, WolFoxOverlayGroupAssociation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if ([sorted isEqualToArray:current]) return;
    for (NSUInteger index = 0; index < sorted.count; index++) {
        [stack removeArrangedSubview:sorted[index]];
        [stack insertArrangedSubview:sorted[index] atIndex:index];
    }
}

static BOOL WolFoxViewShown(UIView *view) {
    for (UIView *current = view; current != nil; current = current.superview) {
        if (current.hidden || current.alpha < 0.05) return NO;
    }
    return !CGRectIsEmpty(view.bounds);
}

// Leftmost of YouTube's buttons in the top row, found from the gear.
static void WolFoxFindTopRowEdge(UIView *view, UIView *overlay, NSArray<UIView *> *excluded,
                                 CGFloat rowY, CGFloat *minX) {
    if (view.hidden || view.alpha < 0.05 || [excluded containsObject:view]) return;
    NSString *name = NSStringFromClass(view.class);
    if ([view isKindOfClass:UIControl.class] || [name containsString:@"Button"] ||
        [name containsString:@"Switch"] || [name containsString:@"Toggle"]) {
        CGRect frame = [view convertRect:view.bounds toView:overlay];
        if (CGRectGetWidth(frame) > 4.0 && CGRectGetWidth(frame) < 120.0 &&
            fabs(CGRectGetMidY(frame) - rowY) < 14.0 &&
            CGRectGetMidX(frame) > CGRectGetWidth(overlay.bounds) * 0.4 &&
            WolFoxViewShown(view)) {
            *minX = MIN(*minX, CGRectGetMinX(frame));
        }
    }
    for (UIView *subview in view.subviews) {
        WolFoxFindTopRowEdge(subview, overlay, excluded, rowY, minX);
    }
}

// The enter or exit fullscreen button. Its YTEnterExitFullscreenButtonView
// wrapper can sit at alpha 0 while the button inside is shown, and there can
// be more than one; prefer the one on screen, else one that is fading in.
static void WolFoxCollectFullscreenButtons(UIView *view, NSMutableArray<UIView *> *found) {
    if (view.hidden) return;
    NSString *identifier = view.accessibilityIdentifier;
    if ([identifier isEqualToString:@"id.player.watch.fullscreen.button"] ||
        [identifier isEqualToString:@"id.player.watch.exit_fullscreen.button"]) {
        [found addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) WolFoxCollectFullscreenButtons(subview, found);
}

static UIView *WolFoxFullscreenAnchor(UIView *root) {
    NSMutableArray<UIView *> *found = [NSMutableArray array];
    WolFoxCollectFullscreenButtons(root, found);
    for (UIView *view in found) if (WolFoxViewShown(view)) return view;
    for (UIView *view in found) {
        BOOL hidden = NO;
        for (UIView *current = view; current != nil; current = current.superview) hidden = hidden || current.hidden;
        if (!hidden && view.window != nil && !CGRectIsEmpty(view.bounds)) return view;
    }
    return nil;
}

// right and centerY are in the coordinates of the row's own superview.
static void WolFoxPlaceZoneStack(UIStackView *stack, UIView *overlay, CGFloat right, CGFloat centerY) {
    CGSize size = [stack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    size.height = 40.0;
    const CGFloat minimum = stack.superview == overlay
        ? CGRectGetMinX(overlay.safeAreaLayoutGuide.layoutFrame) + 8.0 : 8.0;
    const CGFloat left = MAX(minimum, right - size.width);
    CGRect frame = CGRectMake(left, round(centerY - size.height * 0.5), right - left, size.height);
    if (!CGRectEqualToRect(stack.frame, frame)) {
        [UIView performWithoutAnimation:^{
            stack.frame = frame;
            [stack layoutIfNeeded];
        }];
    }
    objc_setAssociatedObject(stack, WolFoxOverlayPlacedAssociation,
                             [NSValue valueWithCGSize:overlay.bounds.size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// YouTube's buttons can't be found while they fade out; keep the last spot
// so our row fades with them instead of vanishing first. A spot from another
// player size (rotation, fullscreen) is stale.
static BOOL WolFoxZoneStackWasPlaced(UIStackView *stack, UIView *overlay) {
    NSValue *size = objc_getAssociatedObject(stack, WolFoxOverlayPlacedAssociation);
    return size != nil && CGSizeEqualToSize(size.CGSizeValue, overlay.bounds.size);
}

// YouTube's top-right buttons in the saved order. YouTube lays them out right
// to left in one container, skipping hidden ones; this keeps its right edge
// and spacing and only changes which button sits where.
static UIView *WolFoxFindIdentified(UIView *view, NSString *identifier, NSArray<UIView *> *skip, int depth) {
    if (depth > 8 || [skip containsObject:view]) return nil;
    if ([view.accessibilityIdentifier isEqualToString:identifier]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = WolFoxFindIdentified(subview, identifier, skip, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

// A row's visible buttons by group (speed has three buttons in one group):
// each group's id, total width and last button.
static void WolFoxStackGroups(UIStackView *stack, NSMutableArray<NSString *> *names,
                              NSMutableArray<NSNumber *> *widths, NSMutableArray<UIView *> *lastViews) {
    NSString *current = nil;
    for (UIView *view in stack.arrangedSubviews) {
        if (view.hidden) continue;
        NSString *group = objc_getAssociatedObject(view, WolFoxOverlayGroupAssociation) ?: @"";
        // The row can squeeze a button; a text one's own width is its title's.
        const CGFloat width = ceil(MAX([view systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].width,
                                       view.intrinsicContentSize.width));
        if (current != nil && [group isEqualToString:current]) {
            widths[widths.count - 1] = @(widths.lastObject.doubleValue + stack.spacing + width);
            lastViews[lastViews.count - 1] = view;
        } else {
            current = group;
            [names addObject:group];
            [widths addObject:@(width)];
            [lastViews addObject:view];
        }
    }
}

// Spreads a row's groups over slots (rects in the row's superview with 4pt
// of padding each side) using custom spacing between groups, so one row can
// sit among YouTube's buttons. Returns the row's frame. No slots: normal spacing.
static CGRect WolFoxSpreadStackOverSlots(UIStackView *stack, NSArray<NSValue *> *slots,
                                         NSArray<NSNumber *> *widths, NSArray<UIView *> *lastViews) {
    NSMapTable<UIView *, NSNumber *> *spacing = [NSMapTable strongToStrongObjectsMapTable];
    for (NSUInteger index = 0; index + 1 < slots.count; index++) {
        const CGFloat gap = CGRectGetMinX(slots[index + 1].CGRectValue) - CGRectGetMinX(slots[index].CGRectValue) -
            widths[index].doubleValue;
        [spacing setObject:@(MAX(0.0, round(gap))) forKey:lastViews[index]];
    }
    for (UIView *view in stack.arrangedSubviews) {
        const CGFloat want = [spacing objectForKey:view] != nil ? [spacing objectForKey:view].doubleValue
                                                                : UIStackViewSpacingUseDefault;
        if ([stack customSpacingAfterView:view] != want) [stack setCustomSpacing:want afterView:view];
    }
    if (slots.count == 0) return CGRectZero;
    const CGRect first = slots.firstObject.CGRectValue;
    const CGFloat left = CGRectGetMinX(first) + 4.0;
    return CGRectMake(round(left), round(CGRectGetMidY(first) - 20.0),
                      ceil(CGRectGetMaxX(slots.lastObject.CGRectValue) - 4.0 - left), 40.0);
}

static void WolFoxSetStackFrame(UIStackView *stack, CGRect frame) {
    if (!CGRectEqualToRect(stack.frame, frame)) {
        [UIView performWithoutAnimation:^{
            stack.frame = frame;
            [stack layoutIfNeeded];
        }];
    } else {
        [stack layoutIfNeeded];
    }
}


// YouTube puts its top buttons back in its own spots whenever it lays the
// row out (controls showing, fullscreen), a frame before our layout runs.
// A moved button is pinned: its frame setters keep our spot, kept as an
// inset from the row's right edge since YouTube lays the row out from there.
static const void *WolFoxTopPinAssociation = &WolFoxTopPinAssociation;
static const void *WolFoxTopMetricsAssociation = &WolFoxTopMetricsAssociation;
static NSHashTable<UIView *> *WolFoxPinnedTopItems;
typedef struct { Class cls; IMP frame; IMP center; } WolFoxPinHook;
static WolFoxPinHook WolFoxPinHooks[8];
static int WolFoxPinHookCount;

static IMP WolFoxPinOriginal(id view, BOOL center) {
    for (Class cls = object_getClass(view); cls != Nil; cls = class_getSuperclass(cls)) {
        for (int index = 0; index < WolFoxPinHookCount; index++) {
            if (WolFoxPinHooks[index].cls == cls) return center ? WolFoxPinHooks[index].center : WolFoxPinHooks[index].frame;
        }
    }
    return NULL;
}

static BOOL WolFoxPinnedX(UIView *view, CGFloat width, CGFloat *x) {
    NSValue *pin = objc_getAssociatedObject(view, WolFoxTopPinAssociation);
    if (pin == nil || view.superview == nil) return NO;
    const CGPoint value = pin.CGPointValue;
    if (fabs(width - value.y) > 0.5) return NO;
    *x = CGRectGetWidth(view.superview.bounds) - value.x - width;
    return YES;
}

static void WolFoxPinnedSetFrame(UIView *view, SEL selector, CGRect frame) {
    CGFloat x;
    if (WolFoxPinnedX(view, CGRectGetWidth(frame), &x)) frame.origin.x = x;
    IMP original = WolFoxPinOriginal(view, NO);
    if (original != NULL) ((void (*)(id, SEL, CGRect))original)(view, selector, frame);
}

static void WolFoxPinnedSetCenter(UIView *view, SEL selector, CGPoint center) {
    CGFloat x;
    const CGFloat width = CGRectGetWidth(view.bounds);
    if (WolFoxPinnedX(view, width, &x)) center.x = x + width * 0.5;
    IMP original = WolFoxPinOriginal(view, YES);
    if (original != NULL) ((void (*)(id, SEL, CGPoint))original)(view, selector, center);
}

static void WolFoxPinTopItem(UIView *item, CGFloat x) {
    Class cls = object_getClass(item);
    BOOL hooked = NO;
    for (int index = 0; index < WolFoxPinHookCount; index++) hooked = hooked || WolFoxPinHooks[index].cls == cls;
    if (!hooked) {
        if (WolFoxPinHookCount >= 8) return;
        WolFoxPinHook *hook = &WolFoxPinHooks[WolFoxPinHookCount];
        NSString *name = NSStringFromClass(cls);
        if (!WolFoxInstallInstanceHook(name, @"setFrame:", (IMP)WolFoxPinnedSetFrame, &hook->frame) ||
            !WolFoxInstallInstanceHook(name, @"setCenter:", (IMP)WolFoxPinnedSetCenter, &hook->center)) return;
        hook->cls = cls;
        WolFoxPinHookCount++;
    }
    if (WolFoxPinnedTopItems == nil) WolFoxPinnedTopItems = [NSHashTable weakObjectsHashTable];
    [WolFoxPinnedTopItems addObject:item];
    const CGFloat width = CGRectGetWidth(item.frame);
    objc_setAssociatedObject(item, WolFoxTopPinAssociation,
                             [NSValue valueWithCGPoint:CGPointMake(CGRectGetWidth(item.superview.bounds) - x - width, width)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WolFoxUnpinTopItem(UIView *item) {
    if (objc_getAssociatedObject(item, WolFoxTopPinAssociation) == nil) return;
    objc_setAssociatedObject(item, WolFoxTopPinAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [WolFoxPinnedTopItems removeObject:item];
    [item.superview setNeedsLayout];
    [item.superview.superview setNeedsLayout];
}

static void WolFoxUnpinTopRow(UIView *overlay) {
    for (UIView *item in WolFoxPinnedTopItems.allObjects) {
        if ([item isDescendantOfView:overlay]) WolFoxUnpinTopItem(item);
    }
}

static void WolFoxMoveNativeTopItem(UIView *item, UIView *container, NSArray<UIView *> *items, CGFloat x) {
    const CGRect old = item.frame;
    CGRect frame = old;
    frame.origin.x = x;
    // Hidden views YouTube stacked on the same spot move along.
    for (UIView *sibling in container.subviews) {
        if (sibling == item || [items containsObject:sibling]) continue;
        if (fabs(CGRectGetMinX(sibling.frame) - CGRectGetMinX(old)) < 0.5 &&
            fabs(CGRectGetMinY(sibling.frame) - CGRectGetMinY(old)) < 0.5 && (sibling.hidden || sibling.alpha < 0.05)) {
            CGRect moved = sibling.frame;
            moved.origin.x = frame.origin.x;
            [UIView performWithoutAnimation:^{ sibling.frame = moved; }];
        }
    }
    // Not animated along with the controls fading in.
    WolFoxPinTopItem(item, x);
    [UIView performWithoutAnimation:^{ item.frame = frame; }];
}

// With some of YTKACE's top buttons saved between YouTube's, YouTube's are
// spaced out to leave a slot for each, and the slots are kept on the row for
// YTKACELayoutTopStack.
static void WolFoxOrderNativeTopRow(UIView *overlay, NSArray<UIView *> *skip, UIStackView *top) {
    NSArray<NSString *> *order = WolFoxNativeTopOrder();
    NSArray<NSString *> *stored = WolFoxTopRowOrder();
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
    NSMutableArray<UIView *> *lastViews = [NSMutableArray array];
    WolFoxStackGroups(top, names, widths, lastViews);
    BOOL mixed = NO, seenNative = NO;
    for (NSString *name in stored) {
        if ([order containsObject:name]) seenNative = YES;
        else if (seenNative && [names containsObject:name]) mixed = YES;
    }
    if (!mixed) objc_setAssociatedObject(top, WolFoxTopSlotsAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!mixed && [order isEqualToArray:WolFoxNativeTopDefaultOrder()]) {
        WolFoxUnpinTopRow(overlay);
        return;
    }
    NSDictionary *identifiers = WolFoxNativeTopIdentifiers();
    UIView *container = nil;
    NSMutableDictionary<NSString *, UIView *> *items = [NSMutableDictionary dictionary];
    for (NSString *name in order) {
        UIView *view = WolFoxFindIdentified(overlay, identifiers[name], skip, 0);
        if (view == nil) continue;
        // The container's direct child holding this button.
        UIView *item = view;
        while (item.superview != nil && item.superview != overlay && item.superview.superview != overlay) {
            item = item.superview;
        }
        if (item.superview == overlay) continue;
        if (container == nil) container = item.superview;
        if (item.superview != container) {
            objc_setAssociatedObject(top, WolFoxTopSlotsAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            WolFoxUnpinTopRow(overlay);
            return;
        }
        items[name] = item;
    }
    NSMutableArray<UIView *> *visible = [NSMutableArray array];
    for (NSString *name in order) {
        UIView *item = items[name];
        if (item != nil && !item.hidden && item.alpha > 0.05 && WolFoxViewShown(item)) [visible addObject:item];
    }
    // Faded out: keep every spot as it is.
    if (visible.count == 0) return;
    for (UIView *item in items.allValues) {
        if (![visible containsObject:item]) WolFoxUnpinTopItem(item);
    }
    if (!mixed && visible.count < 2) return;
    NSArray<UIView *> *byX = [visible sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return [@(CGRectGetMinX(a.frame)) compare:@(CGRectGetMinX(b.frame))];
    }];
    // Already in place, unless slots have to be made.
    if (!mixed && [byX isEqualToArray:visible]) return;
    // YouTube's right edge and gap, measured while nothing is pinned (pinned
    // spots are ours) and kept as an inset from the row's right edge.
    BOOL pinned = NO;
    for (UIView *item in visible) pinned = pinned || objc_getAssociatedObject(item, WolFoxTopPinAssociation) != nil;
    NSValue *metrics = objc_getAssociatedObject(container, WolFoxTopMetricsAssociation);
    if (!pinned || metrics == nil) {
        CGFloat maxX = 0.0;
        for (UIView *item in visible) maxX = MAX(maxX, CGRectGetMaxX(item.frame));
        NSMutableArray<NSNumber *> *gaps = [NSMutableArray array];
        for (NSUInteger index = 1; index < byX.count; index++) {
            [gaps addObject:@(CGRectGetMinX(byX[index].frame) - CGRectGetMaxX(byX[index - 1].frame))];
        }
        [gaps sortUsingSelector:@selector(compare:)];
        const CGFloat measured = gaps.count != 0 ? MAX(0.0, gaps[gaps.count / 2].doubleValue) : 24.0;
        metrics = [NSValue valueWithCGPoint:CGPointMake(CGRectGetWidth(container.bounds) - maxX, measured)];
        objc_setAssociatedObject(container, WolFoxTopMetricsAssociation, metrics, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat right = CGRectGetWidth(container.bounds) - metrics.CGPointValue.x;
    const CGFloat gap = metrics.CGPointValue.y;
    if (!mixed) {
        for (UIView *item in visible.reverseObjectEnumerator) {
            WolFoxMoveNativeTopItem(item, container, items.allValues, right - CGRectGetWidth(item.frame));
            right = CGRectGetMinX(item.frame) - gap;
        }
        return;
    }
    // Left to right: ours the order doesn't name first, then the saved order.
    NSMutableArray *sequence = [NSMutableArray array];
    for (NSString *name in names) {
        if (![stored containsObject:name]) [sequence addObject:name];
    }
    for (NSString *name in stored) {
        if ([names containsObject:name] || [visible containsObject:items[name] ?: (id)NSNull.null]) {
            if (![sequence containsObject:name]) [sequence addObject:name];
        }
    }
    for (NSString *name in order) {
        if ([visible containsObject:items[name] ?: (id)NSNull.null] && ![sequence containsObject:name]) [sequence addObject:name];
    }
    const CGFloat midY = CGRectGetMidY(visible.firstObject.frame);
    NSMutableDictionary<NSString *, NSValue *> *slotByName = [NSMutableDictionary dictionary];
    for (NSString *name in sequence.reverseObjectEnumerator) {
        UIView *item = items[name];
        if (item != nil) {
            WolFoxMoveNativeTopItem(item, container, items.allValues, right - CGRectGetWidth(item.frame));
            right = CGRectGetMinX(item.frame) - gap;
            continue;
        }
        // YouTube spaces its icons, not its tap areas: our buttons pad their
        // icon by 8pt a side, so that padding sits in YouTube's gap.
        const CGFloat width = widths[[names indexOfObject:name]].doubleValue;
        const CGFloat cell = MAX(0.0, width - 16.0);
        const CGRect slot = CGRectMake(right - cell - 8.0 - 4.0, midY - 20.0, width + 8.0, 40.0);
        slotByName[name] = [NSValue valueWithCGRect:[container convertRect:slot toView:overlay]];
        right -= cell + gap;
    }
    NSMutableArray<NSValue *> *slots = [NSMutableArray array];
    for (NSString *name in names) {
        NSValue *slot = slotByName[name];
        // The row's own order has to match the saved one.
        if (slot == nil || (slots.count != 0 && CGRectGetMinX(slot.CGRectValue) <= CGRectGetMinX(slots.lastObject.CGRectValue))) {
            objc_setAssociatedObject(top, WolFoxTopSlotsAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        [slots addObject:slot];
    }
    objc_setAssociatedObject(top, WolFoxTopSlotsAssociation, @[slots, widths, lastViews], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The gap YouTube leaves between its top buttons (24pt on iPhone and iPad).
static CGFloat WolFoxNativeTopGap(UIView *overlay, NSArray<UIView *> *skip) {
    NSMutableArray<NSValue *> *frames = [NSMutableArray array];
    for (NSString *identifier in WolFoxNativeTopIdentifiers().allValues) {
        UIView *view = WolFoxFindIdentified(overlay, identifier, skip, 0);
        if (view == nil || !WolFoxViewShown(view)) continue;
        // The row's own child holding it, as the row lays those out.
        UIView *item = view;
        while (item.superview != nil && item.superview != overlay && item.superview.superview != overlay) item = item.superview;
        [frames addObject:[NSValue valueWithCGRect:[item convertRect:item.bounds toView:overlay]]];
    }
    [frames sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        return [@(CGRectGetMinX(a.CGRectValue)) compare:@(CGRectGetMinX(b.CGRectValue))];
    }];
    NSMutableArray<NSNumber *> *gaps = [NSMutableArray array];
    for (NSUInteger index = 1; index < frames.count; index++) {
        const CGFloat gap = CGRectGetMinX(frames[index].CGRectValue) - CGRectGetMaxX(frames[index - 1].CGRectValue);
        if (gap > 0.0) [gaps addObject:@(gap)];
    }
    if (gaps.count == 0) return 24.0;
    [gaps sortUsingSelector:@selector(compare:)];
    return gaps[gaps.count / 2].doubleValue;
}

// YouTube sizes the video title to stop at its own top buttons. With
// buttons moved or ours added it runs under them; a mask ends it short of
// the leftmost button in the row.
static void WolFoxClipTitle(UIView *overlay, BOOL changed) {
    UIView *gear = WolFoxOverflowControl(overlay);
    if (gear == nil || !WolFoxViewShown(gear)) return;
    const CGFloat rowY = CGRectGetMidY([gear convertRect:gear.bounds toView:overlay]);
    CGFloat edge = CGRectGetMinX([gear convertRect:gear.bounds toView:overlay]);
    WolFoxFindTopRowEdge(overlay, overlay, @[], rowY, &edge);
    Class controls = NSClassFromString(@"YTMainAppControlsOverlayView");
    UIView *host = gear.superview;
    while (host != nil && controls != Nil && ![host isKindOfClass:controls]) host = host.superview;
    if (host == nil) return;
    for (UIView *view in host.subviews) {
        if (![NSStringFromClass(view.class) isEqualToString:@"_ASDisplayView"]) continue;
        const CGRect frame = [view convertRect:view.bounds toView:overlay];
        if (CGRectGetMinX(frame) > CGRectGetWidth(overlay.bounds) * 0.3 || CGRectGetWidth(frame) < 100.0 ||
            CGRectGetMinY(frame) > rowY || CGRectGetMaxY(frame) < rowY) continue;
        const CGFloat limit = edge - 8.0 - CGRectGetMinX(frame);
        CALayer *mask = view.layer.mask;
        if (!changed || limit >= CGRectGetWidth(frame)) {
            if (mask != nil && [mask.name isEqualToString:@"WolFoxTitleClip"]) view.layer.mask = nil;
            continue;
        }
        if (mask != nil && ![mask.name isEqualToString:@"WolFoxTitleClip"]) continue;
        // Fades out over the last 24pt instead of cutting a letter in half.
        if (mask == nil) {
            CAGradientLayer *fade = [CAGradientLayer layer];
            fade.name = @"WolFoxTitleClip";
            fade.startPoint = CGPointMake(0.0, 0.5);
            fade.endPoint = CGPointMake(1.0, 0.5);
            fade.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
            mask = fade;
            view.layer.mask = mask;
        }
        const CGFloat width = MAX(1.0, limit) + 200.0;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        mask.frame = CGRectMake(-200.0, -200.0, width, CGRectGetHeight(view.bounds) + 400.0);
        if ([mask isKindOfClass:CAGradientLayer.class]) {
            ((CAGradientLayer *)mask).locations = @[@0.0, @(MAX(0.0, (width - 24.0) / width)), @1.0];
        }
        [CATransaction commit];
    }
}

static BOOL WolFoxLayoutTopStack(UIView *overlay, NSDictionary<NSString *, UIStackView *> *stacks) {
    UIStackView *stack = stacks[WolFoxOverlayZoneTop];
    NSArray *spread = objc_getAssociatedObject(stack, WolFoxTopSlotsAssociation);
    if (spread != nil) {
        WolFoxSetStackFrame(stack, WolFoxSpreadStackOverSlots(stack, spread[0], spread[1], spread[2]));
        objc_setAssociatedObject(stack, WolFoxOverlayPlacedAssociation,
                                 [NSValue valueWithCGSize:overlay.bounds.size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }
    WolFoxSpreadStackOverSlots(stack, nil, nil, nil);
    UIView *gear = WolFoxOverflowControl(overlay) ?:
        WolFoxFindSettingsControl(overlay, stacks[WolFoxOverlayZoneBelow]);
    if (gear == nil) return WolFoxZoneStackWasPlaced(stack, overlay);
    CGRect gearFrame = [gear convertRect:gear.bounds toView:overlay];
    CGFloat minX = CGRectGetMinX(gearFrame);
    WolFoxFindTopRowEdge(overlay, overlay, stacks.allValues, CGRectGetMidY(gearFrame), &minX);
    // YouTube's gap between icons; our buttons pad their icon by 8pt.
    WolFoxPlaceZoneStack(stack, overlay, minX - MAX(0.0, WolFoxNativeTopGap(overlay, stacks.allValues) - 8.0),
                         CGRectGetMidY(gearFrame));
    return YES;
}

// The left column sits at the player's left edge, centered on the play
// button's row, between the title and the time.
static BOOL WolFoxLayoutLeftStack(UIView *overlay, WolFoxColumnStackView *stack) {
    if (CGRectIsEmpty(overlay.bounds)) return NO;
    const CGRect safe = overlay.safeAreaLayoutGuide.layoutFrame;
    const CGFloat top = MAX(CGRectGetMinY(safe), 0.0) + 56.0;
    CGFloat bottom = MIN(CGRectGetMaxY(safe), CGRectGetHeight(overlay.bounds)) - 60.0;
    // Above the time and chapter row, which the fullscreen button sits on.
    UIView *fullscreen = WolFoxFullscreenAnchor(overlay.superview ?: overlay);
    if (fullscreen != nil) {
        const CGRect frame = [fullscreen convertRect:fullscreen.bounds toView:overlay];
        if (CGRectGetMinY(frame) > top + 40.0) bottom = MIN(bottom, CGRectGetMinY(frame) - 8.0);
    }
    const CGFloat left = round(CGRectGetMinX(safe) + 12.0);
    // YouTube's previous (or play) button: a wrapped column mustn't reach it.
    CGFloat limit = CGFLOAT_MAX;
    for (NSString *name in @[@"_previousButtonView", @"_playPauseButton"]) {
        Ivar ivar = class_getInstanceVariable(object_getClass(overlay), name.UTF8String);
        UIView *view = ivar != NULL ? object_getIvar(overlay, ivar) : nil;
        if (![view isKindOfClass:UIView.class] || view.hidden || view.alpha < 0.05 || view.window == nil) continue;
        limit = CGRectGetMinX([view convertRect:view.bounds toView:overlay]) - 8.0 - left;
        break;
    }
    // Full size when it fits; otherwise smaller (to 70%) so it fits in fewer
    // columns, only as much as needed.
    const CGFloat room = MAX(40.0, bottom - top);
    CGFloat scale = 1.0;
    CGSize size = CGSizeZero;
    for (scale = 1.0; ; scale -= 0.05) {
        stack.maximumHeight = room / scale;
        size = [stack columnSize];
        if (size.width * scale <= limit || scale <= 0.7 + 0.001) break;
    }
    if (size.width <= 0.0) return NO;
    const CGSize shown = CGSizeMake(size.width * scale, size.height * scale);
    const CGFloat centerY = CGRectGetMidY(overlay.bounds);
    const CGFloat y = MIN(MAX(top, round(centerY - shown.height * 0.5)), MAX(top, bottom - shown.height));
    const CGAffineTransform transform = scale < 1.0 ? CGAffineTransformMakeScale(scale, scale) : CGAffineTransformIdentity;
    const CGRect bounds = CGRectMake(0.0, 0.0, ceil(size.width), ceil(size.height));
    const CGPoint center = CGPointMake(left + shown.width * 0.5, y + shown.height * 0.5);
    if (!CGRectEqualToRect(stack.bounds, bounds) || !CGPointEqualToPoint(stack.center, center) ||
        !CGAffineTransformEqualToTransform(stack.transform, transform)) {
        [UIView performWithoutAnimation:^{
            stack.transform = transform;
            stack.bounds = bounds;
            stack.center = center;
        }];
    }
    return YES;
}

static BOOL WolFoxLayoutBottomStack(UIView *overlay, NSDictionary<NSString *, UIStackView *> *stacks) {
    UIStackView *stack = stacks[WolFoxOverlayZoneBottom];
    UIView *fullscreen = WolFoxFullscreenAnchor(overlay.superview ?: overlay);
    if (fullscreen == nil) {
        // the bar may still be loading; look again shortly
        NSUInteger tries = [objc_getAssociatedObject(stack, WolFoxOverlayRetryAssociation) unsignedIntegerValue];
        if (tries < 6) {
            objc_setAssociatedObject(stack, WolFoxOverlayRetryAssociation, @(tries + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            __weak UIView *weakOverlay = overlay;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakOverlay setNeedsLayout];
            });
        }
        return WolFoxZoneStackWasPlaced(stack, overlay);
    }
    objc_setAssociatedObject(stack, WolFoxOverlayRetryAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGRect frame = [fullscreen convertRect:fullscreen.bounds toView:overlay];
    if (!CGRectEqualToRect(frame, [objc_getAssociatedObject(stack, WolFoxOverlayAnchorAssociation) CGRectValue])) {
        objc_setAssociatedObject(stack, WolFoxOverlayAnchorAssociation, [NSValue valueWithCGRect:frame],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        WolFoxDebugLog(@"layout", @"bottom anchor %@ in %@ overlay=%@", NSStringFromCGRect(frame),
                       NSStringFromClass(fullscreen.superview.class), NSStringFromCGSize(overlay.bounds.size));
    }
    WolFoxPlaceZoneStack(stack, overlay, CGRectGetMinX(frame) - 4.0, CGRectGetMidY(frame));
    return YES;
}

// Fullscreen zone: right after the pill of buttons under the progress bar,
// on a frosted pill like YouTube's. Only while that bar is shown.
static UIView *WolFoxFindFullscreenActions(UIView *view, int depth) {
    if (depth > 10 || view.hidden) return nil;
    if ([NSStringFromClass(view.class) isEqualToString:@"YTFullscreenActionsView"]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = WolFoxFindFullscreenActions(subview, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static void WolFoxCollectGlass(UIView *view, NSMutableArray<UIView *> *found, int depth) {
    if (depth > 8 || view.hidden) return;
    if ([NSStringFromClass(view.class) isEqualToString:@"YTFrostedGlassView"] && CGRectGetWidth(view.bounds) > 1.0) {
        [found addObject:view];
    }
    for (UIView *subview in view.subviews) WolFoxCollectGlass(subview, found, depth + 1);
}

extern NSArray<NSDictionary *> *WolFoxFullscreenGroups;
extern BOOL WolFoxFullscreenGroupFrame(NSString *group, UIView *view, CGRect *frame);

// Our buttons go in YouTube's pill: the bar code adds an empty node as wide
// as each of our groups, in the saved order among YouTube's buttons, and the
// row is laid over them with the gaps between groups matching.
static BOOL WolFoxLayoutFullscreenStack(UIView *overlay, UIStackView *stack) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSNumber *> *widths = [NSMutableArray array];
    NSMutableArray<UIView *> *lastViews = [NSMutableArray array];
    WolFoxStackGroups(stack, names, widths, lastViews);
    NSMutableArray<NSDictionary *> *groups = [NSMutableArray array];
    for (NSUInteger index = 0; index < names.count; index++) {
        [groups addObject:@{@"id": names[index], @"width": @(widths[index].doubleValue + 8.0)}];
    }
    const BOOL wanted = groups.count != 0;
    // Nothing in this zone and no room left in YouTube's pill: skip the search.
    if (!wanted && WolFoxFullscreenGroups.count == 0) return NO;
    UIView *actions = WolFoxFindFullscreenActions(overlay.superview ?: overlay, 0);
    if (![groups isEqualToArray:WolFoxFullscreenGroups ?: @[]]) {
        WolFoxFullscreenGroups = wanted ? [groups copy] : nil;
        [actions setNeedsLayout];
        __weak UIView *weakOverlay = overlay;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakOverlay setNeedsLayout];
        });
    }
    if (!wanted || actions == nil || actions.window == nil || CGRectIsEmpty(actions.bounds)) return NO;
    // Outside fullscreen YouTube keeps the bar around, below the player.
    const CGRect bar = [actions convertRect:actions.bounds toView:overlay];
    if (CGRectGetMaxY(bar) > CGRectGetHeight(overlay.bounds) + 1.0 || CGRectGetMinY(bar) < 0.0 ||
        !CGRectIntersectsRect(bar, overlay.bounds)) return NO;
    NSMutableArray<NSValue *> *slots = [NSMutableArray array];
    for (NSString *name in names) {
        CGRect frame;
        if (!WolFoxFullscreenGroupFrame(name, actions, &frame)) break;
        [slots addObject:[NSValue valueWithCGRect:frame]];
    }
    // In YouTube's bar, above its glass, so it fades and hides with the bar.
    if (stack.superview != actions) [actions addSubview:stack];
    [actions bringSubviewToFront:stack];
    // The bar fades itself with the controls; the row just follows it.
    stack.alpha = 1.0;
    stack.userInteractionEnabled = YES;
    CGRect frame;
    if (slots.count == names.count) {
        frame = WolFoxSpreadStackOverSlots(stack, slots, widths, lastViews);
        // The pill can finish its layout after ours; look again a few times.
        NSUInteger tries = [objc_getAssociatedObject(stack, WolFoxOverlayRetryAssociation) unsignedIntegerValue];
        if (CGRectEqualToRect(frame, stack.frame)) tries = 0;
        objc_setAssociatedObject(stack, WolFoxOverlayRetryAssociation, @(tries + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!CGRectEqualToRect(frame, stack.frame) && tries < 4) {
            __weak UIView *weakOverlay = overlay;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakOverlay setNeedsLayout];
            });
        }
    } else {
        // The empty nodes aren't laid out yet: the end of the pill.
        WolFoxSpreadStackOverSlots(stack, nil, nil, nil);
        NSMutableArray<UIView *> *glass = [NSMutableArray array];
        WolFoxCollectGlass(actions, glass, 0);
        UIView *pill = nil;
        for (UIView *view in glass) {
            if (pill == nil || CGRectGetMinX([view convertRect:view.bounds toView:actions]) <
                               CGRectGetMinX([pill convertRect:pill.bounds toView:actions])) pill = view;
        }
        if (pill == nil) return NO;
        const CGRect anchor = [pill convertRect:pill.bounds toView:actions];
        CGSize fitting = [stack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
        frame = CGRectMake(round(CGRectGetMaxX(anchor) - 4.0 - fitting.width),
                           round(CGRectGetMidY(anchor) - 20.0), ceil(fitting.width), 40.0);
    }
    WolFoxSetStackFrame(stack, frame);
    return YES;
}

// Features remember the last overlay that laid out, which can be another
// player's. Laying out the tapped button's overlay on touch down points them
// at the right player before the tap's action runs.
@interface WolFoxOverlayTapRouter : NSObject
+ (instancetype)sharedRouter;
- (void)buttonTouched:(UIButton *)button;
@end

@implementation WolFoxOverlayTapRouter

+ (instancetype)sharedRouter {
    static WolFoxOverlayTapRouter *router;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ router = [WolFoxOverlayTapRouter new]; });
    return router;
}

- (void)buttonTouched:(UIButton *)button {
    UIView *owner = objc_getAssociatedObject(button.superview, WolFoxOverlayOwnerAssociation);
    if (owner == nil) return;
    [owner setNeedsLayout];
    [owner layoutIfNeeded];
    // Like YouTube's own buttons: using one keeps the controls up.
    Class controllerClass = NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController");
    SEL reset = NSSelectorFromString(@"resetAutoHideTimer");
    for (UIResponder *responder = owner; responder != nil; responder = responder.nextResponder) {
        if (controllerClass == Nil || ![responder isKindOfClass:controllerClass]) continue;
        if ([responder respondsToSelector:reset]) ((void (*)(id, SEL))objc_msgSend)(responder, reset);
        break;
    }
}

@end

// YouTube laid its fullscreen bar out again (rotation, a new video): our
// row there follows the pill's new spots.
static const void *WolFoxSlotsSeenAssociation = &WolFoxSlotsSeenAssociation;
static const void *WolFoxButtonSizeAssociation = &WolFoxButtonSizeAssociation;

void WolFoxFullscreenBarDidLayout(UIView *actions) {
    for (UIStackView *stack in WolFoxFullscreenStacks.allObjects) {
        if (stack.superview != actions || stack.hidden) continue;
        // Only when the pill's spots for our buttons moved.
        NSMutableArray *seen = [NSMutableArray array];
        for (NSDictionary *group in WolFoxFullscreenGroups) {
            CGRect frame;
            if (WolFoxFullscreenGroupFrame(group[@"id"], actions, &frame)) [seen addObject:[NSValue valueWithCGRect:frame]];
        }
        if ([seen isEqualToArray:objc_getAssociatedObject(stack, WolFoxSlotsSeenAssociation) ?: @[]]) continue;
        objc_setAssociatedObject(stack, WolFoxSlotsSeenAssociation, seen, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *owner = objc_getAssociatedObject(stack, WolFoxOverlayOwnerAssociation);
        dispatch_async(dispatch_get_main_queue(), ^{ [owner setNeedsLayout]; });
    }
}

void WolFoxOverlayButtonResized(UIButton *button) {
    if (button == nil) return;
    const CGSize size = button.intrinsicContentSize;
    NSValue *old = objc_getAssociatedObject(button, WolFoxButtonSizeAssociation);
    if (old != nil && CGSizeEqualToSize(old.CGSizeValue, size)) return;
    objc_setAssociatedObject(button, WolFoxButtonSizeAssociation, [NSValue valueWithCGSize:size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (old == nil) return;
    __weak UIView *owner = objc_getAssociatedObject(button.superview, WolFoxOverlayOwnerAssociation);
    dispatch_async(dispatch_get_main_queue(), ^{ [owner setNeedsLayout]; });
}

// WolFox 1.2.0 overlay treatment: a readable dark/glass surface with the
// shared red accent. This changes appearance only; sizing, hit testing and
// the button's existing semantic direction remain untouched.
static void WolFoxStyleOverlayButton(UIButton *button) {
    button.tintColor = WolFoxAccentColor();
    button.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.78];
    button.layer.cornerRadius = 12.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [WolFoxAccentColor() colorWithAlphaComponent:0.52].CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.34;
    button.layer.shadowRadius = 4.0;
    button.layer.shadowOffset = CGSizeMake(0.0, 2.0);
    button.layer.masksToBounds = NO;
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
}

UIButton *WolFoxOverlayButton(UIStackView *stack,
                              NSString *identifier,
                              NSString *symbolName,
                              id target,
                              SEL action) {
    // the button may be in another zone's row after a layout change
    UIView *owner = objc_getAssociatedObject(stack, WolFoxOverlayOwnerAssociation) ?: stack.superview;
    NSDictionary<NSString *, UIStackView *> *stacks = owner != nil
        ? objc_getAssociatedObject(owner, WolFoxOverlayZoneStacksAssociation) : nil;
    for (UIStackView *row in stacks.allValues ?: @[stack]) {
        for (UIView *view in row.arrangedSubviews) {
            if (![view.accessibilityIdentifier isEqualToString:identifier] ||
                ![view isKindOfClass:UIButton.class]) continue;
            if (row != stack) {
                [row removeArrangedSubview:view];
                [view removeFromSuperview];
                [stack addArrangedSubview:view];
            }
            if (WolFoxCurrentOverlayGroup != nil) {
                objc_setAssociatedObject(view, WolFoxOverlayGroupAssociation, WolFoxCurrentOverlayGroup,
                                         OBJC_ASSOCIATION_COPY_NONATOMIC);
            }
            WolFoxStyleOverlayButton((UIButton *)view);
            return (UIButton *)view;
        }
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.accessibilityIdentifier = identifier;
    button.accessibilityLabel = identifier;
    WolFoxStyleOverlayButton(button);
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:21.0
                                                            weight:UIImageSymbolWeightMedium];
        [button setPreferredSymbolConfiguration:configuration
                                forImageInState:UIControlStateNormal];
        [button setImage:[UIImage systemImageNamed:symbolName
                                  withConfiguration:configuration]
                forState:UIControlStateNormal];
    }
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    [button addTarget:WolFoxOverlayTapRouter.sharedRouter action:@selector(buttonTouched:)
     forControlEvents:UIControlEventTouchDown];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:40.0].active = YES;
    [button.heightAnchor constraintEqualToConstant:40.0].active = YES;
    if (WolFoxCurrentOverlayGroup != nil) {
        objc_setAssociatedObject(button, WolFoxOverlayGroupAssociation, WolFoxCurrentOverlayGroup,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    // A group's buttons keep the order they were made in (speed: - 1x +).
    static NSUInteger made;
    objc_setAssociatedObject(button, WolFoxOverlayMadeAssociation, @(++made), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [stack addArrangedSubview:button];
    return button;
}

void WolFoxDuoDeskControlsLayout(UIView *controls);

static void WolFoxControlsOverlayLayout(UIView *receiver, SEL selector) {
    if (OriginalControlsOverlayLayout != NULL) {
        ((void (*)(id, SEL))OriginalControlsOverlayLayout)(receiver, selector);
    }

    NSDictionary<NSString *, UIStackView *> *stacks = WolFoxZoneStacks(receiver);
    UIStackView *stack = stacks[WolFoxOverlayZoneBelow];
    NSArray<NSDictionary *> *configurators = nil;
    @synchronized (WolFoxOverlayConfigurators) {
        configurators = [WolFoxOverlayConfigurators copy];
    }
    for (NSDictionary *entry in configurators) {
        WolFoxOverlayConfigurator configurator = entry[@"block"];
        NSString *identifier = entry[@"identifier"];
        WolFoxCurrentOverlayGroup = identifier;
        configurator(receiver, stacks[WolFoxOverlayButtonZone(identifier)] ?: stack);
    }
    WolFoxCurrentOverlayGroup = nil;
    for (NSString *zone in stacks) WolFoxSortZoneStack(stacks[zone], zone);
    WolFoxOrderNativeTopRow(receiver, stacks.allValues, stacks[WolFoxOverlayZoneTop]);
    BOOL aligned = WolFoxAlignOverlayStack(receiver, stack);
    stack.hidden = !WolFoxStackHasVisibleButton(stack) || !aligned;

    UIStackView *top = stacks[WolFoxOverlayZoneTop];
    top.hidden = !WolFoxStackHasVisibleButton(top) || !WolFoxLayoutTopStack(receiver, stacks);
    BOOL rowChanged = !top.hidden;
    for (UIView *item in WolFoxPinnedTopItems.allObjects) rowChanged = rowChanged || [item isDescendantOfView:receiver];
    WolFoxClipTitle(receiver, rowChanged);
    UIStackView *bottom = stacks[WolFoxOverlayZoneBottom];
    bottom.hidden = !WolFoxStackHasVisibleButton(bottom) || !WolFoxLayoutBottomStack(receiver, stacks);
    WolFoxColumnStackView *leftColumn = (WolFoxColumnStackView *)stacks[WolFoxOverlayZoneLeft];
    leftColumn.hidden = !WolFoxStackHasVisibleButton((UIStackView *)leftColumn) || !WolFoxLayoutLeftStack(receiver, leftColumn);
    UIStackView *fullscreen = stacks[WolFoxOverlayZoneFullscreen];
    // Always laid out: it also clears the room in YouTube's pill when empty.
    fullscreen.hidden = !WolFoxLayoutFullscreenStack(receiver, fullscreen);

    // Last, so the laptop-posture split moves the final positions.
    WolFoxDuoDeskControlsLayout(receiver);
}

void WolFoxRegisterOverlayConfigurator(NSString *identifier,
                                       WolFoxOverlayConfigurator configurator) {
    if (identifier.length == 0 || configurator == nil) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WolFoxOverlayConfigurators = [NSMutableArray array];
    });

    @synchronized (WolFoxOverlayConfigurators) {
        for (NSDictionary *entry in WolFoxOverlayConfigurators) {
            if ([entry[@"identifier"] isEqualToString:identifier]) {
                return;
            }
        }
        [WolFoxOverlayConfigurators addObject:@{
            @"identifier": identifier,
            @"block": [configurator copy]
        }];
    }

    WolFoxInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"layoutSubviews",
                              (IMP)WolFoxControlsOverlayLayout,
                              &OriginalControlsOverlayLayout);
    WolFoxInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"setOverlayVisible:",
                              (IMP)WolFoxControlsSetOverlayVisible,
                              &OriginalControlsSetOverlayVisible);
    WolFoxInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"setControlsOverlayVisible:",
                              (IMP)WolFoxControlsSetControlsVisible,
                              &OriginalControlsSetControlsVisible);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"setOverlayVisible:",
                              (IMP)WolFoxVideoSetOverlayVisible,
                              &OriginalVideoSetOverlayVisible);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"setControlsOverlayVisible:",
                              (IMP)WolFoxVideoSetControlsVisible,
                              &OriginalVideoSetControlsVisible);
    WolFoxInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"setHidden:",
                              (IMP)WolFoxControlsSetHidden,
                              &OriginalControlsSetHidden);
}

static UIViewController *WolFoxSheetPresenter(UIView *sourceView) {
    UIResponder *responder = sourceView;
    for (NSUInteger depth = 0; responder != nil && depth < 20; depth++) {
        SEL eventsSelector = NSSelectorFromString(@"eventsDelegate");
        if ([responder respondsToSelector:eventsSelector]) {
            id events = ((id (*)(id, SEL))objc_msgSend)(responder, eventsSelector);
            if (events != nil) return events;
        }
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController != nil && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top;
}

id WolFoxMakeSheet(NSString *title, NSString *subtitle) {
    Class sheetClass = NSClassFromString(@"YTDefaultSheetController");
    if (sheetClass == Nil) return nil;
    SEL init = NSSelectorFromString(
        @"initWithSheetStyle:headerTitle:headerSubtitle:shouldDisableLogging:delegate:parentResponder:");
    if ([sheetClass instancesRespondToSelector:init]) {
        return ((id (*)(id, SEL, NSInteger, id, id, BOOL, id, id))objc_msgSend)(
            [sheetClass alloc], init, 2, title, subtitle, NO, nil, nil);
    }
    SEL makeSheet = NSSelectorFromString(@"sheetControllerWithMessage:subMessage:delegate:parentResponder:");
    if (![sheetClass respondsToSelector:makeSheet]) return nil;
    return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(sheetClass, makeSheet, title, subtitle, nil, nil);
}

BOOL WolFoxShowSheet(id sheet, UIViewController *presenter) {
    SEL present = NSSelectorFromString(@"presentFromViewController:animated:completion:");
    if (sheet == nil || presenter == nil || ![sheet respondsToSelector:present]) return NO;
    ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(sheet, present, presenter, YES, nil);
    return YES;
}

void WolFoxPresentNativeSheet(NSString *title,
                              NSString *subtitle,
                              UIView *sourceView,
                              NSArray<NSDictionary *> *actions) {
    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    SEL makeSimple = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    SEL makeDetailed = NSSelectorFromString(
        @"actionWithTitle:iconImage:secondaryIconImage:accessibilityIdentifier:handler:");
    SEL makeValued = NSSelectorFromString(
        @"actionWithTitle:currentValue:iconImage:accessibilityIdentifier:handler:");
    SEL makeSelectable = NSSelectorFromString(
        @"actionWithTitle:subtitle:iconImage:visiblySelected:accessibilityLabel:"
        @"accessibilityIdentifier:handler:");
    SEL makeSubtitled = NSSelectorFromString(
        @"actionWithTitle:subtitle:iconImage:accessibilityIdentifier:handler:");
    SEL addAction = NSSelectorFromString(@"addAction:");
    if (actionClass == Nil ||
        ![actionClass respondsToSelector:makeSimple]) {
        return;
    }
    id sheet = WolFoxMakeSheet(title.length != 0 ? title : nil, subtitle.length != 0 ? subtitle : nil);
    if (sheet == nil || ![sheet respondsToSelector:addAction]) return;

    for (NSDictionary *item in actions) {
        dispatch_block_t handler = item[@"handler"];
        UIImage *secondary = item[@"secondary"];
        NSString *value = item[@"value"];
        NSString *subtitle = item[@"subtitle"];
        id action = nil;
        BOOL checked = [item[@"check"] boolValue];
        if ((checked || value.length != 0) && [actionClass respondsToSelector:makeValued]) {
            action = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                actionClass, makeValued, item[@"title"], value ?: @"", item[@"icon"], nil, handler);
            UIImage *mark = checked ? (secondary ?: [[UIImage systemImageNamed:@"checkmark"]
                imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]) : secondary;
            SEL setSecondary = NSSelectorFromString(@"setSecondaryIconImage:");
            if (mark != nil && [action respondsToSelector:setSecondary]) {
                ((void (*)(id, SEL, id))objc_msgSend)(action, setSecondary, mark);
            }
        } else if ([actionClass respondsToSelector:makeSelectable]) {
            action = ((id (*)(id, SEL, id, id, id, BOOL, id, id, id))objc_msgSend)(
                actionClass, makeSelectable, item[@"title"], subtitle,
                item[@"icon"], [item[@"selected"] boolValue], nil, nil, handler);
        } else if (subtitle.length != 0 &&
                   [actionClass respondsToSelector:makeSubtitled]) {
            action = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                actionClass, makeSubtitled, item[@"title"], subtitle,
                item[@"icon"], nil, handler);
        } else if (value.length != 0 && [actionClass respondsToSelector:makeValued]) {
            action = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                actionClass, makeValued, item[@"title"], value, item[@"icon"],
                nil, handler);
            SEL setSecondary = NSSelectorFromString(@"setSecondaryIconImage:");
            if (secondary != nil && [action respondsToSelector:setSecondary]) {
                ((void (*)(id, SEL, id))objc_msgSend)(
                    action, setSecondary, secondary);
            }
        } else if (secondary != nil && [actionClass respondsToSelector:makeDetailed]) {
            action = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                actionClass, makeDetailed, item[@"title"], item[@"icon"],
                secondary, nil, handler);
        } else {
            action = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
                actionClass, makeSimple, item[@"title"], item[@"icon"], 0, handler);
        }
        if (action != nil) {
            ((void (*)(id, SEL, id))objc_msgSend)(sheet, addAction, action);
        }
    }

    WolFoxShowSheet(sheet, WolFoxSheetPresenter(sourceView));
}

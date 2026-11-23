#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/OverlayButtonHost.h"

#import <objc/message.h>
#import "../Downloads/DownloadLog.h"
#import <objc/runtime.h>
#import <math.h>

static const void *WolFoxOverlayHiddenAssociation = &WolFoxOverlayHiddenAssociation;
static const void *WolFoxOverlayForcedAssociation = &WolFoxOverlayForcedAssociation;
static const void *WolFoxOverlayEnabledAssociation = &WolFoxOverlayEnabledAssociation;
static const void *WolFoxOverlayTransformAssociation = &WolFoxOverlayTransformAssociation;
static const void *WolFoxDoubleTapAssociation = &WolFoxDoubleTapAssociation;
static const void *WolFoxPrevNextParentAssociation = &WolFoxPrevNextParentAssociation;
static const void *WolFoxProductHiddenAssociation = &WolFoxProductHiddenAssociation;
static const void *WolFoxTimelyShelfProductAssociation = &WolFoxTimelyShelfProductAssociation;
static const NSInteger WolFoxTimelyShelfStateHidden = 2;
static IMP OriginalVideoOverlayLayout;
static IMP OriginalShouldHidePreviousButton;
static IMP OriginalShouldHideNextButton;
static IMP OriginalSetPreviousButtonEnabled;
static IMP OriginalSetNextButtonEnabled;
static IMP OriginalDidUpdatePlayerOverlayContent;
static IMP OriginalHasProductsInVideoOverlay;
static IMP OriginalProductsInVideoOverlay;
static IMP OriginalProductPillOverlayDidAddSubview;
static IMP OriginalProductPillControlsDidAddSubview;
static IMP OriginalTimelyShelfDidInsert;
static IMP OriginalTimelyShelfDidUpdate;
static IMP OriginalUpdateTimelyShelfOverlay;
static IMP OriginalUpdateTimelyShelfStateWith;
static IMP OriginalTimelyShelfFrame;
static IMP OriginalTimelyShelfHeightVC;
static IMP OriginalTimelyShelfHeightBar;
static IMP OriginalTimelyShelfHeightInput;
static IMP OriginalPlayerBarShouldShow;
static IMP OriginalAutonavShowEndscreen;
static IMP OriginalWatermarkNodeApply;
static const void *WolFoxWatermarkNodeAssociation = &WolFoxWatermarkNodeAssociation;

static NSUInteger WolFoxProductHiddenCount = 0;

static void WolFoxSweepProductViews(UIView *root, BOOL hide);
static void WolFoxApplyProductVisibility(UIView *root);

static BOOL WolFoxOverlayPreference(NSString *key) {
    return WolFoxFeatureEnabled(key);
}

static NSString *WolFoxOverlayToken(UIView *view) {
    return [[NSString stringWithFormat:@"%@ %@ %@",
             NSStringFromClass(view.class),
             view.accessibilityIdentifier ?: @"",
             view.accessibilityLabel ?: @""] lowercaseString];
}

static BOOL WolFoxOverlayTokenMatches(NSString *token,
                                      NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([token containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *WolFoxPreviousNextTokens(void) {
    return @[
        @"id.player.previous.button", @"id.player.next.button",
        @"previous.button", @"next.button",
        @"previousbutton", @"nextbutton", @"previous_button", @"next_button",
        @"previous button", @"next button", @"skipprevious", @"skipnext",
        @"replaynextbutton", @"replay_next_button"
    ];
}

static void WolFoxSetPreviousNextContainerEnabled(UIView *view, BOOL enabled) {
    if (view == nil) return;
    NSDictionary *baseline = objc_getAssociatedObject(view,
                                                       WolFoxPrevNextParentAssociation);
    if (!enabled) {
        if (baseline == nil) {
            baseline = @{@"interaction": @(view.userInteractionEnabled),
                         @"alpha": @(view.alpha)};
            objc_setAssociatedObject(view, WolFoxPrevNextParentAssociation,
                                     baseline, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.userInteractionEnabled = NO;
        view.alpha = 0.35;
    } else if (baseline != nil) {
        view.userInteractionEnabled = [baseline[@"interaction"] boolValue];
        view.alpha = [baseline[@"alpha"] doubleValue];
        objc_setAssociatedObject(view, WolFoxPrevNextParentAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void WolFoxSetOverlayHidden(UIView *view, BOOL hidden) {
    if (view == nil ||
        [view.accessibilityIdentifier hasPrefix:@"WolFox"]) {
        return;
    }

    NSNumber *baseline = objc_getAssociatedObject(
        view,
        WolFoxOverlayHiddenAssociation
    );
    if (hidden) {
        if (baseline == nil) {
            objc_setAssociatedObject(view,
                                     WolFoxOverlayHiddenAssociation,
                                     @(view.hidden),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        view.hidden = baseline.boolValue;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view,
                                 WolFoxOverlayHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static UIView *WolFoxOverlayIvarView(id owner, const char *ivarName) {
    Ivar ivar = class_getInstanceVariable(object_getClass(owner), ivarName);
    return object_getIvar(owner, ivar);
}

static void WolFoxApplyPreviousNextVisibility(id controlsOverlay, BOOL hidden) {
    WolFoxSetOverlayHidden(
        WolFoxOverlayIvarView(controlsOverlay, "_previousButtonView"), hidden);
    WolFoxSetOverlayHidden(
        WolFoxOverlayIvarView(controlsOverlay, "_nextButtonView"), hidden);
    WolFoxSetOverlayHidden(
        WolFoxOverlayIvarView(controlsOverlay, "_previousButtonViewFrostedGlassView"),
        hidden);
    WolFoxSetOverlayHidden(
        WolFoxOverlayIvarView(controlsOverlay, "_nextButtonViewFrostedGlassView"),
        hidden);
}

static BOOL WolFoxIsDarkOverlayView(UIView *view) {
    UIView *root = view.superview;
    if (view.class != UIView.class ||
        ![NSStringFromClass(root.class)
            isEqualToString:@"YTMainAppVideoPlayerOverlayView"] ||
        fabs(CGRectGetWidth(view.bounds) - CGRectGetWidth(root.bounds)) >= 2.0 ||
        fabs(CGRectGetHeight(view.bounds) - CGRectGetHeight(root.bounds)) >= 2.0) {
        return NO;
    }
    NSUInteger index = [root.subviews indexOfObjectIdenticalTo:view];
    if (index == NSNotFound || index + 1 >= root.subviews.count) return NO;
    return [NSStringFromClass(root.subviews[index + 1].class)
        isEqualToString:@"YTMainAppVideoOverlayAccessibilityGlassContainerView"];
}

static BOOL WolFoxMatchesAncestorButton(UIView *view, NSString *accessor) {
    SEL selector = NSSelectorFromString(accessor);
    for (UIView *ancestor = view.superview; ancestor != nil;
         ancestor = ancestor.superview) {
        if (![ancestor respondsToSelector:selector]) continue;
        UIView *button = ((id (*)(id, SEL))objc_msgSend)(ancestor, selector);
        if (![button isKindOfClass:UIView.class]) return NO;
        return button == view || [view isDescendantOfView:button];
    }
    return NO;
}

static BOOL WolFoxOverlayShouldHide(UIView *view) {
    NSString *token = WolFoxOverlayToken(view);
    if (WolFoxOverlayPreference(@"YTKACE.Preference.Overlay.DimmingRemoved") &&
        WolFoxIsDarkOverlayView(view)) {
        return YES;
    }
    if (WolFoxOverlayPreference(@"YTKACE.Preference.Overlay.QuickActionsHidden") &&
        WolFoxOverlayTokenMatches(token, @[
            @"quickaction", @"quick_action", @"actionbar", @"action_bar"
        ])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ContinueWatchingDisabled") &&
        WolFoxOverlayTokenMatches(token, @[
            @"continuewatching", @"continue_watching"
        ])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.AutoplayHidden") &&
        WolFoxOverlayTokenMatches(token, @[@"autoplay", @"autonav"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.CaptionsButtonHidden") &&
        WolFoxOverlayTokenMatches(token, @[@"caption", @"subtitle", @"closedcaption"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.CastHidden") &&
        (WolFoxOverlayTokenMatches(token, @[@"cast", @"airplay", @"routebutton"]) ||
         WolFoxMatchesAncestorButton(view, @"playbackRouteButton"))) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.WatermarkHidden") &&
        WolFoxOverlayTokenMatches(token, @[@"watermark", @"branding"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.InfoCardsHidden") &&
        WolFoxOverlayTokenMatches(token, @[@"infocard", @"info_card", @"cardsbutton"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.EndScreenHidden") &&
        WolFoxOverlayTokenMatches(token, @[@"endscreen", @"end_screen"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PlayPauseHidden") &&
        WolFoxOverlayTokenMatches(token, @[@"playpause", @"play_pause"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.MoreButtonHidden") &&
        WolFoxOverlayTokenMatches(token, @[@"overflowbutton", @"settingsbutton", @"morebutton"])) {
        return YES;
    }
    return NO;
}

static id WolFoxProductOverlayModelValue(id object, NSString *key) {
    if (object == nil || key.length == 0) return nil;
    @try {
        SEL selector = NSSelectorFromString(key);
        if ([object respondsToSelector:selector]) {
            return ((id (*)(id, SEL))objc_msgSend)(object, selector);
        }
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL WolFoxProductOverlayBoolValue(id object, NSString *key) {
    if (object == nil || key.length == 0) return NO;
    @try {
        return [[object valueForKey:key] boolValue];
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL WolFoxIsProductOverlayIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSString *token = [identifier lowercaseString];
    if ([token isEqualToString:@"player_overlay_product_in_video"]) return YES;
    if ([token containsString:@"player_overlay"] &&
        [token containsString:@"product"]) {
        return YES;
    }
    return NO;
}

static BOOL WolFoxIsTimelyShelfOverlayIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSString *token = [identifier lowercaseString];
    if ([token isEqualToString:@"player_overlay_timely_shelf"]) return YES;
    if ([token containsString:@"player_overlay"] &&
        [token containsString:@"timely_shelf"]) {
        return YES;
    }
    return NO;
}

static BOOL WolFoxProductPayloadMatches(id object) {
    if (object == nil || [object isKindOfClass:UIView.class]) return NO;
    for (NSString *key in @[@"productsInVideoOverlayRenderer",
                            @"productsInVideoEntity",
                            @"productsInVideoEntityModel",
                            @"productCard",
                            @"shoppingAdInfoCardContentRenderer",
                            @"infoCardProduct"]) {
        if (WolFoxProductOverlayModelValue(object, key) != nil) return YES;
    }
    if (WolFoxProductOverlayBoolValue(object, @"hasProductCard")) {
        return YES;
    }
    if (WolFoxProductOverlayBoolValue(
            object, @"hasShoppingAdInfoCardContentRenderer")) {
        return YES;
    }
    NSString *classToken = [NSStringFromClass([object class]) lowercaseString];
    if (classToken.length != 0 &&
        ([classToken containsString:@"productsinvideo"] ||
         [classToken containsString:@"productinvideo"] ||
         [classToken containsString:@"infocardproduct"] ||
         [classToken containsString:@"shoppingadinfocard"])) {
        return YES;
    }
    return NO;
}

static BOOL WolFoxTimelyShelfShoppingPayloadMatches(id object) {
    if (object == nil || [object isKindOfClass:UIView.class]) return NO;
    if (WolFoxProductPayloadMatches(object)) return YES;
    for (NSString *key in @[@"taggedProducts",
                            @"creatorProduct",
                            @"shoppingData"]) {
        if (WolFoxProductOverlayModelValue(object, key) != nil) return YES;
    }
    if (WolFoxProductOverlayBoolValue(object, @"hasTaggedProducts")) {
        return YES;
    }
    NSString *classToken = [NSStringFromClass([object class]) lowercaseString];
    if (classToken.length != 0 &&
        ([classToken containsString:@"shopping"] ||
         [classToken containsString:@"taggedproduct"] ||
         [classToken containsString:@"creatorproduct"] ||
         [classToken containsString:@"merchandise"])) {
        return YES;
    }
    for (NSString *key in @[@"overlayIdentifier", @"elementIdentifier"]) {
        id raw = WolFoxProductOverlayModelValue(object, key);
        if ([raw isKindOfClass:NSString.class] &&
            [[raw lowercaseString] containsString:@"shopping"]) {
            return YES;
        }
    }
    return NO;
}

static id WolFoxTimelyShelfElementsRenderer(id overlay) {
    id controller =
        WolFoxProductOverlayModelValue(overlay, @"elementsOverlayViewController");
    return WolFoxProductOverlayModelValue(controller, @"renderer");
}

static BOOL WolFoxTimelyShelfElementsShopping(id overlay) {
    NSData *data = WolFoxProductOverlayModelValue(
        WolFoxTimelyShelfElementsRenderer(overlay), @"data");
    if (![data isKindOfClass:NSData.class] || data.length == 0) return NO;
    NSData *marker =
        [@"shopping_timely_shelf" dataUsingEncoding:NSASCIIStringEncoding];
    return [data rangeOfData:marker
                     options:0
                       range:NSMakeRange(0, data.length)].location != NSNotFound;
}

BOOL WolFoxProductOverlayMatches(id overlay) {
    if (overlay == nil) return NO;
    NSString *identifier =
        WolFoxProductOverlayModelValue(overlay, @"overlayIdentifier");
    if ([identifier isKindOfClass:NSString.class] &&
        WolFoxIsProductOverlayIdentifier(identifier)) {
        return YES;
    }
    if (WolFoxProductPayloadMatches(overlay)) return YES;
    id renderer = WolFoxProductOverlayModelValue(overlay, @"renderer");
    if (renderer == overlay) renderer = nil;
    NSString *rendererIdentifier = nil;
    if (renderer != nil) {
        rendererIdentifier =
            WolFoxProductOverlayModelValue(renderer, @"overlayIdentifier");
        if ([rendererIdentifier isKindOfClass:NSString.class] &&
            WolFoxIsProductOverlayIdentifier(rendererIdentifier)) {
            return YES;
        }
        if (WolFoxProductPayloadMatches(renderer)) return YES;
    }
    BOOL timely =
        ([identifier isKindOfClass:NSString.class] &&
         WolFoxIsTimelyShelfOverlayIdentifier(identifier)) ||
        ([rendererIdentifier isKindOfClass:NSString.class] &&
         WolFoxIsTimelyShelfOverlayIdentifier(rendererIdentifier));
    if (timely &&
        (WolFoxTimelyShelfShoppingPayloadMatches(overlay) ||
         (renderer != nil && WolFoxTimelyShelfShoppingPayloadMatches(renderer)) ||
         WolFoxTimelyShelfElementsShopping(overlay))) {
        return YES;
    }
    return NO;
}

static BOOL WolFoxShouldDropProductOverlay(id overlay) {
    return WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        WolFoxProductOverlayMatches(overlay);
}

static void WolFoxForwardProductOverlay(id receiver, SEL selector,
                                         id provider, id overlay,
                                         IMP original) {
    if (WolFoxShouldDropProductOverlay(overlay)) return;
    if (original != NULL) {
        ((void (*)(id, SEL, id, id))original)(
            receiver, selector, provider, overlay);
    }
}

static void WolFoxProductPillDidAddSubviewHook(UIView *receiver, SEL selector,
                                                UIView *subview) {
    static Class controlsClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controlsClass = NSClassFromString(@"YTMainAppControlsOverlayView");
    });
    IMP original = (controlsClass != Nil &&
                    [receiver isKindOfClass:controlsClass])
        ? OriginalProductPillControlsDidAddSubview
        : OriginalProductPillOverlayDidAddSubview;
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, subview);
    }
    WolFoxApplyProductVisibility(subview);
}

static NSArray<NSString *> *WolFoxProductPillTokens(void) {
    static NSArray<NSString *> *tokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = @[
            @"product_in_video", @"products_in_video",
            @"tagged_product", @"creator_product",
            @"shopping", @"merchandise",
            @"products", @"tagged"
        ];
    });
    return tokens;
}

static BOOL WolFoxProductTokenHasBareProduct(NSString *token) {
    if ([token containsString:@"product"] == NO) return NO;
    for (NSString *exclusion in @[@"production", @"producer",
                                  @"productivity"]) {
        if ([token containsString:exclusion]) return NO;
    }
    return YES;
}

static BOOL WolFoxViewLooksLikeProductPill(UIView *view) {
    if (view == nil) return NO;
    NSString *token = WolFoxOverlayToken(view);
    return WolFoxOverlayTokenMatches(token, WolFoxProductPillTokens()) ||
        WolFoxProductTokenHasBareProduct(token);
}

static void WolFoxProductHiddenCounted(UIView *view, BOOL willHide) {
    NSNumber *baseline = objc_getAssociatedObject(
        view, WolFoxProductHiddenAssociation);
    if (willHide) {
        if (baseline == nil && !view.hidden) WolFoxProductHiddenCount++;
    } else if (baseline != nil) {
        if (WolFoxProductHiddenCount > 0) WolFoxProductHiddenCount--;
    }
}

static BOOL WolFoxProductTokenInString(NSString *string) {
    if (string.length == 0) return NO;
    NSString *token = [string lowercaseString];
    return WolFoxOverlayTokenMatches(token, WolFoxProductPillTokens()) ||
        WolFoxProductTokenHasBareProduct(token);
}

static void WolFoxProductSetHidden(UIView *view, BOOL hidden) {
    if (view == nil ||
        [view.accessibilityIdentifier hasPrefix:@"WolFox"]) {
        return;
    }

    NSNumber *baseline = objc_getAssociatedObject(
        view,
        WolFoxProductHiddenAssociation
    );
    if (hidden) {
        if (baseline == nil) {
            objc_setAssociatedObject(view,
                                     WolFoxProductHiddenAssociation,
                                     @(view.hidden),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        view.hidden = baseline.boolValue;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view,
                                 WolFoxProductHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static UIView *WolFoxFindForeignTextExcept(UIView *view, UIView *skip,
                                               NSUInteger depth) {
    if (view == nil || view == skip || depth > 4) return nil;
    if (view.hidden) return nil;
    if (depth == 0) {
        if (!WolFoxProductTokenInString(view.accessibilityLabel) &&
            view.accessibilityLabel.length > 1) {
            return view;
        }
    } else {
        if (WolFoxProductTokenInString(view.accessibilityLabel)) {
            return nil;
        }
        if (view.accessibilityLabel.length > 1) return view;
    }
    if (depth > 0) {
        if ([view isKindOfClass:UILabel.class]) {
            if (!WolFoxProductTokenInString(((UILabel *)view).text) &&
                ((UILabel *)view).text.length > 1) {
                return view;
            }
        } else if ([view isKindOfClass:UIButton.class]) {
            UIButton *button = (UIButton *)view;
            if (!WolFoxProductTokenInString(button.currentTitle) &&
                button.currentTitle.length > 1) {
                return view;
            }
            if (!WolFoxProductTokenInString(button.accessibilityIdentifier) &&
                button.accessibilityIdentifier.length > 1) {
                return view;
            }
        } else if ([view isKindOfClass:UIControl.class]) {
            if (!WolFoxProductTokenInString(view.accessibilityIdentifier) &&
                view.accessibilityIdentifier.length > 1) {
                return view;
            }
        }
    }
    for (UIView *subview in view.subviews) {
        UIView *found = WolFoxFindForeignTextExcept(subview, skip, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static void WolFoxHideProductPill(UIView *pill, BOOL hide) {
    WolFoxProductHiddenCounted(pill, hide);
    WolFoxProductSetHidden(pill, hide);
    if (!hide) return;
    UIView *child = pill;
    for (NSUInteger level = 0; level < 4; level++) {
        UIView *parent = child.superview;
        if (parent == nil || parent == child) break;
        NSString *parentClass = NSStringFromClass(parent.class);
        if ([parentClass containsString:@"VideoPlayerOverlay"] ||
            [parentClass containsString:@"ControlsOverlay"]) {
            break;
        }
        CGFloat h = CGRectGetHeight(parent.bounds);
        if (h <= 0.5 || h > 320.0) {
            if (!WolFoxViewLooksLikeProductPill(parent)) break;
        }
        if (WolFoxFindForeignTextExcept(parent, child, 0) != nil) break;
        WolFoxProductHiddenCounted(parent, YES);
        WolFoxProductSetHidden(parent, YES);
        child = parent;
    }
    if (child.superview != nil) {
        [child.superview setNeedsLayout];
    }
}

static void WolFoxSetOverlayForcedVisible(UIView *view, BOOL forced) {
    NSDictionary *baseline = objc_getAssociatedObject(
        view,
        WolFoxOverlayForcedAssociation
    );
    if (forced) {
        if (baseline == nil) {
            baseline = @{@"hidden": @(view.hidden), @"alpha": @(view.alpha)};
            objc_setAssociatedObject(view,
                                     WolFoxOverlayForcedAssociation,
                                     baseline,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = NO;
        view.alpha = 1.0;
    } else if (baseline != nil) {
        view.hidden = [baseline[@"hidden"] boolValue];
        view.alpha = [baseline[@"alpha"] doubleValue];
        objc_setAssociatedObject(view,
                                 WolFoxOverlayForcedAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void WolFoxApplyOverlayBehavior(UIView *view) {
    NSString *token = WolFoxOverlayToken(view);
    BOOL playPause = WolFoxOverlayTokenMatches(token, @[
        @"playpause", @"play_pause", @"playbackbutton"
    ]);
    BOOL control = [view isKindOfClass:UIControl.class] ||
        WolFoxOverlayTokenMatches(token, @[@"control", @"button"]);
    BOOL force = (WolFoxOverlayPreference(@"YTKACE.Preference.Overlay.AlwaysShowPlayPause") && playPause) ||
        (WolFoxOverlayPreference(@"YTKACE.Preference.Overlay.AlwaysShowControls") && control);
    WolFoxSetOverlayForcedVisible(view, force);

    BOOL previousNext = WolFoxOverlayTokenMatches(
        token, WolFoxPreviousNextTokens());
    BOOL disablePreviousNext = WolFoxOverlayPreference(
        @"YTKACE.Preference.Overlay.PreviousNextDisabled");
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *controlView = (UIControl *)view;
        NSNumber *baseline = objc_getAssociatedObject(
            view,
            WolFoxOverlayEnabledAssociation
        );
        if (disablePreviousNext && previousNext) {
            if (baseline == nil) {
                objc_setAssociatedObject(view,
                                         WolFoxOverlayEnabledAssociation,
                                         @(controlView.enabled),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            controlView.enabled = NO;
            controlView.alpha = 0.35;
        } else if (baseline != nil) {
            controlView.enabled = baseline.boolValue;
            controlView.alpha = 1.0;
            objc_setAssociatedObject(view,
                                     WolFoxOverlayEnabledAssociation,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (previousNext) {
        UIView *container = view.superview;
        if ([NSStringFromClass(container.class)
                containsString:@"TransportControlsButtonView"]) {
            WolFoxSetPreviousNextContainerEnabled(container,
                                                   !disablePreviousNext);
        }
    }

    NSValue *transform = objc_getAssociatedObject(
        view,
        WolFoxOverlayTransformAssociation
    );
    if (WolFoxOverlayPreference(@"YTKACE.Preference.Overlay.CompactPreviousNext") && previousNext) {
        if (transform == nil) {
            objc_setAssociatedObject(view,
                                     WolFoxOverlayTransformAssociation,
                                     [NSValue valueWithCGAffineTransform:view.transform],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.transform = CGAffineTransformScale(
            transform != nil ? transform.CGAffineTransformValue : view.transform,
            0.78,
            0.78
        );
    } else if (transform != nil) {
        view.transform = transform.CGAffineTransformValue;
        objc_setAssociatedObject(view,
                                 WolFoxOverlayTransformAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        if (![recognizer isKindOfClass:UITapGestureRecognizer.class] ||
            ((UITapGestureRecognizer *)recognizer).numberOfTapsRequired < 2) {
            continue;
        }
        NSNumber *baseline = objc_getAssociatedObject(
            recognizer,
            WolFoxDoubleTapAssociation
        );
        if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.DoubleTapDisabled")) {
            if (baseline == nil) {
                objc_setAssociatedObject(recognizer,
                                         WolFoxDoubleTapAssociation,
                                         @(recognizer.enabled),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            recognizer.enabled = NO;
        } else if (baseline != nil) {
            recognizer.enabled = baseline.boolValue;
            objc_setAssociatedObject(recognizer,
                                     WolFoxDoubleTapAssociation,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void WolFoxApplyOverlayTree(UIView *view) {
    WolFoxApplyOverlayBehavior(view);
    WolFoxSetOverlayHidden(view, WolFoxOverlayShouldHide(view));
    for (UIView *subview in view.subviews) {
        WolFoxApplyOverlayTree(subview);
    }
}

static void WolFoxApplyOverlaySelectors(id overlay) {
    NSDictionary<NSString *, NSString *> *selectors = @{
        @"autoplaySwitch": @"YTKACE.Preference.Overlay.AutoplayHidden",
        @"autoplayButton": @"YTKACE.Preference.Overlay.AutoplayHidden",
        @"captionsButton": @"YTKACE.Preference.Overlay.CaptionsButtonHidden",
        @"closedCaptionsButton": @"YTKACE.Preference.Overlay.CaptionsButtonHidden",
        @"castButton": @"YTKACE.Preference.Overlay.CastHidden",
        @"playbackRouteButton": @"YTKACE.Preference.Overlay.CastHidden",
        @"closedCaptionsOrSubtitlesButton": @"YTKACE.Preference.Overlay.CaptionsButtonHidden",
        @"infoCardButton": @"YTKACE.Preference.Overlay.InfoCardsHidden",
        @"watermarkView": @"YTKACE.Preference.Overlay.WatermarkHidden",
        @"featuredChannelWatermarkImageView": @"YTKACE.Preference.Overlay.WatermarkHidden",
        @"endscreenView": @"YTKACE.Preference.Overlay.EndScreenHidden",
        @"creatorEndscreenView": @"YTKACE.Preference.Overlay.EndScreenHidden",
        @"playPauseButton": @"YTKACE.Preference.Overlay.PlayPauseHidden",
        @"overflowButton": @"YTKACE.Preference.Overlay.MoreButtonHidden",
        @"settingsButton": @"YTKACE.Preference.Overlay.MoreButtonHidden"
    };
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if (![overlay respondsToSelector:selector]) {
            continue;
        }
        id value = ((id (*)(id, SEL))objc_msgSend)(overlay, selector);
        if ([value isKindOfClass:UIView.class]) {
            WolFoxSetOverlayHidden(value,
                                   WolFoxFeatureEnabled(selectors[name]));
        }
    }
}

static void WolFoxSweepProductViews(UIView *root, BOOL hide) {
    if (root == nil) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count != 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden &&
            objc_getAssociatedObject(view,
                                     WolFoxProductHiddenAssociation) != nil) {
            if (!hide) {
                WolFoxProductHiddenCounted(view, NO);
                WolFoxProductSetHidden(view, NO);
            } else {
                continue;
            }
        }
        if (hide && WolFoxViewLooksLikeProductPill(view)) {
            WolFoxHideProductPill(view, YES);
            continue;
        }
        if (!hide &&
            objc_getAssociatedObject(view,
                                     WolFoxProductHiddenAssociation) != nil) {
            WolFoxProductHiddenCounted(view, NO);
            WolFoxProductSetHidden(view, NO);
        }
        [stack addObjectsFromArray:view.subviews];
    }
}

static void WolFoxApplyProductVisibility(UIView *root) {
    if (root == nil) return;
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) {
        WolFoxSweepProductViews(root, YES);
    } else if (WolFoxProductHiddenCount > 0) {
        WolFoxSweepProductViews(root, NO);
        if (WolFoxProductHiddenCount > 0) {
            WolFoxProductHiddenCount = 0;
        }
    }
}

BOOL WolFoxProductIdentifierMatches(NSString *identifier) {
    if (identifier.length == 0) return NO;
    return WolFoxProductTokenInString(identifier);
}

static id WolFoxElementsValue(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL WolFoxNodeIsInVideoSubtitle(id node) {
    id controller = WolFoxElementsValue(node, @"nodeController");
    for (NSUInteger depth = 0; controller != nil && depth < 8; depth++) {
        id component = WolFoxElementsValue(controller, @"owningComponent");
        if (component != nil) {
            NSString *uri = [WolFoxElementsValue(component, @"templateURI") description];
            return [uri hasPrefix:@"video_subtitle.eml"];
        }
        controller = WolFoxElementsValue(controller, @"parent");
    }
    return NO;
}

static BOOL WolFoxSubtitleSeparatorCharacter(unichar character, BOOL *bullet) {
    if (character == 0x2022 || character == 0x00B7) {
        *bullet = YES;
        return YES;
    }
    return [NSCharacterSet.whitespaceCharacterSet characterIsMember:character];
}

static NSArray<NSValue *> *WolFoxSubtitleSeparators(NSString *string) {
    NSMutableArray<NSValue *> *separators = [NSMutableArray array];
    NSUInteger length = string.length;
    for (NSUInteger index = 0; index < length;) {
        BOOL bullet = NO;
        NSUInteger start = index;
        while (index < length &&
               WolFoxSubtitleSeparatorCharacter([string characterAtIndex:index], &bullet)) {
            index++;
        }
        if (index == start) {
            index++;
            continue;
        }
        if (index - start >= 2 || bullet) {
            [separators addObject:[NSValue valueWithRange:NSMakeRange(start, index - start)]];
        }
    }
    return separators;
}

static BOOL WolFoxIsProductCount(NSString *segment) {
    NSString *text = [segment lowercaseString];
    if (text.length == 0 ||
        ![NSCharacterSet.decimalDigitCharacterSet characterIsMember:[text characterAtIndex:0]] ||
        !WolFoxProductTokenHasBareProduct(text)) {
        return NO;
    }
    NSArray<NSString *> *words = [text componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet];
    return words.count <= 2;
}

NSAttributedString *WolFoxSubtitleWithoutProductCount(id node, NSAttributedString *text) {
    if (![text isKindOfClass:NSAttributedString.class] || text.length == 0 ||
        [text.string rangeOfString:@"product"
                           options:NSCaseInsensitiveSearch].location == NSNotFound ||
        !WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) {
        return text;
    }
    NSString *string = text.string;
    NSArray<NSValue *> *separators = WolFoxSubtitleSeparators(string);
    NSMutableArray<NSValue *> *pieces = [NSMutableArray array];
    NSMutableIndexSet *counts = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *gaps = [NSMutableIndexSet indexSet];
    NSUInteger start = 0;
    for (NSUInteger slot = 0; slot <= separators.count; slot++) {
        NSRange separator = slot < separators.count ? separators[slot].rangeValue
                                                    : NSMakeRange(string.length, 0);
        NSRange segment = NSMakeRange(start, separator.location - start);
        if (segment.length != 0) {
            if (WolFoxIsProductCount([string substringWithRange:segment])) {
                [counts addIndex:pieces.count];
            }
            [pieces addObject:[NSValue valueWithRange:segment]];
        }
        if (separator.length != 0) {
            [gaps addIndex:pieces.count];
            [pieces addObject:[NSValue valueWithRange:separator]];
        }
        start = NSMaxRange(separator);
    }
    if (counts.count == 0 || !WolFoxNodeIsInVideoSubtitle(node)) return text;

    NSMutableAttributedString *filtered = [NSMutableAttributedString new];
    BOOL leading = separators.count != 0 && separators.firstObject.rangeValue.location == 0;
    BOOL kept = NO;
    NSRange pending = NSMakeRange(NSNotFound, 0);
    for (NSUInteger index = 0; index < pieces.count; index++) {
        NSRange range = pieces[index].rangeValue;
        if ([gaps containsIndex:index]) {
            pending = range;
            continue;
        }
        if ([counts containsIndex:index]) continue;
        if (pending.location != NSNotFound && (kept || leading)) {
            [filtered appendAttributedString:[text attributedSubstringFromRange:pending]];
        }
        [filtered appendAttributedString:[text attributedSubstringFromRange:range]];
        kept = YES;
        pending = NSMakeRange(NSNotFound, 0);
    }
    BOOL trailing = separators.count != 0 &&
        NSMaxRange(separators.lastObject.rangeValue) == string.length;
    if (trailing && pending.location != NSNotFound && (kept || leading)) {
        [filtered appendAttributedString:[text attributedSubstringFromRange:pending]];
    }
    return filtered;
}

static IMP OriginalTextNodeSetNodeController;

static void WolFoxTextNodeSetNodeController(id receiver, SEL selector, id controller) {
    if (OriginalTextNodeSetNodeController != NULL) {
        ((void (*)(id, SEL, id))OriginalTextNodeSetNodeController)(receiver, selector,
                                                                   controller);
    }
    NSAttributedString *text = WolFoxElementsValue(receiver, @"attributedText");
    NSAttributedString *filtered = WolFoxSubtitleWithoutProductCount(receiver, text);
    if (filtered != text) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            receiver, NSSelectorFromString(@"setAttributedText:"), filtered);
    }
}

BOOL WolFoxViewIsInsidePlayerOverlay(UIView *view) {
    NSUInteger depth = 0;
    for (UIView *node = view; node != nil && depth < 12;
         node = node.superview, depth++) {
        NSString *className = NSStringFromClass(node.class);
        if ([className isEqualToString:@"YTMainAppVideoPlayerOverlayView"] ||
            [className isEqualToString:@"YTMainAppControlsOverlayView"]) {
            return YES;
        }
    }
    return NO;
}

void WolFoxHideProductSubtree(UIView *root) {
    if (root == nil || !WolFoxViewIsInsidePlayerOverlay(root)) return;
    WolFoxSweepProductViews(root, YES);
}

static void WolFoxVideoOverlayLayout(UIView *receiver, SEL selector) {
    if (OriginalVideoOverlayLayout != NULL) {
        ((void (*)(id, SEL))OriginalVideoOverlayLayout)(receiver, selector);
    }
    WolFoxApplyOverlaySelectors(receiver);
    WolFoxApplyProductVisibility(receiver);
    if (WolFoxOverlayPreference(@"YTKACE.Preference.Overlay.DimmingRemoved")) {
        for (UIView *subview in receiver.subviews) {
            if (WolFoxIsDarkOverlayView(subview)) {
                WolFoxSetOverlayHidden(subview, YES);
            }
        }
    }
}

static void WolFoxDidUpdatePlayerOverlayContent(id receiver, SEL selector,
                                                 id provider, id overlay) {
    WolFoxForwardProductOverlay(receiver, selector, provider, overlay,
                                 OriginalDidUpdatePlayerOverlayContent);
}

static BOOL WolFoxHasProductsInVideoOverlay(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) return NO;
    return OriginalHasProductsInVideoOverlay != NULL &&
        ((BOOL (*)(id, SEL))OriginalHasProductsInVideoOverlay)(receiver, selector);
}

static id WolFoxProductsInVideoOverlay(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) return nil;
    return OriginalProductsInVideoOverlay == NULL ? nil :
        ((id (*)(id, SEL))OriginalProductsInVideoOverlay)(receiver, selector);
}

static void WolFoxTimelyShelfDidInsert(id receiver, SEL selector,
                                         id provider, id overlay) {
    WolFoxForwardProductOverlay(receiver, selector, provider, overlay,
                                 OriginalTimelyShelfDidInsert);
}

static void WolFoxTimelyShelfDidUpdate(id receiver, SEL selector,
                                        id provider, id overlay) {
    WolFoxForwardProductOverlay(receiver, selector, provider, overlay,
                                 OriginalTimelyShelfDidUpdate);
}

static void WolFoxUpdateTimelyShelfOverlay(id receiver, SEL selector,
                                            id overlay) {
    if (WolFoxShouldDropProductOverlay(overlay)) {
        return;
    }
    if (OriginalUpdateTimelyShelfOverlay != NULL) {
        ((void (*)(id, SEL, id))OriginalUpdateTimelyShelfOverlay)(
            receiver, selector, overlay);
    }
}

static BOOL WolFoxTimelyShelfOverlayIsProduct(id overlay) {
    if (overlay == nil) return NO;
    id renderer = WolFoxTimelyShelfElementsRenderer(overlay);
    if (renderer == nil) return WolFoxProductOverlayMatches(overlay);
    NSNumber *cached =
        objc_getAssociatedObject(renderer, WolFoxTimelyShelfProductAssociation);
    if (cached == nil) {
        cached = @(WolFoxProductOverlayMatches(overlay));
        objc_setAssociatedObject(renderer, WolFoxTimelyShelfProductAssociation,
                                 cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return cached.boolValue;
}

static BOOL WolFoxTimelyShelfShowsProduct(id manager) {
    if (manager == nil) return NO;
    id active =
        WolFoxProductOverlayModelValue(manager, @"activeTimelyShelfOverlay");
    if (active != nil) return WolFoxTimelyShelfOverlayIsProduct(active);
    if (WolFoxProductOverlayBoolValue(manager,
                                      @"isIosMultipleTimelyShelvesEnabled")) {
        return NO;
    }
    NSDictionary *shelves =
        WolFoxProductOverlayModelValue(manager, @"timelyShelfDictionary");
    if (![shelves isKindOfClass:NSDictionary.class]) return NO;
    for (id overlay in shelves.allValues) {
        if (WolFoxTimelyShelfOverlayIsProduct(overlay)) return YES;
    }
    return NO;
}

static id WolFoxTimelyShelfManagerForOwner(id owner) {
    SEL managerSelector = NSSelectorFromString(@"timelyShelfStateManager");
    if (![owner respondsToSelector:managerSelector] &&
        [owner respondsToSelector:@selector(delegate)]) {
        owner = ((id (*)(id, SEL))objc_msgSend)(owner, @selector(delegate));
    }
    if (![owner respondsToSelector:managerSelector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(owner, managerSelector);
}

static void WolFoxUpdateTimelyShelfStateWith(id receiver, SEL selector,
                                              NSInteger state) {
    if (state != WolFoxTimelyShelfStateHidden &&
        WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        WolFoxTimelyShelfShowsProduct(receiver)) {
        state = WolFoxTimelyShelfStateHidden;
    }
    if (OriginalUpdateTimelyShelfStateWith != NULL) {
        ((void (*)(id, SEL, NSInteger))OriginalUpdateTimelyShelfStateWith)(
            receiver, selector, state);
    }
}

static void WolFoxTimelyShelfFrame(id receiver, SEL selector,
                                    id shelf, CGRect overlayBounds) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        WolFoxTimelyShelfOverlayIsProduct(shelf)) {
        id view = WolFoxProductOverlayModelValue(shelf, @"overlayView");
        if ([view isKindOfClass:UIView.class]) {
            UIView *shelfView = (UIView *)view;
            WolFoxProductHiddenCounted(shelfView, YES);
            WolFoxProductSetHidden(shelfView, YES);
            shelfView.frame = CGRectZero;
        }
        return;
    }
    if (OriginalTimelyShelfFrame != NULL) {
        ((void (*)(id, SEL, id, CGRect))OriginalTimelyShelfFrame)(
            receiver, selector, shelf, overlayBounds);
    }
}

static CGFloat WolFoxTimelyShelfHeightHook(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        WolFoxTimelyShelfShowsProduct(
            WolFoxTimelyShelfManagerForOwner(receiver))) {
        return 0.0;
    }
    static Class barClass;
    static Class inputClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        barClass = NSClassFromString(@"YTPlayerBarController");
        inputClass = NSClassFromString(@"YTPlayerBarLayoutInput");
    });
    IMP original = OriginalTimelyShelfHeightVC;
    if (barClass != Nil && [receiver isKindOfClass:barClass]) {
        original = OriginalTimelyShelfHeightBar;
    } else if (inputClass != Nil && [receiver isKindOfClass:inputClass]) {
        original = OriginalTimelyShelfHeightInput;
    }
    return original == NULL ? 0.0 :
        ((CGFloat (*)(id, SEL))original)(receiver, selector);
}

static BOOL WolFoxShouldHidePreviousButton(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden")) return YES;
    // seeking works without a previous video
    if (WolFoxPreviousNextSeekSeconds() > 0) return NO;
    return OriginalShouldHidePreviousButton == NULL
        ? NO
        : ((BOOL (*)(id, SEL))OriginalShouldHidePreviousButton)(
            receiver, selector);
}

static BOOL WolFoxShouldHideNextButton(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden")) return YES;
    if (WolFoxPreviousNextSeekSeconds() > 0) return NO;
    return OriginalShouldHideNextButton == NULL
        ? NO
        : ((BOOL (*)(id, SEL))OriginalShouldHideNextButton)(
            receiver, selector);
}

static void WolFoxSetPreviousButtonEnabled(id receiver, SEL selector, BOOL enabled) {
    ((void (*)(id, SEL, BOOL))OriginalSetPreviousButtonEnabled)(
        receiver, selector, enabled || WolFoxPreviousNextSeekSeconds() > 0);
    WolFoxApplyPreviousNextVisibility(
        receiver,
        WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden"));
}

static void WolFoxSetNextButtonEnabled(id receiver, SEL selector, BOOL enabled) {
    ((void (*)(id, SEL, BOOL))OriginalSetNextButtonEnabled)(
        receiver, selector, enabled || WolFoxPreviousNextSeekSeconds() > 0);
    WolFoxApplyPreviousNextVisibility(
        receiver,
        WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden"));
}

static BOOL WolFoxPlayerBarShouldShow(id receiver, SEL selector, id controller) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProgressAlwaysVisible")) {
        return YES;
    }
    return ((BOOL (*)(id, SEL, id))OriginalPlayerBarShouldShow)(receiver, selector, controller);
}

static BOOL WolFoxAutonavFlag(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static void WolFoxAutonavShowEndscreen(id receiver, SEL selector) {
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.AutoplayPromptHidden")) {
        if (OriginalAutonavShowEndscreen != NULL) {
            ((void (*)(id, SEL))OriginalAutonavShowEndscreen)(receiver, selector);
        }
        return;
    }
    SEL delegateGetter = NSSelectorFromString(@"endscreenDelegate");
    id delegate = [receiver respondsToSelector:delegateGetter] ?
        ((id (*)(id, SEL))objc_msgSend)(receiver, delegateGetter) : nil;
    SEL play = NSSelectorFromString(@"playAutonav");
    if ((WolFoxAutonavFlag(receiver, @"shouldAutonavInBackground") ||
         WolFoxAutonavFlag(receiver, @"shouldStartCountdown")) &&
        !WolFoxAutonavFlag(delegate, @"isVideoInSingleLoop") &&
        [receiver respondsToSelector:play]) {
        ((void (*)(id, SEL))objc_msgSend)(receiver, play);
    }
}

static void WolFoxApplyWatermarkNode(id node) {
    BOOL hide = WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.WatermarkHidden");
    if (!hide && objc_getAssociatedObject(node, WolFoxWatermarkNodeAssociation) == nil) return;
    objc_setAssociatedObject(node, WolFoxWatermarkNodeAssociation, hide ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(node, NSSelectorFromString(@"setHidden:"), hide);
}

static void WolFoxWatermarkNodeApply(id receiver, SEL selector) {
    if (OriginalWatermarkNodeApply != NULL) {
        ((void (*)(id, SEL))OriginalWatermarkNodeApply)(receiver, selector);
    }
    SEL getter = NSSelectorFromString(@"accessibilityIdentifier");
    if (![receiver respondsToSelector:getter] ||
        ![receiver respondsToSelector:NSSelectorFromString(@"setHidden:")]) {
        return;
    }
    id identifier = ((id (*)(id, SEL))objc_msgSend)(receiver, getter);
    if (![identifier isKindOfClass:NSString.class] || ![identifier isEqualToString:@"watermark_image"]) return;
    if (NSThread.isMainThread) {
        WolFoxApplyWatermarkNode(receiver);
        return;
    }
    __weak id weakNode = receiver;
    dispatch_async(dispatch_get_main_queue(), ^{
        id node = weakNode;
        if (node != nil) WolFoxApplyWatermarkNode(node);
    });
}

static NSString *const WolFoxFullscreenActionsKey =
    @"YTKACE.Preference.Overlay.FullscreenActionsHidden";

static CGFloat const WolFoxFullscreenActionsReservedHeight = 34.0;

static IMP OriginalFullscreenActionsLayout;
static IMP OriginalFullscreenEngagementLayout;
static IMP OriginalFullscreenActionBarHeight;
static IMP OriginalFullscreenActionsSizeThatFits;
static void WolFoxApplyHidden(UIView *view, NSString *key) {
    const BOOL hidden = WolFoxFeatureEnabled(key);
    if (view.hidden != hidden) view.hidden = hidden;
}

// Fullscreen bar (under the progress bar): a pill of buttons on the left and
// More videos on the right, both built from Elements nodes. Hidden buttons are
// collapsed to zero width so the pill shrinks to the ones left.
typedef struct { NSInteger unit; CGFloat value; } WolFoxDimension;
static const void *WolFoxFullscreenCollapsedKey = &WolFoxFullscreenCollapsedKey;
static const void *WolFoxFullscreenWidthsKey = &WolFoxFullscreenWidthsKey;

static id WolFoxFullscreenGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return object != nil && [object respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static void WolFoxFullscreenRelayout(id node) {
    for (id current = node; current != nil; current = WolFoxFullscreenGet(current, @"supernode")) {
        SEL invalidate = NSSelectorFromString(@"invalidateCalculatedLayout");
        if ([current respondsToSelector:invalidate]) ((void (*)(id, SEL))objc_msgSend)(current, invalidate);
        SEL needs = NSSelectorFromString(@"setNeedsLayout");
        if ([current respondsToSelector:needs]) ((void (*)(id, SEL))objc_msgSend)(current, needs);
    }
}

static BOOL WolFoxFullscreenCollapse(id node, BOOL collapse) {
    if (node == nil) return NO;
    if ([objc_getAssociatedObject(node, WolFoxFullscreenCollapsedKey) boolValue] == collapse) return NO;
    id style = WolFoxFullscreenGet(node, @"style");
    NSArray<NSString *> *names = @[@"width", @"minWidth", @"maxWidth"];
    if (collapse) {
        NSMutableArray *saved = [NSMutableArray array];
        for (NSString *name in names) {
            SEL getter = NSSelectorFromString(name);
            WolFoxDimension value = {0, 0};
            if ([style respondsToSelector:getter]) {
                value = ((WolFoxDimension (*)(id, SEL))objc_msgSend)(style, getter);
            }
            [saved addObject:[NSValue valueWithBytes:&value objCType:@encode(WolFoxDimension)]];
        }
        objc_setAssociatedObject(node, WolFoxFullscreenWidthsKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSArray<NSValue *> *saved = objc_getAssociatedObject(node, WolFoxFullscreenWidthsKey);
    for (NSUInteger index = 0; index < names.count; index++) {
        NSString *name = names[index];
        SEL setter = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
            [name substringToIndex:1].uppercaseString, [name substringFromIndex:1]]);
        if (![style respondsToSelector:setter]) continue;
        WolFoxDimension value = {1, 0};
        if (!collapse) {
            value = (WolFoxDimension){0, 0};
            if (index < saved.count) [saved[index] getValue:&value];
        }
        ((void (*)(id, SEL, WolFoxDimension))objc_msgSend)(style, setter, value);
    }
    SEL hidden = NSSelectorFromString(@"setHidden:");
    if ([node respondsToSelector:hidden]) ((void (*)(id, SEL, BOOL))objc_msgSend)(node, hidden, collapse);
    objc_setAssociatedObject(node, WolFoxFullscreenCollapsedKey, @(collapse), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static NSString *WolFoxFullscreenID(id node) {
    id value = WolFoxFullscreenGet(node, @"accessibilityIdentifier");
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static NSArray *WolFoxFullscreenChildren(id node) {
    NSArray *children = WolFoxFullscreenGet(node, @"yogaChildren");
    return [children isKindOfClass:NSArray.class] ? children : @[];
}

// The bar's nodes:
//   root > wrapper > [pill, spacer, More videos]
//   pill > [glass, wrapper > like, wrapper > dislike, ..., wrapper > ⋯]
// Wrappers have no size of their own; each button is the one node inside.
static id WolFoxFullscreenButton(id slot) {
    if (WolFoxFullscreenID(slot).length != 0) return slot;
    for (id child in WolFoxFullscreenChildren(slot)) {
        if (WolFoxFullscreenID(child).length != 0) return child;
    }
    return nil;
}

static BOOL WolFoxFullscreenIsPill(id group) {
    for (id slot in WolFoxFullscreenChildren(group)) {
        if ([WolFoxFullscreenID(WolFoxFullscreenButton(slot)) isEqualToString:@"id.video.like.button"]) return YES;
    }
    return NO;
}

static const void *WolFoxFullscreenNameKey = &WolFoxFullscreenNameKey;

// YTKACE's buttons in the fullscreen zone, as [{id, width}] in their own
// order. Each gets a gap of that width in YouTube's pill, placed by the saved
// order (which names YouTube's buttons and ours), and OverlayButtonHost lays
// the button over it. The gap is a margin on the YouTube button next to it.
// Extra nodes in the pill never become real subnodes, and Texture crashes
// when it later inserts a button at a position counted with them.
NSArray<NSDictionary *> *WolFoxFullscreenGroups = nil;

typedef struct {
    WolFoxDimension top, left, bottom, right, start, end, horizontal, vertical, all;
} WolFoxEdgeInsets;

static const void *WolFoxFullscreenMarginKey = &WolFoxFullscreenMarginKey;
static const void *WolFoxFullscreenGapKey = &WolFoxFullscreenGapKey;
static __weak id WolFoxFullscreenLivePill;
// group id -> {slot, offset, width, gap, after}
static NSDictionary<NSString *, NSDictionary *> *WolFoxFullscreenAnchors;

// Finds element's spot in a layout tree, relative to the tree's node.
static BOOL WolFoxFindInLayout(id layout, id element, CGPoint origin, int depth, CGRect *frame) {
    if (layout == nil || depth > 6) return NO;
    for (id sublayout in WolFoxFullscreenGet(layout, @"sublayouts")) {
        CGPoint position = ((CGPoint (*)(id, SEL))objc_msgSend)(sublayout, NSSelectorFromString(@"position"));
        CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(sublayout, NSSelectorFromString(@"size"));
        CGPoint at = CGPointMake(origin.x + (isfinite(position.x) ? position.x : 0.0),
                                 origin.y + (isfinite(position.y) ? position.y : 0.0));
        if (WolFoxFullscreenGet(sublayout, @"layoutElement") == element) {
            *frame = (CGRect){at, size};
            return YES;
        }
        if (WolFoxFindInLayout(sublayout, element, at, depth + 1, frame)) return YES;
    }
    return NO;
}

// Where the gap for one of our buttons is, in view's coordinates. It comes
// from the spot of the YouTube button it sits beside in the pill's last layout.
BOOL WolFoxFullscreenGroupFrame(NSString *group, UIView *view, CGRect *frame) {
    NSDictionary *anchor = WolFoxFullscreenAnchors[group];
    id pill = WolFoxFullscreenLivePill;
    id slot = anchor[@"slot"];
    if (slot == nil || pill == nil || view == nil) return NO;
    SEL loaded = NSSelectorFromString(@"isNodeLoaded");
    if (![pill respondsToSelector:loaded] || !((BOOL (*)(id, SEL))objc_msgSend)(pill, loaded)) return NO;
    CALayer *layer = WolFoxFullscreenGet(pill, @"layer");
    if (![layer isKindOfClass:CALayer.class]) return NO;
    BOOL inside = NO;
    for (CALayer *current = layer; current != nil; current = current.superlayer) {
        if (current == view.layer) { inside = YES; break; }
    }
    id layout = WolFoxFullscreenGet(pill, @"calculatedLayout");
    CGRect local;
    if (!inside || !WolFoxFindInLayout(layout, slot, CGPointZero, 0, &local)) return NO;
    const CGFloat width = [anchor[@"width"] doubleValue];
    const CGFloat offset = [anchor[@"offset"] doubleValue];
    if (width < 1.0) return NO;
    const CGFloat x = [anchor[@"after"] boolValue] ? CGRectGetMaxX(local) + offset
                                                  : CGRectGetMinX(local) - [anchor[@"gap"] doubleValue] + offset;
    CGFloat midY = CGRectGetMidY(local);
    if (CGRectGetHeight(local) < 1.0 && layout != nil) {
        midY = ((CGSize (*)(id, SEL))objc_msgSend)(layout, NSSelectorFromString(@"size")).height / 2.0;
    }
    *frame = [layer convertRect:CGRectMake(x, midY - 24.0, width, 48.0) toLayer:view.layer];
    return YES;
}

// Adds our gap to the margin YouTube gave the button. Yoga uses start/end
// over left/right when they're set. Returns YES when it changed.
static BOOL WolFoxSetSlotGap(id slot, CGFloat before, CGFloat after) {
    NSValue *applied = objc_getAssociatedObject(slot, WolFoxFullscreenGapKey);
    if (CGSizeEqualToSize(applied != nil ? applied.CGSizeValue : CGSizeZero, CGSizeMake(before, after))) return NO;
    id style = WolFoxFullscreenGet(slot, @"style");
    SEL getter = NSSelectorFromString(@"margin");
    SEL setter = NSSelectorFromString(@"setMargin:");
    if (![style respondsToSelector:getter] || ![style respondsToSelector:setter]) return NO;
    WolFoxEdgeInsets margin;
    NSValue *saved = objc_getAssociatedObject(slot, WolFoxFullscreenMarginKey);
    if (saved == nil) {
        margin = ((WolFoxEdgeInsets (*)(id, SEL))objc_msgSend)(style, getter);
        objc_setAssociatedObject(slot, WolFoxFullscreenMarginKey,
                                 [NSValue valueWithBytes:&margin objCType:@encode(WolFoxEdgeInsets)],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        [saved getValue:&margin];
    }
    WolFoxDimension *leading = margin.start.unit != 0 ? &margin.start : &margin.left;
    WolFoxDimension *trailing = margin.end.unit != 0 ? &margin.end : &margin.right;
    if (before > 0.0) *leading = (WolFoxDimension){1, (leading->unit == 1 ? leading->value : 0.0) + before};
    if (after > 0.0) *trailing = (WolFoxDimension){1, (trailing->unit == 1 ? trailing->value : 0.0) + after};
    ((void (*)(id, SEL, WolFoxEdgeInsets))objc_msgSend)(style, setter, margin);
    objc_setAssociatedObject(slot, WolFoxFullscreenGapKey, [NSValue valueWithCGSize:CGSizeMake(before, after)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

// Puts YouTube's buttons in the saved order and gives ours their gaps. Buttons
// the order doesn't name keep their place after the named ones; ours not named
// go last. The reorder is done after the current layout pass. Returns YES when
// a gap changed.
static BOOL WolFoxOrderFullscreenPill(id pill, NSArray *slots, NSArray<NSString *> *keys) {
    NSArray *children = WolFoxFullscreenChildren(pill);
    NSArray *order = WolFoxPreferenceObject(@"YTKACE.Preference.Fullscreen.Order");
    if (![order isKindOfClass:NSArray.class]) order = @[];
    NSMutableDictionary<NSString *, NSNumber *> *widths = [NSMutableDictionary dictionary];
    for (NSDictionary *group in WolFoxFullscreenGroups) {
        NSString *identifier = group[@"id"];
        if (identifier.length != 0 && [group[@"width"] doubleValue] > 0.0) widths[identifier] = group[@"width"];
    }
    NSMutableArray *sequence = [NSMutableArray array];
    for (id name in order) {
        if (![name isKindOfClass:NSString.class]) continue;
        id item = widths[name] != nil ? name : nil;
        if (item == nil && slots.count == keys.count) {
            NSUInteger index = [keys indexOfObject:name];
            if (index != NSNotFound) item = slots[index];
        }
        if (item != nil && ![sequence containsObject:item]) [sequence addObject:item];
    }
    for (id slot in slots) {
        if (![sequence containsObject:slot]) [sequence addObject:slot];
    }
    for (NSDictionary *group in WolFoxFullscreenGroups) {
        NSString *identifier = group[@"id"];
        if (widths[identifier] != nil && ![sequence containsObject:identifier]) [sequence addObject:identifier];
    }
    // Our groups run up to the next YouTube button, or after the last one.
    NSMutableDictionary<NSString *, NSDictionary *> *anchors = [NSMutableDictionary dictionary];
    NSMapTable *before = [NSMapTable strongToStrongObjectsMapTable];
    NSMutableArray *sorted = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *pending = [NSMutableArray array];
    CGFloat run = 0.0;
    for (id item in sequence) {
        if ([item isKindOfClass:NSString.class]) {
            [pending addObject:@{@"id": item, @"offset": @(run)}];
            run += widths[item].doubleValue;
            continue;
        }
        for (NSDictionary *entry in pending) {
            anchors[entry[@"id"]] = @{@"slot": item, @"offset": entry[@"offset"], @"width": widths[entry[@"id"]],
                                      @"gap": @(run), @"after": @NO};
        }
        if (run > 0.0) [before setObject:@(run) forKey:item];
        [pending removeAllObjects];
        run = 0.0;
        [sorted addObject:item];
    }
    id last = sorted.lastObject;
    if (last != nil) {
        for (NSDictionary *entry in pending) {
            anchors[entry[@"id"]] = @{@"slot": last, @"offset": entry[@"offset"], @"width": widths[entry[@"id"]],
                                      @"gap": @(run), @"after": @YES};
        }
    }
    BOOL changed = NO;
    for (id slot in slots) {
        changed |= WolFoxSetSlotGap(slot, [[before objectForKey:slot] doubleValue],
                                    slot == last && pending.count != 0 ? run : 0.0);
    }
    WolFoxFullscreenAnchors = anchors;

    // Everything else (the glass) keeps its side of the buttons.
    NSMutableArray *leading = [NSMutableArray array];
    NSMutableArray *trailing = [NSMutableArray array];
    BOOL seen = NO;
    for (id child in children) {
        if ([slots containsObject:child]) seen = YES;
        else [seen ? trailing : leading addObject:child];
    }
    NSMutableArray *next = [leading mutableCopy];
    [next addObjectsFromArray:sorted];
    [next addObjectsFromArray:trailing];
    if ([next isEqualToArray:children]) return changed;
    __weak id weakPill = pill;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongPill = weakPill;
        if (![WolFoxFullscreenChildren(strongPill) isEqualToArray:children]) return;
        SEL set = NSSelectorFromString(@"setYogaChildren:");
        if (![strongPill respondsToSelector:set]) return;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(strongPill, set, next);
        } @catch (NSException *exception) {
            WolFoxDebugLog(@"fsbar", @"reorder threw %@", exception.reason);
            return;
        }
        WolFoxFullscreenRelayout(strongPill);
    });
    return changed;
}

static void WolFoxApplyFullscreenBar(UIView *bar) {
    id root = nil;
    for (UIView *subview in bar.subviews) {
        root = WolFoxFullscreenGet(subview, @"keepalive_node");
        if (root != nil) break;
    }
    // Step through single-child wrappers to the row of groups.
    NSArray *groups = WolFoxFullscreenChildren(root);
    for (NSUInteger step = 0; groups.count == 1 && step < 3; step++) {
        groups = WolFoxFullscreenChildren(groups.firstObject);
    }
    id pill = nil;
    for (id group in groups) {
        if (WolFoxFullscreenIsPill(group)) pill = group;
    }
    if (pill == nil) return;
    BOOL changed = NO;
    BOOL hideMore = WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.MoreVideosHidden");
    for (id group in groups) {
        if (group == pill || WolFoxFullscreenChildren(group).count == 0) continue;
        changed |= WolFoxFullscreenCollapse(group, hideMore);
    }
    NSMutableArray *buttons = [NSMutableArray array];
    NSMutableArray *slots = [NSMutableArray array];
    for (id slot in WolFoxFullscreenChildren(pill)) {
        id button = WolFoxFullscreenButton(slot);
        if (button == nil) continue;
        [buttons addObject:button];
        [slots addObject:slot];
    }
    // Comments, Ask and ⋯ share an id; in YouTube's order Comments follows
    // dislike and ⋯ is last. Each button is named the first time it's seen,
    // before any reordering, and keeps that name.
    NSUInteger last = NSNotFound;
    for (NSUInteger index = 0; index < buttons.count; index++) {
        if ([WolFoxFullscreenID(buttons[index]) isEqualToString:@"id.elements.button"]) last = index;
    }
    BOOL afterDislike = NO;
    NSUInteger shown = 0;
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSUInteger index = 0; index < buttons.count; index++) {
        id button = buttons[index];
        NSString *identifier = WolFoxFullscreenID(button);
        NSString *key = objc_getAssociatedObject(button, WolFoxFullscreenNameKey);
        if (key == nil) {
            if ([identifier isEqualToString:@"id.video.like.button"]) key = @"Like";
            else if ([identifier isEqualToString:@"id.video.dislike.button"]) key = @"Dislike";
            else if ([identifier isEqualToString:@"id.video.add_to.button"]) key = @"Save";
            else if ([identifier isEqualToString:@"id.video.share.button"]) key = @"Share";
            else if ([identifier isEqualToString:@"id.elements.button"]) {
                key = afterDislike ? @"Comments" : (index == last ? @"Overflow" : @"Ask");
            }
            if (key != nil) objc_setAssociatedObject(button, WolFoxFullscreenNameKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        [keys addObject:key ?: @""];
        afterDislike = [identifier isEqualToString:@"id.video.dislike.button"];
        BOOL hide = key != nil && WolFoxFeatureEnabled(
            [NSString stringWithFormat:@"YTKACE.Preference.Fullscreen.%@Hidden", key]);
        changed |= WolFoxFullscreenCollapse(button, hide);
        if (slots[index] != button) changed |= WolFoxFullscreenCollapse(slots[index], hide);
        if (!hide) shown++;
    }
    // Nothing left in the pill: hide its glass too, unless YTKACE's buttons use it.
    changed |= WolFoxFullscreenCollapse(pill, buttons.count != 0 && shown == 0 && WolFoxFullscreenGroups.count == 0);
    WolFoxFullscreenLivePill = pill;
    changed |= WolFoxOrderFullscreenPill(pill, slots, keys);
    if (changed) WolFoxFullscreenRelayout(root);
}

static void WolFoxFullscreenActionsLayout(UIView *receiver, SEL selector) {
    if (OriginalFullscreenActionsLayout != NULL) {
        ((void (*)(id, SEL))OriginalFullscreenActionsLayout)(receiver, selector);
    }
    WolFoxApplyHidden(receiver, WolFoxFullscreenActionsKey);
    if (!receiver.hidden) {
        WolFoxApplyFullscreenBar(receiver);
        WolFoxFullscreenBarDidLayout(receiver);
    }
}

static void WolFoxFullscreenEngagementLayout(UIView *receiver, SEL selector) {
    if (OriginalFullscreenEngagementLayout != NULL) {
        ((void (*)(id, SEL))OriginalFullscreenEngagementLayout)(receiver, selector);
    }
    WolFoxApplyHidden(receiver, WolFoxFullscreenActionsKey);
}

static CGFloat WolFoxFullscreenActionBarHeight(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(WolFoxFullscreenActionsKey)) return 0.0;
    return ((CGFloat (*)(id, SEL))OriginalFullscreenActionBarHeight)(
        receiver, selector);
}

static CGSize WolFoxFullscreenActionsSizeThatFits(id receiver, SEL selector,
                                                   CGSize size) {
    CGSize fitted = ((CGSize (*)(id, SEL, CGSize))
        OriginalFullscreenActionsSizeThatFits)(receiver, selector, size);
    if (!WolFoxFeatureEnabled(WolFoxFullscreenActionsKey)) return fitted;
    return CGSizeMake(fitted.width, WolFoxFullscreenActionsReservedHeight);
}

static IMP OriginalCreatePanelNavigation;

// Products panels ("PAproduct_list") can open on their own when a video
// loads (the landscape and iPad sidebar). With Remove Products on, the
// panel isn't created.
static BOOL WolFoxIsProductsPanelCommand(id command) {
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden")) return NO;
    NSString *text = [command description];
    return [text containsString:@"PAproduct_list"] || [text containsString:@"shopping_panel"];
}

static id WolFoxCreatePanelNavigation(id self, SEL _cmd, id command, id parent, id delegate) {
    if (WolFoxIsProductsPanelCommand(command)) {
        WolFoxDebugLog(@"products", @"blocked products panel");
        return nil;
    }
    return ((id (*)(id, SEL, id, id, id))OriginalCreatePanelNavigation)(self, _cmd, command, parent, delegate);
}

void WolFoxInstallOverlayVisibilityHooks(void) {
    WolFoxInstallInstanceHook(@"YTEngagementPanelViewControllerManager",
                              @"createNavigationControllerWithRootShowCommand:parentResponder:delegate:",
                              (IMP)WolFoxCreatePanelNavigation, &OriginalCreatePanelNavigation);
    WolFoxInstallInstanceHook(@"ELMTextNode", @"__setNodeController:",
                              (IMP)WolFoxTextNodeSetNodeController,
                              &OriginalTextNodeSetNodeController);
    WolFoxInstallInstanceHook(@"YTFullscreenActionsView", @"layoutSubviews",
                              (IMP)WolFoxFullscreenActionsLayout,
                              &OriginalFullscreenActionsLayout);
    WolFoxInstallInstanceHook(@"YTFullscreenEngagementActionBarView",
                              @"layoutSubviews",
                              (IMP)WolFoxFullscreenEngagementLayout,
                              &OriginalFullscreenEngagementLayout);
    WolFoxInstallInstanceHook(@"YTFullscreenEngagementActionBarView",
                              @"actionBarHeight",
                              (IMP)WolFoxFullscreenActionBarHeight,
                              &OriginalFullscreenActionBarHeight);
    WolFoxInstallInstanceHook(@"YTFullscreenActionsView",
                              @"sizeThatFits:",
                              (IMP)WolFoxFullscreenActionsSizeThatFits,
                              &OriginalFullscreenActionsSizeThatFits);
    WolFoxRegisterOverlayConfigurator(@"visibility", ^(UIView *overlay,
                                                        UIStackView *stack) {
        for (UIView *subview in overlay.subviews) {
            if (subview != stack) {
                WolFoxApplyOverlayTree(subview);
            }
        }
        WolFoxApplyOverlaySelectors(overlay);
        WolFoxApplyProductVisibility(overlay);
        WolFoxApplyPreviousNextVisibility(
            overlay,
            WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PreviousNextHidden"));
    });
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"layoutSubviews",
                              (IMP)WolFoxVideoOverlayLayout,
                              &OriginalVideoOverlayLayout);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"playerOverlayProvider:didUpdateContentForPlayerOverlay:",
                              (IMP)WolFoxDidUpdatePlayerOverlayContent,
                              &OriginalDidUpdatePlayerOverlayContent);
    WolFoxInstallInstanceHook(@"YTIPlayerOverlayRenderer",
                              @"hasProductsInVideoOverlayRenderer",
                              (IMP)WolFoxHasProductsInVideoOverlay,
                              &OriginalHasProductsInVideoOverlay);
    WolFoxInstallInstanceHook(@"YTIPlayerOverlayRenderer",
                              @"productsInVideoOverlayRenderer",
                              (IMP)WolFoxProductsInVideoOverlay,
                              &OriginalProductsInVideoOverlay);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"didAddSubview:",
                              (IMP)WolFoxProductPillDidAddSubviewHook,
                              &OriginalProductPillOverlayDidAddSubview);
    WolFoxInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"didAddSubview:",
                              (IMP)WolFoxProductPillDidAddSubviewHook,
                              &OriginalProductPillControlsDidAddSubview);
    WolFoxInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"playerOverlayProvider:didInsertPlayerOverlay:",
                              (IMP)WolFoxTimelyShelfDidInsert,
                              &OriginalTimelyShelfDidInsert);
    WolFoxInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"playerOverlayProvider:didUpdateContentForPlayerOverlay:",
                              (IMP)WolFoxTimelyShelfDidUpdate,
                              &OriginalTimelyShelfDidUpdate);
    WolFoxInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"updateTimelyShelfOverlay:",
                              (IMP)WolFoxUpdateTimelyShelfOverlay,
                              &OriginalUpdateTimelyShelfOverlay);
    WolFoxInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"updateTimelyShelfState:",
                              (IMP)WolFoxUpdateTimelyShelfStateWith,
                              &OriginalUpdateTimelyShelfStateWith);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"setTimelyShelfFrame:fromOverlayBounds:",
                              (IMP)WolFoxTimelyShelfFrame,
                              &OriginalTimelyShelfFrame);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"timelyShelfHeight",
                              (IMP)WolFoxTimelyShelfHeightHook,
                              &OriginalTimelyShelfHeightVC);
    WolFoxInstallInstanceHook(@"YTPlayerBarController",
                              @"timelyShelfHeight",
                              (IMP)WolFoxTimelyShelfHeightHook,
                              &OriginalTimelyShelfHeightBar);
    WolFoxInstallInstanceHook(@"YTPlayerBarLayoutInput",
                              @"timelyShelfHeight",
                              (IMP)WolFoxTimelyShelfHeightHook,
                              &OriginalTimelyShelfHeightInput);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"shouldHidePreviousButton",
                              (IMP)WolFoxShouldHidePreviousButton,
                              &OriginalShouldHidePreviousButton);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"shouldHideNextButton",
                              (IMP)WolFoxShouldHideNextButton,
                              &OriginalShouldHideNextButton);
    WolFoxInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"setPreviousButtonEnabled:",
                              (IMP)WolFoxSetPreviousButtonEnabled,
                              &OriginalSetPreviousButtonEnabled);
    WolFoxInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"setNextButtonEnabled:",
                              (IMP)WolFoxSetNextButtonEnabled,
                              &OriginalSetNextButtonEnabled);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"playerBarControllerShouldShowPlayerBarView:",
                              (IMP)WolFoxPlayerBarShouldShow,
                              &OriginalPlayerBarShouldShow);
    WolFoxInstallInstanceHook(@"YTAutonavEndscreenController",
                              @"showEndscreen",
                              (IMP)WolFoxAutonavShowEndscreen,
                              &OriginalAutonavShowEndscreen);
    WolFoxInstallInstanceHook(@"ELMImageNode",
                              @"controllerDidApplyProperties",
                              (IMP)WolFoxWatermarkNodeApply,
                              &OriginalWatermarkNodeApply);
}

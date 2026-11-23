#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalSheetLayout;
static IMP OriginalSheetAppear;
static IMP OriginalContextualAppear;
static IMP OriginalSheetWillAppear;
static IMP OriginalModalShow;
static IMP OriginalModalReposition;
static IMP OriginalContextualWillAppear;
static IMP OriginalContextualLayout;

static const void *WolFoxSheetGlassAssociation = &WolFoxSheetGlassAssociation;

// WolFox sheet palette: keep the native glass effect, then add a restrained
// navy surface and red focus treatment without changing the sheet hierarchy.
static UIColor *WolFoxWolFoxNavySurface(void) {
    return [UIColor colorWithRed:0.025 green:0.055 blue:0.11 alpha:0.82];
}

static UIColor *WolFoxWolFoxRedAccent(void) {
    return [UIColor colorWithRed:0.95 green:0.12 blue:0.16 alpha:1.0];
}

static BOOL WolFoxSheetGlassEnabled(void) {
    return WolFoxLiquidGlassAvailable() && WolFoxFeatureEnabled(@"YTKACE.Preference.Glass.Menus");
}

static UIView *WolFoxFindViewOfClass(UIView *root, NSString *name) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count != 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([NSStringFromClass(view.class) isEqualToString:name]) return view;
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static BOOL WolFoxColorIsSolid(UIColor *color) {
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    return color != nil && [color getRed:&red green:&green blue:&blue alpha:&alpha] && alpha > 0.3;
}

static BOOL WolFoxIsSheetContainer(UIView *view) {
    static NSSet<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[@"YTDraggableView", @"YTDialogContainerScrollView", @"GOODialogView",
                                      @"YTContextualWrapView", @"YTActionSheetHeaderView", @"UIScrollView",
                                      @"GOODialogContentView", @"YTMinimumWidthDialogView"]];
    });
    return [names containsObject:NSStringFromClass(view.class)];
}

static BOOL WolFoxIsELMRoot(UIView *view) {
    return [NSStringFromClass(view.class) hasSuffix:@"ELMView"];
}

static BOOL WolFoxIsELMView(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return WolFoxIsELMRoot(view) || [name hasPrefix:@"_AS"] || [name hasPrefix:@"AS"];
}

static void WolFoxClearELMBackground(UIView *view, UIView *sheet, NSInteger depth) {
    if (depth > 4) return;
    for (UIView *subview in view.subviews) {
        if (![NSStringFromClass(subview.class) isEqualToString:@"_ASDisplayView"]) continue;
        if (WolFoxColorIsSolid(subview.backgroundColor) &&
            CGRectGetWidth(subview.bounds) >= CGRectGetWidth(sheet.bounds) * 0.9 &&
            CGRectGetHeight(subview.bounds) >= 40.0) {
            id node = nil;
            @try { node = [subview valueForKey:@"asyncdisplaykit_node"]; } @catch (__unused NSException *exception) {}
            if ([node respondsToSelector:@selector(setBackgroundColor:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(node, @selector(setBackgroundColor:), UIColor.clearColor);
            } else {
                subview.backgroundColor = UIColor.clearColor;
            }
        }
        WolFoxClearELMBackground(subview, sheet, depth + 1);
    }
}

static void WolFoxClearSheetBackgrounds(UIView *view, UIView *sheet, UIView *glass, NSInteger depth) {
    if (depth > 10) return;
    for (UIView *subview in view.subviews) {
        if (subview == glass) continue;
        if (WolFoxIsELMRoot(subview)) {
            WolFoxClearELMBackground(subview, sheet, 0);
            continue;
        }
        if (WolFoxIsELMView(subview)) continue;
        if (WolFoxIsSheetContainer(subview) && WolFoxColorIsSolid(subview.backgroundColor)) {
            subview.backgroundColor = UIColor.clearColor;
        }
        WolFoxClearSheetBackgrounds(subview, sheet, glass, depth + 1);
    }
}

static UIVisualEffect *WolFoxSheetGlassEffect(void) {
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    return [effectClass respondsToSelector:styleSelector]
        ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, 0)
        : [effectClass new];
}

static void WolFoxClearShadows(UIView *view, UIView *stop) {
    for (UIView *current = view; current != nil && current != stop; current = current.superview) {
        if (current.layer.shadowOpacity > 0.0) current.layer.shadowOpacity = 0.0;
    }
}

static void WolFoxApplyPanelGlass(UIView *sheet, CGFloat fallbackRadius);

static void WolFoxApplySheetGlass(UIViewController *controller) {
    if (!WolFoxSheetGlassEnabled() || !controller.isViewLoaded) return;
    UIView *sheet = WolFoxFindViewOfClass(controller.view, @"YTDraggableView");
    if (sheet == nil) {
        sheet = WolFoxFindViewOfClass(controller.view, @"YTContextualWrapView");
        if (sheet != nil) {
            WolFoxClearShadows(sheet, controller.view.window);
            for (UIView *current = sheet; current != nil; current = current.superview) {
                SEL shadow = NSSelectorFromString(@"shadowLayer");
                if ([NSStringFromClass(current.class) isEqualToString:@"YTContextualSheetView"] &&
                    [current respondsToSelector:shadow]) {
                    CALayer *layer = ((id (*)(id, SEL))objc_msgSend)(current, shadow);
                    layer.shadowOpacity = 0.0;
                    layer.shadowPath = NULL;
                    current.layer.shadowOpacity = 0.0;
                    break;
                }
            }
        }
    }
    if (sheet == nil || CGRectIsEmpty(sheet.bounds)) return;
    WolFoxApplyPanelGlass(sheet, 24.0);
}

static void WolFoxApplyPanelGlass(UIView *sheet, CGFloat fallbackRadius) {
    UIVisualEffectView *glass = objc_getAssociatedObject(sheet, WolFoxSheetGlassAssociation);
    if (glass == nil) {
        glass = [[UIVisualEffectView alloc] initWithEffect:WolFoxSheetGlassEffect()];
        glass.userInteractionEnabled = NO;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(sheet, WolFoxSheetGlassAssociation, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != sheet) [sheet insertSubview:glass atIndex:0];
    else if (sheet.subviews.firstObject != glass) [sheet sendSubviewToBack:glass];
    glass.frame = sheet.bounds;
    CGFloat radius = sheet.layer.cornerRadius > 0.0 ? sheet.layer.cornerRadius : fallbackRadius;
    glass.layer.cornerRadius = radius;
    glass.layer.maskedCorners = sheet.layer.cornerRadius > 0.0 ? sheet.layer.maskedCorners
        : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner);
    glass.backgroundColor = WolFoxWolFoxNavySurface();
    glass.layer.borderColor = [WolFoxWolFoxRedAccent() colorWithAlphaComponent:0.34].CGColor;
    glass.layer.borderWidth = 1.0;
    // Inherit the host's semantic direction; do not rearrange content or
    // assume a left-to-right button order for RTL layouts.
    glass.semanticContentAttribute = sheet.semanticContentAttribute;
    sheet.backgroundColor = UIColor.clearColor;
    sheet.tintColor = WolFoxWolFoxRedAccent();
    WolFoxClearSheetBackgrounds(sheet, sheet, glass, 0);
}

static void WolFoxApplySheetGlassLater(UIViewController *controller) {
    __weak UIViewController *weakController = controller;
    for (NSNumber *delay in @[@0.05, @0.15, @0.3, @0.5, @0.8, @1.2]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strong = weakController;
            if (strong == nil || strong.view.window == nil) return;
            WolFoxApplySheetGlass(strong);
        });
    }
}

static void WolFoxSheetLayout(UIViewController *receiver, SEL selector) {
    if (OriginalSheetLayout != NULL) ((void (*)(id, SEL))OriginalSheetLayout)(receiver, selector);
    if (!WolFoxSheetGlassEnabled()) return;
    __weak UIViewController *weakController = receiver;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = weakController;
        if (controller != nil) WolFoxApplySheetGlass(controller);
    });
}

static void WolFoxSheetWillAppear(UIViewController *receiver, SEL selector, BOOL animated) {
    if (OriginalSheetWillAppear != NULL) ((void (*)(id, SEL, BOOL))OriginalSheetWillAppear)(receiver, selector, animated);
    if (!WolFoxSheetGlassEnabled()) return;
    [receiver.view layoutIfNeeded];
    WolFoxApplySheetGlass(receiver);
}

static void WolFoxApplyModalGlass(UIView *modal) {
    if (!WolFoxSheetGlassEnabled() || modal.window == nil) return;
    UIView *dialog = nil;
    @try { dialog = [modal valueForKey:@"_dialogView"]; } @catch (__unused NSException *exception) {}
    if (![dialog isKindOfClass:UIView.class] || CGRectIsEmpty(dialog.bounds)) return;
    WolFoxClearShadows(dialog, modal.superview);
    dialog.layer.shadowOpacity = 0.0;
    WolFoxApplyPanelGlass(dialog, 28.0);
    UIVisualEffectView *glass = objc_getAssociatedObject(dialog, WolFoxSheetGlassAssociation);
    glass.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
        kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    if (dialog.layer.cornerRadius < 12.0) {
        dialog.layer.cornerRadius = 28.0;
        dialog.layer.cornerCurve = kCACornerCurveContinuous;
    }
    dialog.clipsToBounds = YES;
}

static IMP OriginalAlertLayout;
static IMP OriginalAlertReveal;
static IMP OriginalYTAlertLayout;
static IMP OriginalReportLayout;
static IMP OriginalReportReveal;
static IMP OriginalContextualBegin;
static IMP OriginalContextualContainerLayout;

static void WolFoxAlertLayout(UIView *receiver, SEL selector) {
    if (OriginalAlertLayout != NULL) ((void (*)(id, SEL))OriginalAlertLayout)(receiver, selector);
    WolFoxApplyModalGlass(receiver);
}

static void WolFoxAlertReveal(UIView *receiver, SEL selector) {
    if (OriginalAlertReveal != NULL) ((void (*)(id, SEL))OriginalAlertReveal)(receiver, selector);
    WolFoxApplyModalGlass(receiver);
}

static void WolFoxYTAlertLayout(UIView *receiver, SEL selector) {
    if (OriginalYTAlertLayout != NULL) ((void (*)(id, SEL))OriginalYTAlertLayout)(receiver, selector);
    WolFoxApplyModalGlass(receiver);
}

static void WolFoxReportLayout(UIView *receiver, SEL selector) {
    if (OriginalReportLayout != NULL) ((void (*)(id, SEL))OriginalReportLayout)(receiver, selector);
    WolFoxApplyModalGlass(receiver);
}

static void WolFoxReportReveal(UIView *receiver, SEL selector) {
    if (OriginalReportReveal != NULL) ((void (*)(id, SEL))OriginalReportReveal)(receiver, selector);
    WolFoxApplyModalGlass(receiver);
}

static void WolFoxContextualBegin(UIPresentationController *receiver, SEL selector) {
    if (OriginalContextualBegin != NULL) ((void (*)(id, SEL))OriginalContextualBegin)(receiver, selector);
    UIViewController *presented = receiver.presentedViewController;
    [presented.view layoutIfNeeded];
    WolFoxApplySheetGlass(presented);
}

static void WolFoxContextualContainerLayout(UIPresentationController *receiver, SEL selector) {
    if (OriginalContextualContainerLayout != NULL) {
        ((void (*)(id, SEL))OriginalContextualContainerLayout)(receiver, selector);
    }
    WolFoxApplySheetGlass(receiver.presentedViewController);
}

static void WolFoxModalShow(UIView *receiver, SEL selector) {
    if (OriginalModalShow != NULL) ((void (*)(id, SEL))OriginalModalShow)(receiver, selector);
    WolFoxApplyModalGlass(receiver);
}

static void WolFoxModalReposition(UIView *receiver, SEL selector) {
    if (OriginalModalReposition != NULL) ((void (*)(id, SEL))OriginalModalReposition)(receiver, selector);
    WolFoxApplyModalGlass(receiver);
}

static void WolFoxSheetAppear(UIViewController *receiver, SEL selector, BOOL animated) {
    if (OriginalSheetAppear != NULL) ((void (*)(id, SEL, BOOL))OriginalSheetAppear)(receiver, selector, animated);
    WolFoxApplySheetGlass(receiver);
    WolFoxApplySheetGlassLater(receiver);
}

static void WolFoxContextualAppear(UIViewController *receiver, SEL selector, BOOL animated) {
    if (OriginalContextualAppear != NULL) ((void (*)(id, SEL, BOOL))OriginalContextualAppear)(receiver, selector, animated);
    WolFoxApplySheetGlass(receiver);
    WolFoxApplySheetGlassLater(receiver);
}

static void WolFoxContextualWillAppear(UIViewController *receiver, SEL selector, BOOL animated) {
    if (OriginalContextualWillAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalContextualWillAppear)(receiver, selector, animated);
    }
    [receiver.view layoutIfNeeded];
    WolFoxApplySheetGlass(receiver);
}

static void WolFoxContextualLayout(UIViewController *receiver, SEL selector) {
    if (OriginalContextualLayout != NULL) ((void (*)(id, SEL))OriginalContextualLayout)(receiver, selector);
    if (!WolFoxSheetGlassEnabled()) return;
    __weak UIViewController *weakController = receiver;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = weakController;
        if (controller != nil) WolFoxApplySheetGlass(controller);
    });
}

__attribute__((constructor)) static void WolFoxInstallGlassSheets(void) {
    if (!WolFoxLiquidGlassAvailable()) return;
    WolFoxInstallInstanceHook(@"YTBottomSheetController", @"viewWillLayoutSubviews",
                              (IMP)WolFoxSheetLayout, &OriginalSheetLayout);
    WolFoxInstallInstanceHook(@"YTBottomSheetController", @"viewDidAppear:",
                              (IMP)WolFoxSheetAppear, &OriginalSheetAppear);
    WolFoxInstallInstanceHook(@"YTBottomSheetController", @"viewWillAppear:",
                              (IMP)WolFoxSheetWillAppear, &OriginalSheetWillAppear);
    WolFoxInstallInstanceHook(@"GOOAlertView", @"layoutSubviews",
                              (IMP)WolFoxAlertLayout, &OriginalAlertLayout);
    WolFoxInstallInstanceHook(@"GOOAlertView", @"revealDialog",
                              (IMP)WolFoxAlertReveal, &OriginalAlertReveal);
    WolFoxInstallInstanceHook(@"YTAlertView", @"layoutSubviews",
                              (IMP)WolFoxYTAlertLayout, &OriginalYTAlertLayout);
    WolFoxInstallInstanceHook(@"YTReportFormModalAlertView", @"layoutSubviews",
                              (IMP)WolFoxReportLayout, &OriginalReportLayout);
    WolFoxInstallInstanceHook(@"YTReportFormModalAlertView", @"revealDialog",
                              (IMP)WolFoxReportReveal, &OriginalReportReveal);
    WolFoxInstallInstanceHook(@"YTContextualSheetPresentationController", @"presentationTransitionWillBegin",
                              (IMP)WolFoxContextualBegin, &OriginalContextualBegin);
    WolFoxInstallInstanceHook(@"YTContextualSheetPresentationController", @"containerViewDidLayoutSubviews",
                              (IMP)WolFoxContextualContainerLayout, &OriginalContextualContainerLayout);
    WolFoxInstallInstanceHook(@"GOOModalView", @"show",
                              (IMP)WolFoxModalShow, &OriginalModalShow);
    WolFoxInstallInstanceHook(@"GOOModalView", @"reposition",
                              (IMP)WolFoxModalReposition, &OriginalModalReposition);
    WolFoxInstallInstanceHook(@"YTContextualSheetViewController", @"viewDidAppear:",
                              (IMP)WolFoxContextualAppear, &OriginalContextualAppear);
    WolFoxInstallInstanceHook(@"YTContextualSheetViewController", @"viewWillAppear:",
                              (IMP)WolFoxContextualWillAppear, &OriginalContextualWillAppear);
    WolFoxInstallInstanceHook(@"YTContextualSheetViewController", @"viewWillLayoutSubviews",
                              (IMP)WolFoxContextualLayout, &OriginalContextualLayout);
}

#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalFrostedLayout;
static IMP OriginalFrostedMoveToWindow;
static const void *WolFoxPlayerGlassAssociation = &WolFoxPlayerGlassAssociation;

static BOOL WolFoxInPlayerControls(UIView *view) {
    NSUInteger depth = 0;
    for (UIView *current = view.superview; current != nil && depth < 10; current = current.superview, depth++) {
        NSString *name = NSStringFromClass(current.class);
        if ([name containsString:@"Overlay"] || [name containsString:@"Player"] ||
            [name containsString:@"Fullscreen"] || [name containsString:@"Watch"]) return YES;
    }
    return NO;
}

static NSArray<UIView *> *WolFoxFrostedLayers(UIView *frosted) {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    for (NSString *key in @[@"_blurEffectView", @"_overlayView"]) {
        id view = nil;
        @try { view = [frosted valueForKey:key]; } @catch (__unused NSException *exception) {}
        if ([view isKindOfClass:UIView.class]) [views addObject:view];
    }
    return views;
}

static void WolFoxApplyFrostedGlass(UIView *receiver) {
    UIVisualEffectView *glass = objc_getAssociatedObject(receiver, WolFoxPlayerGlassAssociation);
    BOOL enabled = WolFoxLiquidGlassAvailable() && WolFoxFeatureEnabled(@"YTKACE.Preference.Glass.Player");
    BOOL wanted = enabled && WolFoxInPlayerControls(receiver);
    if (!wanted) {
        if (glass != nil) {
            [glass removeFromSuperview];
            for (UIView *layer in WolFoxFrostedLayers(receiver)) layer.alpha = 1.0;
        }
        return;
    }
    if (glass == nil) {
        Class effectClass = NSClassFromString(@"UIGlassEffect");
        SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
        UIVisualEffect *effect = [effectClass respondsToSelector:styleSelector]
            ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, 0)
            : [effectClass new];
        if (effect == nil) return;
        glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.userInteractionEnabled = NO;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.clipsToBounds = YES;
        objc_setAssociatedObject(receiver, WolFoxPlayerGlassAssociation, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIView *layer in WolFoxFrostedLayers(receiver)) layer.alpha = 0.0;
    if (glass.superview != receiver) [receiver insertSubview:glass atIndex:0];
    glass.frame = receiver.bounds;
    CGFloat radius = receiver.layer.cornerRadius;
    CGFloat capsule = MIN(CGRectGetWidth(receiver.bounds), CGRectGetHeight(receiver.bounds)) * 0.5;
    glass.layer.cornerRadius = radius > 0.0 ? MIN(radius, capsule) : capsule;
    receiver.backgroundColor = UIColor.clearColor;
}

static void WolFoxFrostedLayout(UIView *receiver, SEL selector) {
    if (OriginalFrostedLayout != NULL) ((void (*)(id, SEL))OriginalFrostedLayout)(receiver, selector);
    WolFoxApplyFrostedGlass(receiver);
}

static void WolFoxFrostedMoveToWindow(UIView *receiver, SEL selector) {
    if (OriginalFrostedMoveToWindow != NULL) ((void (*)(id, SEL))OriginalFrostedMoveToWindow)(receiver, selector);
    if (receiver.window != nil) [receiver setNeedsLayout];
}

__attribute__((constructor)) static void WolFoxInstallPlayerGlass(void) {
    if (!WolFoxLiquidGlassAvailable()) return;
    WolFoxInstallInstanceHook(@"YTFrostedGlassView", @"layoutSubviews",
                              (IMP)WolFoxFrostedLayout, &OriginalFrostedLayout);
    WolFoxInstallInstanceHook(@"YTFrostedGlassView", @"didMoveToWindow",
                              (IMP)WolFoxFrostedMoveToWindow, &OriginalFrostedMoveToWindow);
}

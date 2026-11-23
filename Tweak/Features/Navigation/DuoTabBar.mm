// YouTube's tabs in the iPhone Duo's system vertical tab bar.
//
// On the Duo (iOS 27.1 and later) the system draws a tab bar controller's tabs
// in the vertical bar beside the status items: a glass column that expands
// with labels when held or dragged. YouTube's Duo layout draws its own floating
// column instead (YTFloatingPivotBarView), which has none of that behavior.
//
// While the vertical bar shows, YouTube's tabs are mirrored into the system bar
// with DuoKit's DUOMirroredTabBar (Vendor/DuoKit). Choosing a tab presses
// YouTube's own tab, so YouTube's navigation runs unchanged; YouTube's column
// stays laid out but is not drawn or touchable. Unfolded portrait has no
// vertical bar, so there the tabs go to the system's floating bottom tab bar.
// On other iPhones nothing changes.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "DuoKit.h"
#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

void WolFoxSelectPivotItem(UIView *item);

NSString * const WolFoxDuoNativeTabBarKey = @"YTKACE.Preference.Tabs.DuoNativeBar";

// YTKACE draws some tabs' icons and labels in its own views, with YouTube's
// button image and title hidden or empty (TabBarHooks.mm): its own tab with
// the first pair of tags, and added tabs such as History with the second.
static const NSInteger WolFoxTabIconTags[] = {0x59414345, 0x59414349};
static const NSInteger WolFoxTabLabelTags[] = {0x59414347, 0x5941434A};

#pragma mark - Reading YouTube's tabs

static void WolFoxCollectItems(UIView *view, NSMutableArray<UIView *> *items) {
    for (UIView *subview in view.subviews) {
        if ([NSStringFromClass(subview.class) isEqualToString:@"YTPivotBarItemView"]) {
            if (!subview.hidden && CGRectGetWidth(subview.bounds) > 0.0) [items addObject:subview];
            continue;
        }
        WolFoxCollectItems(subview, items);
    }
}

static NSArray<UIView *> *WolFoxBarItems(UIView *bar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    WolFoxCollectItems(bar, items);
    [items sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGRect fa = [a convertRect:a.bounds toView:bar];
        CGRect fb = [b convertRect:b.bounds toView:bar];
        if (fabs(CGRectGetMinY(fa) - CGRectGetMinY(fb)) > 1.0) {
            return CGRectGetMinY(fa) < CGRectGetMinY(fb) ? NSOrderedAscending : NSOrderedDescending;
        }
        return CGRectGetMinX(fa) < CGRectGetMinX(fb) ? NSOrderedAscending : NSOrderedDescending;
    }];
    return items;
}

static UIButton *WolFoxItemButton(UIView *item) {
    SEL selector = NSSelectorFromString(@"navigationButton");
    id button = [item respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(item, selector) : nil;
    return [button isKindOfClass:UIButton.class] ? button : nil;
}

static NSString *WolFoxItemTitle(UIView *item) {
    for (NSInteger tag : WolFoxTabLabelTags) {
        UILabel *custom = (UILabel *)[item viewWithTag:tag];
        if ([custom isKindOfClass:UILabel.class] && custom.text.length) return custom.text;
    }
    NSString *title = WolFoxItemButton(item).titleLabel.text;
    if (title.length) return title;
    for (UIView *subview in item.subviews) {
        if (subview.accessibilityLabel.length) return subview.accessibilityLabel;
    }
    return item.accessibilityLabel ?: @"";
}

static UIImage *WolFoxItemImage(UIView *item) {
    for (NSInteger tag : WolFoxTabIconTags) {
        UIImageView *custom = (UIImageView *)[item viewWithTag:tag];
        if ([custom isKindOfClass:UIImageView.class] && !custom.hidden && custom.image) return custom.image;
    }
    UIButton *button = WolFoxItemButton(item);
    return button.imageView.image ?: button.currentImage;
}

static BOOL WolFoxItemSelected(UIView *item) {
    SEL selector = NSSelectorFromString(@"isSelected");
    if ([item respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(item, selector)) return YES;
    return (item.accessibilityTraits & UIAccessibilityTraitSelected) != 0;
}

#pragma mark - Mirroring

static DUOMirroredTabBar *WolFoxDuoTabs;
static __weak UIView *WolFoxDuoBar;
static NSPointerArray *WolFoxDuoItems;
// YouTube shows a filled icon on the selected tab only, so each tab's outline
// and filled icons are remembered by title as they appear.
static NSMutableDictionary<NSString *, UIImage *> *WolFoxDuoIcons;
static NSMutableDictionary<NSString *, UIImage *> *WolFoxDuoSelectedIcons;

// With YTKACE's debug logs on, records each change in what one bar decided
// and why, so a case seen only on a phone can be read back from its log.
static void WolFoxLogDuoDecision(UIView *bar, NSString *decision) {
    static NSMapTable<UIView *, NSString *> *last;
    if (last == nil) last = [NSMapTable weakToStrongObjectsMapTable];
    if ([[last objectForKey:bar] isEqualToString:decision]) return;
    [last setObject:decision forKey:bar];
    WolFoxDebugLog(@"duo-tabs", @"bar %p %@ frame=%@ window=%@ %@", bar, decision,
                   NSStringFromCGRect([bar convertRect:bar.bounds toView:nil]),
                   NSStringFromClass(bar.window.class), NSStringFromCGRect(bar.window.bounds));
}

static void WolFoxUpdateDuoTabs(UIView *bar) {
    BOOL enabled = WolFoxFeatureEnabled(WolFoxDuoNativeTabBarKey);
    BOOL showing = DUOViewShowing(bar);
    NSArray<UIView *> *items = enabled && showing ? WolFoxBarItems(bar) : @[];
    NSInteger edge = DUOVerticalBarEdge(bar.window);
    // Unfolded portrait has no vertical bar; on a Duo the system's floating
    // bottom tab bar takes YouTube's tabs there, so every pose has the same
    // bar. Other iPhones keep YouTube's own bar.
    DUOObserveHinge(bar);
    BOOL bottomBar = DUOIsDuo();
    if (items.count == 0 || (edge == 0 && !bottomBar)) {
        WolFoxLogDuoDecision(bar, [NSString stringWithFormat:@"youtube column: enabled=%d showing=%d items=%lu edge=%ld alpha=%.2f hidden=%d",
                                   enabled, showing, (unsigned long)items.count, (long)edge, bar.alpha, bar.hidden]);
        if (WolFoxDuoBar == bar || WolFoxDuoBar == nil) [WolFoxDuoTabs hide];
        DUOSetViewCovered(bar, NO);
        return;
    }
    if (WolFoxDuoTabs == nil) {
        WolFoxDuoIcons = [NSMutableDictionary dictionary];
        WolFoxDuoSelectedIcons = [NSMutableDictionary dictionary];
        WolFoxDuoTabs = [[DUOMirroredTabBar alloc] initWithSelectHandler:^(NSUInteger index) {
            UIView *item = index < WolFoxDuoItems.count
                ? (__bridge UIView *)[WolFoxDuoItems pointerAtIndex:index] : nil;
            if (item != nil) WolFoxSelectPivotItem(item);
        }];
    }
    WolFoxDuoBar = bar;
    WolFoxDuoItems = [NSPointerArray weakObjectsPointerArray];
    NSMutableArray<DUOMirroredTab *> *tabs = [NSMutableArray array];
    NSUInteger selectedIndex = NSNotFound;
    for (UIView *item in items) {
        NSString *title = WolFoxItemTitle(item);
        BOOL selected = WolFoxItemSelected(item);
        if (selected) selectedIndex = tabs.count;
        UIImage *image = WolFoxItemImage(item);
        if (image != nil) (selected ? WolFoxDuoSelectedIcons : WolFoxDuoIcons)[title] = image;
        [tabs addObject:[DUOMirroredTab tabWithTitle:title
                                               image:WolFoxDuoIcons[title]
                                       selectedImage:WolFoxDuoSelectedIcons[title]]];
        [WolFoxDuoItems addPointer:(__bridge void *)item];
    }
    WolFoxDuoTabs.showsBottomBar = bottomBar;
    BOOL shown = [WolFoxDuoTabs showTabs:tabs selectedIndex:selectedIndex inWindow:bar.window];
    WolFoxLogDuoDecision(bar, [NSString stringWithFormat:@"%@: %lu tabs, edge=%ld",
                               shown ? @"system bar" : @"youtube column (system bar refused)",
                               (unsigned long)tabs.count, (long)edge]);
    DUOSetViewCovered(bar, shown);
}

// Layout runs often; update once per run loop turn.
static void WolFoxScheduleDuoTabs(UIView *bar) {
    static NSHashTable<UIView *> *pending;
    if (pending == nil) pending = [NSHashTable weakObjectsHashTable];
    if ([pending containsObject:bar]) return;
    [pending addObject:bar];
    __weak UIView *weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongBar = weakBar;
        if (strongBar == nil) return;
        [pending removeObject:strongBar];
        WolFoxUpdateDuoTabs(strongBar);
    });
}

static UIView *WolFoxFloatingBarAncestor(UIView *view) {
    for (UIView *current = view; current != nil; current = current.superview) {
        if ([NSStringFromClass(current.class) isEqualToString:@"YTFloatingPivotBarView"]) return current;
    }
    return nil;
}

#pragma mark - Hooks

static IMP WolFoxOrigFloatingLayout;
static IMP WolFoxOrigFloatingMoveToWindow;

static void WolFoxFloatingLayout(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))WolFoxOrigFloatingLayout)(self, _cmd);
    WolFoxScheduleDuoTabs(self);
}

static void WolFoxFloatingMoveToWindow(UIView *self, SEL _cmd) {
    if (WolFoxOrigFloatingMoveToWindow) ((void (*)(id, SEL))WolFoxOrigFloatingMoveToWindow)(self, _cmd);
    WolFoxScheduleDuoTabs(self);
}

// Called from TabBarHooks.mm's setSelected: hook (a method is hooked once).
void WolFoxDuoTabsSelectionChanged(UIView *item) {
    if (!DUOIsDuo()) return;
    UIView *bar = WolFoxFloatingBarAncestor(item);
    if (bar != nil) WolFoxScheduleDuoTabs(bar);
}

void WolFoxInstallDuoTabBarHooks(void) {
    if (!DUOIsDuo()) return;
    if (NSClassFromString(@"YTFloatingPivotBarView") == Nil) return;
    WolFoxInstallInstanceHook(@"YTFloatingPivotBarView", @"layoutSubviews",
                              (IMP)WolFoxFloatingLayout, &WolFoxOrigFloatingLayout);
    WolFoxInstallInstanceHook(@"YTFloatingPivotBarView", @"didMoveToWindow",
                              (IMP)WolFoxFloatingMoveToWindow, &WolFoxOrigFloatingMoveToWindow);
}

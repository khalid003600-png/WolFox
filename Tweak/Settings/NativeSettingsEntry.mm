#import "WolFoxSettingsPages.h"
#import "WolFoxSettingsSearch.h"
#import "../Runtime/Localization.h"
#import "WolFoxRootOptionsController.h"
#import "WolFoxDownloadsController.h"
#import "../Runtime/Hooking.h"
#import "../UI/Assets.h"
#import "../WolFox.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static const NSUInteger WolFoxNativeSettingsCategory = 0x796b6361;
static const NSUInteger WolFoxNativeSettingsGroup = 0x796b6163;
static NSString *const WolFoxInertIdentifier = @"WolFoxInertItem";
static const NSInteger WolFoxSearchFieldTag = 0x5954534B;
static const void *WolFoxSettingIconImageKey = &WolFoxSettingIconImageKey;
static IMP OriginalSettingsCategoryOrder;
static IMP OriginalUpdateSettingsSection;
static IMP OriginalOrderedSettingsGroups;
static IMP OriginalSettingsGroupTitle;
static IMP OriginalOrderedGroupCategories;
static IMP OriginalSettingsCellLayout;

typedef UIViewController * _Nonnull (^WolFoxNativeBuilder)(void);

static NSArray<NSDictionary *> *WolFoxNativeLayout(void) {
    NSMutableArray *layout = [NSMutableArray arrayWithArray:@[
        @{@"kind": @"search"},
        @{@"kind": @"row", @"title": @"Downloads & Library"}
    ]];
    for (NSDictionary *section in WolFoxSettingsMenu()) {
        [layout addObject:@{@"kind": @"header", @"title": section[@"header"]}];
        for (NSDictionary *row in section[@"rows"]) {
            [layout addObject:@{@"kind": @"row", @"title": row[@"title"], @"id": row[@"id"]}];
        }
    }
    [layout addObject:@{@"kind": @"footer"}];
    return layout;
}

static NSDictionary *WolFoxNativeMenuRow(NSString *title) {
    for (NSDictionary *section in WolFoxSettingsMenu()) {
        for (NSDictionary *row in section[@"rows"]) {
            if ([row[@"title"] isEqualToString:title]) return row;
        }
    }
    return nil;
}

static NSArray *WolFoxSettingsCategoryOrder(id receiver, SEL selector) {
    NSArray *order = OriginalSettingsCategoryOrder == NULL ? @[] :
        ((id (*)(id, SEL))OriginalSettingsCategoryOrder)(receiver, selector);
    if ([order containsObject:@(WolFoxNativeSettingsCategory)]) return order;
    NSMutableArray *updated = [order mutableCopy] ?: [NSMutableArray array];
    NSUInteger index = [updated indexOfObject:@1];
    [updated insertObject:@(WolFoxNativeSettingsCategory)
                  atIndex:index == NSNotFound ? updated.count : index + 1];
    return updated;
}

static NSArray *WolFoxOrderedSettingsGroups(id receiver, SEL selector) {
    NSArray *groups = OriginalOrderedSettingsGroups == NULL ? @[] :
        ((id (*)(id, SEL))OriginalOrderedSettingsGroups)(receiver, selector);
    Class groupClass = NSClassFromString(@"YTSettingsGroupData");
    SEL initializer = NSSelectorFromString(@"initWithGroupType:");
    if (groupClass == Nil || ![groupClass instancesRespondToSelector:initializer]) return groups;
    id group = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(
        [groupClass alloc], initializer, WolFoxNativeSettingsGroup);
    if (group == nil) return groups;
    NSMutableArray *updated = [groups mutableCopy] ?: [NSMutableArray array];
    [updated insertObject:group atIndex:0];
    return updated;
}

static NSString *WolFoxSettingsGroupTitle(id receiver, SEL selector, NSUInteger type) {
    if (type == WolFoxNativeSettingsGroup) return @"WolFox";
    return OriginalSettingsGroupTitle == NULL ? nil :
        ((id (*)(id, SEL, NSUInteger))OriginalSettingsGroupTitle)(receiver, selector, type);
}

static NSArray *WolFoxOrderedGroupCategories(id receiver, SEL selector, NSUInteger type) {
    if (type == WolFoxNativeSettingsGroup) return @[@(WolFoxNativeSettingsCategory)];
    return OriginalOrderedGroupCategories == NULL ? @[] :
        ((id (*)(id, SEL, NSUInteger))OriginalOrderedGroupCategories)(receiver, selector, type);
}

static NSString *WolFoxNativeSettingsSubtitle(NSString *title) {
    NSString *value = WolFoxNativeMenuRow(title)[@"detail"];
    if ([title isEqualToString:@"Downloads & Library"]) value = @"Saved video, audio, Shorts, imports and backups";
    return value != nil ? WolFoxLocalized(value) : nil;
}

static UIImage *WolFoxSettingIconStoredImage(id receiver) {
    return objc_getAssociatedObject(receiver, WolFoxSettingIconImageKey);
}

static UIImage *WolFoxTintedIcon(UIImage *image, UIColor *color) {
    if (image == nil) return nil;
    UIColor *fill = color ?: UIColor.labelColor;
    UIGraphicsImageRendererFormat *format =
        UIGraphicsImageRendererFormat.preferredFormat;
    format.opaque = NO;
    format.scale = image.scale;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format];
    UIImage *tinted = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        CGRect bounds = CGRectMake(0.0, 0.0, image.size.width, image.size.height);
        [image drawInRect:bounds];
        [fill set];
        UIRectFillUsingBlendMode(bounds, kCGBlendModeSourceIn);
    }];
    return [tinted imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static id WolFoxIconImageForStyle(id receiver, SEL selector, long long style) {
    (void)selector;
    (void)style;
    return WolFoxTintedIcon(WolFoxSettingIconStoredImage(receiver), nil);
}

static id WolFoxIconImageForColor(id receiver, SEL selector, UIColor *color) {
    (void)selector;
    return WolFoxTintedIcon(WolFoxSettingIconStoredImage(receiver), color);
}

static id WolFoxIconImageForSelected(id receiver, SEL selector, BOOL selected) {
    (void)selector;
    (void)selected;
    return WolFoxTintedIcon(WolFoxSettingIconStoredImage(receiver), nil);
}

static id WolFoxIconImagePlain(id receiver, SEL selector) {
    (void)selector;
    return WolFoxTintedIcon(WolFoxSettingIconStoredImage(receiver), nil);
}

static Class WolFoxSettingIconClass(void) {
    static Class iconClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class superclass = NSClassFromString(@"YTIIcon");
        if (superclass == Nil) return;
        iconClass = objc_allocateClassPair(superclass, "WolFoxSettingIcon", 0);
        if (iconClass == Nil) return;
        class_addMethod(iconClass, NSSelectorFromString(@"iconImageWithPageStyle:"),
                        (IMP)WolFoxIconImageForStyle, "@24@0:8q16");
        class_addMethod(iconClass, NSSelectorFromString(@"delhiIconImageWithPageStyle:"),
                        (IMP)WolFoxIconImageForStyle, "@24@0:8q16");
        class_addMethod(iconClass, NSSelectorFromString(@"iconImageWithColor:"),
                        (IMP)WolFoxIconImageForColor, "@24@0:8@16");
        class_addMethod(iconClass, NSSelectorFromString(@"newIconImageWithColor:"),
                        (IMP)WolFoxIconImageForColor, "@24@0:8@16");
        class_addMethod(iconClass, NSSelectorFromString(@"iconImageWithSelected:"),
                        (IMP)WolFoxIconImageForSelected, "@20@0:8B16");
        class_addMethod(iconClass, NSSelectorFromString(@"delhiIconImageWithSelected:"),
                        (IMP)WolFoxIconImageForSelected, "@20@0:8B16");
        class_addMethod(iconClass, NSSelectorFromString(@"iconImageForContextMenu"),
                        (IMP)WolFoxIconImagePlain, "@16@0:8");
        objc_registerClassPair(iconClass);
    });
    return iconClass;
}

static UIImage *WolFoxNativeSettingsIconImage(NSString *title) {
    if ([title isEqualToString:@"SponsorBlock"]) {
        return WolFoxAssetImage(@"sponsorblock_shield_template", @"play.shield");
    }
    if ([title isEqualToString:@"Shorts"]) return WolFoxShortsImage(NO);
    if ([title isEqualToString:@"Downloads & Library"]) {
        return WolFoxDownloadTabImage(NO);
    }
    NSString *symbol = WolFoxNativeMenuRow(title)[@"symbol"];
    return symbol.length != 0 ? [UIImage systemImageNamed:symbol] : nil;
}

static UIImage *WolFoxSquaredIcon(UIImage *image) {
    if (image == nil) return nil;
    CGFloat side = MAX(image.size.width, image.size.height);
    if (side <= 0.0) return image;
    UIGraphicsImageRendererFormat *format =
        UIGraphicsImageRendererFormat.preferredFormat;
    format.opaque = NO;
    format.scale = image.scale;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)
                                               format:format];
    UIImage *padded = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [image drawInRect:CGRectMake((side - image.size.width) / 2.0,
                                     (side - image.size.height) / 2.0,
                                     image.size.width, image.size.height)];
    }];
    return [padded imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static void WolFoxApplyNativeSettingsIcon(id item, NSString *title) {
    SEL setSettingIcon = NSSelectorFromString(@"setSettingIcon:");
    if (item == nil || ![item respondsToSelector:setSettingIcon]) return;
    Class iconClass = WolFoxSettingIconClass();
    UIImage *image = WolFoxSquaredIcon(WolFoxNativeSettingsIconImage(title));
    if (iconClass == Nil || image == nil) return;
    id icon = [iconClass new];
    objc_setAssociatedObject(icon, WolFoxSettingIconImageKey, image,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(item, setSettingIcon, icon);
}

static id WolFoxNativePlainItem(NSString *title, NSString *description) {
    Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
    if (itemClass == Nil) return nil;
    SEL described = NSSelectorFromString(
        @"itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:"
         "selectBlock:");
    if (description != nil && [itemClass respondsToSelector:described]) {
        return ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
            itemClass, described, title, description,
            WolFoxInertIdentifier, nil, nil);
    }
    SEL plain = NSSelectorFromString(
        @"itemWithTitle:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if (![itemClass respondsToSelector:plain]) return nil;
    return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
        itemClass, plain, title, WolFoxInertIdentifier, nil, nil);
}

static void WolFoxMakeItemInert(id item) {
    if (item == nil) return;
    for (NSString *name in @[@"setInkEnabled:", @"setEnabled:", @"setSettingEnabled:"]) {
        SEL selector = NSSelectorFromString(name);
        if ([item respondsToSelector:selector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(item, selector, NO);
        }
    }
}

static void WolFoxSettingsCellLayout(id receiver, SEL selector) {
    if (OriginalSettingsCellLayout != NULL) {
        ((void (*)(id, SEL))OriginalSettingsCellLayout)(receiver, selector);
    }
    if (![receiver isKindOfClass:UIView.class]) return;
    UIView *cell = receiver;
    NSString *identifier = cell.accessibilityIdentifier;
    UIView *host = cell;
    if ([cell respondsToSelector:@selector(contentView)]) {
        UIView *content = ((UIView *(*)(id, SEL))objc_msgSend)(
            cell, @selector(contentView));
        if (content != nil) host = content;
    }
    UISearchBar *field = (UISearchBar *)[host viewWithTag:WolFoxSearchFieldTag];
    if ([identifier isEqualToString:@"WolFoxSearchItem"]) {
        if (field == nil) {
            field = [UISearchBar new];
            field.tag = WolFoxSearchFieldTag;
            field.placeholder = WolFoxLocalized(@"Search");
            field.searchBarStyle = UISearchBarStyleMinimal;
            field.userInteractionEnabled = NO;
            [host addSubview:field];
        }
        field.frame = CGRectInset(host.bounds, -8.0, 0.0);
        [host bringSubviewToFront:field];
        cell.userInteractionEnabled = YES;
        return;
    }
    if (field != nil) [field removeFromSuperview];
    cell.userInteractionEnabled = ![identifier isEqualToString:WolFoxInertIdentifier];
}

static id WolFoxNativeSearchRow(id settingsController) {
    Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
    SEL plain = NSSelectorFromString(
        @"itemWithTitle:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if (itemClass == Nil || ![itemClass respondsToSelector:plain]) return nil;
    __weak id weakController = settingsController;
    BOOL (^select)(id, NSUInteger) = ^BOOL(__unused id cell, __unused NSUInteger index) {
        id controller = weakController;
        if (![controller isKindOfClass:UIViewController.class]) return NO;
        WolFoxPresentSettingsSearchOverlay(controller);
        return YES;
    };
    return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
        itemClass, plain, @" ", @"WolFoxSearchItem", nil, [select copy]);
}

static id WolFoxNativeSettingsItem(NSString *title,
                                   id settingsController,
                                   WolFoxNativeBuilder builder) {
    Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
    SEL selector = NSSelectorFromString(
        @"itemWithTitle:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if (itemClass == Nil || ![itemClass respondsToSelector:selector]) return nil;
    NSString *(^detail)(void) = builder == nil
        ? (NSString *(^)(void))nil
        : ^NSString *{ return @"›"; };
    BOOL (^select)(id, NSUInteger) = builder == nil
        ? (BOOL (^)(id, NSUInteger))nil
        : ^BOOL(__unused id cell, __unused NSUInteger index) {
            UIViewController *controller = builder();
            if (controller == nil) return NO;
            SEL push = NSSelectorFromString(@"pushViewController:");
            if ([settingsController respondsToSelector:push]) {
                ((void (*)(id, SEL, id))objc_msgSend)(settingsController, push, controller);
                return YES;
            }
            UINavigationController *navigation =
                [settingsController isKindOfClass:UIViewController.class]
                    ? ((UIViewController *)settingsController).navigationController : nil;
            [navigation pushViewController:controller animated:YES];
            return navigation != nil;
        };
    SEL described = NSSelectorFromString(
        @"itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:"
         "selectBlock:");
    NSString *subtitle = WolFoxNativeSettingsSubtitle(title);
    NSString *localizedTitle = WolFoxLocalized(title);
    id item = nil;
    if (subtitle.length != 0 && [itemClass respondsToSelector:described]) {
        item = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
            itemClass, described, localizedTitle, subtitle,
            @"WolFoxNativeSettingsItem", detail, select);
    } else {
        item = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
            itemClass, selector, localizedTitle, @"WolFoxNativeSettingsItem",
            detail, select);
    }
    WolFoxApplyNativeSettingsIcon(item, title);
    return item;
}

static void WolFoxUpdateNativeSettingsSection(id receiver, SEL selector,
                                              NSUInteger category, id entry) {
    if (category != WolFoxNativeSettingsCategory) {
        if (OriginalUpdateSettingsSection != NULL) {
            ((void (*)(id, SEL, NSUInteger, id))OriginalUpdateSettingsSection)(
                receiver, selector, category, entry);
        }
        return;
    }

    id settingsController = nil;
    @try {
        settingsController = [receiver valueForKey:@"_settingsViewControllerDelegate"];
    } @catch (__unused NSException *exception) {
        return;
    }
    NSMutableDictionary<NSString *, WolFoxNativeBuilder> *builders = [@{
        @"Downloads & Library": [^UIViewController *{
            WolFoxDownloadsController *controller = [WolFoxDownloadsController new];
            controller.hidesSettingsButton = YES;
            return controller;
        } copy]
    } mutableCopy];
    for (NSDictionary *section in WolFoxSettingsMenu()) {
        for (NSDictionary *row in section[@"rows"]) {
            NSString *pageID = row[@"id"];
            builders[row[@"title"]] = [^UIViewController *{ return WolFoxMakeSettingsPage(pageID); } copy];
        }
    }

    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *definition in WolFoxNativeLayout()) {
        NSString *kind = definition[@"kind"];
        NSString *title = definition[@"title"];
        id item = nil;
        if ([kind isEqualToString:@"search"]) {
            item = WolFoxNativeSearchRow(settingsController);
        } else if ([kind isEqualToString:@"header"]) {
            item = WolFoxNativePlainItem(nil, WolFoxLocalized(title));
            WolFoxMakeItemInert(item);
        } else if ([kind isEqualToString:@"footer"]) {
            NSString *info = [WolFoxDeviceInformationText()
                stringByReplacingOccurrencesOfString:@"\n" withString:@"  •  "];
            item = WolFoxNativePlainItem(nil, info);
            WolFoxMakeItemInert(item);
        } else {
            item = WolFoxNativeSettingsItem(title, settingsController, builders[title]);
        }
        if (item != nil) [items addObject:item];
    }

    SEL modern = NSSelectorFromString(
        @"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
    SEL legacy = NSSelectorFromString(
        @"setSectionItems:forCategory:title:titleDescription:headerHidden:");
    if ([settingsController respondsToSelector:modern]) {
        id icon = [NSClassFromString(@"YTIIcon") new];
        SEL setIconType = NSSelectorFromString(@"setIconType:");
        if ([icon respondsToSelector:setIconType]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(icon, setIconType, 44);
        }
        ((void (*)(id, SEL, id, NSUInteger, id, id, id, BOOL))objc_msgSend)(
            settingsController, modern, items, category, @"WolFox", icon, nil, NO);
    } else if ([settingsController respondsToSelector:legacy]) {
        ((void (*)(id, SEL, id, NSUInteger, id, id, BOOL))objc_msgSend)(
            settingsController, legacy, items, category, @"WolFox", nil, NO);
    }
}

void WolFoxInstallNativeSettingsHooks(void) {
    WolFoxInstallClassHook(@"YTAppSettingsPresentationData", @"settingsCategoryOrder",
                           (IMP)WolFoxSettingsCategoryOrder,
                           &OriginalSettingsCategoryOrder);
    WolFoxInstallInstanceHook(@"YTSettingsSectionItemManager",
                              @"updateSectionForCategory:withEntry:",
                              (IMP)WolFoxUpdateNativeSettingsSection,
                              &OriginalUpdateSettingsSection);
    WolFoxInstallInstanceHook(@"YTSettingsCell", @"layoutSubviews",
                              (IMP)WolFoxSettingsCellLayout,
                              &OriginalSettingsCellLayout);
    WolFoxInstallClassHook(@"YTAppSettingsGroupPresentationData", @"orderedGroups",
                           (IMP)WolFoxOrderedSettingsGroups,
                           &OriginalOrderedSettingsGroups);
    WolFoxInstallInstanceHook(@"YTSettingsGroupData", @"titleForSettingGroupType:",
                              (IMP)WolFoxSettingsGroupTitle,
                              &OriginalSettingsGroupTitle);
    WolFoxInstallInstanceHook(@"YTSettingsGroupData", @"orderedCategoriesForGroupType:",
                              (IMP)WolFoxOrderedGroupCategories,
                              &OriginalOrderedGroupCategories);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSUInteger attempt = 1; attempt <= 60; attempt++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(attempt * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WolFoxInstallNativeSettingsHooks();
            });
        }
    });
}

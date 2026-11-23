#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../Settings/WolFoxDownloadsController.h"
#import "../../UI/Assets.h"
#import "../Interface/NavigationVisibility.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalSetPivotRenderer;
static IMP OriginalSetFloatingPivotRenderer;
static IMP OriginalPivotItemLayout;
static IMP OriginalPivotItemSetSelected;
static IMP OriginalPivotItemTraitChanged;
static IMP OriginalPivotLabelSetHidden;
static IMP OriginalPivotLabelSetAlpha;
static IMP OriginalPivotButtonLayout;
static IMP OriginalPivotBarLayout;
static IMP OriginalPivotControllerAppear;
static IMP OriginalSetDefaultSelectedPivot;
static BOOL WolFoxStartupNative;
static IMP OriginalPivotBarStyleColors;
static IMP OriginalPivotBarSetBackgroundStyle;
static IMP OriginalAppViewDidLoad;
static IMP OriginalBrowseViewDidLoad;
static IMP OriginalBrowseResponseViewDidLoad;
static IMP OriginalWrapperViewDidLoad;
static const void *WolFoxDownloadsAssociation = &WolFoxDownloadsAssociation;
static const void *WolFoxTabAssociation = &WolFoxTabAssociation;
static const void *WolFoxTabSelectedAssociation = &WolFoxTabSelectedAssociation;
static const void *WolFoxTabDragOutAssociation = &WolFoxTabDragOutAssociation;
static const void *WolFoxBuiltTabAssociation = &WolFoxBuiltTabAssociation;

static id WolFoxValue(id receiver, NSString *selectorName);

// YouTube's own icon type for Subscriptions, so it draws the tab like its others.
static NSInteger WolFoxSubscriptionsIconType(void) {
    static NSInteger value = -1;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class iconClass = NSClassFromString(@"YTIIcon");
        id descriptor = [iconClass respondsToSelector:@selector(descriptor)]
            ? ((id (*)(id, SEL))objc_msgSend)(iconClass, @selector(descriptor)) : nil;
        SEL fieldSelector = NSSelectorFromString(@"fieldWithName:");
        id field = [descriptor respondsToSelector:fieldSelector]
            ? ((id (*)(id, SEL, id))objc_msgSend)(descriptor, fieldSelector, @"iconType") : nil;
        id enumDescriptor = WolFoxValue(field, @"enumDescriptor");
        SEL lookup = NSSelectorFromString(@"getValue:forEnumTextFormatName:");
        if (![enumDescriptor respondsToSelector:lookup]) return;
        for (NSString *name in @[@"TAB_SUBSCRIPTIONS_CAIRO", @"TAB_SUBSCRIPTIONS"]) {
            int32_t found = 0;
            if (((BOOL (*)(id, SEL, int32_t *, id))objc_msgSend)(enumDescriptor, lookup, &found, name)) {
                value = found;
                break;
            }
        }
    });
    return value;
}
static BOOL WolFoxStencilRendering;
static NSString * const WolFoxPivotIdentifier = @"FEWolFox";
static NSInteger const WolFoxExtraIconTag = 0x59414349;
static NSInteger const WolFoxExtraLabelTag = 0x5941434A;
static BOOL WolFoxStartupApplied;
static NSString *WolFoxFirstVisiblePivot;

static BOOL WolFoxNavigationRefreshScheduled;

static id WolFoxValue(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return receiver != nil && [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector)
        : nil;
}

static void WolFoxSetValue(id receiver, NSString *selectorName, id value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (receiver != nil && [receiver respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(receiver, selector, value);
    }
}

static id WolFoxNew(NSString *className) {
    Class cls = NSClassFromString(className);
    return cls == Nil ? nil : [[cls alloc] init];
}

static id WolFoxMakePivotItem(void) {
    Class rendererClass = NSClassFromString(@"YTIPivotBarRenderer");
    SEL factory = NSSelectorFromString(@"pivotSupportedRenderersWithBrowseId:title:iconType:");
    if (rendererClass != Nil && [rendererClass respondsToSelector:factory]) {
        id renderer = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
            rendererClass,
            factory,
            WolFoxPivotIdentifier,
            @"WolFox",
            77
        );
        id item = WolFoxValue(renderer, @"pivotBarItemRenderer");
        if (item != nil) {
            WolFoxSetValue(item, @"setPivotIdentifier:", WolFoxPivotIdentifier);
        }
        if (renderer != nil) {
            return renderer;
        }
    }
    id browseEndpoint = WolFoxNew(@"YTIBrowseEndpoint");
    id command = WolFoxNew(@"YTICommand");
    id itemRenderer = WolFoxNew(@"YTIPivotBarItemRenderer");
    id supportedRenderer = WolFoxNew(@"YTIPivotBarSupportedRenderers");
    Class formattedClass = NSClassFromString(@"YTIFormattedString");
    SEL formattedSelector = NSSelectorFromString(@"formattedStringWithString:");
    if (browseEndpoint == nil || command == nil || itemRenderer == nil ||
        supportedRenderer == nil || formattedClass == Nil ||
        ![formattedClass respondsToSelector:formattedSelector]) {
        return nil;
    }

    WolFoxSetValue(browseEndpoint, @"setBrowseId:", WolFoxPivotIdentifier);
    WolFoxSetValue(command, @"setBrowseEndpoint:", browseEndpoint);
    WolFoxSetValue(itemRenderer, @"setPivotIdentifier:", WolFoxPivotIdentifier);
    WolFoxSetValue(itemRenderer, @"setNavigationEndpoint:", command);
    id title = ((id (*)(id, SEL, id))objc_msgSend)(
        formattedClass,
        formattedSelector,
        @"WolFox"
    );
    WolFoxSetValue(itemRenderer, @"setTitle:", title);

    id icon = WolFoxValue(itemRenderer, @"icon");
    SEL iconSelector = NSSelectorFromString(@"setIconType:");
    if ([icon respondsToSelector:iconSelector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(icon, iconSelector, 77);
    }
    WolFoxSetValue(
        supportedRenderer,
        @"setPivotBarItemRenderer:",
        itemRenderer
    );
    return supportedRenderer;
}

static id WolFoxMakeBrowsePivotItem(NSString *browseID,
                                    NSString *title,
                                    NSInteger iconType) {
    Class rendererClass = NSClassFromString(@"YTIPivotBarRenderer");
    SEL factory = NSSelectorFromString(@"pivotSupportedRenderersWithBrowseId:title:iconType:");
    if (rendererClass != Nil && [rendererClass respondsToSelector:factory]) {
        id renderer = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
            rendererClass, factory, browseID, title, iconType
        );
        id item = WolFoxValue(renderer, @"pivotBarItemRenderer");
        if (item != nil) {
            WolFoxSetValue(item, @"setPivotIdentifier:", browseID);
        }
        if (renderer != nil) {
            return renderer;
        }
    }
    id browseEndpoint = WolFoxNew(@"YTIBrowseEndpoint");
    id command = WolFoxNew(@"YTICommand");
    id itemRenderer = WolFoxNew(@"YTIPivotBarItemRenderer");
    id supportedRenderer = WolFoxNew(@"YTIPivotBarSupportedRenderers");
    Class formattedClass = NSClassFromString(@"YTIFormattedString");
    SEL formattedSelector = NSSelectorFromString(@"formattedStringWithString:");
    if (browseEndpoint == nil || command == nil || itemRenderer == nil ||
        supportedRenderer == nil || formattedClass == Nil ||
        ![formattedClass respondsToSelector:formattedSelector]) {
        return nil;
    }
    WolFoxSetValue(browseEndpoint, @"setBrowseId:", browseID);
    WolFoxSetValue(command, @"setBrowseEndpoint:", browseEndpoint);
    WolFoxSetValue(itemRenderer, @"setPivotIdentifier:", browseID);
    WolFoxSetValue(itemRenderer, @"setNavigationEndpoint:", command);
    id icon = WolFoxValue(itemRenderer, @"icon");
    SEL setIconType = NSSelectorFromString(@"setIconType:");
    if ([icon respondsToSelector:setIconType]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(icon, setIconType, iconType);
    }
    id formatted = ((id (*)(id, SEL, id))objc_msgSend)(
        formattedClass, formattedSelector, title
    );
    WolFoxSetValue(itemRenderer, @"setTitle:", formatted);
    WolFoxSetValue(supportedRenderer, @"setPivotBarItemRenderer:", itemRenderer);
    return supportedRenderer;
}

static NSInteger WolFoxInteger(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return receiver != nil && [receiver respondsToSelector:selector]
        ? ((NSInteger (*)(id, SEL))objc_msgSend)(receiver, selector)
        : 0;
}

static NSString *WolFoxBrowseIdentifier(UIViewController *controller) {
    id endpoint = WolFoxValue(controller, @"navigationEndpoint");
    if (endpoint == nil) {
        endpoint = WolFoxValue(controller, @"navEndpoint");
    }
    if (endpoint == nil) {
        @try {
            endpoint = [controller valueForKey:@"_navEndpoint"];
        } @catch (__unused NSException *exception) {
        }
    }
    id browseEndpoint = WolFoxValue(endpoint, @"browseEndpoint");
    if (browseEndpoint == nil &&
        [endpoint respondsToSelector:NSSelectorFromString(@"browseId")]) {
        browseEndpoint = endpoint;
    }
    return WolFoxValue(browseEndpoint, @"browseId");
}

static void WolFoxAttachDownloads(UIViewController *controller) {
    if (!WolFoxMasterEnabled() ||
        ![WolFoxBrowseIdentifier(controller) isEqualToString:WolFoxPivotIdentifier] ||
        objc_getAssociatedObject(controller, WolFoxDownloadsAssociation) != nil) {
        return;
    }
    WolFoxDownloadsController *downloads = [WolFoxDownloadsController new];
    [controller addChildViewController:downloads];
    downloads.view.frame = controller.view.bounds;
    downloads.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    [controller.view addSubview:downloads.view];
    [downloads didMoveToParentViewController:controller];
    objc_setAssociatedObject(controller,
                             WolFoxDownloadsAssociation,
                             downloads,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WolFoxTryAttachDownloads(UIViewController *controller) {
    WolFoxAttachDownloads(controller);
    if (objc_getAssociatedObject(controller, WolFoxDownloadsAssociation) == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WolFoxAttachDownloads(controller);
        });
    }
}

static void WolFoxAppViewDidLoad(UIViewController *receiver, SEL selector) {
    if (OriginalAppViewDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalAppViewDidLoad)(receiver, selector);
    }
    WolFoxTryAttachDownloads(receiver);
}

static void WolFoxBrowseViewDidLoad(UIViewController *receiver, SEL selector) {
    if (OriginalBrowseViewDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalBrowseViewDidLoad)(receiver, selector);
    }
    WolFoxTryAttachDownloads(receiver);
}

static void WolFoxBrowseResponseViewDidLoad(UIViewController *receiver,
                                            SEL selector) {
    if (OriginalBrowseResponseViewDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalBrowseResponseViewDidLoad)(receiver, selector);
    }
    WolFoxTryAttachDownloads(receiver);
}

static void WolFoxWrapperViewDidLoad(UIViewController *receiver, SEL selector) {
    if (OriginalWrapperViewDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalWrapperViewDidLoad)(receiver, selector);
    }
    WolFoxTryAttachDownloads(receiver);
}

static id WolFoxTabValue(id receiver, NSArray<NSString *> *selectors) {
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
            if (value != nil) {
                return value;
            }
        }
    }
    return nil;
}

static NSString *WolFoxTabToken(id item) {
    for (NSString *selectorName in @[
        @"pivotIdentifier",
        @"tabIdentifier",
        @"browseId"
    ]) {
        id value = WolFoxTabValue(item, @[selectorName]);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return [value lowercaseString];
        }
    }
    NSArray<NSString *> *activeRenderers =
        WolFoxInteger(item, @"hasPivotBarItemRenderer") != 0
            ? @[@"pivotBarItemRenderer"]
            : (WolFoxInteger(item, @"hasPivotBarIconOnlyItemRenderer") != 0
                ? @[@"pivotBarIconOnlyItemRenderer"]
                : @[@"pivotBarItemRenderer", @"pivotBarIconOnlyItemRenderer"]);
    for (NSString *rendererName in activeRenderers) {
        id nested = WolFoxTabValue(item, @[rendererName]);
        if (nested != nil && nested != item) {
            NSString *token = WolFoxTabToken(nested);
            if (token.length != 0) {
                return token;
            }
        }
    }
    id renderer = WolFoxTabValue(item, @[@"renderer"]);
    if (renderer != nil && renderer != item) {
        NSString *token = WolFoxTabToken(renderer);
        if (token.length != 0) {
            return token;
        }
    }
    id endpoint = WolFoxTabValue(item, @[@"navigationEndpoint", @"endpoint"]);
    id browseEndpoint = WolFoxTabValue(endpoint, @[@"browseEndpoint"]);
    id browseID = WolFoxTabValue(browseEndpoint ?: endpoint, @[@"browseId"]);
    if ([browseID isKindOfClass:NSString.class] && [browseID length] != 0) {
        return [browseID lowercaseString];
    }
    id identifier = WolFoxTabValue(item, @[@"identifier"]);
    return [identifier isKindOfClass:NSString.class]
        ? [identifier lowercaseString]
        : @"";
}

static NSMutableDictionary<NSString *, NSString *> *WolFoxStartupIdentifiers;

static NSString *WolFoxRawTabIdentifier(id item, NSUInteger depth) {
    if (item == nil || depth > 3) return nil;
    for (NSString *name in @[@"pivotIdentifier", @"tabIdentifier", @"browseId"]) {
        id value = WolFoxTabValue(item, @[name]);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return value;
        }
    }
    for (NSString *name in @[@"pivotBarItemRenderer", @"pivotBarIconOnlyItemRenderer",
                             @"renderer", @"navigationEndpoint", @"endpoint",
                             @"browseEndpoint"]) {
        id nested = WolFoxTabValue(item, @[name]);
        if (nested == nil || nested == item) continue;
        NSString *found = WolFoxRawTabIdentifier(nested, depth + 1);
        if (found.length != 0) return found;
    }
    return nil;
}

static void WolFoxNoteStartupIdentifier(NSString *canonical, id item) {
    if (canonical.length == 0) return;
    NSString *identifier = WolFoxRawTabIdentifier(item, 0);
    if (identifier.length == 0) return;
    if (WolFoxStartupIdentifiers == nil) {
        WolFoxStartupIdentifiers = [NSMutableDictionary dictionary];
    }
    if ([WolFoxStartupIdentifiers[canonical] isEqualToString:identifier]) return;
    WolFoxStartupIdentifiers[canonical] = identifier;
    [NSUserDefaults.standardUserDefaults
        setObject:WolFoxStartupIdentifiers.allKeys
           forKey:@"YTKACE.Preference.Tabs.Known"];
}

// The playlist picked for the Playlist tab, as a browse id (VL + playlist id).
static NSString *WolFoxCustomPlaylistBrowseID(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTKACE.Preference.Tabs.CustomPlaylist"];
    if (![stored isKindOfClass:NSString.class] || [stored length] == 0) return nil;
    return [@"VL" stringByAppendingString:stored];
}

// Playlist ids are random letters, so match the Playlist tab exactly and
// before the other tabs' substring checks.
static BOOL WolFoxIsCustomPlaylistToken(NSString *token) {
    NSString *browseID = WolFoxCustomPlaylistBrowseID();
    return browseID != nil && [token isEqualToString:browseID.lowercaseString];
}

static NSString *WolFoxHideKeyForToken(NSString *token) {
    if (WolFoxIsCustomPlaylistToken(token)) return @"YTKACE.Preference.Tabs.Hidden.CustomPlaylist";
    if ([token containsString:@"uc-9-kytw8zkzndhqj6fgpwq"] ||
        [token containsString:@"music_home"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Music";
    }
    if ([token containsString:@"uc4r8dwomoi7cawx8_ljqhig"] ||
        [token containsString:@"trending_live"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Live";
    }
    if ([token containsString:@"ucopncn46ubxvtpkmrmu4abg"] ||
        [token containsString:@"gaming"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Gaming";
    }
    if ([token containsString:@"ucyfdidrxb8qhf0nx7iooyw"] ||
        [token containsString:@"news"]) {
        return @"YTKACE.Preference.Tabs.Hidden.News";
    }
    if ([token containsString:@"fecommunity"] ||
        [token containsString:@"communit"] ||
        [token containsString:@"post"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Posts";
    }
    if ([token containsString:@"ucegdi0xixxz-qjofpf4jskw"] ||
        [token containsString:@"sports"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Sports";
    }
    if ([token containsString:@"uctfrv9o2ahqozjjynzrv-xg"] ||
        [token containsString:@"learning"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Learning";
    }
    if ([token containsString:@"ucrpq4p1ql_hg8rkxikm1moq"] ||
        [token containsString:@"fashion"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Fashion";
    }
    if ([token containsString:@"feplaylist_aggregation"] ||
        [token containsString:@"playlist_aggregation"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Playlists";
    }
    if ([token containsString:@"fehistory"] ||
        [token isEqualToString:@"history"]) {
        return @"YTKACE.Preference.Tabs.Hidden.History";
    }
    if ([token containsString:@"fenotifications_inbox"] ||
        [token containsString:@"notifications_inbox"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Notifs";
    }
    if ([token isEqualToString:@"vlwl"] ||
        [token containsString:@"watch_later"]) {
        return @"YTKACE.Preference.Tabs.Hidden.WatchLater";
    }
    if ([token containsString:@"short"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Shorts";
    }
    if ([token containsString:@"subscription"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Subscriptions";
    }
    if ([token containsString:@"library"] ||
        [token containsString:@"you_tab"] ||
        [token isEqualToString:@"you"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Library";
    }
    if ([token containsString:@"create"] ||
        [token containsString:@"upload"] ||
        [token containsString:@"plus"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Create";
    }
    if ([token containsString:@"home"] ||
        [token containsString:@"what_to_watch"]) {
        return @"YTKACE.Preference.Tabs.Hidden.Home";
    }
    return nil;
}

static NSString *WolFoxCanonicalTabToken(NSString *token) {
    if (WolFoxIsCustomPlaylistToken(token)) return @"customplaylist";
    if ([token containsString:@"uc-9-kytw8zkzndhqj6fgpwq"] ||
        [token containsString:@"music_home"]) {
        return @"music";
    }
    if ([token containsString:@"uc4r8dwomoi7cawx8_ljqhig"] ||
        [token containsString:@"trending_live"]) {
        return @"live";
    }
    if ([token containsString:@"ucopncn46ubxvtpkmrmu4abg"] ||
        [token containsString:@"gaming"]) {
        return @"gaming";
    }
    if ([token containsString:@"ucyfdidrxb8qhf0nx7iooyw"] ||
        [token containsString:@"news"]) {
        return @"news";
    }
    if ([token containsString:@"fecommunity"] ||
        [token containsString:@"communit"] ||
        [token containsString:@"post"]) {
        return @"posts";
    }
    if ([token containsString:@"ucegdi0xixxz-qjofpf4jskw"] ||
        [token containsString:@"sports"]) {
        return @"sports";
    }
    if ([token containsString:@"uctfrv9o2ahqozjjynzrv-xg"] ||
        [token containsString:@"learning"]) {
        return @"learning";
    }
    if ([token containsString:@"ucrpq4p1ql_hg8rkxikm1moq"] ||
        [token containsString:@"fashion"]) {
        return @"fashion";
    }
    if ([token containsString:@"feplaylist_aggregation"] ||
        [token containsString:@"playlist_aggregation"]) {
        return @"playlists";
    }
    if ([token containsString:@"fehistory"] ||
        [token isEqualToString:@"history"]) {
        return @"history";
    }
    if ([token containsString:@"fenotifications_inbox"] ||
        [token containsString:@"notifications_inbox"]) {
        return @"notifications";
    }
    if ([token isEqualToString:@"vlwl"] ||
        [token containsString:@"watch_later"]) {
        return @"watchlater";
    }
    if ([token containsString:@"short"] || [token containsString:@"reel"]) {
        return @"shorts";
    }
    if ([token containsString:@"subscription"]) {
        return @"subscriptions";
    }
    if ([token containsString:@"library"] ||
        [token containsString:@"you_tab"] ||
        [token isEqualToString:@"you"]) {
        return @"you";
    }
    if ([token containsString:@"create"] ||
        [token containsString:@"upload"] ||
        [token containsString:@"plus"]) {
        return @"create";
    }
    if ([token containsString:@"home"] ||
        [token containsString:@"what_to_watch"]) {
        return @"home";
    }
    return token;
}

static NSArray *WolFoxTabItems(id renderer, NSString **setterName) {
    NSArray<NSString *> *getters = @[
        @"itemsArray",
        @"items",
        @"pivotBarItemsArray",
        @"pivotBarItems"
    ];
    NSArray<NSString *> *setters = @[
        @"setItemsArray:",
        @"setItems:",
        @"setPivotBarItemsArray:",
        @"setPivotBarItems:"
    ];
    for (NSUInteger index = 0; index < getters.count; index++) {
        id value = WolFoxTabValue(renderer, @[getters[index]]);
        if ([value isKindOfClass:NSArray.class]) {
            if (setterName != NULL) {
                *setterName = setters[index];
            }
            return value;
        }
    }
    return nil;
}

static NSInteger WolFoxTabOrderIndex(NSString *token, NSArray *order) {
    NSString *canonical = WolFoxCanonicalTabToken(token);
    for (NSUInteger index = 0; index < order.count; index++) {
        id value = order[index];
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *entry = [value lowercaseString];
        if ([canonical isEqualToString:entry] ||
            [canonical isEqualToString:WolFoxCanonicalTabToken(entry)]) {
            return (NSInteger)index;
        }
    }
    for (NSUInteger index = 0; index < order.count; index++) {
        id value = order[index];
        if (![value isKindOfClass:NSString.class]) continue;
        if ([token containsString:[value lowercaseString]]) return (NSInteger)index;
    }
    return NSIntegerMax;
}

static void WolFoxSetTabTitle(id target, NSString *text) {
    Class formattedClass = NSClassFromString(@"YTIFormattedString");
    SEL formattedSelector = NSSelectorFromString(@"formattedStringWithString:");
    id value = text;
    if (formattedClass != Nil && [formattedClass respondsToSelector:formattedSelector]) {
        value = ((id (*)(id, SEL, id))objc_msgSend)(
            formattedClass,
            formattedSelector,
            text
        );
    }
    SEL selector = NSSelectorFromString(@"setTitle:");
    if ([target respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(target, selector, value);
    }
}

static void WolFoxApplyTabName(id item, NSString *token) {
    NSDictionary *names =
        [NSUserDefaults.standardUserDefaults dictionaryForKey:@"YTKACE.Preference.Tabs.Names"];
    NSString *replacement = names[token] ?: names[WolFoxCanonicalTabToken(token)];
    if (![replacement isKindOfClass:NSString.class] || replacement.length == 0) {
        return;
    }
    id target = WolFoxTabValue(item, @[
        @"pivotBarItemRenderer",
        @"pivotBarIconOnlyItemRenderer"
    ]) ?: item;
    WolFoxSetTabTitle(target, replacement);
}

static BOOL WolFoxTabFieldSet(id message, NSString *field) {
    NSString *suffix = [[field substringToIndex:1].uppercaseString stringByAppendingString:[field substringFromIndex:1]];
    SEL has = NSSelectorFromString([@"has" stringByAppendingString:suffix]);
    return ![message respondsToSelector:has] || ((BOOL (*)(id, SEL))objc_msgSend)(message, has);
}

static NSString *WolFoxTabSetter(NSString *field) {
    return [NSString stringWithFormat:@"set%@%@:", [field substringToIndex:1].uppercaseString,
                                      [field substringFromIndex:1]];
}

static int32_t WolFoxOneofCase(id message, NSString *oneof) {
    SEL selector = NSSelectorFromString([oneof stringByAppendingString:@"OneOfCase"]);
    return [message respondsToSelector:selector] ? ((int32_t (*)(id, SEL))objc_msgSend)(message, selector) : 0;
}

static const int32_t WolFoxIconOnlyItemCase = 318370163;

static id WolFoxLabeledTab(id item) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Tabs.LabelsHidden") ||
        WolFoxOneofCase(item, @"items") != WolFoxIconOnlyItemCase) {
        return item;
    }
    id iconOnly = WolFoxValue(item, @"pivotBarIconOnlyItemRenderer");
    id label = WolFoxValue(WolFoxValue(WolFoxValue(iconOnly, @"accessibility"), @"accessibilityData"), @"label");
    id renderer = WolFoxNew(@"YTIPivotBarItemRenderer");
    id supported = WolFoxNew(@"YTIPivotBarSupportedRenderers");
    if (![label isKindOfClass:NSString.class] || [label length] == 0 || renderer == nil || supported == nil) {
        return item;
    }
    for (NSString *field in @[@"pivotIdentifier", @"targetId", @"navigationEndpoint", @"accessibility",
                              @"presentationStyle", @"trackingParams", @"progressIndicator",
                              @"onSelected", @"onDeselected", @"indicator", @"onLongPress"]) {
        if (WolFoxTabFieldSet(iconOnly, field)) {
            WolFoxSetValue(renderer, WolFoxTabSetter(field), WolFoxValue(iconOnly, field));
        }
    }
    NSString *image = @{@5: @"icon", @10: @"thumbnail", @16: @"avatar"}[@(WolFoxOneofCase(iconOnly, @"image"))];
    if (image != nil) {
        WolFoxSetValue(renderer, WolFoxTabSetter(image), WolFoxValue(iconOnly, image));
    }
    for (NSString *field in @[@"navigationType", @"notificationSelectionBehavior", @"isDisabled"]) {
        SEL getter = NSSelectorFromString(field);
        SEL setter = NSSelectorFromString(WolFoxTabSetter(field));
        if (![iconOnly respondsToSelector:getter] || ![renderer respondsToSelector:setter] ||
            !WolFoxTabFieldSet(iconOnly, field)) {
            continue;
        }
        if ([field isEqualToString:@"isDisabled"]) {
            BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(iconOnly, getter);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(renderer, setter, value);
        } else {
            int32_t value = ((int32_t (*)(id, SEL))objc_msgSend)(iconOnly, getter);
            ((void (*)(id, SEL, int32_t))objc_msgSend)(renderer, setter, value);
        }
    }
    WolFoxSetTabTitle(renderer, label);
    WolFoxSetValue(supported, @"setPivotBarItemRenderer:", renderer);
    return supported;
}

static void WolFoxFillEmptyTabTitle(id item) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Tabs.LabelsHidden")) return;
    id renderer = WolFoxValue(item, @"pivotBarItemRenderer");
    if (renderer == nil) return;
    id title = WolFoxValue(WolFoxValue(renderer, @"title"), @"stringWithFormattingRemoved");
    if ([title isKindOfClass:NSString.class] && [title length] != 0) return;
    id label = WolFoxValue(WolFoxValue(WolFoxValue(renderer, @"accessibility"), @"accessibilityData"), @"label");
    if (![label isKindOfClass:NSString.class] || [label length] == 0) return;
    WolFoxSetTabTitle(renderer, label);
}

static BOOL WolFoxIsDownloadTab(id item) {
    NSString *token = WolFoxTabToken(item);
    if ([token containsString:@"ytkace"]) {
        return YES;
    }
    NSString *identifier = WolFoxRawTabIdentifier(item, 0);
    if (identifier.length != 0) {
        return [[identifier lowercaseString] containsString:@"ytkace"];
    }
    NSString *description = [[item description] lowercaseString];
    return [description containsString:@"feytkace"] ||
        [description containsString:@"ytkace"];
}

static void WolFoxSetPivotRenderer(id receiver, SEL selector, id renderer) {
    if (renderer != nil) {
        NSString *setterName = nil;
        NSArray *items = WolFoxTabItems(renderer, &setterName);
        if (items != nil) {
            NSMutableArray *filtered = [NSMutableArray array];
            BOOL hasDownloadTab = NO;
            for (id item in items) {
                id candidate = item;
                NSString *token = WolFoxTabToken(candidate);
                if (WolFoxIsDownloadTab(candidate)) {
                    BOOL duplicate = hasDownloadTab;
                    hasDownloadTab = YES;
                    WolFoxNoteStartupIdentifier(@"ytkace", candidate);
                    if (!duplicate && WolFoxMasterEnabled() &&
                        ![NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.Tabs.Hidden.YTKACETab"]) {
                        [filtered addObject:candidate];
                    }
                    continue;
                }
                NSString *hideKey = WolFoxHideKeyForToken(token);
                WolFoxNoteStartupIdentifier(WolFoxCanonicalTabToken(token), candidate);
                if (WolFoxMasterEnabled() && hideKey != nil &&
                    [NSUserDefaults.standardUserDefaults boolForKey:hideKey]) {
                    continue;
                }
                if (WolFoxMasterEnabled() &&
                    [WolFoxCanonicalTabToken(token) isEqualToString:@"create"]) {
                    [filtered addObject:candidate];
                    continue;
                }
                if (WolFoxMasterEnabled()) {
                    candidate = WolFoxLabeledTab(candidate);
                    WolFoxApplyTabName(candidate, token);
                }
                [filtered addObject:candidate];
            }

            NSMutableArray<NSDictionary *> *extraTabs = [@[
                @{@"token": @"music", @"id": @"UC-9-kyTW8ZkZNDHQJ6FgpwQ",
                  @"title": @"Music", @"key": @"YTKACE.Preference.Tabs.Hidden.Music", @"icon": @1001},
                @{@"token": @"live", @"id": @"UC4R8DWoMoI7CAwX8_LjQHig",
                  @"title": @"Live", @"key": @"YTKACE.Preference.Tabs.Hidden.Live", @"icon": @1002},
                @{@"token": @"gaming", @"id": @"UCOpNcN46UbXVtpKMrmU4Abg",
                  @"title": @"Gaming", @"key": @"YTKACE.Preference.Tabs.Hidden.Gaming", @"icon": @1003},
                @{@"token": @"news", @"id": @"UCYfdidRxbB8Qhf0Nx7ioOYw",
                  @"title": @"News", @"key": @"YTKACE.Preference.Tabs.Hidden.News", @"icon": @1004},
                @{@"token": @"sports", @"id": @"UCEgdi0XIXXZ-qJOFPf4JSKw",
                  @"title": @"Sports", @"key": @"YTKACE.Preference.Tabs.Hidden.Sports", @"icon": @1005},
                @{@"token": @"learning", @"id": @"UCtFRv9O2AHqOZjjynzrv-xg",
                  @"title": @"Learning", @"key": @"YTKACE.Preference.Tabs.Hidden.Learning", @"icon": @1006},
                @{@"token": @"fashion", @"id": @"UCrpQ4p1Ql_hG8rKXIKM1MOQ",
                  @"title": @"Fashion", @"key": @"YTKACE.Preference.Tabs.Hidden.Fashion", @"icon": @1007},
                @{@"token": @"playlists", @"id": @"FEplaylist_aggregation",
                  @"title": @"Playlists", @"key": @"YTKACE.Preference.Tabs.Hidden.Playlists", @"icon": @1008},
                @{@"token": @"history", @"id": @"FEhistory",
                  @"title": @"History", @"key": @"YTKACE.Preference.Tabs.Hidden.History", @"icon": @1009},
                @{@"token": @"notifications", @"id": @"FEnotifications_inbox",
                  @"title": @"Notifs", @"key": @"YTKACE.Preference.Tabs.Hidden.Notifs", @"icon": @1010},
                @{@"token": @"watchlater", @"id": @"VLWL",
                  @"title": @"WLater", @"key": @"YTKACE.Preference.Tabs.Hidden.WatchLater", @"icon": @1011},
                @{@"token": @"posts", @"id": @"FEpost_home",
                  @"title": @"Posts", @"key": @"YTKACE.Preference.Tabs.Hidden.Posts", @"icon": @1012},
                @{@"token": @"subscriptions", @"id": @"FEsubscriptions",
                  @"title": WolFoxLocalized(@"Subscriptions"),
                  @"key": @"YTKACE.Preference.Tabs.Hidden.Subscriptions",
                  @"icon": @(WolFoxSubscriptionsIconType() > 0 ? WolFoxSubscriptionsIconType() : 1013)}
            ] mutableCopy];
            NSString *playlistBrowseID = WolFoxCustomPlaylistBrowseID();
            if (playlistBrowseID != nil) {
                [extraTabs addObject:@{@"token": @"customplaylist", @"id": playlistBrowseID,
                    @"title": @"Playlist", @"key": @"YTKACE.Preference.Tabs.Hidden.CustomPlaylist", @"icon": @1014}];
            }
            NSMutableSet<NSString *> *present = [NSMutableSet set];
            for (id item in filtered) {
                [present addObject:WolFoxCanonicalTabToken(WolFoxTabToken(item))];
            }
            NSDictionary *customNames =
                [NSUserDefaults.standardUserDefaults dictionaryForKey:@"YTKACE.Preference.Tabs.Names"];
            for (NSDictionary *entry in extraTabs) {
                NSString *token = entry[@"token"];
                if ([NSUserDefaults.standardUserDefaults boolForKey:entry[@"key"]] ||
                    [present containsObject:token]) {
                    continue;
                }
                NSString *title = customNames[token] ?: entry[@"title"];
                id item = WolFoxMakeBrowsePivotItem(entry[@"id"],
                                                     title,
                                                     [entry[@"icon"] integerValue]);
                if (item != nil) {
                    id itemRenderer = WolFoxValue(item, @"pivotBarItemRenderer");
                    if (itemRenderer != nil) {
                        objc_setAssociatedObject(itemRenderer, WolFoxBuiltTabAssociation, @YES,
                                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    WolFoxNoteStartupIdentifier(token, item);
                    [filtered addObject:item];
                    [present addObject:token];
                }
            }

            if (WolFoxMasterEnabled() && !hasDownloadTab &&
                ![NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.Tabs.Hidden.YTKACETab"]) {
                id downloadItem = WolFoxMakePivotItem();
                if (downloadItem != nil) {
                    WolFoxNoteStartupIdentifier(@"ytkace", downloadItem);
                    [filtered addObject:downloadItem];
                }
            }

            if (WolFoxMasterEnabled()) {
                for (id item in filtered) {
                    if (![WolFoxCanonicalTabToken(WolFoxTabToken(item)) isEqualToString:@"create"]) {
                        WolFoxFillEmptyTabTitle(item);
                    }
                }
            }

            NSArray *order =
                [NSUserDefaults.standardUserDefaults arrayForKey:@"YTKACE.Preference.Tabs.Order"];
            if (WolFoxMasterEnabled() && order.count != 0) {
                [filtered sortUsingComparator:^NSComparisonResult(id left, id right) {
                    NSInteger leftIndex =
                        WolFoxTabOrderIndex(WolFoxTabToken(left), order);
                    NSInteger rightIndex =
                        WolFoxTabOrderIndex(WolFoxTabToken(right), order);
                    if (leftIndex == rightIndex) {
                        return NSOrderedSame;
                    }
                    return leftIndex < rightIndex
                        ? NSOrderedAscending
                        : NSOrderedDescending;
                }];
            }

            NSString *firstIdentifier = filtered.count != 0 ? WolFoxRawTabIdentifier(filtered.firstObject, 0) : nil;
            if (firstIdentifier.length != 0) WolFoxFirstVisiblePivot = [firstIdentifier copy];
            SEL setter = NSSelectorFromString(setterName);
            if ([items isKindOfClass:NSMutableArray.class]) {
                [(NSMutableArray *)items setArray:filtered];
            } else if ([renderer respondsToSelector:setter]) {
                ((void (*)(id, SEL, id))objc_msgSend)(renderer, setter, filtered);
            }
        }
    }

    static Class floatingClass;
    if (floatingClass == Nil) floatingClass = NSClassFromString(@"YTFloatingPivotBarView");
    BOOL floating = floatingClass != Nil && [receiver isKindOfClass:floatingClass];
    if (floating) {
        NSArray *tabs = renderer != nil ? WolFoxTabItems(renderer, NULL) : nil;
        WolFoxDebugLog(@"tabbar", @"floating bar renderer tabs=%lu", (unsigned long)tabs.count);
    }
    IMP original = floating ? OriginalSetFloatingPivotRenderer : OriginalSetPivotRenderer;
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, renderer);
    }
}

static id WolFoxItemRenderer(UIView *view);

static BOOL WolFoxItemFlag(UIView *item, const char *name) {
    Ivar flag = class_getInstanceVariable(object_getClass(item), name);
    return flag != NULL && strcmp(ivar_getTypeEncoding(flag), @encode(BOOL)) == 0 &&
        *(BOOL *)((uint8_t *)(__bridge void *)item + ivar_getOffset(flag));
}

static IMP OriginalIsIconsOnly;

static BOOL WolFoxIsIconsOnly(id receiver, SEL selector) {
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Tabs.LabelsHidden")) return NO;
    return OriginalIsIconsOnly != NULL && ((BOOL (*)(id, SEL))OriginalIsIconsOnly)(receiver, selector);
}

static BOOL WolFoxYouTubeDropsTabTitle(UIView *item) {
    if (!WolFoxItemFlag(item, "_enableIconOnlyBottomNav") && !WolFoxItemFlag(item, "_enableIconOnlyOfflinePivotBar")) {
        return NO;
    }
    id renderer = WolFoxItemRenderer(item);
    if (renderer == nil) return NO;
    id title = WolFoxValue(WolFoxValue(renderer, @"title"), @"stringWithFormattingRemoved");
    return ![title isKindOfClass:NSString.class] || [title length] == 0;
}

static BOOL WolFoxYouTubeHidesTabLabels(UIView *item) {
    if (WolFoxYouTubeDropsTabTitle(item)) return YES;
    SEL getter = NSSelectorFromString(@"hideLabel");
    if ([item respondsToSelector:getter] && ((BOOL (*)(id, SEL))objc_msgSend)(item, getter)) return YES;
    SEL barGetter = NSSelectorFromString(@"hideItemLabels");
    for (UIView *bar = item.superview; bar != nil; bar = bar.superview) {
        if ([bar respondsToSelector:barGetter]) return ((BOOL (*)(id, SEL))objc_msgSend)(bar, barGetter);
    }
    return NO;
}

static BOOL WolFoxTabLabelsHidden(UIView *item) {
    BOOL hidden = WolFoxFeatureEnabled(@"YTKACE.Preference.Tabs.LabelsHidden");
    static Class floatingClass;
    if (floatingClass == Nil) floatingClass = NSClassFromString(@"YTFloatingPivotBarView");
    SEL getter = NSSelectorFromString(@"hideLabel");
    SEL setter = NSSelectorFromString(@"setHideLabel:");
    if (floatingClass == Nil || ![item respondsToSelector:getter] || ![item respondsToSelector:setter]) {
        return hidden || WolFoxYouTubeHidesTabLabels(item);
    }
    UIView *bar = item.superview;
    while (bar != nil && ![bar isKindOfClass:floatingClass]) bar = bar.superview;
    if (bar == nil) return hidden || WolFoxYouTubeHidesTabLabels(item);
    if (((BOOL (*)(id, SEL))objc_msgSend)(item, getter) != hidden) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setter, hidden);
        [item setNeedsLayout];
    }
    return hidden || WolFoxYouTubeDropsTabTitle(item);
}

static void WolFoxSetLabelsHidden(UIView *view, BOOL hidden) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UILabel.class]) {
            subview.hidden = hidden;
            subview.alpha = hidden ? 0.0 : 1.0;
        }
        WolFoxSetLabelsHidden(subview, hidden);
    }
}

static BOOL WolFoxInsidePivotItem(UIView *view) {
    for (UIView *current = view.superview; current != nil; current = current.superview) {
        if ([NSStringFromClass(current.class) containsString:@"PivotBarItemView"]) {
            return YES;
        }
    }
    return NO;
}

static UIView *WolFoxPivotItemAncestor(UIView *view) {
    for (UIView *current = view.superview; current != nil; current = current.superview) {
        if ([NSStringFromClass(current.class) containsString:@"PivotBarItemView"]) {
            return current;
        }
    }
    return nil;
}

static void WolFoxPivotLabelSetHidden(UILabel *receiver,
                                      SEL selector,
                                      BOOL hidden) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Tabs.LabelsHidden") &&
        WolFoxInsidePivotItem(receiver)) {
        hidden = YES;
    }
    if (OriginalPivotLabelSetHidden != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPivotLabelSetHidden)(
            receiver, selector, hidden
        );
    }
}

static void WolFoxPivotLabelSetAlpha(UILabel *receiver,
                                     SEL selector,
                                     CGFloat alpha) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Tabs.LabelsHidden") &&
        WolFoxInsidePivotItem(receiver)) {
        alpha = 0.0;
    }
    if (OriginalPivotLabelSetAlpha != NULL) {
        ((void (*)(id, SEL, CGFloat))OriginalPivotLabelSetAlpha)(
            receiver, selector, alpha
        );
    }
}

static UIImageView *WolFoxFindImageView(UIView *view);

static BOOL WolFoxContainsLabel(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) return YES;
    for (UIView *child in view.subviews) {
        if (WolFoxContainsLabel(child)) return YES;
    }
    return NO;
}

static void WolFoxCollectIconCandidates(UIView *view,
                                        UIView *root,
                                        NSMutableArray<UIView *> *candidates) {
    if (view != root && ![view isKindOfClass:UILabel.class]) {
        NSString *name = NSStringFromClass(view.class).lowercaseString;
        CGFloat width = CGRectGetWidth(view.bounds);
        CGFloat height = CGRectGetHeight(view.bounds);
        BOOL iconClass = [view isKindOfClass:UIImageView.class] ||
            [name containsString:@"icon"] || [name containsString:@"image"];
        BOOL iconSize = width >= 12.0 && height >= 12.0 &&
            width <= 64.0 && height <= 64.0;
        if ((view.tag == 0x59414345 || view.tag == WolFoxExtraIconTag ||
             iconClass) && iconSize) {
            [candidates addObject:view];
        }
    }
    for (UIView *child in view.subviews) {
        WolFoxCollectIconCandidates(child, root, candidates);
    }
}

static UIView *WolFoxIconContainer(UIView *candidate, UIView *root) {
    UIView *container = candidate;
    while (container.superview != nil && container.superview != root) {
        UIView *parent = container.superview;
        if (WolFoxContainsLabel(parent) ||
            CGRectGetWidth(parent.bounds) > 80.0 ||
            CGRectGetHeight(parent.bounds) > 80.0) {
            break;
        }
        container = parent;
    }
    return container;
}

static void WolFoxCenterPivotIcon(UIView *view, BOOL centered) {
    if (!centered) return;
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    WolFoxCollectIconCandidates(view, view, candidates);
    UIView *candidate = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    CGPoint rootCenter = CGPointMake(CGRectGetMidX(view.bounds),
                                     CGRectGetMidY(view.bounds));
    for (UIView *item in candidates) {
        CGPoint center = [item.superview convertPoint:item.center toView:view];
        CGFloat score = fabs(center.x - rootCenter.x) +
            fabs(CGRectGetWidth(item.bounds) - 24.0) * 0.25 +
            (item.hidden ? 100.0 : 0.0);
        if (item.tag == 0x59414345 || item.tag == WolFoxExtraIconTag) {
            score -= 1000.0;
        }
        if (score < bestScore) {
            bestScore = score;
            candidate = item;
        }
    }
    UIView *iconView = candidate == nil ? nil : WolFoxIconContainer(candidate, view);
    if (iconView == nil || iconView.superview == nil) return;
    CGPoint target = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds),
                                                     CGRectGetMidY(view.bounds))
                                toView:iconView.superview];
    iconView.center = target;
}

static UILabel *WolFoxFindNativeLabel(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        return (view.tag == 0x59414347 || view.tag == WolFoxExtraLabelTag)
            ? nil : (UILabel *)view;
    }
    for (UIView *subview in view.subviews) {
        UILabel *label = WolFoxFindNativeLabel(subview);
        if (label != nil) {
            return label;
        }
    }
    return nil;
}

static UIColor *WolFoxTabForegroundColor(UIView *view) {
    for (UIView *current = view.superview; current != nil; current = current.superview) {
        UIColor *color = [current.backgroundColor
            resolvedColorWithTraitCollection:view.traitCollection];
        CGFloat red = 0.0;
        CGFloat green = 0.0;
        CGFloat blue = 0.0;
        CGFloat alpha = 0.0;
        if ([color getRed:&red green:&green blue:&blue alpha:&alpha] &&
            alpha > 0.2) {
            CGFloat luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722;
            return luminance < 0.5 ? UIColor.whiteColor : UIColor.blackColor;
        }
    }
    return [UIColor.labelColor
        resolvedColorWithTraitCollection:view.traitCollection];
}

static UIImageView *WolFoxFindImageView(UIView *view) {
    if ([view isKindOfClass:UIImageView.class]) {
        return (view.tag == 0x59414345 || view.tag == WolFoxExtraIconTag)
            ? nil : (UIImageView *)view;
    }
    for (UIView *subview in view.subviews) {
        UIImageView *imageView = WolFoxFindImageView(subview);
        if (imageView != nil) {
            return imageView;
        }
    }
    return nil;
}

static BOOL WolFoxViewIsVisible(UIView *view) {
    if (view.window == nil) {
        return NO;
    }
    for (UIView *current = view; current != nil; current = current.superview) {
        if (current.hidden || current.alpha < 0.01) {
            return NO;
        }
    }
    return YES;
}

static UIView *WolFoxFindDownloadsRoot(UIView *view) {
    if ([view.accessibilityIdentifier isEqualToString:@"WolFoxDownloadsRoot"]) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIView *result = WolFoxFindDownloadsRoot(subview);
        if (result != nil) {
            return result;
        }
    }
    return nil;
}

static BOOL WolFoxDownloadsAreVisible(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *root = WolFoxFindDownloadsRoot(window);
            if (root != nil && WolFoxViewIsVisible(root)) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL WolFoxNativeTabRows(UIView *view, CGRect *iconFrame, CGRect *labelFrame) {
    for (UIView *sibling in view.superview.subviews) {
        if (sibling == view || ![NSStringFromClass(sibling.class) containsString:@"PivotBarItemView"]) {
            continue;
        }
        UIButton *button = WolFoxValue(sibling, @"navigationButton");
        if (![button isKindOfClass:UIButton.class]) continue;
        UILabel *label = button.titleLabel;
        UIImageView *image = button.imageView;
        if (label.hidden || label.alpha < 0.01 || label.text.length == 0 || CGRectIsEmpty(label.frame) ||
            image == nil || image.hidden || CGRectIsEmpty(image.frame)) {
            continue;
        }
        // Measure the rows inside the sibling tab, not relative to this one:
        // tabs share a size, but on a vertical tab bar (iPhone Duo) they are
        // stacked, so converting to this tab would shift by the tab offset.
        *iconFrame = [button convertRect:image.frame toView:sibling];
        *labelFrame = [button convertRect:label.frame toView:sibling];
        return YES;
    }
    return NO;
}

static void WolFoxLayoutTabIconAndLabel(UIView *view, UIView *icon, UILabel *label, BOOL hideLabel) {
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    CGFloat size = 24.0;
    CGFloat labelHeight = ceil(label.font.lineHeight);
    CGFloat iconY = hideLabel ? (height - size) * 0.5 : (height - size - 2.0 - labelHeight) * 0.5;
    CGFloat labelY = iconY + size + 2.0;
    CGRect nativeIcon = CGRectZero;
    CGRect nativeLabel = CGRectZero;
    if (!hideLabel && WolFoxNativeTabRows(view, &nativeIcon, &nativeLabel)) {
        iconY = CGRectGetMidY(nativeIcon) - size * 0.5;
        labelY = CGRectGetMinY(nativeLabel);
        labelHeight = CGRectGetHeight(nativeLabel);
    }
    icon.frame = CGRectMake((width - size) * 0.5, iconY, size, size);
    label.frame = CGRectMake(0.0, labelY, width, labelHeight);
}

static void WolFoxRestorePivotItem(UIView *view,
                                   UILabel *nativeLabel,
                                   BOOL hideLabel) {
    [[view viewWithTag:0x59414347] removeFromSuperview];
    [[view viewWithTag:0x59414345] removeFromSuperview];
    objc_setAssociatedObject(view,
                             WolFoxTabAssociation,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (nativeLabel != nil) {
        nativeLabel.hidden = hideLabel;
        nativeLabel.alpha = 1.0;
    }
    UIImageView *nativeImageView = WolFoxFindImageView(view);
    if (nativeImageView != nil) {
        nativeImageView.hidden = NO;
    }
}

static void WolFoxApplyDownloadIcon(UIView *view) {
    UILabel *nativeLabel = WolFoxFindNativeLabel(view);
    NSString *token = WolFoxTabToken(view);
    NSString *text = nativeLabel.text ?: @"";
    BOOL exactIdentifier = [token isEqualToString:@"feytkace"];
    BOOL exactLabel = [text caseInsensitiveCompare:@"WolFox"] == NSOrderedSame;
    BOOL associated = [objc_getAssociatedObject(
        view,
        WolFoxTabAssociation
    ) boolValue];
    BOOL definiteOther = (token.length != 0 && !exactIdentifier) ||
        (text.length != 0 && !exactLabel);
    BOOL hideLabel = WolFoxTabLabelsHidden(view);
    if (definiteOther) {
        WolFoxRestorePivotItem(view, nativeLabel, hideLabel);
        return;
    }
    BOOL recognized = exactIdentifier || exactLabel || associated;
    if (!recognized) {
        return;
    }
    objc_setAssociatedObject(view,
                             WolFoxTabAssociation,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIImageView *nativeImageView = WolFoxFindImageView(view);
    UIColor *tabColor = WolFoxTabForegroundColor(view);
    UILabel *label = (UILabel *)[view viewWithTag:0x59414347];
    if (nativeLabel != nil) {
        nativeLabel.text = @"";
        nativeLabel.hidden = YES;
        nativeLabel.alpha = 0.0;
    }
    if (label == nil) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.tag = 0x59414347;
        label.text = @"WolFox";
        label.font = nativeLabel.font ?: [UIFont systemFontOfSize:10.0];
        label.textAlignment = NSTextAlignmentCenter;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleTopMargin;
        [view addSubview:label];
    }
    label.textColor = tabColor;
    label.hidden = hideLabel;
    label.alpha = 1.0;
    BOOL selected = [objc_getAssociatedObject(
        view,
        WolFoxTabSelectedAssociation
    ) boolValue];
    SEL selectedSelector = NSSelectorFromString(@"isSelected");
    if ([view respondsToSelector:selectedSelector]) {
        selected = selected ||
            ((BOOL (*)(id, SEL))objc_msgSend)(view, selectedSelector);
    }
    selected = selected ||
        ((view.accessibilityTraits & UIAccessibilityTraitSelected) != 0) ||
        WolFoxDownloadsAreVisible();
    if ([objc_getAssociatedObject(view, WolFoxTabDragOutAssociation) boolValue]) selected = NO;
    UIImage *image = WolFoxDownloadTabImage(selected);
    UIImageView *imageView = (UIImageView *)[view viewWithTag:0x59414345];
    if (imageView == nil) {
        imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        imageView.tag = 0x59414345;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
            UIViewAutoresizingFlexibleRightMargin |
            UIViewAutoresizingFlexibleBottomMargin;
        [view addSubview:imageView];
    }
    if (nativeImageView != nil && nativeImageView != imageView) {
        nativeImageView.hidden = YES;
    }
    imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    imageView.tintColor = tabColor;
    imageView.hidden = NO;
    WolFoxLayoutTabIconAndLabel(view, imageView, label, hideLabel);
}

static NSDictionary *WolFoxExtraTabIcon(NSString *token) {
    static NSDictionary *icons;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        icons = @{
            @"music": @[@"yt_outline_music_24pt_3x_Normal",
                         @"music_24pt_3x_Normal",
                         @"music.note", @"music.note"],
            @"live": @[@"live_24pt_3x_Normal", @"ic_youtube_live_3x_Normal",
                        @"dot.radiowaves.left.and.right",
                        @"dot.radiowaves.left.and.right"],
            @"gaming": @[@"gaming_24pt_3x_Normal",
                          @"gaming_24pt_3x_Normal_fill",
                          @"gamecontroller", @"gamecontroller.fill"],
            @"news": @[@"news_24pt_3x_Normal", @"news_24pt_3x_Normal",
                        @"newspaper", @"newspaper.fill"],
            @"sports": @[@"G_sport", @"G_sport_fill",
                          @"trophy", @"trophy.fill"],
            @"learning": @[@"G_Learning", @"G_Learning_fill",
                            @"graduationcap", @"graduationcap.fill"],
            @"fashion": @[@"fashion_24pt_3x_Normal",
                           @"fashion_24pt_3x_Normal",
                           @"tshirt", @"tshirt.fill"],
            @"playlists": @[@"playlist", @"playlist_fill",
                             @"music.note.list", @"music.note.list"],
            @"history": @[@"history", @"history_fill",
                           @"clock.arrow.circlepath",
                           @"clock.arrow.circlepath"],
            @"notifications": @[@"ic_notifications_none_3x_Normal",
                                 @"ic_notifications_3x_Normal",
                                 @"bell", @"bell.fill"],
            @"customplaylist": @[@"playlist", @"playlist_fill",
                                  @"list.bullet.rectangle", @"list.bullet.rectangle.fill"],
            @"watchlater": @[@"clock_24pt_3x_Normal",
                              @"yt_fill_clock_24pt_3x_Normal",
                              @"clock", @"clock.fill"],
            @"posts": @[@"", @"",
                         @"bubble.left.and.bubble.right",
                         @"bubble.left.and.bubble.right.fill"],
            @"subscriptions": @[@"youtube_outline/subscriptions_cairo_24pt", @"youtube_fill/subscriptions_cairo_24pt",
                                 @"rectangle.stack", @"rectangle.stack.fill"]
        };
    });
    NSArray *values = icons[token];
    return values == nil ? nil : @{
        @"normalAsset": values[0],
        @"selectedAsset": values[1],
        @"normalSymbol": values[2],
        @"selectedSymbol": values[3]
    };
}

static BOOL WolFoxPivotItemSelected(UIView *view) {
    if ([objc_getAssociatedObject(view, WolFoxTabDragOutAssociation) boolValue]) return NO;
    BOOL selected = [objc_getAssociatedObject(
        view,
        WolFoxTabSelectedAssociation
    ) boolValue];
    SEL selector = NSSelectorFromString(@"isSelected");
    if ([view respondsToSelector:selector]) {
        selected = selected ||
            ((BOOL (*)(id, SEL))objc_msgSend)(view, selector);
    }
    return selected ||
        ((view.accessibilityTraits & UIAccessibilityTraitSelected) != 0);
}

static id WolFoxItemRenderer(UIView *view) {
    id renderer = nil;
    @try {
        renderer = [view valueForKey:@"renderer"];
    } @catch (__unused NSException *exception) {
    }
    return renderer;
}

static BOOL WolFoxIsBuiltTab(id renderer) {
    if (renderer == nil) return NO;
    id nested = WolFoxValue(renderer, @"pivotBarItemRenderer");
    return objc_getAssociatedObject(renderer, WolFoxBuiltTabAssociation) != nil ||
        (nested != nil && objc_getAssociatedObject(nested, WolFoxBuiltTabAssociation) != nil);
}

static void WolFoxApplyExtraTabIcon(UIView *view) {
    NSString *token = WolFoxCanonicalTabToken(WolFoxTabToken(view));
    id renderer = token.length == 0 || [token isEqualToString:@"subscriptions"]
        ? WolFoxItemRenderer(view) : nil;
    if (token.length == 0) token = WolFoxCanonicalTabToken(WolFoxTabToken(renderer));
    NSDictionary *config = WolFoxExtraTabIcon(token);
    if (config == nil) {
        UILabel *nativeLabel = WolFoxFindNativeLabel(view);
        NSString *hint = [[NSString stringWithFormat:@"%@ %@ %@ %@",
            nativeLabel.text ?: @"", view.accessibilityLabel ?: @"",
            view.accessibilityIdentifier ?: @"", view.description ?: @""] lowercaseString];
        NSDictionary *aliases = @{
            @"music": @[@"music"],
            @"live": @[@"live"],
            @"gaming": @[@"gaming"],
            @"news": @[@"news"],
            @"sports": @[@"sports"],
            @"learning": @[@"learning"],
            @"fashion": @[@"fashion"],
            @"playlists": @[@"playlists", @"playlist"],
            @"history": @[@"history"],
            @"notifications": @[@"notifs", @"notifications"],
            @"watchlater": @[@"wlater", @"watch later"],
            @"posts": @[@"posts", @"post"]
        };
        for (NSString *candidate in aliases) {
            for (NSString *alias in aliases[candidate]) {
                if ([hint containsString:alias]) {
                    token = candidate;
                    config = WolFoxExtraTabIcon(token);
                    break;
                }
            }
            if (config != nil) break;
        }
    }
    if ([token isEqualToString:@"subscriptions"] &&
        (!WolFoxIsBuiltTab(renderer) || WolFoxSubscriptionsIconType() > 0)) {
        config = nil;
    }
    if (config == nil) {
        [[view viewWithTag:WolFoxExtraIconTag] removeFromSuperview];
        [[view viewWithTag:WolFoxExtraLabelTag] removeFromSuperview];
        return;
    }
    UIImageView *nativeImage = WolFoxFindImageView(view);
    if (nativeImage != nil) {
        nativeImage.hidden = YES;
    }
    UIImageView *icon = (UIImageView *)[view viewWithTag:WolFoxExtraIconTag];
    if (icon == nil) {
        icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        icon.tag = WolFoxExtraIconTag;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.userInteractionEnabled = NO;
        [view addSubview:icon];
    }
    BOOL selected = WolFoxPivotItemSelected(view);
    NSString *asset = config[selected ? @"selectedAsset" : @"normalAsset"];
    NSString *symbol = config[selected ? @"selectedSymbol" : @"normalSymbol"];
    UIImage *image = WolFoxAssetImage(asset, nil) ?:
        WolFoxYouTubeImage(asset.length != 0 ? @[asset] : @[], symbol);
    if (image == nil) {
        image = [UIImage systemImageNamed:@"circle"];
    }
    icon.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    icon.tintColor = WolFoxTabForegroundColor(view);
    icon.hidden = NO;
    BOOL hideLabel = WolFoxTabLabelsHidden(view);
    UILabel *nativeLabel = WolFoxFindNativeLabel(view);
    UILabel *label = (UILabel *)[view viewWithTag:WolFoxExtraLabelTag];
    NSString *title = nativeLabel.text.length != 0
        ? nativeLabel.text : label.text;
    UIFont *font = nativeLabel.font ?: label.font;
    if (nativeLabel != nil) {
        nativeLabel.text = @"";
        nativeLabel.hidden = YES;
        nativeLabel.alpha = 0.0;
    }
    if (label == nil) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.tag = WolFoxExtraLabelTag;
        label.textAlignment = NSTextAlignmentCenter;
        label.userInteractionEnabled = NO;
        [view addSubview:label];
    }
    label.text = title;
    label.font = font ?: [UIFont systemFontOfSize:10.0];
    label.textColor = icon.tintColor;
    label.hidden = hideLabel;
    label.alpha = hideLabel ? 0.0 : 1.0;
    WolFoxLayoutTabIconAndLabel(view, icon, label, hideLabel);
}

static NSString *const WolFoxTintModeKey = @"YTKACE.Preference.Tabs.SelectedTint";
static NSString *const WolFoxTintColorKey = @"YTKACE.Preference.Tabs.SelectedTintColor";
static const void *WolFoxNativeTextColorAssociation = &WolFoxNativeTextColorAssociation;
static const void *WolFoxNativeIconAssociation = &WolFoxNativeIconAssociation;
static IMP OriginalPivotLabelSetTextColor;
static NSInteger WolFoxTintMode;
static UIColor *WolFoxTintColor;

static NSString *WolFoxPivotItemIdentifier(UIView *item);
static UIImageView *WolFoxFindPhotoView(UIView *view);

static BOOL WolFoxRefreshTabTint(void) {
    NSInteger mode = [WolFoxPreferenceObject(WolFoxTintModeKey) integerValue];
    id stored = WolFoxPreferenceObject(WolFoxTintColorKey);
    NSString *value = [[([stored isKindOfClass:NSString.class] ? stored : @"#0A84FF")
        stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    unsigned int rgb = 0x0A84FF;
    if (value.length == 6) [[NSScanner scannerWithString:value] scanHexInt:&rgb];
    UIColor *color = [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                                     green:((rgb >> 8) & 0xFF) / 255.0
                                      blue:(rgb & 0xFF) / 255.0
                                     alpha:1.0];
    BOOL changed = mode != WolFoxTintMode || ![color isEqual:WolFoxTintColor];
    WolFoxTintMode = mode;
    WolFoxTintColor = color;
    return changed;
}

static void WolFoxSetLabelColor(UILabel *label, UIColor *color) {
    if (color == nil || [label.textColor isEqual:color]) return;
    if (OriginalPivotLabelSetTextColor != NULL) {
        ((void (*)(id, SEL, id))OriginalPivotLabelSetTextColor)(label, @selector(setTextColor:), color);
    } else {
        label.textColor = color;
    }
}

static void WolFoxPivotLabelSetTextColor(UILabel *receiver, SEL selector, UIColor *color) {
    if (WolFoxTintMode != 0) {
        UIView *item = WolFoxPivotItemAncestor(receiver);
        if (item != nil) {
            objc_setAssociatedObject(receiver, WolFoxNativeTextColorAssociation, color,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (WolFoxPivotItemSelected(item)) color = WolFoxTintColor;
        }
    }
    if (OriginalPivotLabelSetTextColor != NULL) {
        ((void (*)(id, SEL, id))OriginalPivotLabelSetTextColor)(receiver, selector, color);
    }
}

static void WolFoxCollectLabels(UIView *view, NSMutableArray<UILabel *> *labels) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UILabel.class]) [labels addObject:(UILabel *)subview];
        WolFoxCollectLabels(subview, labels);
    }
}

static void WolFoxApplyTabTint(UIView *item) {
    BOOL tinted = WolFoxTintMode != 0 && WolFoxPivotItemSelected(item);
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    WolFoxCollectLabels(item, labels);
    for (UILabel *label in labels) {
        UIColor *native = objc_getAssociatedObject(label, WolFoxNativeTextColorAssociation);
        if (WolFoxTintMode == 0) {
            if (native == nil) continue;
            objc_setAssociatedObject(label, WolFoxNativeTextColorAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            WolFoxSetLabelColor(label, native);
            continue;
        }
        if (native == nil && label.textColor != nil && ![label.textColor isEqual:WolFoxTintColor]) {
            native = label.textColor;
            objc_setAssociatedObject(label, WolFoxNativeTextColorAssociation, native,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        WolFoxSetLabelColor(label, tinted ? WolFoxTintColor : native);
    }
    BOOL avatar = [WolFoxPivotItemIdentifier(item) isEqualToString:@"FElibrary"] &&
        WolFoxFindPhotoView(item) != nil;
    BOOL tintIcon = tinted && WolFoxTintMode == 2 && !avatar;
    for (NSNumber *tag in @[@0x59414345, @(WolFoxExtraIconTag)]) {
        UIView *custom = [item viewWithTag:tag.integerValue];
        if (tintIcon && [custom isKindOfClass:UIImageView.class]) custom.tintColor = WolFoxTintColor;
    }
    UIImageView *icon = WolFoxFindImageView(item);
    NSArray *native = icon != nil ? objc_getAssociatedObject(icon, WolFoxNativeIconAssociation) : nil;
    if (native == nil) return;
    objc_setAssociatedObject(icon, WolFoxNativeIconAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (icon.image == native[1]) icon.image = native[0];
    icon.tintColor = native[2];
}

static IMP OriginalIconTintSelected;

static UIColor *WolFoxIconTintSelected(UIView *receiver, SEL selector) {
    if (WolFoxTintMode == 2 && ![WolFoxPivotItemIdentifier(receiver) isEqualToString:@"FElibrary"]) {
        return WolFoxTintColor;
    }
    return OriginalIconTintSelected == NULL ? nil
        : ((id (*)(id, SEL))OriginalIconTintSelected)(receiver, selector);
}

static void WolFoxRestyleSelectedTab(UIView *item) {
    SEL setter = NSSelectorFromString(@"setSelected:");
    if (!WolFoxPivotItemSelected(item) || ![item respondsToSelector:setter]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setter, YES);
}

static void WolFoxApplyPivotItemPresentation(UIView *view) {
    BOOL hideLabels = WolFoxTabLabelsHidden(view);
    WolFoxSetLabelsHidden(view, hideLabels);
    WolFoxApplyDownloadIcon(view);
    WolFoxApplyExtraTabIcon(view);
    WolFoxCenterPivotIcon(view, hideLabels);
    WolFoxApplyTabTint(view);
}

static void WolFoxPivotButtonLayout(UIView *receiver, SEL selector) {
    if (OriginalPivotButtonLayout != NULL) {
        ((void (*)(id, SEL))OriginalPivotButtonLayout)(receiver, selector);
    }
    if (WolFoxTintMode != 0) {
        UIView *tintItem = WolFoxPivotItemAncestor(receiver);
        if (tintItem != nil) WolFoxApplyTabTint(tintItem);
    }
    UIView *item = WolFoxPivotItemAncestor(receiver);
    if (item == nil || CGRectIsEmpty(item.bounds) || !WolFoxTabLabelsHidden(item)) return;
    WolFoxSetLabelsHidden(receiver, YES);
    UIImageView *icon = nil;
    for (UIView *child in receiver.subviews) {
        if (![child isKindOfClass:UIImageView.class] || child.hidden ||
            CGRectGetWidth(child.bounds) < 12.0 ||
            CGRectGetHeight(child.bounds) < 12.0) {
            continue;
        }
        icon = (UIImageView *)child;
        break;
    }
    if (icon == nil) return;
    CGPoint target = [item convertPoint:CGPointMake(CGRectGetMidX(item.bounds),
                                                    CGRectGetMidY(item.bounds))
                                  toView:receiver];
    icon.center = target;
}

static BOOL WolFoxContainsCreateText(NSString *value) {
    NSString *text = value.lowercaseString;
    return [text containsString:@"create"] ||
        [text containsString:@"upload"] ||
        [text containsString:@"add video"];
}

static void WolFoxHideCreateViews(UIView *view) {
    BOOL hideCreate = [NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.Tabs.Hidden.Create"];
    for (UIView *subview in view.subviews) {
        NSString *label = subview.accessibilityLabel;
        NSString *identifier = subview.accessibilityIdentifier;
        NSString *className = NSStringFromClass(subview.class);
        if (hideCreate &&
            (WolFoxContainsCreateText(label) ||
             WolFoxContainsCreateText(identifier) ||
             WolFoxContainsCreateText(className))) {
            subview.hidden = YES;
            subview.userInteractionEnabled = NO;
        }
        WolFoxHideCreateViews(subview);
    }
}

static NSString * const WolFoxTabBarGlassModeKey = @"YTKACE.Preference.Tabs.GlassMode";

NSInteger WolFoxTabBarGlassMode(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id value = [defaults objectForKey:WolFoxTabBarGlassModeKey];
    if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
    return [defaults boolForKey:@"YTKACE.Preference.Tabs.Glass"] ? 1 : 0;
}

BOOL WolFoxTabBarOwnGlass(void) {
    return WolFoxTabBarGlassMode() == 1;
}

static IMP WolFoxOrigYouTubeGlass;
static IMP WolFoxOrigYouTubeGlassImpl;
static IMP WolFoxOrigGlassAvailable;
static IMP WolFoxOrigGlassCompute;
static IMP WolFoxOrigPivotGlassEffect;
static IMP WolFoxOrigPivotGlassEffectStyle;

static BOOL WolFoxForcedYouTubeGlass(IMP original, id receiver, SEL selector) {
    NSInteger mode = WolFoxTabBarGlassMode();
    BOOL value = original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
    WolFoxDebugLog(@"glass", @"%@ %@ original=%d mode=%ld", NSStringFromClass(object_getClass(receiver)),
                   NSStringFromSelector(selector), value, (long)mode);
    if (mode == 2) return YES;
    if (mode == 1 || mode == 3) return NO;
    return value;
}

static BOOL WolFoxYouTubeGlass(id receiver, SEL selector) {
    return WolFoxForcedYouTubeGlass(WolFoxOrigYouTubeGlass, receiver, selector);
}

static BOOL WolFoxYouTubeGlassImpl(id receiver, SEL selector) {
    return WolFoxForcedYouTubeGlass(WolFoxOrigYouTubeGlassImpl, receiver, selector);
}

static BOOL WolFoxGlassAvailableValue(IMP original, id receiver, SEL selector) {
    BOOL value = original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
    WolFoxDebugLog(@"glass", @"M3CLiquidGlass %@ original=%d", NSStringFromSelector(selector), value);
    if (WolFoxTabBarGlassMode() == 2 && NSClassFromString(@"UIGlassEffect") != Nil) return YES;
    return value;
}

static BOOL WolFoxGlassAvailable(id receiver, SEL selector) {
    return WolFoxGlassAvailableValue(WolFoxOrigGlassAvailable, receiver, selector);
}

static BOOL WolFoxGlassCompute(id receiver, SEL selector) {
    return WolFoxGlassAvailableValue(WolFoxOrigGlassCompute, receiver, selector);
}

static id WolFoxPivotGlassValue(id value, SEL selector) {
    NSInteger mode = WolFoxTabBarGlassMode();
    WolFoxDebugLog(@"glass", @"YTPivotBarView %@ effect=%@ mode=%ld", NSStringFromSelector(selector),
                   value != nil ? NSStringFromClass([value class]) : @"nil", (long)mode);
    return mode == 1 || mode == 3 ? nil : value;
}

static id WolFoxPivotGlassEffect(id receiver, SEL selector) {
    id value = ((id (*)(id, SEL))WolFoxOrigPivotGlassEffect)(receiver, selector);
    return WolFoxPivotGlassValue(value, selector);
}

static id WolFoxPivotGlassEffectStyle(id receiver, SEL selector, NSInteger style) {
    id value = ((id (*)(id, SEL, NSInteger))WolFoxOrigPivotGlassEffectStyle)(receiver, selector, style);
    return WolFoxPivotGlassValue(value, selector);
}

static IMP WolFoxOrigFloatyBars;
static IMP WolFoxOrigFloatyBarsImpl;
static IMP WolFoxOrigFloatingStyle;
static IMP WolFoxOrigFloatingStyleImpl;
static IMP WolFoxOrigPivotSetFloatingStyle;

static BOOL WolFoxFloatyValue(IMP original, id receiver, SEL selector) {
    BOOL value = original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
    NSInteger mode = WolFoxTabBarGlassMode();
    WolFoxDebugLog(@"glass", @"%@ %@ original=%d mode=%ld", NSStringFromClass(object_getClass(receiver)),
                   NSStringFromSelector(selector), value, (long)mode);
    if (mode == 2) return YES;
    if (mode == 1 || mode == 3) return NO;
    return value;
}

static BOOL WolFoxFloatyBars(id receiver, SEL selector) {
    return WolFoxFloatyValue(WolFoxOrigFloatyBars, receiver, selector);
}

static BOOL WolFoxFloatyBarsImpl(id receiver, SEL selector) {
    return WolFoxFloatyValue(WolFoxOrigFloatyBarsImpl, receiver, selector);
}

static long long WolFoxFloatingStyleValue(IMP original, id receiver, SEL selector) {
    long long value = original != NULL ? ((long long (*)(id, SEL))original)(receiver, selector) : 0;
    NSInteger mode = WolFoxTabBarGlassMode();
    WolFoxDebugLog(@"glass", @"%@ %@ original=%lld mode=%ld", NSStringFromClass(object_getClass(receiver)),
                   NSStringFromSelector(selector), value, (long)mode);
    if (mode == 2) return 2;
    if (mode == 1 || mode == 3) return 0;
    return value;
}

static long long WolFoxFloatingStyle(id receiver, SEL selector) {
    return WolFoxFloatingStyleValue(WolFoxOrigFloatingStyle, receiver, selector);
}

static long long WolFoxFloatingStyleImpl(id receiver, SEL selector) {
    return WolFoxFloatingStyleValue(WolFoxOrigFloatingStyleImpl, receiver, selector);
}

static void WolFoxPivotSetFloatingStyle(id receiver, SEL selector, long long style) {
    NSInteger mode = WolFoxTabBarGlassMode();
    if ((mode == 1 || mode == 3) && style == 2) style = 0;
    ((void (*)(id, SEL, long long))WolFoxOrigPivotSetFloatingStyle)(receiver, selector, style);
}

static BOOL WolFoxMethodTypesMatch(Class cls, NSString *selector, BOOL meta, const char *prefix) {
    Method method = meta ? class_getClassMethod(cls, NSSelectorFromString(selector))
                         : class_getInstanceMethod(cls, NSSelectorFromString(selector));
    const char *types = method != NULL ? method_getTypeEncoding(method) : NULL;
    return types != NULL && strncmp(types, prefix, strlen(prefix)) == 0;
}

static IMP WolFoxOrigInfoDictionary;
static IMP WolFoxOrigInfoObject;
static NSString * const WolFoxDesignCompatibilityKey = @"UIDesignRequiresCompatibility";

static NSDictionary *WolFoxInfoDictionary(NSBundle *self, SEL _cmd) {
    NSDictionary *info = ((id (*)(id, SEL))WolFoxOrigInfoDictionary)(self, _cmd);
    if (self != NSBundle.mainBundle || info[WolFoxDesignCompatibilityKey] == nil) return info;
    NSMutableDictionary *copy = [info mutableCopy];
    [copy removeObjectForKey:WolFoxDesignCompatibilityKey];
    return copy;
}

static id WolFoxInfoObject(NSBundle *self, SEL _cmd, NSString *key) {
    if (self == NSBundle.mainBundle && [key isEqualToString:WolFoxDesignCompatibilityKey]) {
        return nil;
    }
    return ((id (*)(id, SEL, id))WolFoxOrigInfoObject)(self, _cmd, key);
}

__attribute__((constructor)) static void WolFoxInstallLiquidGlassDesign(void) {
    BOOL config = WolFoxMethodTypesMatch(NSClassFromString(@"YTColdConfig"),
        @"mainAppCoreClientIos27EnableLiquidGlass", NO, "B16") &&
        WolFoxInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientIos27EnableLiquidGlass",
            (IMP)WolFoxYouTubeGlass, &WolFoxOrigYouTubeGlass);
    BOOL impl = WolFoxMethodTypesMatch(NSClassFromString(@"YTColdConfigMainAppCoreClientImpl"),
        @"ios27EnableLiquidGlass", NO, "B16") &&
        WolFoxInstallInstanceHook(@"YTColdConfigMainAppCoreClientImpl", @"ios27EnableLiquidGlass",
            (IMP)WolFoxYouTubeGlassImpl, &WolFoxOrigYouTubeGlassImpl);
    BOOL available = WolFoxMethodTypesMatch(NSClassFromString(@"M3CLiquidGlass"),
        @"isLiquidGlassAvailable", YES, "B16") &&
        WolFoxInstallClassHook(@"M3CLiquidGlass", @"isLiquidGlassAvailable",
            (IMP)WolFoxGlassAvailable, &WolFoxOrigGlassAvailable);
    BOOL compute = WolFoxMethodTypesMatch(NSClassFromString(@"M3CLiquidGlass"),
        @"computeIsLiquidGlassAvailable", YES, "B16") &&
        WolFoxInstallClassHook(@"M3CLiquidGlass", @"computeIsLiquidGlassAvailable",
            (IMP)WolFoxGlassCompute, &WolFoxOrigGlassCompute);
    BOOL effect = WolFoxMethodTypesMatch(NSClassFromString(@"YTPivotBarView"), @"liquidGlassEffect", NO, "@16") &&
        WolFoxInstallInstanceHook(@"YTPivotBarView", @"liquidGlassEffect",
            (IMP)WolFoxPivotGlassEffect, &WolFoxOrigPivotGlassEffect);
    BOOL effectStyle = WolFoxMethodTypesMatch(NSClassFromString(@"YTPivotBarView"),
        @"liquidGlassEffectForPageStyle:", NO, "@24") &&
        WolFoxInstallInstanceHook(@"YTPivotBarView", @"liquidGlassEffectForPageStyle:",
            (IMP)WolFoxPivotGlassEffectStyle, &WolFoxOrigPivotGlassEffectStyle);
    BOOL floaty = WolFoxMethodTypesMatch(NSClassFromString(@"YTColdConfig"),
        @"mainAppCoreClientIosEnablePositionedFloatyBars", NO, "B16") &&
        WolFoxInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientIosEnablePositionedFloatyBars",
            (IMP)WolFoxFloatyBars, &WolFoxOrigFloatyBars);
    BOOL floatyImpl = WolFoxMethodTypesMatch(NSClassFromString(@"YTColdConfigMainAppCoreClientImpl"),
        @"iosEnablePositionedFloatyBars", NO, "B16") &&
        WolFoxInstallInstanceHook(@"YTColdConfigMainAppCoreClientImpl", @"iosEnablePositionedFloatyBars",
            (IMP)WolFoxFloatyBarsImpl, &WolFoxOrigFloatyBarsImpl);
    BOOL floatStyle = WolFoxMethodTypesMatch(NSClassFromString(@"YTColdConfig"),
        @"mainAppCoreClientIosFloatingBarStyle", NO, "q16") &&
        WolFoxInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientIosFloatingBarStyle",
            (IMP)WolFoxFloatingStyle, &WolFoxOrigFloatingStyle);
    BOOL floatStyleImpl = WolFoxMethodTypesMatch(NSClassFromString(@"YTColdConfigMainAppCoreClientImpl"),
        @"iosFloatingBarStyle", NO, "q16") &&
        WolFoxInstallInstanceHook(@"YTColdConfigMainAppCoreClientImpl", @"iosFloatingBarStyle",
            (IMP)WolFoxFloatingStyleImpl, &WolFoxOrigFloatingStyleImpl);
    BOOL pivotStyle = WolFoxMethodTypesMatch(NSClassFromString(@"YTPivotBarView"), @"setFloatingBarStyle:", NO, "v24") &&
        WolFoxInstallInstanceHook(@"YTPivotBarView", @"setFloatingBarStyle:",
            (IMP)WolFoxPivotSetFloatingStyle, &WolFoxOrigPivotSetFloatingStyle);
    WolFoxDownloadLog(@"glass", @"youtube glass hooks config=%d impl=%d available=%d compute=%d effect=%d style=%d "
                      "floaty=%d/%d floatStyle=%d/%d pivotStyle=%d mode=%ld",
                      config, impl, available, compute, effect, effectStyle, floaty, floatyImpl, floatStyle,
                      floatStyleImpl, pivotStyle, (long)WolFoxTabBarGlassMode());
    if (NSClassFromString(@"UIGlassEffect") == Nil) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL any = WolFoxTabBarGlassMode() == 1 || WolFoxTabBarGlassMode() == 2;
    for (NSString *key in @[@"YTKACE.Preference.Glass.TopBar",
                            @"YTKACE.Preference.Glass.Menus", @"YTKACE.Preference.Glass.Notices",
                            @"YTKACE.Preference.Glass.Player"]) {
        if ([defaults boolForKey:key]) any = YES;
    }
    if (!any) return;
    id info = (__bridge id)CFBundleGetInfoDictionary(CFBundleGetMainBundle());
    if ([info respondsToSelector:@selector(removeObjectForKey:)]) {
        @try {
            [info removeObjectForKey:WolFoxDesignCompatibilityKey];
        } @catch (__unused NSException *exception) {
        }
    }
    WolFoxInstallInstanceHook(@"NSBundle", @"infoDictionary",
        (IMP)WolFoxInfoDictionary, &WolFoxOrigInfoDictionary);
    WolFoxInstallInstanceHook(@"NSBundle", @"objectForInfoDictionaryKey:",
        (IMP)WolFoxInfoObject, &WolFoxOrigInfoObject);
}

static const void *WolFoxPivotBarSolidAssociation = &WolFoxPivotBarSolidAssociation;
static const void *WolFoxPivotBarGlassAssociation = &WolFoxPivotBarGlassAssociation;
static const void *WolFoxPivotBarPillAssociation = &WolFoxPivotBarPillAssociation;
static const void *WolFoxPivotBarLensAssociation = &WolFoxPivotBarLensAssociation;
static const void *WolFoxPivotBarMagnifyAssociation = &WolFoxPivotBarMagnifyAssociation;
static const void *WolFoxPivotBarHoleAssociation = &WolFoxPivotBarHoleAssociation;
static const void *WolFoxPivotBarPressTimeAssociation = &WolFoxPivotBarPressTimeAssociation;
static const void *WolFoxPivotBarFadedAssociation = &WolFoxPivotBarFadedAssociation;

static BOOL WolFoxViewContainsPivotItem(UIView *view) {
    static Class itemClass;
    if (itemClass == Nil) itemClass = NSClassFromString(@"YTPivotBarItemView");
    if (itemClass != Nil && [view isKindOfClass:itemClass]) return YES;
    for (UIView *subview in view.subviews) {
        if (WolFoxViewContainsPivotItem(subview)) return YES;
    }
    return NO;
}

static void WolFoxCollectPivotItems(UIView *view, NSMutableArray<UIView *> *items) {
    static Class itemClass;
    if (itemClass == Nil) itemClass = NSClassFromString(@"YTPivotBarItemView");
    if (itemClass != Nil && [view isKindOfClass:itemClass]) {
        [items addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) WolFoxCollectPivotItems(subview, items);
}

static NSHashTable<UIView *> *WolFoxPivotFadedViews(UIView *bar) {
    NSHashTable *faded = objc_getAssociatedObject(bar, WolFoxPivotBarFadedAssociation);
    if (faded == nil) {
        faded = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(bar, WolFoxPivotBarFadedAssociation, faded,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return faded;
}

static UIVisualEffect *WolFoxMakeGlassEffect(BOOL interactive) {
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    UIVisualEffect *effect = [effectClass respondsToSelector:styleSelector]
        ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, interactive ? 1 : 0)
        : [effectClass new];
    SEL interactiveSelector = NSSelectorFromString(@"setInteractive:");
    if (interactive && [effect respondsToSelector:interactiveSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, interactiveSelector, YES);
    }
    return effect;
}


static UIView *WolFoxSelectedPivotItem(UIView *bar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    WolFoxCollectPivotItems(bar, items);
    for (UIView *item in items) {
        if ([objc_getAssociatedObject(item, WolFoxTabSelectedAssociation) boolValue]) return item;
    }
    return nil;
}

static id WolFoxPivotControllerForView(UIView *view);

// The highlighted item, but only if it is the tab YouTube is really showing.
// With a tab hidden (like Shorts opened from a shelf), YouTube can be on that
// tab while the bar still highlights Home. A tap on Home must then switch
// tabs instead of being treated as a tap on the current tab (#231).
static UIView *WolFoxCurrentPivotItem(UIView *bar) {
    UIView *selected = WolFoxSelectedPivotItem(bar);
    if (selected == nil) return nil;
    id controller = WolFoxPivotControllerForView(bar);
    SEL current = NSSelectorFromString(@"selectedPivotIdentifier");
    if (![controller respondsToSelector:current]) return selected;
    id identifier = ((id (*)(id, SEL))objc_msgSend)(controller, current);
    NSString *itemIdentifier = WolFoxPivotItemIdentifier(selected);
    if (![identifier isKindOfClass:NSString.class] || [identifier length] == 0 || itemIdentifier == nil) return selected;
    if ([identifier caseInsensitiveCompare:itemIdentifier] == NSOrderedSame) return selected;
    WolFoxDebugLog(@"tabbar", @"showing %@ but bar highlights %@", identifier, itemIdentifier);
    return nil;
}

static NSArray<UIView *> *WolFoxSortedPivotItems(UIView *bar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    WolFoxCollectPivotItems(bar, items);
    NSMutableArray<UIView *> *visible = [NSMutableArray array];
    for (UIView *item in items) {
        if (!item.hidden && CGRectGetWidth(item.bounds) > 0.0) [visible addObject:item];
    }
    [visible sortUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
        CGFloat a = CGRectGetMinX([left convertRect:left.bounds toView:bar]);
        CGFloat b = CGRectGetMinX([right convertRect:right.bounds toView:bar]);
        return a < b ? NSOrderedAscending : (a > b ? NSOrderedDescending : NSOrderedSame);
    }];
    return visible;
}

static void WolFoxTabGeometry(CGRect glass, NSUInteger count, CGFloat *start, CGFloat *step, CGFloat *overlap) {
    CGFloat spill = count <= 4 ? 8.0 : 16.0;
    CGFloat pitch = count == 0 ? 0.0 : (CGRectGetWidth(glass) - 8.0 - spill) / (CGFloat)count;
    if (start) *start = CGRectGetMinX(glass) + 4.0;
    if (step) *step = pitch;
    if (overlap) *overlap = spill;
}

static CGRect WolFoxPillFrameForItem(UIView *bar, UIVisualEffectView *glass, UIView *item) {
    NSArray<UIView *> *sorted = WolFoxSortedPivotItems(bar);
    NSUInteger index = [sorted indexOfObject:item];
    CGRect itemFrame = [item convertRect:item.bounds toView:bar];
    CGFloat inset = 4.0;
    CGFloat left = CGRectGetMinX(itemFrame) + 2.0;
    CGFloat right = CGRectGetMaxX(itemFrame) - 2.0;
    if (index != NSNotFound) {
        CGFloat start = 0.0, step = 0.0, overlap = 0.0;
        WolFoxTabGeometry(glass.frame, sorted.count, &start, &step, &overlap);
        left = start + step * (CGFloat)index;
        right = left + step + overlap;
    }
    left = MAX(left, CGRectGetMinX(glass.frame) + inset);
    right = MIN(right, CGRectGetMaxX(glass.frame) - inset);
    return CGRectMake(left, CGRectGetMinY(glass.frame) + inset,
                      MAX(right - left, 20.0), CGRectGetHeight(glass.frame) - inset * 2.0);
}

static void WolFoxLayoutItemsInGlass(UIView *bar, CGRect glassFrame) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    WolFoxCollectPivotItems(bar, items);
    NSMutableArray<UIView *> *visible = [NSMutableArray array];
    for (UIView *item in items) {
        if (!item.hidden && CGRectGetWidth(item.bounds) > 0.0) [visible addObject:item];
    }
    if (visible.count == 0) return;
    [visible sortUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
        CGFloat a = CGRectGetMinX([left convertRect:left.bounds toView:bar]);
        CGFloat b = CGRectGetMinX([right convertRect:right.bounds toView:bar]);
        return a < b ? NSOrderedAscending : (a > b ? NSOrderedDescending : NSOrderedSame);
    }];
    CGFloat start = 0.0, slot = 0.0, overlap = 0.0;
    WolFoxTabGeometry(glassFrame, visible.count, &start, &slot, &overlap);
    for (NSUInteger index = 0; index < visible.count; index++) {
        UIView *item = visible[index];
        if (item.superview == nil) continue;
        CGRect current = [item convertRect:item.bounds toView:bar];
        CGRect target = CGRectMake(start + overlap * 0.5 + slot * index,
                                   CGRectGetMidY(glassFrame) - CGRectGetHeight(current) * 0.5,
                                   slot, CGRectGetHeight(current));
        CGRect local = [bar convertRect:target toView:item.superview];
        if (!CGRectEqualToRect(CGRectIntegral(item.frame), CGRectIntegral(local))) {
            item.frame = local;
        }
    }
}

// Icon-only tabs keep their renderer under iconOnlyItemRenderer.
static id WolFoxPivotItemAnyRenderer(UIView *item) {
    id renderer = nil;
    @try {
        renderer = [item valueForKey:@"renderer"];
    } @catch (__unused NSException *exception) {
    }
    if (renderer != nil) return renderer;
    @try {
        renderer = [item valueForKey:@"iconOnlyItemRenderer"];
    } @catch (__unused NSException *exception) {
    }
    return renderer;
}

void WolFoxSelectPivotItem(UIView *item) {
    id controller = nil;
    id renderer = nil;
    @try {
        controller = [item valueForKey:@"delegate"];
        renderer = [item valueForKey:@"renderer"];
    } @catch (__unused NSException *exception) {
    }
    NSString *identifier = nil;
    @try {
        identifier = [WolFoxPivotItemAnyRenderer(item) valueForKey:@"pivotIdentifier"];
    } @catch (__unused NSException *exception) {
    }
    SEL tap = NSSelectorFromString(@"didTapItemWithRenderer:");
    if (renderer != nil && [controller respondsToSelector:tap]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, tap, renderer);
        return;
    }
    SEL select = NSSelectorFromString(@"selectItemWithPivotIdentifier:");
    if ([identifier isKindOfClass:NSString.class] && identifier.length != 0 &&
        [controller respondsToSelector:select]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, select, identifier);
        return;
    }
    SEL buttonSelector = NSSelectorFromString(@"navigationButton");
    UIControl *button = [item respondsToSelector:buttonSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(item, buttonSelector) : nil;
    if ([button isKindOfClass:UIControl.class]) {
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

static UIColor *WolFoxPillColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:0.0 alpha:0.4]
            : [UIColor colorWithWhite:0.0 alpha:0.08];
    }];
}

static UIView *WolFoxPivotItemsContainer(UIView *bar) {
    for (UIView *subview in bar.subviews) {
        if (WolFoxViewContainsPivotItem(subview)) return subview;
    }
    return nil;
}

static void WolFoxLensSetObject(id lens, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    if ([lens respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(lens, selector, value);
    }
}

static void WolFoxLensSetInteger(id lens, NSString *name, NSInteger value) {
    SEL selector = NSSelectorFromString(name);
    if ([lens respondsToSelector:selector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(lens, selector, value);
    }
}

static void WolFoxLensSetBool(id lens, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if ([lens respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(lens, selector, value);
    }
}

static UIView *WolFoxMakeSystemLens(UIView *bar) {
    Class lensClass = NSClassFromString(@"_UILiquidLensView");
    SEL initSelector = NSSelectorFromString(@"initWithRestingBackground:");
    if (lensClass == Nil || ![lensClass instancesRespondToSelector:initSelector]) return nil;
    Class selectionClass = NSClassFromString(@"_UITabSelectionView");
    BOOL native = selectionClass != Nil && [selectionClass isSubclassOfClass:UIView.class];
    UIView *resting = native ? [selectionClass new] : [UIView new];
    if (!native) resting.backgroundColor = WolFoxPillColor();
    UIView *lens = ((id (*)(id, SEL, id))objc_msgSend)([lensClass alloc], initSelector, resting);
    if (![lens isKindOfClass:UIView.class]) return nil;
    WolFoxLensSetObject(lens, @"setLiftedContainerView:", bar);
    WolFoxLensSetInteger(lens, @"setLiftedContentMode:", 1);
    WolFoxLensSetInteger(lens, @"setStyle:", 1);
    WolFoxLensSetBool(lens, @"setWarpsContentBelow:", YES);
    if (!native) {
        @try {
            [lens setValue:WolFoxPillColor() forKey:@"restingBackgroundColor"];
        } @catch (__unused NSException *exception) {
        }
    }
    lens.userInteractionEnabled = YES;
    return lens;
}

static BOOL WolFoxIsSystemLens(UIView *view) {
    Class lensClass = NSClassFromString(@"_UILiquidLensView");
    return lensClass != Nil && [view isKindOfClass:lensClass];
}

static void WolFoxTrackLens(UIView *lens, CFTimeInterval seconds);
static void WolFoxLowerWhenArrived(UIView *lens, CGPoint target, id token, dispatch_block_t lower);

static void WolFoxLensSpring(NSTimeInterval response, CGFloat bounce, CGFloat velocity, dispatch_block_t animations) {
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState |
        UIViewAnimationOptionAllowUserInteraction;
    SEL spring = NSSelectorFromString(@"animateWithSpringDuration:bounce:initialSpringVelocity:delay:options:animations:completion:");
    if ([UIView respondsToSelector:spring]) {
        ((void (*)(id, SEL, NSTimeInterval, CGFloat, CGFloat, NSTimeInterval, UIViewAnimationOptions, id, id))objc_msgSend)(
            UIView.class, spring, response, bounce, velocity, 0.0, options, animations, nil);
    } else {
        [UIView animateWithDuration:response delay:0.0 usingSpringWithDamping:1.0 - bounce
              initialSpringVelocity:velocity options:options animations:animations completion:nil];
    }
}

static const void *WolFoxPivotBarExpandedAssociation = &WolFoxPivotBarExpandedAssociation;

static const void *WolFoxPivotBarMinimizedAssociation = &WolFoxPivotBarMinimizedAssociation;
static const void *WolFoxPivotBarMiniAppliedAssociation = &WolFoxPivotBarMiniAppliedAssociation;
static const void *WolFoxPivotBarMiniMaskAssociation = &WolFoxPivotBarMiniMaskAssociation;
static NSString *const WolFoxMinimizeKey = @"YTKACE.Preference.Tabs.GlassMinimize";
static __weak UIView *WolFoxMinimizeBar;
static BOOL WolFoxMinimizeEnabled;
static CGFloat WolFoxMinimizeProgress;

static BOOL WolFoxBarMinimized(UIView *bar) {
    return bar != nil && [objc_getAssociatedObject(bar, WolFoxPivotBarMinimizedAssociation) boolValue];
}


static NSString *WolFoxPivotItemIdentifier(UIView *item);

static void WolFoxBarSpring(NSTimeInterval response, CGFloat damping, NSTimeInterval delay,
                            dispatch_block_t animations, void (^completion)(BOOL)) {
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState |
        UIViewAnimationOptionAllowUserInteraction;
    SEL spring = NSSelectorFromString(@"animateWithSpringDuration:bounce:initialSpringVelocity:delay:options:animations:completion:");
    if ([UIView respondsToSelector:spring]) {
        ((void (*)(id, SEL, NSTimeInterval, CGFloat, CGFloat, NSTimeInterval, UIViewAnimationOptions, id, id))objc_msgSend)(
            UIView.class, spring, response, 1.0 - damping, 0.0, delay, options, animations, completion);
    } else {
        [UIView animateWithDuration:response * 1.5 delay:delay usingSpringWithDamping:damping
              initialSpringVelocity:0.0 options:options animations:animations completion:completion];
    }
}

static void WolFoxSetBarScale(UIView *bar, CGFloat scale, NSTimeInterval response, CGFloat damping) {
    UIView *glass = objc_getAssociatedObject(bar, WolFoxPivotBarGlassAssociation);
    CATransform3D transform = CATransform3DIdentity;
    if (glass != nil && fabs(scale - 1.0) > 0.0001) {
        CGFloat dx = CGRectGetMidX(glass.frame) - CGRectGetMidX(bar.bounds);
        CGFloat dy = CGRectGetMidY(glass.frame) - CGRectGetMidY(bar.bounds);
        transform = CATransform3DTranslate(transform, dx, dy, 0.0);
        transform = CATransform3DScale(transform, scale, scale, 1.0);
        transform = CATransform3DTranslate(transform, -dx, -dy, 0.0);
    }
    CALayer *layer = bar.layer;
    if (CATransform3DEqualToTransform(layer.sublayerTransform, transform)) return;
    CALayer *shown = layer.presentationLayer ?: layer;
    CATransform3D from = shown.sublayerTransform;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.sublayerTransform = transform;
    [CATransaction commit];
    if (response <= 0.0) {
        [layer removeAnimationForKey:@"ytkace.scale"];
        return;
    }
    CASpringAnimation *animation = [CASpringAnimation animationWithKeyPath:@"sublayerTransform"];
    animation.mass = 1.0;
    animation.stiffness = pow(2.0 * M_PI / response, 2.0);
    animation.damping = 4.0 * M_PI * damping / response;
    animation.fromValue = [NSValue valueWithCATransform3D:from];
    animation.toValue = [NSValue valueWithCATransform3D:transform];
    animation.duration = animation.settlingDuration;
    [layer addAnimation:animation forKey:@"ytkace.scale"];
}

static const void *WolFoxPivotBarMiniIconAssociation = &WolFoxPivotBarMiniIconAssociation;
static const void *WolFoxPivotBarMiniIconRectAssociation = &WolFoxPivotBarMiniIconRectAssociation;
static NSTimeInterval WolFoxMiniMaskResponse;
static CGFloat WolFoxMiniMaskDamping;

static void WolFoxSpringLayer(CALayer *layer, NSString *key, id from, id to, NSTimeInterval response, CGFloat damping) {
    CASpringAnimation *animation = [CASpringAnimation animationWithKeyPath:key];
    animation.mass = 1.0;
    animation.stiffness = pow(2.0 * M_PI / response, 2.0);
    animation.damping = 4.0 * M_PI * damping / response;
    animation.fromValue = from;
    animation.toValue = to;
    animation.duration = animation.settlingDuration;
    [layer addAnimation:animation forKey:[@"ytkace." stringByAppendingString:key]];
}

static void WolFoxInstallMiniMask(UIView *bar) {
    UIView *container = WolFoxPivotItemsContainer(bar);
    UIView *glass = objc_getAssociatedObject(bar, WolFoxPivotBarGlassAssociation);
    if (container == nil || glass == nil) return;
    CALayer *mask = objc_getAssociatedObject(bar, WolFoxPivotBarMiniMaskAssociation);
    if (mask == nil) {
        mask = [CALayer layer];
        mask.backgroundColor = UIColor.blackColor.CGColor;
        mask.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(bar, WolFoxPivotBarMiniMaskAssociation, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (container.layer.mask == mask) return;
    CGRect frame = [bar convertRect:glass.frame toView:container];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [mask removeAllAnimations];
    mask.bounds = CGRectMake(0, 0, CGRectGetWidth(frame), CGRectGetHeight(frame));
    mask.position = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    mask.cornerRadius = CGRectGetHeight(frame) * 0.5;
    container.layer.mask = mask;
    [CATransaction commit];
}

static void WolFoxUpdateMiniMask(UIView *bar, CGRect glassFrame) {
    CALayer *mask = objc_getAssociatedObject(bar, WolFoxPivotBarMiniMaskAssociation);
    UIView *container = WolFoxPivotItemsContainer(bar);
    if (mask == nil || container == nil || container.layer.mask != mask) return;
    CGRect frame = [bar convertRect:glassFrame toView:container];
    CGRect bounds = CGRectMake(0, 0, CGRectGetWidth(frame), CGRectGetHeight(frame));
    CGPoint position = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    CGFloat radius = CGRectGetHeight(frame) * 0.5;
    if (CGRectEqualToRect(mask.bounds, bounds) && CGPointEqualToPoint(mask.position, position)) return;
    CALayer *shown = mask.presentationLayer ?: mask;
    CGRect fromBounds = shown.bounds;
    CGPoint fromPosition = shown.position;
    CGFloat fromRadius = shown.cornerRadius;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.bounds = bounds;
    mask.position = position;
    mask.cornerRadius = radius;
    [CATransaction commit];
    if (WolFoxMiniMaskResponse <= 0.0) return;
    WolFoxSpringLayer(mask, @"bounds", [NSValue valueWithCGRect:fromBounds], [NSValue valueWithCGRect:bounds],
                      WolFoxMiniMaskResponse, WolFoxMiniMaskDamping);
    WolFoxSpringLayer(mask, @"position", [NSValue valueWithCGPoint:fromPosition], [NSValue valueWithCGPoint:position],
                      WolFoxMiniMaskResponse, WolFoxMiniMaskDamping);
    WolFoxSpringLayer(mask, @"cornerRadius", @(fromRadius), @(radius), WolFoxMiniMaskResponse, WolFoxMiniMaskDamping);
}

static void WolFoxRemoveMiniMask(UIView *bar) {
    CALayer *mask = objc_getAssociatedObject(bar, WolFoxPivotBarMiniMaskAssociation);
    UIView *container = WolFoxPivotItemsContainer(bar);
    if (mask != nil && container.layer.mask == mask) container.layer.mask = nil;
}

static UIImage *WolFoxRenderItemIcon(UIView *item, CGRect *iconRect) {
    CGSize size = item.bounds.size;
    CGFloat scale = item.window.screen.scale ?: 3.0;
    size_t width = (size_t)ceil(size.width * scale);
    size_t height = (size_t)ceil(size.height * scale);
    if (width == 0 || height == 0) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return nil;
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, scale, -scale);
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    WolFoxCollectLabels(item, labels);
    NSMutableArray<NSNumber *> *opacity = [NSMutableArray array];
    for (UILabel *label in labels) {
        [opacity addObject:@(label.layer.opacity)];
        label.layer.opacity = 0.0;
    }
    CGFloat alpha = item.alpha;
    item.layer.opacity = 1.0;
    [item.layer renderInContext:context];
    item.layer.opacity = (float)alpha;
    for (NSUInteger index = 0; index < labels.count; index++) {
        labels[index].layer.opacity = opacity[index].floatValue;
    }
    uint8_t *pixels = (uint8_t *)CGBitmapContextGetData(context);
    size_t minX = width, minY = height, maxX = 0, maxY = 0;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            if (pixels[(y * width + x) * 4 + 3] < 24) continue;
            minX = MIN(minX, x); maxX = MAX(maxX, x);
            minY = MIN(minY, y); maxY = MAX(maxY, y);
        }
    }
    CGImageRef full = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (full == NULL || maxX < minX || maxY < minY) {
        if (full != NULL) CGImageRelease(full);
        return nil;
    }
    CGRect pixelsRect = CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1);
    CGImageRef cropped = CGImageCreateWithImageInRect(full, pixelsRect);
    CGImageRelease(full);
    if (cropped == NULL) return nil;
    UIImage *image = [UIImage imageWithCGImage:cropped scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(cropped);
    if (iconRect != NULL) {
        *iconRect = CGRectMake(pixelsRect.origin.x / scale, pixelsRect.origin.y / scale,
                               pixelsRect.size.width / scale, pixelsRect.size.height / scale);
    }
    return image;
}

static UIImageView *WolFoxMiniIcon(UIView *bar) {
    UIImageView *icon = objc_getAssociatedObject(bar, WolFoxPivotBarMiniIconAssociation);
    if (icon == nil) {
        icon = [UIImageView new];
        icon.userInteractionEnabled = NO;
        icon.hidden = YES;
        objc_setAssociatedObject(bar, WolFoxPivotBarMiniIconAssociation, icon, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return icon;
}

static CGPoint WolFoxMiniIconHome(UIView *bar, UIView *glass, UIView *selected) {
    NSValue *stored = objc_getAssociatedObject(bar, WolFoxPivotBarMiniIconRectAssociation);
    CGRect rect = stored != nil ? stored.CGRectValue : selected.bounds;
    CGRect inBar = [selected convertRect:rect toView:bar];
    return CGPointMake(CGRectGetMidX(inBar) - CGRectGetMinX(glass.frame),
                       CGRectGetMidY(inBar) - CGRectGetMinY(glass.frame));
}

static void WolFoxApplyMiniAlpha(UIView *bar, BOOL minimized) {
    BOOL applied = [objc_getAssociatedObject(bar, WolFoxPivotBarMiniAppliedAssociation) boolValue];
    if (applied == minimized) return;
    objc_setAssociatedObject(bar, WolFoxPivotBarMiniAppliedAssociation, minimized ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *selected = WolFoxSelectedPivotItem(bar);
    UIView *pill = objc_getAssociatedObject(bar, WolFoxPivotBarPillAssociation);
    pill.alpha = minimized ? 0.0 : 1.0;
    for (UIView *item in WolFoxSortedPivotItems(bar)) {
        if (item != selected) item.alpha = minimized ? 0.0 : 1.0;
    }
}

static void WolFoxRestoreMiniIcon(UIView *bar) {
    UIImageView *icon = objc_getAssociatedObject(bar, WolFoxPivotBarMiniIconAssociation);
    if (icon != nil) icon.hidden = YES;
    for (UIView *item in WolFoxSortedPivotItems(bar)) item.alpha = 1.0;
}

static void WolFoxSetBarMinimized(UIView *bar, BOOL minimized) {
    if (bar == nil || WolFoxBarMinimized(bar) == minimized) return;
    UIView *selected = WolFoxSelectedPivotItem(bar);
    UIView *glass = objc_getAssociatedObject(bar, WolFoxPivotBarGlassAssociation);
    if (minimized && (selected == nil || glass == nil ||
                      [WolFoxPivotItemIdentifier(selected) isEqualToString:@"FEshorts"])) return;
    if (minimized) {
        CGRect rect = CGRectZero;
        UIImage *image = WolFoxRenderItemIcon(selected, &rect);
        if (image == nil) return;
        objc_setAssociatedObject(bar, WolFoxPivotBarMiniIconRectAssociation, [NSValue valueWithCGRect:rect],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIImageView *icon = WolFoxMiniIcon(bar);
        UIView *host = ((UIVisualEffectView *)glass).contentView;
        if (icon.superview != host) [host addSubview:icon];
        [host bringSubviewToFront:icon];
        [UIView performWithoutAnimation:^{
            icon.image = image;
            icon.bounds = CGRectMake(0, 0, CGRectGetWidth(rect), CGRectGetHeight(rect));
            icon.center = WolFoxMiniIconHome(bar, glass, selected);
            icon.alpha = 1.0;
            icon.hidden = NO;
            selected.alpha = 0.0;
        }];
    }
    objc_setAssociatedObject(bar, WolFoxPivotBarMinimizedAssociation, minimized ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WolFoxMinimizeProgress = minimized ? 1.0 : 0.0;
    WolFoxSetBarScale(bar, 1.0, 0.3, 0.8);
    WolFoxInstallMiniMask(bar);
    __weak UIView *weakBar = bar;
    NSTimeInterval response = minimized ? 0.36 : 0.3;
    WolFoxMiniMaskResponse = response;
    WolFoxMiniMaskDamping = 0.72;
    WolFoxBarSpring(response, 0.72, 0.0, ^{
        [bar setNeedsLayout];
        [bar layoutIfNeeded];
    }, ^(__unused BOOL finished) {
        UIView *strongBar = weakBar;
        if (strongBar != nil && !WolFoxBarMinimized(strongBar)) WolFoxRestoreMiniIcon(strongBar);
    });
    WolFoxMiniMaskResponse = 0.0;
    UIImageView *miniIcon = objc_getAssociatedObject(bar, WolFoxPivotBarMiniIconAssociation);
    WolFoxBarSpring(minimized ? 0.42 : 0.36, minimized ? 0.76 : 0.72, 0.05, ^{
        WolFoxApplyMiniAlpha(bar, minimized);
        if (!minimized) {
            selected.alpha = 1.0;
            miniIcon.alpha = 0.0;
        }
    }, ^(__unused BOOL finished) {
        UIView *strongBar = weakBar;
        if (strongBar != nil && !WolFoxBarMinimized(strongBar)) WolFoxRemoveMiniMask(strongBar);
    });
}

static void WolFoxSetBarExpanded(UIView *bar, BOOL expanded) {
    if (bar == nil || [objc_getAssociatedObject(bar, WolFoxPivotBarExpandedAssociation) boolValue] == expanded) return;
    objc_setAssociatedObject(bar, WolFoxPivotBarExpandedAssociation, expanded ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *lens = objc_getAssociatedObject(bar, WolFoxPivotBarPillAssociation);
    if (lens != nil) WolFoxTrackLens(lens, 0.7);
    WolFoxLensSpring(0.4, expanded ? 0.5 : 0.25, 0.0, ^{
        [bar setNeedsLayout];
        [bar layoutIfNeeded];
    });
}

static void WolFoxSetSystemLensLifted(UIView *lens, BOOL lifted, __unused NSString *tag,
                                      dispatch_block_t animations, dispatch_block_t done) {
    WolFoxTrackLens(lens, 0.8);
    SEL selector = NSSelectorFromString(@"setLifted:animated:alongsideAnimations:completion:");
    if (![lens respondsToSelector:selector]) {
        [UIView animateWithDuration:0.3 animations:animations completion:^(__unused BOOL finished) {
            if (done != nil) done();
        }];
        return;
    }
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        if (done != nil) done();
    };
    ((void (*)(id, SEL, BOOL, BOOL, id, id))objc_msgSend)(lens, selector, lifted, YES,
        animations, completion);
}

static void WolFoxUpdateGlassPill(UIView *bar, UIVisualEffectView *glass) {
    UIView *pill = objc_getAssociatedObject(bar, WolFoxPivotBarPillAssociation);
    if (pill == nil) {
        pill = WolFoxMakeSystemLens(bar);
        if (pill == nil) {
            pill = [UIView new];
            pill.userInteractionEnabled = NO;
            pill.layer.cornerCurve = kCACornerCurveContinuous;
            pill.backgroundColor = WolFoxPillColor();
        }
        objc_setAssociatedObject(bar, WolFoxPivotBarPillAssociation, pill,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL dragging = objc_getAssociatedObject(pill, WolFoxPivotBarFadedAssociation) != nil;
    if (dragging) return;
    if (WolFoxIsSystemLens(pill)) {
        UIView *host = glass.contentView;
        if (pill.superview != host) {
            [pill removeFromSuperview];
            host.clipsToBounds = NO;
            [host addSubview:pill];
            WolFoxLensSetObject(pill, @"setLiftedContainerView:", host);
            for (UIView *subview in bar.subviews.copy) {
                if ([NSStringFromClass(subview.class) containsString:@"DestOutView"]) [subview removeFromSuperview];
            }
        }
    } else if (pill.superview != bar) {
        [pill removeFromSuperview];
        [bar insertSubview:pill aboveSubview:glass];
    } else {
        [bar insertSubview:pill aboveSubview:glass];
    }
    UIView *selected = WolFoxSelectedPivotItem(bar);
    if (selected == nil) {
        pill.hidden = YES;
        return;
    }
    CGRect target = WolFoxPillFrameForItem(bar, glass, selected);
    BOOL systemLens = WolFoxIsSystemLens(pill);
    if (systemLens) target = [bar convertRect:target toView:pill.superview];
    CGRect current = pill.frame;
    if (systemLens) {
        current = CGRectMake(pill.center.x - CGRectGetWidth(pill.bounds) * 0.5,
                             pill.center.y - CGRectGetHeight(pill.bounds) * 0.5,
                             CGRectGetWidth(pill.bounds), CGRectGetHeight(pill.bounds));
    }
    BOOL moved = fabs(CGRectGetMidX(current) - CGRectGetMidX(target)) > 1.0 ||
        fabs(CGRectGetMidY(current) - CGRectGetMidY(target)) > 1.0 ||
        fabs(CGRectGetWidth(current) - CGRectGetWidth(target)) > 1.0 ||
        fabs(CGRectGetHeight(current) - CGRectGetHeight(target)) > 1.0;
    BOOL animate = !pill.hidden && !CGRectIsEmpty(current) && moved;
    pill.hidden = NO;
    if (!systemLens) pill.layer.cornerRadius = CGRectGetHeight(target) * 0.5;
    if (systemLens && !moved) return;
    if (systemLens && (!animate || fabs(CGRectGetMidX(current) - CGRectGetMidX(target)) < 12.0)) {
        [UIView performWithoutAnimation:^{
            pill.bounds = CGRectMake(0, 0, CGRectGetWidth(target), CGRectGetHeight(target));
            pill.center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        }];
    } else if (animate && systemLens) {
        id token = [NSObject new];
        objc_setAssociatedObject(pill, WolFoxPivotBarFadedAssociation, token,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGPoint center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        CGRect lifted = CGRectMake(0, 0, CGRectGetWidth(target) + 16.0, CGRectGetHeight(target) + 16.0);
        __weak UIView *weakPill = pill;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *settled = weakPill;
            if (settled != nil && objc_getAssociatedObject(settled, WolFoxPivotBarFadedAssociation) == token) {
                objc_setAssociatedObject(settled, WolFoxPivotBarFadedAssociation, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
        CGPoint start = pill.center;
        WolFoxSetSystemLensLifted(pill, YES, @"tap", ^{
            pill.bounds = lifted;
            pill.center = start;
        }, nil);
        WolFoxLensSpring(0.4, 0.15, 0.0, ^{ pill.center = center; });
        WolFoxLowerWhenArrived(pill, center, token, ^{
            UIView *strongPill = weakPill;
            if (strongPill == nil ||
                objc_getAssociatedObject(strongPill, WolFoxPivotBarFadedAssociation) != token) return;
            WolFoxSetSystemLensLifted(strongPill, NO, @"tap", ^{
                strongPill.bounds = CGRectMake(0, 0, CGRectGetWidth(target), CGRectGetHeight(target));
                strongPill.center = center;
            }, ^{
                UIView *lens = weakPill;
                if (lens != nil && objc_getAssociatedObject(lens, WolFoxPivotBarFadedAssociation) == token) {
                    objc_setAssociatedObject(lens, WolFoxPivotBarFadedAssociation, nil,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            });
        });
    } else if (animate) {
        [UIView animateWithDuration:0.35 delay:0.0 usingSpringWithDamping:0.8
              initialSpringVelocity:0.3 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ pill.frame = target; } completion:nil];
    } else {
        pill.frame = target;
    }
}

@interface WolFoxGlassSlideHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) BOOL lifted;
@property (nonatomic, assign) CGPoint startPoint;
@property (nonatomic, assign) CGFloat restingWidth;
@property (nonatomic, assign) CFTimeInterval pressStart;
@property (nonatomic, assign) CFTimeInterval lastMove;
@property (nonatomic, assign) CGFloat lastX;
@property (nonatomic, assign) CGFloat velocityX;
@property (nonatomic, assign) CGFloat anchorX;
@property (nonatomic, weak) UIView *touchedItem;
@property (nonatomic, weak) UIControl *heldButton;
@property (nonatomic, assign) NSUInteger pressID;
+ (instancetype)sharedHandler;
- (void)handlePress:(UILongPressGestureRecognizer *)gesture;
- (void)attachMagnifierToLens:(UIView *)lens bar:(UIView *)bar;
@end

static NSString *WolFoxPivotItemIdentifier(UIView *item) {
    id renderer = WolFoxPivotItemAnyRenderer(item);
    id identifier = nil;
    @try {
        identifier = [renderer valueForKey:@"pivotIdentifier"];
    } @catch (__unused NSException *exception) {
    }
    return [identifier isKindOfClass:NSString.class] && [identifier length] != 0 ? identifier : nil;
}

static UIImageView *WolFoxFindPhotoView(UIView *view) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UIImageView.class] && !subview.hidden) {
            UIImage *image = ((UIImageView *)subview).image;
            if (image != nil && image.renderingMode != UIImageRenderingModeAlwaysTemplate &&
                CGRectGetWidth(subview.bounds) >= 12.0) {
                return (UIImageView *)subview;
            }
        }
        UIImageView *found = WolFoxFindPhotoView(subview);
        if (found != nil) return found;
    }
    return nil;
}

static UIImageView *WolFoxAvatarView(UIView *bar) {
    for (UIView *item in WolFoxSortedPivotItems(bar)) {
        id renderer = nil;
        @try {
            renderer = [item valueForKey:@"renderer"];
        } @catch (__unused NSException *exception) {
        }
        id identifier = nil;
        @try {
            identifier = [renderer valueForKey:@"pivotIdentifier"];
        } @catch (__unused NSException *exception) {
        }
        if ([identifier isEqual:@"FElibrary"]) return WolFoxFindPhotoView(item);
    }
    return nil;
}

static const void *WolFoxStencilSlicesAssociation = &WolFoxStencilSlicesAssociation;

static UIView *WolFoxItemContaining(UIView *view, UIView *bar) {
    for (UIView *item in WolFoxSortedPivotItems(bar)) {
        if ([view isDescendantOfView:item]) return item;
    }
    return nil;
}

static void WolFoxSyncStencilSlices(UIView *copy) {
    NSMapTable<UIView *, UIView *> *slices = objc_getAssociatedObject(copy, WolFoxStencilSlicesAssociation);
    if (slices.count == 0) return;
    [UIView performWithoutAnimation:^{
        for (UIView *item in slices) {
            UIView *slice = [slices objectForKey:item];
            if (item.superview == nil) continue;
            CALayer *shown = item.layer.presentationLayer ?: item.layer;
            CGRect frame = [item.superview convertRect:shown.frame toView:copy];
            slice.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        }
    }];
}

static void WolFoxSyncLensMask(UIView *lens) {
    UIView *copy = objc_getAssociatedObject(lens, WolFoxPivotBarMagnifyAssociation);
    if (copy == nil || lens.superview == nil) return;
    WolFoxSyncStencilSlices(copy);
    UIView *mask = copy.maskView;
    if (mask == nil) {
        mask = [UIView new];
        mask.backgroundColor = UIColor.blackColor;
        mask.layer.cornerCurve = kCACornerCurveContinuous;
        copy.maskView = mask;
    }
    CALayer *shown = lens.layer.presentationLayer ?: lens.layer;
    CGRect lensFrame = shown.frame;
    CGRect frame = [lens.superview convertRect:lensFrame toView:copy];
    mask.frame = frame;
    mask.layer.cornerRadius = CGRectGetHeight(frame) * 0.5;
    UIView *items = objc_getAssociatedObject(lens, WolFoxPivotBarHoleAssociation);
    if (items == nil) return;
    CAShapeLayer *hole = [items.layer.mask isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer *)items.layer.mask : nil;
    if (hole == nil) {
        hole = [CAShapeLayer layer];
        hole.fillRule = kCAFillRuleEvenOdd;
        items.layer.mask = hole;
    }
    CGRect lensRect = CGRectInset([lens.superview convertRect:lensFrame toView:items], 4.0, 4.0);
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:CGRectInset(items.bounds, -200.0, -200.0)];
    [path appendPath:[UIBezierPath bezierPathWithRoundedRect:lensRect cornerRadius:CGRectGetHeight(lensRect) * 0.5]];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    hole.frame = items.bounds;
    hole.path = path.CGPath;
    [CATransaction commit];
}

@interface WolFoxLensTracker : NSObject
@property(nonatomic, weak) UIView *lens;
@property(nonatomic, strong) CADisplayLink *link;
@property(nonatomic, assign) CFTimeInterval until;
@property(nonatomic, copy) dispatch_block_t pendingLower;
@property(nonatomic, assign) CGPoint lowerTarget;
@property(nonatomic, weak) id lowerToken;
@end

@implementation WolFoxLensTracker

- (void)tick {
    UIView *lens = self.lens;
    if (lens == nil || CACurrentMediaTime() > self.until) {
        [self.link invalidate];
        self.link = nil;
        if (lens != nil) WolFoxSyncLensMask(lens);
        return;
    }
    WolFoxSyncLensMask(lens);
    [self checkArrival];
}

- (void)checkArrival {
    UIView *lens = self.lens;
    if (lens == nil || self.pendingLower == nil) return;
    CGPoint shown = (lens.layer.presentationLayer ?: lens.layer).position;
    if (fabs(shown.x - self.lowerTarget.x) >= 8.0) return;
    dispatch_block_t lower = self.pendingLower;
    self.pendingLower = nil;
    if (objc_getAssociatedObject(lens, WolFoxPivotBarFadedAssociation) == self.lowerToken) lower();
}

@end

static const void *WolFoxLensTrackerAssociation = &WolFoxLensTrackerAssociation;

static void WolFoxTrackLens(UIView *lens, CFTimeInterval seconds) {
    if (lens == nil) return;
    WolFoxLensTracker *tracker = objc_getAssociatedObject(lens, WolFoxLensTrackerAssociation);
    if (tracker == nil) {
        tracker = [WolFoxLensTracker new];
        tracker.lens = lens;
        objc_setAssociatedObject(lens, WolFoxLensTrackerAssociation, tracker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tracker.until = MAX(tracker.until, CACurrentMediaTime() + seconds);
    if (tracker.link == nil) {
        tracker.link = [CADisplayLink displayLinkWithTarget:tracker selector:@selector(tick)];
        [tracker.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

static void WolFoxLowerWhenArrived(UIView *lens, CGPoint target, id token, dispatch_block_t lower) {
    if (lens == nil) return;
    WolFoxTrackLens(lens, 1.0);
    WolFoxLensTracker *tracker = objc_getAssociatedObject(lens, WolFoxLensTrackerAssociation);
    tracker.pendingLower = lower;
    tracker.lowerTarget = target;
    tracker.lowerToken = token;
    __weak WolFoxLensTracker *weakTracker = tracker;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WolFoxLensTracker *strongTracker = weakTracker;
        if (strongTracker.pendingLower == nil || strongTracker.pendingLower != lower) return;
        strongTracker.pendingLower = nil;
        UIView *strongLens = strongTracker.lens;
        if (strongLens != nil && objc_getAssociatedObject(strongLens, WolFoxPivotBarFadedAssociation) == token) lower();
    });
}

static void WolFoxClearLensHole(UIView *lens) {
    UIView *items = objc_getAssociatedObject(lens, WolFoxPivotBarHoleAssociation);
    items.layer.mask = nil;
    objc_setAssociatedObject(lens, WolFoxPivotBarHoleAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *WolFoxScrubTarget(UIView *bar, CGPoint point, UIEvent *event);
static UIView *WolFoxInlinePlayerBar(UIView *bar);

@implementation WolFoxGlassSlideHandler

+ (instancetype)sharedHandler {
    static WolFoxGlassSlideHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ handler = [WolFoxGlassSlideHandler new]; });
    return handler;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    UIView *bar = gesture.view;
    UIView *glass = objc_getAssociatedObject(bar, WolFoxPivotBarGlassAssociation);
    if (glass == nil) return NO;
    if (WolFoxBarMinimized(bar)) {
        WolFoxSetBarMinimized(bar, NO);
        return NO;
    }
    CGPoint point = [gesture locationInView:bar];
    if (!CGRectContainsPoint(glass.frame, point)) return NO;
    UIView *scrub = WolFoxScrubTarget(bar, point, nil);
    if (scrub != nil && scrub != WolFoxInlinePlayerBar(bar)) return NO;
    UIView *touched = [self pivotItemNearX:point.x inView:bar bar:bar];
    if (touched != nil && WolFoxPivotItemIdentifier(touched) == nil) return NO;
    gesture.cancelsTouchesInView = touched == nil || touched != WolFoxCurrentPivotItem(bar);
    return YES;
}



- (UIVisualEffectView *)lensForBar:(UIView *)bar {
    UIVisualEffectView *lens = objc_getAssociatedObject(bar, WolFoxPivotBarLensAssociation);
    if (lens == nil) {
        lens = [[UIVisualEffectView alloc] initWithEffect:WolFoxMakeGlassEffect(YES)];
        lens.userInteractionEnabled = NO;
        lens.layer.cornerCurve = kCACornerCurveContinuous;
        lens.clipsToBounds = YES;
        objc_setAssociatedObject(bar, WolFoxPivotBarLensAssociation, lens,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (lens.superview != bar) [bar addSubview:lens];
    [bar bringSubviewToFront:lens];
    return lens;
}

- (UIView *)pivotItemNearX:(CGFloat)x inView:(UIView *)view bar:(UIView *)bar {
    NSArray<UIView *> *sorted = WolFoxSortedPivotItems(bar);
    UIView *glass = objc_getAssociatedObject(bar, WolFoxPivotBarGlassAssociation);
    if (sorted.count == 0 || glass == nil) return nil;
    CGFloat barX = [view convertPoint:CGPointMake(x, 0.0) toView:bar].x;
    CGFloat start = 0.0, slot = 0.0, overlap = 0.0;
    WolFoxTabGeometry(glass.frame, sorted.count, &start, &slot, &overlap);
    NSInteger index = slot > 0.0 ? (NSInteger)floor((barX - start - overlap * 0.5) / slot) : 0;
    index = MAX(0, MIN((NSInteger)sorted.count - 1, index));
    return sorted[(NSUInteger)index];
}

- (UIControl *)buttonForItem:(UIView *)item {
    SEL buttonSelector = NSSelectorFromString(@"navigationButton");
    if (![item respondsToSelector:buttonSelector]) return nil;
    UIControl *button = ((id (*)(id, SEL))objc_msgSend)(item, buttonSelector);
    return [button isKindOfClass:UIControl.class] ? button : nil;
}

- (UIView *)stencilForItems:(UIView *)items {
    CGSize size = items.bounds.size;
    CGFloat scale = items.window.screen.scale ?: 3.0;
    size_t width = (size_t)ceil(size.width * scale);
    size_t height = (size_t)ceil(size.height * scale);
    if (width == 0 || height == 0) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return nil;
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, scale, -scale);
    NSMutableArray<UIView *> *flipped = [NSMutableArray array];
    SEL setSelected = NSSelectorFromString(@"setSelected:");
    WolFoxStencilRendering = YES;
    UIView *bar = items.superview;
    UIImageView *avatar = WolFoxAvatarView(bar);
    BOOL avatarHidden = avatar.hidden;
    avatar.hidden = YES;
    NSMutableArray<UIView *> *draggedOut = [NSMutableArray array];
    for (UIView *item in WolFoxSortedPivotItems(bar)) {
        if ([objc_getAssociatedObject(item, WolFoxTabDragOutAssociation) boolValue]) {
            objc_setAssociatedObject(item, WolFoxTabDragOutAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [draggedOut addObject:item];
        }
    }
    for (UIView *item in WolFoxSortedPivotItems(bar)) {
        if (WolFoxPivotItemSelected(item) || ![item respondsToSelector:setSelected]) continue;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setSelected, YES);
        [item layoutIfNeeded];
        [flipped addObject:item];
    }
    CALayer *hole = items.layer.mask;
    items.layer.mask = nil;
    [items.layer renderInContext:context];
    items.layer.mask = hole;
    for (UIView *item in flipped) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setSelected, NO);
        [item layoutIfNeeded];
    }
    for (UIView *item in draggedOut) {
        objc_setAssociatedObject(item, WolFoxTabDragOutAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    avatar.hidden = avatarHidden;
    WolFoxStencilRendering = NO;
    uint8_t *pixels = (uint8_t *)CGBitmapContextGetData(context);
    double total = 0.0;
    double weight = 0.0;
    for (size_t index = 0; index < width * height; index++) {
        uint8_t *pixel = pixels + index * 4;
        if (pixel[3] < 128) continue;
        uint8_t peak = MAX(pixel[0], MAX(pixel[1], pixel[2]));
        total += (double)peak / (double)pixel[3];
        weight += 1.0;
    }
    BOOL brightIcons = weight == 0.0 || total / weight > 0.5;
    BOOL keepColor = WolFoxTintMode != 0;
    for (size_t index = 0; !keepColor && index < width * height; index++) {
        uint8_t *pixel = pixels + index * 4;
        uint8_t alpha = pixel[3];
        uint8_t level = 0;
        if (alpha > 0) {
            CGFloat color = (CGFloat)MAX(pixel[0], MAX(pixel[1], pixel[2])) / (CGFloat)alpha;
            CGFloat contrast = brightIcons ? color : 1.0 - color;
            CGFloat ratio = MAX(0.0, MIN(1.0, (contrast - 0.5) / 0.35));
            level = (uint8_t)(ratio * (CGFloat)alpha);
        }
        pixel[0] = level;
        pixel[1] = level;
        pixel[2] = level;
        pixel[3] = level;
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (image == NULL) return nil;
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, size.width, size.height)];
    UIColor *tint = brightIcons ? UIColor.whiteColor : UIColor.blackColor;
    NSMapTable<UIView *, UIView *> *slices = [NSMapTable weakToStrongObjectsMapTable];
    CGRect whole = CGRectMake(0.0, 0.0, size.width, size.height);
    for (UIView *item in WolFoxSortedPivotItems(bar)) {
        CGRect frame = CGRectIntersection([item convertRect:item.bounds toView:items], whole);
        if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) continue;
        CGRect pixels = CGRectMake(floor(frame.origin.x * scale), floor(frame.origin.y * scale),
                                   ceil(frame.size.width * scale), ceil(frame.size.height * scale));
        CGImageRef piece = CGImageCreateWithImageInRect(image, pixels);
        if (piece == NULL) continue;
        UIImageView *slice = [[UIImageView alloc] initWithImage:
            [[UIImage imageWithCGImage:piece scale:scale orientation:UIImageOrientationUp]
                imageWithRenderingMode:keepColor ? UIImageRenderingModeAlwaysOriginal
                                                 : UIImageRenderingModeAlwaysTemplate]];
        CGImageRelease(piece);
        slice.frame = CGRectMake(pixels.origin.x / scale, pixels.origin.y / scale,
                                 pixels.size.width / scale, pixels.size.height / scale);
        slice.tintColor = tint;
        [view addSubview:slice];
        [slices setObject:slice forKey:item];
    }
    CGImageRelease(image);
    if (avatar != nil && !avatarHidden && avatar.image != nil && avatar.window != nil) {
        CGRect face = [avatar convertRect:avatar.bounds toView:items];
        CGFloat radius = MIN(avatar.layer.cornerRadius, MIN(face.size.width, face.size.height) * 0.5);
        if (radius <= 0.0) radius = MIN(face.size.width, face.size.height) * 0.5;
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = scale;
        UIImage *photo = [[[UIGraphicsImageRenderer alloc] initWithSize:face.size format:format]
            imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
            CGRect bounds = CGRectMake(0.0, 0.0, face.size.width, face.size.height);
            [[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius] addClip];
            CGSize source = avatar.image.size;
            CGFloat fill = source.width > 0.0 && source.height > 0.0
                ? MAX(bounds.size.width / source.width, bounds.size.height / source.height) : 1.0;
            CGSize drawn = CGSizeMake(source.width * fill, source.height * fill);
            [avatar.image drawInRect:CGRectMake((bounds.size.width - drawn.width) * 0.5,
                                                (bounds.size.height - drawn.height) * 0.5,
                                                drawn.width, drawn.height)];
        }];
        UIImageView *photoSlice = [[UIImageView alloc] initWithImage:photo];
        photoSlice.frame = face;
        [view addSubview:photoSlice];
        UIView *owner = WolFoxItemContaining(avatar, bar);
        if (owner != nil) {
            UIView *holder = [slices objectForKey:owner];
            if (holder != nil) {
                photoSlice.frame = [view convertRect:face toView:holder];
                [holder addSubview:photoSlice];
            }
        }
    }
    objc_setAssociatedObject(view, WolFoxStencilSlicesAssociation, slices, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return view;
}

- (void)attachMagnifierToLens:(UIView *)lens bar:(UIView *)bar {
    UIView *old = objc_getAssociatedObject(lens, WolFoxPivotBarMagnifyAssociation);
    [old removeFromSuperview];
    UIView *items = WolFoxPivotItemsContainer(bar);
    UIView *copy = [self stencilForItems:items];
    if (copy == nil || lens.superview == nil) return;
    copy.userInteractionEnabled = NO;
    copy.frame = [items convertRect:items.bounds toView:lens.superview];
    [lens.superview insertSubview:copy atIndex:0];
    WolFoxLensSetObject(lens, @"setLiftedContentView:", copy);
    objc_setAssociatedObject(lens, WolFoxPivotBarMagnifyAssociation, copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(lens, WolFoxPivotBarHoleAssociation, items, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WolFoxSyncLensMask(lens);
}

- (void)liftLens:(UIView *)lens bar:(UIView *)bar size:(CGSize)size center:(CGPoint)center {
    WolFoxSetBarExpanded(bar, YES);
    NSUInteger pressID = self.pressID;
    __weak UIView *weakLens = lens;
    __weak UIView *weakBar = bar;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strongLens = weakLens;
        if (strongLens == nil || weakBar == nil || !self.lifted || self.pressID != pressID) return;
        [self attachMagnifierToLens:strongLens bar:weakBar];
    });
    UIView *old = objc_getAssociatedObject(lens, WolFoxPivotBarMagnifyAssociation);
    [old removeFromSuperview];
    UIView *items = WolFoxPivotItemsContainer(bar);
    UIView *copy = [self stencilForItems:items];
    if (copy != nil && lens.superview != nil) {
        copy.userInteractionEnabled = NO;
        copy.frame = [items convertRect:items.bounds toView:lens.superview];
        [lens.superview insertSubview:copy atIndex:0];
        WolFoxLensSetObject(lens, @"setLiftedContentView:", copy);
        objc_setAssociatedObject(lens, WolFoxPivotBarMagnifyAssociation, copy,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(lens, WolFoxPivotBarHoleAssociation, items,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        WolFoxSyncLensMask(lens);
    }
    self.lifted = YES;
    WolFoxSetSystemLensLifted(lens, YES, @"press", ^{
        lens.bounds = CGRectMake(0, 0, size.width, size.height);
        WolFoxSyncLensMask(lens);
    }, nil);
    WolFoxLensSpring(0.4, 0.15, 0.0, ^{ lens.center = center; });
}

- (void)handleSystemLens:(UIView *)lens gesture:(UILongPressGestureRecognizer *)gesture
                     bar:(UIView *)bar glass:(UIView *)glass {
    UIView *host = lens.superview ?: bar;
    CGPoint point = [gesture locationInView:bar];
    UIView *selectedNow = WolFoxSelectedPivotItem(bar);
    CGRect restingFrame = selectedNow != nil
        ? [bar convertRect:WolFoxPillFrameForItem(bar, (UIVisualEffectView *)glass, selectedNow) toView:host]
        : lens.frame;
    CGFloat lensWidth = self.lifted ? self.restingWidth : CGRectGetWidth(restingFrame);
    CGFloat width = lensWidth + 16.0;
    CGFloat height = CGRectGetHeight(restingFrame) + 16.0;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        UIView *grabbed = [self pivotItemNearX:point.x inView:bar bar:bar];
        CGRect slot = grabbed != nil ? WolFoxPillFrameForItem(bar, (UIVisualEffectView *)glass, grabbed) : CGRectNull;
        self.anchorX = CGRectIsNull(slot) || CGRectGetWidth(slot) <= 0.0
            ? 0.5 : MAX(0.0, MIN(1.0, (point.x - CGRectGetMinX(slot)) / CGRectGetWidth(slot)));
    }
    CGFloat anchor = self.anchorX;
    CGFloat clamped = MAX(CGRectGetMinX(glass.frame) + lensWidth * anchor,
                          MIN(point.x, CGRectGetMaxX(glass.frame) - lensWidth * (1.0 - anchor)));
    CGFloat centerX = clamped - lensWidth * anchor + lensWidth * 0.5;
    CGPoint center = [bar convertPoint:CGPointMake(centerX, CGRectGetMidY(glass.frame)) toView:host];
    CFTimeInterval now = CACurrentMediaTime();
    if (gesture.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(lens, WolFoxPivotBarFadedAssociation, [NSObject new],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.pressStart = now;
        self.lastMove = now;
        self.lastX = point.x;
        self.velocityX = 0.0;
        self.startPoint = point;
        self.dragging = NO;
        self.lifted = NO;
        self.restingWidth = CGRectGetWidth(restingFrame);
        self.touchedItem = [self pivotItemNearX:point.x inView:bar bar:bar];
        self.heldButton = nil;
        self.pressID += 1;
        UIView *selected = WolFoxSelectedPivotItem(bar);
        BOOL same = self.touchedItem == selected;
        for (UIView *subview in bar.subviews.copy) {
            if ([NSStringFromClass(subview.class) containsString:@"DestOutView"]) [subview removeFromSuperview];
        }
        (void)same;
        if (self.touchedItem != nil) {
            [self liftLens:lens bar:bar size:CGSizeMake(width, height) center:center];
        }
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CFTimeInterval step = now - self.lastMove;
        if (step > 0.001) {
            CGFloat instant = (point.x - self.lastX) / step;
            self.velocityX = instant * 0.6 + self.velocityX * 0.4;
            self.lastX = point.x;
            self.lastMove = now;
        }
        if (!self.dragging && fabs(point.x - self.startPoint.x) > 4.0) {
            self.dragging = YES;
            if (!gesture.cancelsTouchesInView) {
                self.heldButton = [self buttonForItem:self.touchedItem];
            }
            if (!self.lifted) {
                [self liftLens:lens bar:bar size:CGSizeMake(width, height) center:center];
                return;
            }
        }
        if (!self.lifted) return;
        WolFoxLensSpring(0.2, 0.15, 0.0, ^{ lens.center = center; });
        WolFoxTrackLens(lens, 0.4);
        return;
    }
    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled) {
        return;
    }
    BOOL dragging = self.dragging;
    self.pressID += 1;
    WolFoxSetBarExpanded(bar, NO);
    UIView *draggedFrom = self.touchedItem;
    if ([objc_getAssociatedObject(draggedFrom, WolFoxTabDragOutAssociation) boolValue]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(draggedFrom, WolFoxTabDragOutAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            WolFoxApplyPivotItemPresentation(draggedFrom);
        });
    }
    UIControl *heldButton = self.heldButton;
    self.heldButton = nil;
    if (!self.lifted) {
        BOOL bump = !dragging && gesture.state == UIGestureRecognizerStateEnded &&
            self.touchedItem != nil && self.touchedItem == WolFoxCurrentPivotItem(bar);
        if (!bump) {
            objc_setAssociatedObject(lens, WolFoxPivotBarFadedAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIView *tapped = self.touchedItem;
            if (gesture.state == UIGestureRecognizerStateEnded && tapped != nil &&
                WolFoxPivotItemIdentifier(tapped) != nil && tapped != WolFoxCurrentPivotItem(bar)) {
                WolFoxSelectPivotItem(tapped);
            }
            return;
        }
        id bumpToken = [NSObject new];
        objc_setAssociatedObject(lens, WolFoxPivotBarFadedAssociation, bumpToken,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGRect resting = restingFrame;
        CGPoint middle = CGPointMake(CGRectGetMidX(resting), CGRectGetMidY(resting));
        __weak UIView *weakBump = lens;
        WolFoxSetSystemLensLifted(lens, YES, @"bump", ^{
            lens.bounds = CGRectMake(0, 0, CGRectGetWidth(resting) + 14.0, CGRectGetHeight(resting) + 10.0);
            lens.center = middle;
        }, nil);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *bumped = weakBump;
            if (bumped == nil || objc_getAssociatedObject(bumped, WolFoxPivotBarFadedAssociation) != bumpToken) return;
            WolFoxSetSystemLensLifted(bumped, NO, @"bump", ^{
                bumped.bounds = CGRectMake(0, 0, CGRectGetWidth(resting), CGRectGetHeight(resting));
                bumped.center = middle;
            }, nil);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *bumped = weakBump;
            if (bumped != nil && objc_getAssociatedObject(bumped, WolFoxPivotBarFadedAssociation) == bumpToken) {
                objc_setAssociatedObject(bumped, WolFoxPivotBarFadedAssociation, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
        return;
    }
    self.lifted = NO;
    id token = [NSObject new];
    objc_setAssociatedObject(lens, WolFoxPivotBarFadedAssociation, token,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *nearest = dragging ? [self pivotItemNearX:point.x inView:bar bar:bar] : self.touchedItem;
    if (gesture.state == UIGestureRecognizerStateCancelled) nearest = WolFoxSelectedPivotItem(bar);
    if (nearest != nil && WolFoxPivotItemIdentifier(nearest) == nil) nearest = WolFoxSelectedPivotItem(bar);
    CGRect target = nearest != nil
        ? [bar convertRect:WolFoxPillFrameForItem(bar, (UIVisualEffectView *)glass, nearest) toView:host]
        : lens.frame;
    __weak UIView *weakLens = lens;
    CGPoint slide = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    WolFoxLensSpring(0.4, 0.15, 0.0, ^{
        lens.center = slide;
        WolFoxSyncLensMask(lens);
    });
    WolFoxLowerWhenArrived(lens, slide, token, ^{
        UIView *lowering = weakLens;
        if (lowering == nil || objc_getAssociatedObject(lowering, WolFoxPivotBarFadedAssociation) != token) return;
        UIView *copy = objc_getAssociatedObject(lowering, WolFoxPivotBarMagnifyAssociation);
        copy.hidden = YES;
        WolFoxClearLensHole(lowering);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *settled = weakLens;
            if (settled != nil && objc_getAssociatedObject(settled, WolFoxPivotBarFadedAssociation) == token) {
                objc_setAssociatedObject(settled, WolFoxPivotBarFadedAssociation, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
        WolFoxSetSystemLensLifted(lowering, NO, @"up", ^{
            lowering.bounds = CGRectMake(0, 0, target.size.width, target.size.height);
            lowering.center = slide;
            WolFoxSyncLensMask(lowering);
        }, ^{
            UIView *strongLens = weakLens;
            if (strongLens != nil && objc_getAssociatedObject(strongLens, WolFoxPivotBarFadedAssociation) == token) {
                objc_setAssociatedObject(strongLens, WolFoxPivotBarFadedAssociation, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
    });
    if (gesture.state == UIGestureRecognizerStateEnded && nearest != nil &&
        nearest != WolFoxCurrentPivotItem(bar)) {
        if (heldButton != nil) {
            __weak UIView *weakNearest = nearest;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *pick = weakNearest;
                if (pick != nil && pick != WolFoxCurrentPivotItem(bar)) WolFoxSelectPivotItem(pick);
            });
        } else {
            WolFoxSelectPivotItem(nearest);
        }
    }
}

- (CGFloat)lensCenterForPoint:(CGPoint)point bar:(UIView *)bar glass:(UIView *)glass width:(CGFloat)width {
    return MAX(CGRectGetMinX(glass.frame) + width * 0.35,
               MIN(point.x, CGRectGetMaxX(glass.frame) - width * 0.35));
}

- (void)handlePress:(UILongPressGestureRecognizer *)gesture {
    UIView *bar = gesture.view;
    UIView *glass = objc_getAssociatedObject(bar, WolFoxPivotBarGlassAssociation);
    UIView *pill = objc_getAssociatedObject(bar, WolFoxPivotBarPillAssociation);
    if (glass == nil || pill == nil) return;
    if (WolFoxIsSystemLens(pill)) {
        [self handleSystemLens:pill gesture:gesture bar:bar glass:glass];
        return;
    }
    UIVisualEffectView *lens = [self lensForBar:bar];
    CGPoint point = [gesture locationInView:bar];
    CGFloat width = MAX(CGRectGetWidth(pill.frame), 80.0) + 26.0;
    CGFloat height = CGRectGetHeight(glass.frame) + 18.0;
    CGFloat centerX = [self lensCenterForPoint:point bar:bar glass:glass width:width];
    CGPoint center = CGPointMake(centerX, CGRectGetMidY(glass.frame));
    if (gesture.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(pill, WolFoxPivotBarFadedAssociation, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lens.bounds = pill.bounds.size.width > 0 ? pill.bounds : CGRectMake(0, 0, width, height);
        lens.center = pill.frame.size.width > 0
            ? CGPointMake(CGRectGetMidX(pill.frame), CGRectGetMidY(pill.frame)) : center;
        lens.layer.cornerRadius = CGRectGetHeight(lens.bounds) * 0.5;
        lens.alpha = 0.0;
        lens.hidden = NO;
        [UIView animateWithDuration:0.3 delay:0.0 usingSpringWithDamping:0.7
              initialSpringVelocity:0.5 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            lens.alpha = 1.0;
            lens.bounds = CGRectMake(0, 0, width, height);
            lens.layer.cornerRadius = height * 0.5;
            lens.center = center;
            pill.alpha = 0.0;
        } completion:nil];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        [UIView animateWithDuration:0.12 delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{ lens.center = center; } completion:nil];
        return;
    }
    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled) {
        return;
    }
    objc_setAssociatedObject(pill, WolFoxPivotBarFadedAssociation, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    WolFoxCollectPivotItems(bar, items);
    UIView *nearest = nil;
    CGFloat best = CGFLOAT_MAX;
    for (UIView *item in items) {
        if (item.hidden || CGRectGetWidth(item.bounds) <= 0.0) continue;
        CGFloat distance = fabs(CGRectGetMidX([item convertRect:item.bounds toView:bar]) - lens.center.x);
        if (distance < best) {
            best = distance;
            nearest = item;
        }
    }
    CGRect target = nearest != nil
        ? WolFoxPillFrameForItem(bar, (UIVisualEffectView *)glass, nearest) : pill.frame;
    pill.frame = target;
    pill.layer.cornerRadius = CGRectGetHeight(target) * 0.5;
    [UIView animateWithDuration:0.32 delay:0.0 usingSpringWithDamping:0.8
          initialSpringVelocity:0.3 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        lens.bounds = CGRectMake(0, 0, target.size.width, target.size.height);
        lens.layer.cornerRadius = target.size.height * 0.5;
        lens.center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        lens.alpha = 0.0;
        pill.alpha = 1.0;
    } completion:^(BOOL finished) {
        if (finished) lens.hidden = YES;
    }];
    if (gesture.state == UIGestureRecognizerStateEnded && nearest != nil &&
        nearest != WolFoxSelectedPivotItem(bar)) {
        WolFoxSelectPivotItem(nearest);
    }
}

@end

static void WolFoxInstallGlassSlide(UIView *bar) {
    for (UIGestureRecognizer *recognizer in bar.gestureRecognizers) {
        if (recognizer.delegate == [WolFoxGlassSlideHandler sharedHandler]) return;
    }
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[WolFoxGlassSlideHandler sharedHandler] action:@selector(handlePress:)];
    press.minimumPressDuration = 0.0;
    press.allowableMovement = CGFLOAT_MAX;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesEnded = NO;
    press.delegate = [WolFoxGlassSlideHandler sharedHandler];
    [bar addGestureRecognizer:press];
}

BOOL WolFoxLiquidGlassAvailable(void) {
    return NSClassFromString(@"UIGlassEffect") != Nil;
}

static BOOL WolFoxViewLooksLikeScrubber(UIView *view, NSUInteger depth) {
    NSString *name = NSStringFromClass(view.class).lowercaseString;
    for (NSString *word in @[@"scrub", @"progress", @"playerbar", @"slider", @"seek", @"timebar"]) {
        if ([name containsString:word]) return YES;
    }
    if (depth == 0) return NO;
    for (UIView *subview in view.subviews) {
        if (WolFoxViewLooksLikeScrubber(subview, depth - 1)) return YES;
    }
    return NO;
}

static UIView *WolFoxInlinePlayerBar(UIView *bar) {
    Class playerBarClass = NSClassFromString(@"YTInlinePlayerBarContainerView");
    if (playerBarClass == Nil || objc_getAssociatedObject(bar, WolFoxPivotBarGlassAssociation) == nil) return nil;
    for (UIView *child in bar.subviews) {
        if ([child isKindOfClass:playerBarClass] && !child.hidden && child.alpha > 0.01 &&
            child.userInteractionEnabled && child.window != nil) {
            return child;
        }
    }
    return nil;
}

static UIView *WolFoxScrubTarget(UIView *bar, CGPoint point, UIEvent *event) {
    UIView *playerBar = WolFoxInlinePlayerBar(bar);
    if (playerBar == nil) return nil;
    CGPoint local = [bar convertPoint:point toView:playerBar];
    if (CGRectContainsPoint(playerBar.bounds, local)) return [playerBar hitTest:local withEvent:event];
    UIView *glass = objc_getAssociatedObject(bar, WolFoxPivotBarGlassAssociation);
    if (point.y >= CGRectGetMinY(glass.frame) + 12.0) return nil;
    Class gestureClass = NSClassFromString(@"YTInlineScrubGestureView");
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:playerBar];
    while (queue.count != 0) {
        UIView *node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (gestureClass != Nil && [node isKindOfClass:gestureClass] && !node.hidden && node.userInteractionEnabled) {
            CGPoint inside = [bar convertPoint:point toView:node];
            return CGRectContainsPoint(node.bounds, inside) ? node : nil;
        }
        [queue addObjectsFromArray:node.subviews];
    }
    return nil;
}

static IMP OriginalPivotBarPointInside;
static IMP OriginalPivotBarHitTest;

static BOOL WolFoxPivotBarPointInside(UIView *receiver, SEL selector, CGPoint point, UIEvent *event) {
    BOOL inside = OriginalPivotBarPointInside != NULL &&
        ((BOOL (*)(id, SEL, CGPoint, id))OriginalPivotBarPointInside)(receiver, selector, point, event);
    if (WolFoxBarMinimized(receiver)) {
        UIView *glass = objc_getAssociatedObject(receiver, WolFoxPivotBarGlassAssociation);
        return glass != nil && CGRectContainsPoint(CGRectInset(glass.frame, -6.0, -6.0), point);
    }
    if (inside) return YES;
    UIView *playerBar = WolFoxInlinePlayerBar(receiver);
    return playerBar != nil && CGRectContainsPoint(playerBar.frame, point);
}

static UIView *WolFoxPivotBarHitTest(UIView *receiver, SEL selector, CGPoint point, UIEvent *event) {
    if (WolFoxBarMinimized(receiver)) {
        UIView *glass = objc_getAssociatedObject(receiver, WolFoxPivotBarGlassAssociation);
        return glass != nil && CGRectContainsPoint(CGRectInset(glass.frame, -6.0, -6.0), point) ? receiver : nil;
    }
    UIView *scrub = WolFoxScrubTarget(receiver, point, event);
    if (scrub != nil && scrub != WolFoxInlinePlayerBar(receiver)) return scrub;
    if (!CGRectContainsPoint(receiver.bounds, point)) return nil;
    return OriginalPivotBarHitTest == NULL ? nil
        : ((id (*)(id, SEL, CGPoint, id))OriginalPivotBarHitTest)(receiver, selector, point, event);
}

static CGFloat const WolFoxMinimizeDistance = 64.0;
static BOOL WolFoxMinimizeActive;
static __weak UIScrollView *WolFoxMinimizeScroll;
static CGFloat WolFoxMinimizeLastOffset;
static const void *WolFoxMinimizePanAssociation = &WolFoxMinimizePanAssociation;

static BOOL WolFoxMinimizeEligible(UIScrollView *scrollView, UIView *bar) {
    UIWindow *window = bar.window;
    if (window == nil || scrollView.window != window || bar.hidden || bar.alpha < 0.01) return NO;
    if (CGRectGetHeight(scrollView.bounds) < CGRectGetHeight(window.bounds) * 0.4) return NO;
    CGFloat range = scrollView.contentSize.height + scrollView.adjustedContentInset.top +
        scrollView.adjustedContentInset.bottom - CGRectGetHeight(scrollView.bounds);
    if (range < WolFoxMinimizeDistance * 1.5) return NO;
    if (!CGRectIntersectsRect([bar convertRect:bar.bounds toView:window], window.bounds)) return NO;
    UIView *selected = WolFoxSelectedPivotItem(bar);
    return selected != nil && ![WolFoxPivotItemIdentifier(selected) isEqualToString:@"FEshorts"];
}

static void WolFoxApplyMinimizeProgress(UIView *bar, CGFloat progress, BOOL tracking) {
    WolFoxMinimizeProgress = progress;
    CGFloat scale = (progress <= 0.0 || progress >= 1.0) ? 1.0 : 1.0 - progress * 0.05;
    if (tracking) WolFoxSetBarScale(bar, scale, 0.1, 0.8);
    else WolFoxSetBarScale(bar, scale, 0.3, 0.8);
}

@interface WolFoxMinimizePanTracker : NSObject
@end

@implementation WolFoxMinimizePanTracker

- (void)pan:(UIPanGestureRecognizer *)pan {
    UIScrollView *scrollView = (UIScrollView *)pan.view;
    UIView *bar = WolFoxMinimizeBar;
    if (!WolFoxMinimizeEnabled || bar == nil || ![scrollView isKindOfClass:UIScrollView.class]) return;
    if (pan.state == UIGestureRecognizerStateBegan) {
        if (!WolFoxMinimizeEligible(scrollView, bar)) return;
        WolFoxMinimizeActive = YES;
        WolFoxMinimizeScroll = scrollView;
        WolFoxMinimizeLastOffset = scrollView.contentOffset.y;
        return;
    }
    if (pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateCancelled &&
        pan.state != UIGestureRecognizerStateFailed) return;
    if (!WolFoxMinimizeActive || WolFoxMinimizeScroll != scrollView) return;
    WolFoxMinimizeActive = NO;
    BOOL minimized = WolFoxBarMinimized(bar);
    CGFloat progress = WolFoxMinimizeProgress;
    CGFloat velocity = -[pan velocityInView:scrollView].y;
    if (pan.state == UIGestureRecognizerStateEnded && fabs(velocity) > 50.0) {
        CGFloat rate = scrollView.decelerationRate;
        CGFloat travel = velocity / 1000.0 * rate / MAX(0.0001, 1.0 - rate);
        CGFloat minY = -scrollView.adjustedContentInset.top;
        CGFloat maxY = MAX(minY, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom -
                                 CGRectGetHeight(scrollView.bounds));
        CGFloat target = MAX(minY, MIN(maxY, scrollView.contentOffset.y + travel));
        progress += (target - scrollView.contentOffset.y) / WolFoxMinimizeDistance;
        if (target <= minY + 0.5) progress = 0.0;
    }
    if (progress >= 1.0) {
        if (minimized) WolFoxApplyMinimizeProgress(bar, 1.0, NO);
        else WolFoxSetBarMinimized(bar, YES);
    } else if (minimized) {
        WolFoxSetBarMinimized(bar, NO);
    } else {
        WolFoxApplyMinimizeProgress(bar, 0.0, NO);
    }
}

@end

static IMP OriginalScrollSetContentOffset;

static NSUInteger WolFoxShortsClipGeneration;

static NSArray<UIView *> *WolFoxShortsClipViews(UIScrollView *pager) {
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:pager];
    for (UIView *view = pager.superview.superview.superview; view != nil && views.count < 3; view = view.superview) {
        if ([view isKindOfClass:NSClassFromString(@"YTAppView")]) break;
        if (view.clipsToBounds) [views addObject:view];
    }
    return views;
}

static const void *WolFoxShortsClipViewsAssociation = &WolFoxShortsClipViewsAssociation;
static const void *WolFoxShortsCoverAssociation = &WolFoxShortsCoverAssociation;

static UIView *WolFoxShortsCover(UIScrollView *pager, NSArray<UIView *> *views, BOOL create) {
    UIView *cover = objc_getAssociatedObject(pager, WolFoxShortsCoverAssociation);
    if (cover != nil || !create) return cover;
    UIView *outer = views.lastObject;
    if (outer == nil || outer.window == nil) return nil;
    CGRect frame = [outer convertRect:outer.bounds toView:nil];
    CGFloat below = CGRectGetHeight(outer.window.bounds) - CGRectGetMaxY(frame);
    if (below <= 0.5) return nil;
    cover = [[UIView alloc] initWithFrame:CGRectMake(0.0, CGRectGetHeight(outer.bounds), CGRectGetWidth(outer.bounds), below)];
    cover.backgroundColor = UIColor.blackColor;
    cover.userInteractionEnabled = NO;
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [outer addSubview:cover];
    UIView *backing = [[UIView alloc] initWithFrame:[outer.superview convertRect:cover.frame fromView:outer]];
    backing.backgroundColor = UIColor.blackColor;
    backing.userInteractionEnabled = NO;
    backing.autoresizingMask = cover.autoresizingMask;
    [outer.superview insertSubview:backing belowSubview:outer];
    objc_setAssociatedObject(cover, WolFoxShortsCoverAssociation, backing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(pager, WolFoxShortsCoverAssociation, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return cover;
}

static void WolFoxFadeShortsCover(UIView *cover, CGFloat alpha, void (^completion)(BOOL finished)) {
    [UIView animateWithDuration:0.2 delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ cover.alpha = alpha; }
                     completion:completion];
}

static void WolFoxSetShortsClipping(UIScrollView *pager, BOOL clips) {
    NSArray<UIView *> *views = objc_getAssociatedObject(pager, WolFoxShortsClipViewsAssociation);
    if (!clips) {
        if (views == nil) {
            views = WolFoxShortsClipViews(pager);
            objc_setAssociatedObject(pager, WolFoxShortsClipViewsAssociation, views, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UIView *cover = WolFoxShortsCover(pager, views, YES);
        cover.alpha = 1.0;
        for (UIView *view in views) view.clipsToBounds = NO;
        if (cover != nil) WolFoxFadeShortsCover(cover, 0.0, nil);
        return;
    }
    UIView *cover = WolFoxShortsCover(pager, views, NO);
    void (^reclip)(void) = ^{
        for (UIView *view in views) view.clipsToBounds = YES;
        [(UIView *)objc_getAssociatedObject(cover, WolFoxShortsCoverAssociation) removeFromSuperview];
        [cover removeFromSuperview];
        objc_setAssociatedObject(pager, WolFoxShortsCoverAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(pager, WolFoxShortsClipViewsAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    };
    if (cover == nil) {
        reclip();
        return;
    }
    NSUInteger generation = WolFoxShortsClipGeneration;
    __weak UIScrollView *weakPager = pager;
    WolFoxFadeShortsCover(cover, 1.0, ^(__unused BOOL finished) {
        UIScrollView *strongPager = weakPager;
        if (strongPager == nil || generation != WolFoxShortsClipGeneration ||
            strongPager.isDragging || strongPager.isDecelerating) return;
        reclip();
    });
}

static void WolFoxScheduleShortsReclip(UIScrollView *pager, NSUInteger generation) {
    __weak UIScrollView *weakPager = pager;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIScrollView *strongPager = weakPager;
        if (strongPager == nil || generation != WolFoxShortsClipGeneration) return;
        if (strongPager.isDragging || strongPager.isDecelerating) {
            WolFoxScheduleShortsReclip(strongPager, generation);
            return;
        }
        WolFoxSetShortsClipping(strongPager, YES);
    });
}

static void WolFoxShortsSeeThrough(UIScrollView *receiver) {
    static Class pagerClass;
    static Class rootClass;
    if (pagerClass == Nil) {
        pagerClass = NSClassFromString(@"YTAsyncCollectionView");
        rootClass = NSClassFromString(@"YTReelWatchRootView");
    }
    if (pagerClass == Nil || rootClass == Nil || [receiver class] != pagerClass) return;
    if (![receiver.superview.superview isKindOfClass:rootClass]) return;
    if (!receiver.isDragging && !receiver.isDecelerating) return;
    UIView *cover = objc_getAssociatedObject(receiver, WolFoxShortsCoverAssociation);
    if (cover != nil && cover.layer.presentationLayer.opacity > 0.01 && cover.alpha > 0.0) {
        WolFoxFadeShortsCover(cover, 0.0, nil);
    }
    if (objc_getAssociatedObject(receiver, WolFoxShortsClipViewsAssociation) == nil) {
        WolFoxSetShortsClipping(receiver, NO);
        static BOOL logged;
        if (!logged) {
            logged = YES;
            NSMutableArray *names = [NSMutableArray array];
            for (UIView *view in objc_getAssociatedObject(receiver, WolFoxShortsClipViewsAssociation))
                [names addObject:[NSString stringWithFormat:@"%@%@", NSStringFromClass(view.class),
                                  NSStringFromCGRect([view convertRect:view.bounds toView:nil])]];
            WolFoxDownloadLog(@"glass", @"shorts unclip %@", [names componentsJoinedByString:@" < "]);
        }
    }
    WolFoxScheduleShortsReclip(receiver, ++WolFoxShortsClipGeneration);
}

static void WolFoxScrollSetContentOffset(UIScrollView *receiver, SEL selector, CGPoint offset) {
    if (OriginalScrollSetContentOffset != NULL) {
        ((void (*)(id, SEL, CGPoint))OriginalScrollSetContentOffset)(receiver, selector, offset);
    }
    WolFoxShortsSeeThrough(receiver);
    if (!WolFoxMinimizeEnabled) return;
    UIView *bar = WolFoxMinimizeBar;
    if (bar == nil) return;
    if (objc_getAssociatedObject(receiver, WolFoxMinimizePanAssociation) == nil && receiver.isTracking) {
        static WolFoxMinimizePanTracker *tracker;
        if (tracker == nil) tracker = [WolFoxMinimizePanTracker new];
        objc_setAssociatedObject(receiver, WolFoxMinimizePanAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [receiver.panGestureRecognizer addTarget:tracker action:@selector(pan:)];
        if (WolFoxMinimizeEligible(receiver, bar)) {
            WolFoxMinimizeActive = YES;
            WolFoxMinimizeScroll = receiver;
            WolFoxMinimizeLastOffset = receiver.contentOffset.y;
        }
        return;
    }
    if (receiver != WolFoxMinimizeScroll) return;
    CGFloat y = receiver.contentOffset.y;
    BOOL minimized = WolFoxBarMinimized(bar);
    if (y <= -receiver.adjustedContentInset.top + 0.5) {
        WolFoxMinimizeLastOffset = y;
        if (minimized) WolFoxSetBarMinimized(bar, NO);
        else if (WolFoxMinimizeProgress > 0.0) WolFoxApplyMinimizeProgress(bar, 0.0, receiver.isTracking);
        return;
    }
    if (!WolFoxMinimizeActive || !receiver.isTracking) return;
    CGFloat delta = y - WolFoxMinimizeLastOffset;
    WolFoxMinimizeLastOffset = y;
    if (fabs(delta) < 0.01) return;
    CGFloat progress = WolFoxMinimizeProgress + delta / WolFoxMinimizeDistance;
    progress = MAX(minimized ? 0.01 : 0.0, MIN(1.0, progress));
    if (!minimized && progress >= 1.0) {
        WolFoxMinimizeActive = NO;
        WolFoxSetBarMinimized(bar, YES);
        return;
    }
    WolFoxApplyMinimizeProgress(bar, progress, YES);
}

static IMP OriginalHidePivotBarOnScroll;
static IMP OriginalUpdatePivotBarVisibility;

static BOOL WolFoxHidePivotBarOnScroll(id receiver, SEL selector) {
    if (WolFoxMinimizeEnabled) return NO;
    return OriginalHidePivotBarOnScroll != NULL &&
        ((BOOL (*)(id, SEL))OriginalHidePivotBarOnScroll)(receiver, selector);
}

static void WolFoxUpdatePivotBarVisibility(id receiver, SEL selector, UIScrollView *scrollView,
                                           CGFloat offsetY, BOOL atBottom) {
    if (WolFoxMinimizeEnabled) return;
    if (OriginalUpdatePivotBarVisibility != NULL) {
        ((void (*)(id, SEL, id, CGFloat, BOOL))OriginalUpdatePivotBarVisibility)(
            receiver, selector, scrollView, offsetY, atBottom);
    }
}

static const void *WolFoxShortsBackdropAssociation = &WolFoxShortsBackdropAssociation;

static void WolFoxApplyShortsBackdrop(UIView *bar, BOOL shorts) {
    UIView *host = bar.superview;
    if (host == nil) return;
    id saved = objc_getAssociatedObject(host, WolFoxShortsBackdropAssociation);
    if (shorts) {
        if (saved == nil) {
            objc_setAssociatedObject(host, WolFoxShortsBackdropAssociation, host.backgroundColor ?: (id)NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        host.backgroundColor = UIColor.blackColor;
    } else if (saved != nil) {
        host.backgroundColor = saved == NSNull.null ? nil : saved;
        objc_setAssociatedObject(host, WolFoxShortsBackdropAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL WolFoxApplyPivotBarGlass(UIView *receiver, UIView *blur) {
    UIVisualEffectView *glass = objc_getAssociatedObject(receiver, WolFoxPivotBarGlassAssociation);
    BOOL wanted = WolFoxTabBarOwnGlass() &&
        WolFoxLiquidGlassAvailable();
    if (!wanted) {
        if (glass != nil) {
            [glass removeFromSuperview];
            [(UIView *)objc_getAssociatedObject(receiver, WolFoxPivotBarPillAssociation) removeFromSuperview];
            [(UIView *)objc_getAssociatedObject(receiver, WolFoxPivotBarLensAssociation) removeFromSuperview];
            objc_setAssociatedObject(receiver, WolFoxPivotBarLensAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(receiver, WolFoxPivotBarPillAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(receiver, WolFoxPivotBarGlassAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            blur.hidden = NO;
            for (UIView *view in WolFoxPivotFadedViews(receiver).allObjects) view.alpha = 1.0;
            [WolFoxPivotFadedViews(receiver) removeAllObjects];
        }
        return NO;
    }
    if (glass == nil) {
        glass = [[UIVisualEffectView alloc] initWithEffect:WolFoxMakeGlassEffect(NO)];
        glass.userInteractionEnabled = NO;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.clipsToBounds = NO;
        objc_setAssociatedObject(receiver, WolFoxPivotBarGlassAssociation, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    blur.hidden = YES;
    NSHashTable<UIView *> *faded = WolFoxPivotFadedViews(receiver);
    UIView *ownPill = objc_getAssociatedObject(receiver, WolFoxPivotBarPillAssociation);
    UIView *ownLens = objc_getAssociatedObject(receiver, WolFoxPivotBarLensAssociation);
    for (UIView *sibling in receiver.subviews) {
        if (sibling == glass || sibling == ownPill || sibling == ownLens) continue;
        if (WolFoxViewContainsPivotItem(sibling)) {
            sibling.opaque = NO;
            sibling.backgroundColor = UIColor.clearColor;
        } else if (sibling.alpha > 0.0 && !WolFoxViewLooksLikeScrubber(sibling, 3) &&
                   (CGRectGetHeight(sibling.frame) >= CGRectGetHeight(receiver.bounds) * 0.6 ||
                    CGRectGetHeight(sibling.frame) <= 1.5)) {
            sibling.alpha = 0.0;
            [faded addObject:sibling];
        }
    }
    receiver.backgroundColor = UIColor.clearColor;
    receiver.layer.backgroundColor = UIColor.clearColor.CGColor;
    receiver.opaque = NO;
    if (glass.superview != receiver) {
        [glass removeFromSuperview];
        [receiver insertSubview:glass atIndex:0];
    } else {
        [receiver sendSubviewToBack:glass];
    }
    // YouTube's strip along the bottom ("You're Incognito", offline, back
    // online) sits over the bar's lower part; keep the glass above it.
    CGFloat covered = 0.0;
    for (UIView *sibling in receiver.superview.subviews) {
        if (sibling.hidden || sibling.alpha < 0.01 ||
            ![NSStringFromClass(sibling.class) isEqualToString:@"YTSlimStatusBarView"]) continue;
        CGRect strip = [sibling convertRect:sibling.bounds toView:receiver];
        // Only while the strip is on screen over the bar's lower part. With
        // the watch page open both slide off screen and the glass must too.
        UIWindow *window = receiver.window;
        CGRect onScreen = window != nil ? [sibling convertRect:sibling.bounds toView:nil] : CGRectNull;
        if (window == nil || CGRectGetMinY(onScreen) >= CGRectGetHeight(window.bounds) - 1.0) continue;
        if (CGRectGetHeight(strip) > 0.0 && CGRectGetMinY(strip) > 0.0 &&
            CGRectGetMinY(strip) < CGRectGetHeight(receiver.bounds)) {
            covered = MAX(covered, CGRectGetHeight(receiver.bounds) - CGRectGetMinY(strip));
        }
    }
    CGFloat itemHeight = CGRectGetHeight(receiver.bounds) - MAX(receiver.safeAreaInsets.bottom, covered);
    CGFloat extra = 7.0;
    CGFloat glassHeight = MAX(itemHeight, 44.0) + extra * 2.0;
    CGFloat glassTop = covered > 0.0
        ? CGRectGetHeight(receiver.bounds) - covered - glassHeight - 4.0
        : MIN(0.0, CGRectGetHeight(receiver.bounds) - glassHeight - 4.0);
    BOOL expanded = [objc_getAssociatedObject(receiver, WolFoxPivotBarExpandedAssociation) boolValue];
    NSUInteger tabs = 0;
    for (UIView *item in WolFoxSortedPivotItems(receiver)) {
        if (!item.hidden && CGRectGetWidth(item.bounds) > 0.0) tabs += 1;
    }
    CGFloat barWidth = CGRectGetWidth(receiver.bounds);
    CGFloat margin = expanded ? 14.0 : 21.0;
    CGFloat glassWidth = barWidth - margin * 2.0;
    CGRect screen = (receiver.window.screen ?: UIScreen.mainScreen).bounds;
    CGFloat shortSide = MIN(CGRectGetWidth(screen), CGRectGetHeight(screen));
    if (shortSide > 0.0) glassWidth = MIN(glassWidth, shortSide - margin * 2.0);
    if (tabs > 0 && tabs <= 4) {
        // Grow by the same amount as a full-width bar when pressed.
        CGFloat grow = expanded ? (21.0 - 14.0) * 2.0 : 0.0;
        glassWidth = MIN(glassWidth, 86.0 * (CGFloat)tabs + 16.0 + grow);
    }
    CGRect frame = CGRectMake((barWidth - glassWidth) * 0.5, glassTop, glassWidth, glassHeight);
    UIView *current = WolFoxSelectedPivotItem(receiver);
    BOOL darkBar = current != nil && [WolFoxPivotItemIdentifier(current) isEqualToString:@"FEshorts"];
    WolFoxMinimizeEnabled = WolFoxFeatureEnabled(WolFoxMinimizeKey);
    WolFoxMinimizeBar = receiver;
    BOOL minimized = WolFoxBarMinimized(receiver);
    if (minimized && (!WolFoxMinimizeEnabled || darkBar || current == nil)) {
        objc_setAssociatedObject(receiver, WolFoxPivotBarMinimizedAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        minimized = NO;
        WolFoxApplyMiniAlpha(receiver, NO);
        WolFoxRestoreMiniIcon(receiver);
        WolFoxRemoveMiniMask(receiver);
    }
    if (!WolFoxMinimizeEnabled || darkBar) {
        WolFoxMinimizeProgress = 0.0;
        WolFoxSetBarScale(receiver, 1.0, 0.0, 1.0);
    }
    CGRect fullFrame = frame;
    CGFloat circle = MIN(48.0, glassHeight);
    if (minimized) {
        frame = CGRectMake(28.0, CGRectGetMidY(frame) - circle * 0.5, circle, circle);
    }
    receiver.clipsToBounds = NO;
    receiver.layer.masksToBounds = NO;
    glass.frame = frame;
    glass.layer.cornerRadius = CGRectGetHeight(frame) * 0.5;
    WolFoxUpdateMiniMask(receiver, frame);
    WolFoxApplyShortsBackdrop(receiver, darkBar);
    UIUserInterfaceStyle style = darkBar ? UIUserInterfaceStyleDark : UIUserInterfaceStyleUnspecified;
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleUnspecified) {
        glass.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
    }
    if (!WolFoxStencilRendering && current != nil && receiver.overrideUserInterfaceStyle != style) {
        receiver.overrideUserInterfaceStyle = style;
        for (UIView *item in WolFoxSortedPivotItems(receiver)) WolFoxApplyPivotItemPresentation(item);
    }
    glass.alpha = 1.0;
    WolFoxLayoutItemsInGlass(receiver, fullFrame);
    UIImageView *miniIcon = objc_getAssociatedObject(receiver, WolFoxPivotBarMiniIconAssociation);
    if (miniIcon != nil && !miniIcon.hidden && current != nil) {
        miniIcon.center = minimized ? CGPointMake(CGRectGetWidth(frame) * 0.5, CGRectGetHeight(frame) * 0.5)
                                    : WolFoxMiniIconHome(receiver, glass, current);
    }
    if (!minimized) WolFoxUpdateGlassPill(receiver, glass);
    WolFoxInstallGlassSlide(receiver);
    return YES;
}

static IMP OriginalSearchOptOutFrostedPivot;

static BOOL WolFoxSearchOptOutFrostedPivot(__unused id receiver, __unused SEL selector) {
    return NO;
}

NSInteger WolFoxFrostedTabBarMode(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTKACE.Preference.Tabs.Frosted"];
    if ([stored respondsToSelector:@selector(integerValue)]) return MAX(0, MIN(2, [stored integerValue]));
    return WolFoxFeatureEnabled(@"YTKACE.Preference.Tabs.FrostedHidden") ? 2 : 0;
}

static IMP OriginalFrostedPermitted;

static BOOL WolFoxFrostedPermitted(id receiver, SEL selector) {
    NSInteger mode = WolFoxMasterEnabled() ? WolFoxFrostedTabBarMode() : 0;
    if (WolFoxLiquidGlassAvailable() && WolFoxTabBarOwnGlass()) return YES;
    if (mode == 1) return YES;
    if (mode == 2) return NO;
    return OriginalFrostedPermitted != NULL && ((BOOL (*)(id, SEL))OriginalFrostedPermitted)(receiver, selector);
}

static NSString *WolFoxColorText(UIColor *color) {
    if (color == nil) return @"nil";
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return @"?";
    return [NSString stringWithFormat:@"%.2f,%.2f,%.2f,%.2f", red, green, blue, alpha];
}

static NSString *WolFoxPivotItemColors(UIView *item) {
    if (item == nil) return @"-";
    UIImageView *icon = WolFoxFindImageView(item);
    UILabel *label = WolFoxFindNativeLabel(item);
    return [NSString stringWithFormat:@"%@ icon=%@ label=%@", WolFoxPivotItemIdentifier(item) ?: @"?",
            WolFoxColorText(icon.tintColor), WolFoxColorText(label.textColor)];
}

static void WolFoxLogPivotState(UIView *receiver) {
    if (receiver.window == nil || !WolFoxDebugLogsEnabled()) return;
    UIView *selected = WolFoxSelectedPivotItem(receiver);
    UIView *other = nil;
    for (UIView *item in WolFoxSortedPivotItems(receiver)) {
        if (item != selected && !item.hidden) {
            other = item;
            break;
        }
    }
    UIVisualEffectView *glass = objc_getAssociatedObject(receiver, WolFoxPivotBarGlassAssociation);
    NSString *selectedID = WolFoxPivotItemIdentifier(selected);
    NSString *state = [NSString stringWithFormat:
        @"tab=%@ shorts=%d glass=%d glassFrame=%@ minimized=%d alpha=%.2f hidden=%d bg=%@ style=%ld trait=%ld "
        @"backdrop=%@ pill=%@ selected[%@] other[%@]",
        selectedID ?: @"none", [selectedID isEqualToString:@"FEshorts"], glass.superview == receiver,
        glass.superview == receiver ? NSStringFromCGRect(glass.frame) : @"-", WolFoxBarMinimized(receiver),
        receiver.alpha, receiver.hidden, WolFoxColorText(receiver.backgroundColor),
        (long)receiver.overrideUserInterfaceStyle, (long)receiver.traitCollection.userInterfaceStyle,
        WolFoxColorText(receiver.superview.backgroundColor), WolFoxColorText(WolFoxPillColor()),
        WolFoxPivotItemColors(selected), WolFoxPivotItemColors(other)];
    static NSString *lastState;
    if ([state isEqualToString:lastState]) return;
    lastState = state;
    WolFoxDebugLog(@"tabbar", @"%@", state);
}

static void WolFoxApplyPivotBarBackgroundInner(UIView *receiver);

static void WolFoxApplyPivotBarBackground(UIView *receiver) {
    WolFoxApplyPivotBarBackgroundInner(receiver);
    WolFoxLogPivotState(receiver);
}

static void WolFoxApplyPivotBarBackgroundInner(UIView *receiver) {
    if (WolFoxRefreshTabTint()) {
        for (UIView *item in WolFoxSortedPivotItems(receiver)) {
            WolFoxRestyleSelectedTab(item);
            WolFoxApplyPivotItemPresentation(item);
        }
    }
    SEL blurSelector = NSSelectorFromString(@"blurView");
    UIView *blur = [receiver respondsToSelector:blurSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, blurSelector)
        : nil;
    if (WolFoxApplyPivotBarGlass(receiver, blur)) return;
    BOOL applied = [objc_getAssociatedObject(
        receiver, WolFoxPivotBarSolidAssociation) boolValue];
    if (!WolFoxMasterEnabled() || WolFoxFrostedTabBarMode() != 2) {
        if (!applied) return;
        blur.hidden = NO;
        receiver.backgroundColor = UIColor.clearColor;
        receiver.opaque = NO;
        objc_setAssociatedObject(receiver, WolFoxPivotBarSolidAssociation,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    UIUserInterfaceStyle style = receiver.traitCollection.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified) {
        style = receiver.window.traitCollection.userInterfaceStyle;
    }
    UIColor *solid = style == UIUserInterfaceStyleDark
        ? UIColor.blackColor
        : UIColor.whiteColor;
    blur.hidden = YES;
    for (UIView *sibling in receiver.subviews) {
        if (sibling != blur && [sibling isKindOfClass:UIVisualEffectView.class]) {
            sibling.hidden = YES;
        }
    }
    receiver.backgroundColor = solid;
    receiver.opaque = YES;
    objc_setAssociatedObject(receiver, WolFoxPivotBarSolidAssociation,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WolFoxRefreshPivotBarsInView(UIView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"YTPivotBarView"]) {
        WolFoxApplyPivotBarBackground(view);
        return;
    }
    for (UIView *subview in view.subviews) {
        WolFoxRefreshPivotBarsInView(subview);
    }
}

void WolFoxRefreshPivotBarBackground(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden) WolFoxRefreshPivotBarsInView(window);
        }
    }
}

static void WolFoxPivotBarStyleColors(UIView *receiver, SEL selector) {
    if (OriginalPivotBarStyleColors != NULL) {
        ((void (*)(id, SEL))OriginalPivotBarStyleColors)(receiver, selector);
    }
    WolFoxApplyPivotBarBackground(receiver);
}

static void WolFoxPivotBarSetBackgroundStyle(UIView *receiver, SEL selector,
                                             int style) {
    if (OriginalPivotBarSetBackgroundStyle != NULL) {
        ((void (*)(id, SEL, int))OriginalPivotBarSetBackgroundStyle)(
            receiver, selector, style);
    }
    WolFoxApplyPivotBarBackground(receiver);
}

static NSString *WolFoxStartupTabToken(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id stored = [defaults objectForKey:@"YTKACE.Preference.Tabs.Startup"];
    if ([stored isKindOfClass:NSString.class]) return stored;
    NSArray<NSString *> *legacy = @[@"", @"explore", @"subscriptions",
                                    @"shorts", @"library"];
    NSInteger index = [stored respondsToSelector:@selector(integerValue)]
        ? [stored integerValue] : 0;
    NSString *token = (index > 0 && index < (NSInteger)legacy.count)
        ? legacy[(NSUInteger)index] : @"";
    [defaults setObject:token forKey:@"YTKACE.Preference.Tabs.Startup"];
    return token;
}

static NSString *WolFoxStartupPivotIdentifier(NSString *token) {
    if (token.length == 0) return nil;
    NSDictionary<NSString *, NSString *> *known = @{
        @"home": @"FEwhat_to_watch",
        @"explore": @"FEexplore",
        @"subscriptions": @"FEsubscriptions",
        @"shorts": @"FEshorts",
        @"library": @"FElibrary",
        @"you": @"FElibrary"
    };
    NSString *identifier = known[token];
    if (identifier.length != 0) return identifier;
    return WolFoxStartupIdentifiers[token];
}

static NSString *WolFoxWantedStartupPivot(void) {
    NSString *identifier = WolFoxStartupPivotIdentifier(WolFoxStartupTabToken());
    if (identifier.length != 0) return identifier;
    if (WolFoxMasterEnabled() &&
        [NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.Tabs.Hidden.Home"] &&
        WolFoxFirstVisiblePivot.length != 0 && ![WolFoxFirstVisiblePivot isEqualToString:@"FEwhat_to_watch"]) {
        return WolFoxFirstVisiblePivot;
    }
    return nil;
}

static __weak id WolFoxPivotBarControllerRef;

static id WolFoxPivotControllerForView(UIView *view) {
    if (WolFoxPivotBarControllerRef != nil) return WolFoxPivotBarControllerRef;
    SEL lookup = NSSelectorFromString(@"pivotBarItemForIdentifier:");
    UIResponder *responder = view;
    while (responder != nil) {
        if ([responder respondsToSelector:lookup]) {
            WolFoxPivotBarControllerRef = responder;
            return responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static BOOL WolFoxNavigateToPivot(id controller, NSString *identifier) {
    if (controller == nil || identifier.length == 0) return NO;
    SEL lookup = NSSelectorFromString(@"pivotBarItemForIdentifier:");
    SEL tap = NSSelectorFromString(@"didTapItemWithRenderer:");
    if (![controller respondsToSelector:lookup] ||
        ![controller respondsToSelector:tap]) {
        return NO;
    }
    id item = ((id (*)(id, SEL, id))objc_msgSend)(controller, lookup, identifier);
    if (item == nil) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(controller, tap, item);
    return YES;
}

static BOOL WolFoxStartupNavigated;

static void WolFoxApplyStartupTab(UIView *receiver) {
    if (WolFoxStartupApplied) return;
    NSString *identifier = WolFoxWantedStartupPivot();
    if (identifier.length == 0) {
        if (WolFoxFirstVisiblePivot.length != 0) WolFoxStartupApplied = YES;
        return;
    }
    static NSTimeInterval firstSeen = 0.0;
    const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (firstSeen == 0.0) firstSeen = now;
    if (now - firstSeen > 8.0) {
        WolFoxStartupApplied = YES;
        return;
    }

    id controller = WolFoxPivotControllerForView(receiver);

    id target = controller ?: receiver;
    SEL current = NSSelectorFromString(@"selectedPivotIdentifier");
    if ([target respondsToSelector:current]) {
        id selected = ((id (*)(id, SEL))objc_msgSend)(target, current);
        // Already switched to it by tapping it below: done. Running the Home
        // workaround after a real switch breaks tab switching for good.
        if (WolFoxStartupNavigated && [selected isKindOfClass:NSString.class] &&
            [selected caseInsensitiveCompare:identifier] == NSOrderedSame) {
            WolFoxStartupApplied = YES;
            return;
        }
        // Home hidden: YouTube files its launch Home page under whichever tab
        // it starts on. Point it at Home first, then switch, so that tab gets
        // its own page. Only before our first switch.
        if ([selected isKindOfClass:NSString.class] && !WolFoxStartupNavigated &&
            [NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.Tabs.Hidden.Home"]) {
            SEL selectItem = NSSelectorFromString(@"selectItemWithPivotIdentifier:");
            SEL setSelected = NSSelectorFromString(@"setSelectedPivotIdentifier:");
            if ([controller respondsToSelector:selectItem])
                ((void (*)(id, SEL, id))objc_msgSend)(controller, selectItem, @"FEwhat_to_watch");
            if ([controller respondsToSelector:setSelected])
                ((void (*)(id, SEL, id))objc_msgSend)(controller, setSelected, @"FEwhat_to_watch");
            @try {
                [controller setValue:@"FEwhat_to_watch" forKey:@"_pivotIdentifier"];
            } @catch (__unused NSException *exception) {
            }
            WolFoxStartupNavigated = WolFoxNavigateToPivot(controller, identifier);
            if ([selected caseInsensitiveCompare:identifier] == NSOrderedSame || !WolFoxStartupNavigated) {
                WolFoxStartupApplied = YES;
            }
            return;
        }
        if ([selected isKindOfClass:NSString.class] &&
            [selected caseInsensitiveCompare:identifier] == NSOrderedSame) {
            WolFoxStartupApplied = YES;
            return;
        }
    }

    if (WolFoxNavigateToPivot(controller, identifier)) {
        WolFoxStartupNavigated = YES;
        return;
    }

    SEL select = NSSelectorFromString(@"selectItemWithPivotIdentifier:");
    if ([target respondsToSelector:select]) {
        ((void (*)(id, SEL, id))objc_msgSend)(target, select, identifier);
    }
}

static void WolFoxSetDefaultSelectedPivot(id receiver, SEL selector, id identifier) {
    NSString *wanted = WolFoxStartupPivotIdentifier(WolFoxStartupTabToken());
    if (wanted.length != 0 && !WolFoxStartupApplied) {
        WolFoxStartupNative = YES;
        identifier = wanted;
    }
    if (OriginalSetDefaultSelectedPivot != NULL) {
        ((void (*)(id, SEL, id))OriginalSetDefaultSelectedPivot)(receiver, selector,
                                                                identifier);
    }
}

static void WolFoxScheduleStartupTab(id controller) {
    if (WolFoxStartupApplied) return;
    if (WolFoxWantedStartupPivot().length == 0 && WolFoxFirstVisiblePivot.length != 0) {
        WolFoxStartupApplied = YES;
        return;
    }
    static BOOL scheduled = NO;
    if (scheduled) return;
    scheduled = YES;
    const double delay = WolFoxStartupNative ? 0.0 : 0.35;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        scheduled = NO;
        SEL pivotView = NSSelectorFromString(@"pivotBarView");
        UIView *view = [controller respondsToSelector:pivotView]
            ? ((id (*)(id, SEL))objc_msgSend)(controller, pivotView)
            : nil;
        WolFoxApplyStartupTab(view);
        if (!WolFoxStartupApplied) WolFoxScheduleStartupTab(controller);
    });
}

static void WolFoxPivotControllerAppear(id receiver, SEL selector, BOOL animated) {
    if (OriginalPivotControllerAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPivotControllerAppear)(receiver, selector,
                                                                animated);
    }
    WolFoxPivotBarControllerRef = receiver;
    WolFoxScheduleStartupTab(receiver);
}

static void WolFoxPivotBarLayout(UIView *receiver, SEL selector) {
    if (OriginalPivotBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalPivotBarLayout)(receiver, selector);
    }
    WolFoxHideCreateViews(receiver);
    WolFoxApplyPivotBarBackground(receiver);
}

static void WolFoxPivotItemLayout(UIView *receiver, SEL selector) {
    if (OriginalPivotItemLayout != NULL) {
        ((void (*)(id, SEL))OriginalPivotItemLayout)(receiver, selector);
    }
    WolFoxApplyPivotItemPresentation(receiver);
}

void WolFoxDuoTabsSelectionChanged(UIView *item);

static void WolFoxPivotItemSetSelected(UIView *receiver,
                                       SEL selector,
                                       BOOL selected) {
    BOOL wasSelected = [objc_getAssociatedObject(receiver, WolFoxTabSelectedAssociation) boolValue];
    if (OriginalPivotItemSetSelected != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPivotItemSetSelected)(
            receiver, selector, selected
        );
    }
    objc_setAssociatedObject(receiver,
                             WolFoxTabSelectedAssociation,
                             @(selected),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WolFoxApplyPivotItemPresentation(receiver);
    WolFoxDuoTabsSelectionChanged(receiver);
    if (WolFoxStencilRendering) return;
    if (selected) {
        UIView *bar = receiver.superview;
        while (bar != nil && ![NSStringFromClass(bar.class) isEqualToString:@"YTPivotBarView"]) {
            bar = bar.superview;
        }
        if (!wasSelected) WolFoxSetBarMinimized(bar, NO);
        [bar setNeedsLayout];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        WolFoxApplyPivotItemPresentation(receiver);
    });
}

static void WolFoxPivotItemTraitChanged(UIView *receiver,
                                        SEL selector,
                                        UITraitCollection *previous) {
    if (OriginalPivotItemTraitChanged != NULL) {
        ((void (*)(id, SEL, id))OriginalPivotItemTraitChanged)(
            receiver, selector, previous
        );
    }
    WolFoxApplyPivotItemPresentation(receiver);
    dispatch_async(dispatch_get_main_queue(), ^{
        WolFoxApplyPivotItemPresentation(receiver);
    });
    if (WolFoxFeatureEnabled(WolFoxOLEDKey) &&
        !WolFoxNavigationRefreshScheduled) {
        WolFoxNavigationRefreshScheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            WolFoxNavigationRefreshScheduled = NO;
            WolFoxRefreshNavigationAppearance();
        });
    }
}

// The glass sits above YouTube's bottom strip (incognito, offline, sleep
// timer), so lay it out again when the strip comes or goes, or the bar moves.
static IMP OriginalSlimStatusLayout;
static IMP OriginalSlimStatusMoveToWindow;
static IMP OriginalPivotSetFrame;
static IMP OriginalPivotSetCenter;

static void WolFoxRelayoutPivotBesideStrip(UIView *strip) {
    Class bar = NSClassFromString(@"YTPivotBarView");
    for (UIView *sibling in strip.superview.subviews) {
        if (bar != Nil && [sibling isKindOfClass:bar]) [sibling setNeedsLayout];
    }
}

static BOOL WolFoxHasStripBeside(UIView *bar) {
    for (UIView *sibling in bar.superview.subviews) {
        if ([NSStringFromClass(sibling.class) isEqualToString:@"YTSlimStatusBarView"]) return YES;
    }
    return NO;
}

static void WolFoxSlimStatusLayout(UIView *receiver, SEL selector) {
    if (OriginalSlimStatusLayout != NULL) ((void (*)(id, SEL))OriginalSlimStatusLayout)(receiver, selector);
    WolFoxRelayoutPivotBesideStrip(receiver);
}

static void WolFoxSlimStatusMoveToWindow(UIView *receiver, SEL selector) {
    if (OriginalSlimStatusMoveToWindow != NULL) ((void (*)(id, SEL))OriginalSlimStatusMoveToWindow)(receiver, selector);
    WolFoxRelayoutPivotBesideStrip(receiver);
}

static void WolFoxPivotSetFrame(UIView *receiver, SEL selector, CGRect frame) {
    BOOL moved = !CGRectEqualToRect(receiver.frame, frame);
    ((void (*)(id, SEL, CGRect))OriginalPivotSetFrame)(receiver, selector, frame);
    if (moved && WolFoxHasStripBeside(receiver)) [receiver setNeedsLayout];
}

static void WolFoxPivotSetCenter(UIView *receiver, SEL selector, CGPoint center) {
    BOOL moved = !CGPointEqualToPoint(receiver.center, center);
    ((void (*)(id, SEL, CGPoint))OriginalPivotSetCenter)(receiver, selector, center);
    if (moved && WolFoxHasStripBeside(receiver)) [receiver setNeedsLayout];
}

void WolFoxInstallTabBarHooks(void) {
    WolFoxInstallInstanceHook(@"YTSlimStatusBarView", @"layoutSubviews",
                              (IMP)WolFoxSlimStatusLayout, &OriginalSlimStatusLayout);
    WolFoxInstallInstanceHook(@"YTSlimStatusBarView", @"didMoveToWindow",
                              (IMP)WolFoxSlimStatusMoveToWindow, &OriginalSlimStatusMoveToWindow);
    WolFoxInstallInstanceHook(@"YTPivotBarView", @"setFrame:",
                              (IMP)WolFoxPivotSetFrame, &OriginalPivotSetFrame);
    WolFoxInstallInstanceHook(@"YTPivotBarView", @"setCenter:",
                              (IMP)WolFoxPivotSetCenter, &OriginalPivotSetCenter);
    WolFoxRefreshTabTint();
    WolFoxInstallClassHook(@"YTFloatingBarExperiment",
                           @"isIconsOnly",
                           (IMP)WolFoxIsIconsOnly,
                           &OriginalIsIconsOnly);
    WolFoxInstallInstanceHook(@"YTPivotBarItemView",
                              @"iconTintColorSelected",
                              (IMP)WolFoxIconTintSelected,
                              &OriginalIconTintSelected);
    WolFoxInstallInstanceHook(@"UILabel",
                              @"setTextColor:",
                              (IMP)WolFoxPivotLabelSetTextColor,
                              &OriginalPivotLabelSetTextColor);
    WolFoxInstallInstanceHook(@"UILabel",
                              @"setHidden:",
                              (IMP)WolFoxPivotLabelSetHidden,
                              &OriginalPivotLabelSetHidden);
    WolFoxInstallInstanceHook(@"UILabel",
                              @"setAlpha:",
                              (IMP)WolFoxPivotLabelSetAlpha,
                              &OriginalPivotLabelSetAlpha);
    WolFoxInstallInstanceHook(@"YTQTMButton",
                              @"layoutSubviews",
                              (IMP)WolFoxPivotButtonLayout,
                              &OriginalPivotButtonLayout);
    WolFoxInstallInstanceHook(@"YTPivotBarView",
                              @"setRenderer:",
                              (IMP)WolFoxSetPivotRenderer,
                              &OriginalSetPivotRenderer);
    Method floatingSetter = class_getInstanceMethod(NSClassFromString(@"YTFloatingPivotBarView"),
                                                    @selector(setRenderer:));
    const char *floatingTypes = floatingSetter != NULL ? method_getTypeEncoding(floatingSetter) : NULL;
    BOOL floatingHooked = floatingTypes != NULL && strncmp(floatingTypes, "v24@0:8@16", 10) == 0 &&
        WolFoxInstallInstanceHook(@"YTFloatingPivotBarView", @"setRenderer:",
                                  (IMP)WolFoxSetPivotRenderer, &OriginalSetFloatingPivotRenderer);
    WolFoxDownloadLog(@"tabbar", @"floating bar hook=%d types=%s", floatingHooked, floatingTypes ?: "-");
    WolFoxInstallInstanceHook(@"YTPivotBarItemView",
                              @"layoutSubviews",
                              (IMP)WolFoxPivotItemLayout,
                              &OriginalPivotItemLayout);
    WolFoxInstallInstanceHook(@"YTPivotBarItemView",
                              @"setSelected:",
                              (IMP)WolFoxPivotItemSetSelected,
                              &OriginalPivotItemSetSelected);
    WolFoxInstallInstanceHook(@"YTPivotBarItemView",
                              @"traitCollectionDidChange:",
                              (IMP)WolFoxPivotItemTraitChanged,
                              &OriginalPivotItemTraitChanged);
    WolFoxInstallInstanceHook(@"YTPivotBarView",
                              @"layoutSubviews",
                              (IMP)WolFoxPivotBarLayout,
                              &OriginalPivotBarLayout);
    WolFoxInstallInstanceHook(@"YTPivotBarView",
                              @"pointInside:withEvent:",
                              (IMP)WolFoxPivotBarPointInside,
                              &OriginalPivotBarPointInside);
    if (WolFoxTabBarOwnGlass() && WolFoxLiquidGlassAvailable()) {
        WolFoxInstallInstanceHook(@"UIScrollView",
                                  @"setContentOffset:",
                                  (IMP)WolFoxScrollSetContentOffset,
                                  &OriginalScrollSetContentOffset);
        WolFoxInstallInstanceHook(@"YTScrollableNavigationController",
                                  @"hidePivotBarOnScroll",
                                  (IMP)WolFoxHidePivotBarOnScroll,
                                  &OriginalHidePivotBarOnScroll);
        WolFoxInstallInstanceHook(@"YTScrollableNavigationController",
                                  @"updatePivotBarVisibilityForScrollView:contentOffsetY:isAtBottom:",
                                  (IMP)WolFoxUpdatePivotBarVisibility,
                                  &OriginalUpdatePivotBarVisibility);
        WolFoxInstallInstanceHook(@"YTSearchResultsViewController",
                                  @"optOutOfFrostedPivotBar",
                                  (IMP)WolFoxSearchOptOutFrostedPivot,
                                  &OriginalSearchOptOutFrostedPivot);
    }
    WolFoxInstallInstanceHook(@"YTPivotBarViewController",
                              @"isFrostedPivotBarPermitted",
                              (IMP)WolFoxFrostedPermitted,
                              &OriginalFrostedPermitted);
    WolFoxInstallInstanceHook(@"YTPivotBarView",
                              @"hitTest:withEvent:",
                              (IMP)WolFoxPivotBarHitTest,
                              &OriginalPivotBarHitTest);
    WolFoxInstallInstanceHook(@"YTPivotBarViewController",
                              @"viewDidAppear:",
                              (IMP)WolFoxPivotControllerAppear,
                              &OriginalPivotControllerAppear);
    WolFoxInstallInstanceHook(@"YTAppPivotBarController",
                              @"setDefaultSelectedPivotIdentifier:",
                              (IMP)WolFoxSetDefaultSelectedPivot,
                              &OriginalSetDefaultSelectedPivot);
    WolFoxInstallInstanceHook(@"YTPivotBarView",
                              @"styleBackgroundColors",
                              (IMP)WolFoxPivotBarStyleColors,
                              &OriginalPivotBarStyleColors);
    WolFoxInstallInstanceHook(@"YTPivotBarView",
                              @"setBackgroundStyle:",
                              (IMP)WolFoxPivotBarSetBackgroundStyle,
                              &OriginalPivotBarSetBackgroundStyle);
    WolFoxInstallInstanceHook(@"YTAppViewController",
                              @"viewDidLoad",
                              (IMP)WolFoxAppViewDidLoad,
                              &OriginalAppViewDidLoad);
    WolFoxInstallInstanceHook(@"YTBrowseViewController",
                              @"viewDidLoad",
                              (IMP)WolFoxBrowseViewDidLoad,
                              &OriginalBrowseViewDidLoad);
    WolFoxInstallInstanceHook(@"YTBrowseResponseViewController",
                              @"viewDidLoad",
                              (IMP)WolFoxBrowseResponseViewDidLoad,
                              &OriginalBrowseResponseViewDidLoad);
    WolFoxInstallInstanceHook(@"YTWrapperFlatViewController",
                              @"viewDidLoad",
                              (IMP)WolFoxWrapperViewDidLoad,
                              &OriginalWrapperViewDidLoad);
}

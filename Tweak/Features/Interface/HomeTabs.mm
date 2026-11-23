#import "../Downloads/DownloadLog.h"
#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalBrowseLoadResponse;
static IMP OriginalBrowseLoadInitialResponse;

static BOOL WolFoxHomeBool(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSInteger WolFoxHomeInt(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? (NSInteger)((int (*)(id, SEL))objc_msgSend)(object, selector) : -1;
}

static id WolFoxHomeObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static void WolFoxHomeSetBool(id object, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if ([object respondsToSelector:selector]) ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}

static IMP OriginalFoxScrollableTabs;
static IMP OriginalFoxCollapsingTabs;
static IMP OriginalFoxIosCollapsingTabs;

static BOOL WolFoxFoxTabsSeen;

// Home and Subscriptions tabs at the top of Home, which sit where the filter
// chips used to be.
BOOL WolFoxHomeTabsLayoutActive(void) {
    return WolFoxFoxTabsSeen && !WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.HomeTabsHidden");
}

static BOOL WolFoxFoxFlag(IMP original, id receiver, SEL selector) {
    BOOL value = original != NULL && ((BOOL (*)(id, SEL))original)(receiver, selector);
    if (value) WolFoxFoxTabsSeen = YES;
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.HomeTabsHidden")) return NO;
    return value;
}

static BOOL WolFoxFoxScrollableTabs(id receiver, SEL selector) {
    return WolFoxFoxFlag(OriginalFoxScrollableTabs, receiver, selector);
}

static BOOL WolFoxFoxCollapsingTabs(id receiver, SEL selector) {
    return WolFoxFoxFlag(OriginalFoxCollapsingTabs, receiver, selector);
}

static BOOL WolFoxFoxIosCollapsingTabs(id receiver, SEL selector) {
    return WolFoxFoxFlag(OriginalFoxIosCollapsingTabs, receiver, selector);
}

static NSString *WolFoxHomeTabBrowseID(id tab) {
    id renderer = WolFoxHomeObject(tab, @"tabRenderer");
    id endpoint = WolFoxHomeObject(WolFoxHomeObject(renderer, @"endpoint"), @"browseEndpoint");
    id browseID = WolFoxHomeObject(endpoint, @"browseId");
    return [browseID isKindOfClass:NSString.class] ? browseID : nil;
}

static id WolFoxHomeNew(NSString *name) {
    Class cls = NSClassFromString(name);
    return cls != Nil ? [cls new] : nil;
}

static void WolFoxHomeSet(id object, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    if (object != nil && value != nil && [object respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
    }
}

static id WolFoxHomeExtension(NSString *className, NSInteger field) {
    static NSMutableDictionary *cache;
    NSString *key = [NSString stringWithFormat:@"%@|%ld", className, (long)field];
    if (cache[key] != nil) return cache[key] == NSNull.null ? nil : cache[key];
    if (cache == nil) cache = [NSMutableDictionary dictionary];
    id result = nil;
    Class registryClass = NSClassFromString(@"GoogleGlobalExtensionRegistry");
    Class target = NSClassFromString(className);
    SEL registrySel = NSSelectorFromString(@"extensionRegistry");
    SEL lookup = NSSelectorFromString(@"extensionForDescriptor:fieldNumber:");
    if (registryClass != Nil && target != Nil && [registryClass respondsToSelector:registrySel] &&
        [target respondsToSelector:@selector(descriptor)]) {
        id registry = ((id (*)(id, SEL))objc_msgSend)(registryClass, registrySel);
        id descriptor = ((id (*)(id, SEL))objc_msgSend)(target, @selector(descriptor));
        if ([registry respondsToSelector:lookup]) {
            result = ((id (*)(id, SEL, id, NSInteger))objc_msgSend)(registry, lookup, descriptor, field);
        }
    }
    cache[key] = result ?: NSNull.null;
    return result;
}

static id WolFoxHomeWrap(NSString *className, NSInteger field, id value) {
    id extension = WolFoxHomeExtension(className, field);
    id wrapper = WolFoxHomeNew(className);
    SEL setter = NSSelectorFromString(@"setExtension:value:");
    if (extension == nil || wrapper == nil || value == nil || ![wrapper respondsToSelector:setter]) return nil;
    ((void (*)(id, SEL, id, id))objc_msgSend)(wrapper, setter, extension, value);
    return wrapper;
}

static id WolFoxHomeReloadData(id tab) {
    id list = WolFoxHomeObject(WolFoxHomeObject(WolFoxHomeObject(tab, @"tabRenderer"), @"content"), @"sectionListRenderer");
    for (id continuation in WolFoxHomeObject(list, @"continuationsArray")) {
        id data = WolFoxHomeObject(continuation, @"reloadContinuationData");
        if ([WolFoxHomeObject(data, @"continuation") length] != 0) return data;
    }
    return nil;
}

static id WolFoxHomeReloadCommand(id data) {
    id endpoint = WolFoxHomeNew(@"YTIBrowseSectionListReloadEndpoint");
    id continuations = WolFoxHomeNew(@"YTIBrowseSectionListReloadSupportedContinuations");
    if (data == nil || endpoint == nil || continuations == nil) return nil;
    WolFoxHomeSet(continuations, @"setReloadContinuationData:", data);
    WolFoxHomeSet(endpoint, @"setContinuation:", continuations);
    return WolFoxHomeWrap(@"YTICommand", 120837120, endpoint);
}

static id WolFoxHomeChip(NSString *title, NSInteger icon, id command, BOOL selected) {
    id chip = WolFoxHomeNew(@"YTIChipCloudChipRenderer");
    if (chip == nil) return nil;
    id style = WolFoxHomeNew(@"YTIChipCloudChipStyle");
    id styleDescriptor = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"YTIChipCloudChipStyle"), @selector(descriptor));
    id field = ((id (*)(id, SEL, id))objc_msgSend)(styleDescriptor, NSSelectorFromString(@"fieldWithName:"), @"styleType");
    id enumDescriptor = WolFoxHomeObject(field, @"enumDescriptor");
    int32_t value = 0;
    SEL lookup = NSSelectorFromString(@"getValue:forEnumTextFormatName:");
    if ([enumDescriptor respondsToSelector:lookup] &&
        ((BOOL (*)(id, SEL, int32_t *, id))objc_msgSend)(enumDescriptor, lookup, &value, @"STYLE_HOME_FILTER")) {
        ((void (*)(id, SEL, int))objc_msgSend)(style, NSSelectorFromString(@"setStyleType:"), value);
        WolFoxHomeSet(chip, @"setStyle:", style);
    }
    if (title.length != 0) {
        Class formatted = NSClassFromString(@"YTIFormattedString");
        SEL make = NSSelectorFromString(@"formattedStringWithString:");
        if ([formatted respondsToSelector:make]) {
            WolFoxHomeSet(chip, @"setText:", ((id (*)(id, SEL, id))objc_msgSend)(formatted, make, title));
        }
    }
    if (icon > 0) {
        id image = WolFoxHomeNew(@"YTIIcon");
        ((void (*)(id, SEL, int))objc_msgSend)(image, NSSelectorFromString(@"setIconType:"), (int)icon);
        WolFoxHomeSet(chip, @"setIcon:", image);
    }
    WolFoxHomeSet(chip, @"setNavigationEndpoint:", command);
    WolFoxHomeSetBool(chip, @"setIsSelected:", selected);
    return WolFoxHomeWrap(@"YTIRenderer", 91394224, chip);
}

static void WolFoxHomeBuildChips(NSArray *tabs, id home) {
    id list = WolFoxHomeObject(WolFoxHomeObject(WolFoxHomeObject(home, @"tabRenderer"), @"content"), @"sectionListRenderer");
    if (list == nil) return;
    id header = WolFoxHomeObject(list, @"header");
    if (WolFoxHomeBool(list, @"hasHeader") && WolFoxHomeBool(header, @"hasFeedFilterChipBarRenderer")) return;
    id bar = WolFoxHomeNew(@"YTIFeedFilterChipBarRenderer");
    NSMutableArray *contents = WolFoxHomeObject(bar, @"contentsArray");
    if (![contents isKindOfClass:NSMutableArray.class]) return;
    id homeReload = nil;
    for (id continuation in WolFoxHomeObject(list, @"continuationsArray")) {
        id data = WolFoxHomeObject(continuation, @"reloadContinuationData");
        if ([WolFoxHomeObject(data, @"continuation") length] != 0) homeReload = data;
    }
    for (id tab in tabs) {
        if (tab == home) continue;
        id renderer = WolFoxHomeObject(tab, @"tabRenderer");
        if (!WolFoxHomeBool(renderer, @"unselectable")) continue;
        id command = WolFoxHomeObject(renderer, @"endpoint");
        NSInteger icon = WolFoxHomeInt(renderer, @"tabIcon");
        if (command == nil || icon <= 0) continue;
        id chip = WolFoxHomeChip(nil, icon, command, NO);
        if (chip != nil) [contents addObject:chip];
        Class dividerClass = WolFoxHomeObject(WolFoxHomeExtension(@"YTIRenderer", 325920579), @"msgClass");
        id divider = dividerClass != Nil ? WolFoxHomeWrap(@"YTIRenderer", 325920579, [dividerClass new]) : nil;
        if (divider != nil) [contents addObject:divider];
    }
    NSString *homeTitle = WolFoxHomeObject(WolFoxHomeObject(home, @"tabRenderer"), @"title");
    id all = WolFoxHomeChip(homeTitle.length != 0 ? homeTitle : @"All", 0, WolFoxHomeReloadCommand(homeReload), YES);
    if (all != nil) [contents addObject:all];
    for (id tab in tabs) {
        if (tab == home) continue;
        id renderer = WolFoxHomeObject(tab, @"tabRenderer");
        NSString *title = WolFoxHomeObject(renderer, @"title");
        if (title.length == 0 || WolFoxHomeBool(renderer, @"unselectable")) continue;
        id command = WolFoxHomeReloadCommand(WolFoxHomeReloadData(tab)) ?: WolFoxHomeObject(renderer, @"endpoint");
        id chip = WolFoxHomeChip(title, 0, command, NO);
        if (chip != nil) [contents addObject:chip];
    }
    WolFoxDownloadLog(@"home", @"redesign chips=%lu", (unsigned long)contents.count);
    if (contents.count < 2) return;
    WolFoxHomeSet(bar, @"setOnFiltersCleared:", WolFoxHomeReloadCommand(homeReload));
    id newHeader = header ?: WolFoxHomeNew(@"YTISectionListHeaderSupportedRenderers");
    WolFoxHomeSet(newHeader, @"setFeedFilterChipBarRenderer:", bar);
    WolFoxHomeSet(list, @"setHeader:", newHeader);
}

// Notes when Home comes with its Home and Subscriptions tabs. YouTube can turn
// that layout on from the server without the flags above.
static void WolFoxNoteHomeTabs(id single) {
    NSArray *tabs = WolFoxHomeObject(single, @"tabsArray");
    if (![tabs isKindOfClass:NSArray.class] || tabs.count < 2) return;
    for (id tab in tabs) {
        NSString *browseID = WolFoxHomeTabBrowseID(tab);
        if ([browseID isEqualToString:@"FEwhat_to_watch"] ||
            [browseID isEqualToString:@"FEsubscriptions"]) {
            if (!WolFoxFoxTabsSeen) WolFoxDebugLog(@"topics", @"home tabs layout seen");
            WolFoxFoxTabsSeen = YES;
            return;
        }
    }
}

static void WolFoxTrimHomeTabsInRenderer(id single) {
    WolFoxNoteHomeTabs(single);
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.HomeTabsHidden")) return;
    NSMutableArray *tabs = WolFoxHomeObject(single, @"tabsArray");
    if (![tabs isKindOfClass:NSMutableArray.class] || tabs.count < 2) return;
    id home = nil;
    BOOL subscriptions = NO;
    for (id tab in tabs) {
        NSString *browseID = WolFoxHomeTabBrowseID(tab);
        if (home == nil && [browseID isEqualToString:@"FEwhat_to_watch"]) home = tab;
        if ([browseID isEqualToString:@"FEsubscriptions"]) subscriptions = YES;
    }
    if (home == nil && subscriptions) home = tabs.firstObject;
    if (home == nil) return;
    WolFoxHomeBuildChips([tabs copy], home);
    [tabs setArray:@[home]];
    WolFoxHomeSetBool(single, @"setHideTabBar:", YES);
    WolFoxHomeSetBool(single, @"setDisableTabSwiping:", YES);
    WolFoxHomeSetBool(WolFoxHomeObject(home, @"tabRenderer"), @"setHasPresentationStyle:", NO);
}

static void WolFoxTrimHomeTabs(id response) {
    WolFoxTrimHomeTabsInRenderer(WolFoxHomeObject(WolFoxHomeObject(response, @"contents"),
                                                  @"singleColumnBrowseResultsRenderer"));
}

static IMP OriginalTabsLoadModel;
static IMP OriginalTabsLoadModelReload;
static IMP OriginalTabsUpdateModel;

static void WolFoxTabsLoadModel(id receiver, SEL selector, id model) {
    WolFoxTrimHomeTabsInRenderer(model);
    ((void (*)(id, SEL, id))OriginalTabsLoadModel)(receiver, selector, model);
}

static void WolFoxTabsLoadModelReload(id receiver, SEL selector, id model, BOOL reload) {
    WolFoxTrimHomeTabsInRenderer(model);
    ((void (*)(id, SEL, id, BOOL))OriginalTabsLoadModelReload)(receiver, selector, model, reload);
}

static void WolFoxTabsUpdateModel(id receiver, SEL selector, id model, BOOL isDefault, BOOL reload) {
    WolFoxTrimHomeTabsInRenderer(model);
    ((void (*)(id, SEL, id, BOOL, BOOL))OriginalTabsUpdateModel)(receiver, selector, model, isDefault, reload);
}

static void WolFoxBrowseLoadResponse(id receiver, SEL selector, id response) {
    WolFoxTrimHomeTabs(response);
    ((void (*)(id, SEL, id))OriginalBrowseLoadResponse)(receiver, selector, response);
}

static void WolFoxBrowseLoadInitialResponse(id receiver, SEL selector, id response) {
    WolFoxTrimHomeTabs(response);
    ((void (*)(id, SEL, id))OriginalBrowseLoadInitialResponse)(receiver, selector, response);
}

// Report an older app version on Home requests so the server sends the
// layout from before the redesign.
static NSString * const WolFoxHomeSpoofVersion = @"21.33.6";
static IMP OriginalBrowseRequestWrite;
static IMP OriginalBrowseRequestSize;

static BOOL WolFoxIsHomeContinuation(NSString *token) {
    if (![token isKindOfClass:NSString.class] || token.length == 0) return NO;
    NSString *base64 = [[token stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
        stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    base64 = [base64 stringByRemovingPercentEncoding] ?: base64;
    while (base64.length % 4 != 0) base64 = [base64 stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64
                                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSData *needle = [@"FEwhat_to_watch" dataUsingEncoding:NSUTF8StringEncoding];
    return data.length != 0 && [data rangeOfData:needle options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}

static void WolFoxSpoofHomeRequest(id request) {
    id browseID = WolFoxHomeObject(request, @"browseId");
    BOOL home = [browseID isKindOfClass:NSString.class] && [browseID isEqualToString:@"FEwhat_to_watch"];
    if (!home && WolFoxIsHomeContinuation(WolFoxHomeObject(request, @"continuation"))) home = YES;
    if (!home) return;
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.HomeTabsHidden")) return;
    id context = WolFoxHomeObject(request, @"context");
    NSString *version = WolFoxHomeObject(WolFoxHomeObject(context, @"client"), @"clientVersion");
    if (context == nil || [version isEqualToString:WolFoxHomeSpoofVersion]) return;
    id copy = [context copy];
    WolFoxHomeSet(WolFoxHomeObject(copy, @"client"), @"setClientVersion:", WolFoxHomeSpoofVersion);
    WolFoxHomeSet(request, @"setContext:", copy);
}

static size_t WolFoxBrowseRequestSize(id receiver, SEL selector) {
    WolFoxSpoofHomeRequest(receiver);
    return ((size_t (*)(id, SEL))OriginalBrowseRequestSize)(receiver, selector);
}

static void WolFoxBrowseRequestWrite(id receiver, SEL selector, id stream) {
    WolFoxSpoofHomeRequest(receiver);
    ((void (*)(id, SEL, id))OriginalBrowseRequestWrite)(receiver, selector, stream);
}

static IMP OriginalRequestSetHeader;
static IMP OriginalRequestSetBody;

static BOOL WolFoxIsSpoofedHomeBody(NSData *body) {
    if (body.length == 0) return NO;
    NSData *needle = [WolFoxHomeSpoofVersion dataUsingEncoding:NSUTF8StringEncoding];
    return [body rangeOfData:needle options:0 range:NSMakeRange(0, body.length)].location != NSNotFound;
}

// Keep the version header in line with the spoofed request body.
static void WolFoxMatchVersionHeader(NSMutableURLRequest *request) {
    if (![request.URL.path containsString:@"/browse"] || !WolFoxIsSpoofedHomeBody(request.HTTPBody)) return;
    NSString *current = [request valueForHTTPHeaderField:@"X-Youtube-Client-Version"];
    if (current == nil || [current isEqualToString:WolFoxHomeSpoofVersion]) return;
    ((void (*)(id, SEL, id, id))OriginalRequestSetHeader)(request, @selector(setValue:forHTTPHeaderField:),
                                                         WolFoxHomeSpoofVersion, @"X-Youtube-Client-Version");
}

static void WolFoxRequestSetHeader(NSMutableURLRequest *receiver, SEL selector, NSString *value, NSString *field) {
    ((void (*)(id, SEL, id, id))OriginalRequestSetHeader)(receiver, selector, value, field);
    if (![field isKindOfClass:NSString.class] ||
        [field caseInsensitiveCompare:@"X-Youtube-Client-Version"] != NSOrderedSame) return;
    WolFoxMatchVersionHeader(receiver);
}

static void WolFoxRequestSetBody(NSMutableURLRequest *receiver, SEL selector, NSData *body) {
    ((void (*)(id, SEL, id))OriginalRequestSetBody)(receiver, selector, body);
    WolFoxMatchVersionHeader(receiver);
}

__attribute__((constructor)) static void WolFoxInstallHomeTabs(void) {
    WolFoxInstallInstanceHook(@"NSMutableURLRequest", @"setValue:forHTTPHeaderField:",
                              (IMP)WolFoxRequestSetHeader, &OriginalRequestSetHeader);
    WolFoxInstallInstanceHook(@"NSMutableURLRequest", @"setHTTPBody:",
                              (IMP)WolFoxRequestSetBody, &OriginalRequestSetBody);
    Class browseRequest = NSClassFromString(@"YTIBrowseRequest");
    SEL write = NSSelectorFromString(@"writeToCodedOutputStream:");
    Method inherited = class_getInstanceMethod(browseRequest, write);
    const char *writeTypes = inherited != NULL ? method_getTypeEncoding(inherited) : NULL;
    if (writeTypes != NULL && strncmp(writeTypes, "v24@0:8@16", 10) == 0) {
        OriginalBrowseRequestWrite = method_getImplementation(inherited);
        if (!class_addMethod(browseRequest, write, (IMP)WolFoxBrowseRequestWrite, writeTypes)) {
            OriginalBrowseRequestWrite = method_setImplementation(
                class_getInstanceMethod(browseRequest, write), (IMP)WolFoxBrowseRequestWrite);
        }
    }
    SEL size = NSSelectorFromString(@"serializedSize");
    Method sizeMethod = class_getInstanceMethod(browseRequest, size);
    const char *sizeTypes = sizeMethod != NULL ? method_getTypeEncoding(sizeMethod) : NULL;
    if (OriginalBrowseRequestWrite != NULL && sizeTypes != NULL && strncmp(sizeTypes, "Q16@0:8", 7) == 0) {
        OriginalBrowseRequestSize = method_getImplementation(sizeMethod);
        if (!class_addMethod(browseRequest, size, (IMP)WolFoxBrowseRequestSize, sizeTypes)) {
            OriginalBrowseRequestSize = method_setImplementation(
                class_getInstanceMethod(browseRequest, size), (IMP)WolFoxBrowseRequestSize);
        }
    }
    WolFoxInstallInstanceHook(@"YTBrowseViewController", @"loadWithResponse:",
                              (IMP)WolFoxBrowseLoadResponse, &OriginalBrowseLoadResponse);
    WolFoxInstallInstanceHook(@"YTBrowseViewController", @"loadWithInitialResponse:",
                              (IMP)WolFoxBrowseLoadInitialResponse, &OriginalBrowseLoadInitialResponse);
    WolFoxInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientIosEnableScrollableTabsInFox",
                              (IMP)WolFoxFoxScrollableTabs, &OriginalFoxScrollableTabs);
    WolFoxInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientEnableCollapsingTabsAfterDwellInFox",
                              (IMP)WolFoxFoxCollapsingTabs, &OriginalFoxCollapsingTabs);
    WolFoxInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientIosEnableCollapsingTabsAfterDwellInFox",
                              (IMP)WolFoxFoxIosCollapsingTabs, &OriginalFoxIosCollapsingTabs);
    WolFoxInstallInstanceHook(@"YTTabsViewController", @"loadWithModel:",
                              (IMP)WolFoxTabsLoadModel, &OriginalTabsLoadModel);
    WolFoxInstallInstanceHook(@"YTTabsViewController", @"loadWithModel:reloadContentViewControllers:",
                              (IMP)WolFoxTabsLoadModelReload, &OriginalTabsLoadModelReload);
    WolFoxInstallInstanceHook(@"YTTabsViewController", @"updateWithModel:isDefaultModel:reloadContentViewControllers:",
                              (IMP)WolFoxTabsUpdateModel, &OriginalTabsUpdateModel);
}

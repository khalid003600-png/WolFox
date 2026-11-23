#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdint.h>
#import <string.h>

static IMP OriginalShouldBlockUpgradeDialog;
static IMP OriginalAdShieldSignals;
static IMP OriginalAdShieldSignalsWithoutIDFA;
static IMP OriginalAdsDecorateContext;
static IMP OriginalAccountAdsDecorateContext;
static IMP OriginalPlayerAdsArray;
static IMP OriginalAdSlotsArray;
static IMP OriginalAdPlacementsArray;
static IMP OriginalAdBreakParams;
static IMP OriginalAdNextParams;
static IMP OriginalAdParams;
static IMP OriginalEnableSkippableAd;
static IMP OriginalMDXSessionImplAdPlaying;
static IMP OriginalIsPlayingAd;
static IMP OriginalIsPlayingAdSurvey;
static IMP OriginalIsPlayingAdIntro;
static IMP OriginalCreateAdsPlaybackCoordinator;
static IMP OriginalReelContentModel;
static IMP OriginalReelShouldDisplay;
static IMP OriginalCompanionAd;
static IMP OriginalHasCompanionAdRenderer;
static IMP OriginalHasAppPromoCompanionAdRenderer;
static IMP OriginalHasShoppingCompanionAdRenderer;
static const void *WolFoxAdObjectAssociation = &WolFoxAdObjectAssociation;
static const void *WolFoxSectionContentsAssociation =
    &WolFoxSectionContentsAssociation;
static const void *WolFoxSectionContentCountAssociation =
    &WolFoxSectionContentCountAssociation;
static IMP OriginalURLSessionTaskResume;

static const char * const WolFoxAdMarkers[] = {
    "eml.ad",
    "eml_ad",
    "pagead/",
    "yt-ads-web-view-id",
    "compact_promoted",
    "grid_promoted",
    "promoted_sparkles",
    "promoted_discovery",
    "promoted_15_click",
    "promoted_native_text",
    ".promoted_video",
    "_promoted_video",
    "promoted_app_install",
    "promoted_text_banner",
    "shopping_ad_info_card",
    ".display_ad",
    "_display_ad",
    ".infeed_ad",
    "_infeed_ad",
    ".ad_slot",
    "_ad_slot",
    ".ad_badge",
    "_ad_badge",
    ".native_ad_badge",
    "_native_ad_badge",
    ".simple_ad_badge",
    "_simple_ad_badge",
    "YTIReelNonVideoAdsCustomData",
    "reelNonVideoAdsCustomData",
    "YTIReelNonVideoAdsCustomData_reelNonVideoAdsCustomData",
    "adsVideoWithContext",
    "ads_video_with_context",
    "shorts_ad",
    "shortsAd",
    "reel_ad",
    "reelAd"
};

typedef struct {
    int16_t next[128];
    int16_t fail;
    BOOL terminal;
} WolFoxAdTrieNode;

static WolFoxAdTrieNode WolFoxAdTrie[512];
static int32_t WolFoxAdTrieCount;

static void WolFoxAdTrieReset(int32_t node) {
    for (NSUInteger byte = 0; byte < 128; byte++) {
        WolFoxAdTrie[node].next[byte] = -1;
    }
    WolFoxAdTrie[node].fail = 0;
    WolFoxAdTrie[node].terminal = NO;
}

static void WolFoxAdTrieInsert(const char *marker) {
    int32_t state = 0;
    for (const unsigned char *byte = (const unsigned char *)marker;
         *byte != '\0'; byte++) {
        if (*byte >= 128) return;
        if (WolFoxAdTrie[state].next[*byte] < 0) {
            const int32_t capacity =
                (int32_t)(sizeof(WolFoxAdTrie) / sizeof(WolFoxAdTrie[0]));
            // Out of room: skip the rest of this marker instead of writing
            // past the table.
            if (WolFoxAdTrieCount + 1 >= capacity) return;
            int32_t node = ++WolFoxAdTrieCount;
            WolFoxAdTrieReset(node);
            WolFoxAdTrie[state].next[*byte] = (int16_t)node;
        }
        state = WolFoxAdTrie[state].next[*byte];
    }
    WolFoxAdTrie[state].terminal = YES;
}

static void WolFoxAdTrieBuild(void) {
    WolFoxAdTrieCount = 0;
    WolFoxAdTrieReset(0);
    NSUInteger markerCount = sizeof(WolFoxAdMarkers) / sizeof(WolFoxAdMarkers[0]);
    for (NSUInteger marker = 0; marker < markerCount; marker++) {
        WolFoxAdTrieInsert(WolFoxAdMarkers[marker]);
    }

    int16_t queue[512];
    int32_t head = 0;
    int32_t tail = 0;
    for (NSUInteger byte = 0; byte < 128; byte++) {
        int16_t next = WolFoxAdTrie[0].next[byte];
        if (next < 0) {
            WolFoxAdTrie[0].next[byte] = 0;
        } else {
            queue[tail++] = next;
        }
    }
    while (head < tail) {
        int16_t state = queue[head++];
        int16_t failure = WolFoxAdTrie[state].fail;
        WolFoxAdTrie[state].terminal =
            WolFoxAdTrie[state].terminal || WolFoxAdTrie[failure].terminal;
        for (NSUInteger byte = 0; byte < 128; byte++) {
            int16_t next = WolFoxAdTrie[state].next[byte];
            if (next < 0) {
                WolFoxAdTrie[state].next[byte] =
                    WolFoxAdTrie[failure].next[byte];
            } else {
                WolFoxAdTrie[next].fail =
                    WolFoxAdTrie[failure].next[byte];
                queue[tail++] = next;
            }
        }
    }
}

static BOOL WolFoxAdBytes(NSData *data) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    int32_t state = 0;
    for (NSUInteger index = 0; index < length; index++) {
        uint8_t byte = bytes[index];
        if (byte >= 128) {
            state = 0;
            continue;
        }
        state = WolFoxAdTrie[state].next[byte];
        if (WolFoxAdTrie[state].terminal) return YES;
    }
    return NO;
}

static BOOL WolFoxAdsHostMatches(NSString *host, NSString *suffix) {
    NSUInteger hostLength = host.length;
    NSUInteger suffixLength = suffix.length;
    if (hostLength < suffixLength) return NO;
    if (![host hasSuffix:suffix]) return NO;
    if (hostLength == suffixLength) return YES;
    return [host characterAtIndex:hostLength - suffixLength - 1] == '.';
}

static BOOL WolFoxAdsHostIsBlocked(NSString *host) {
    if (host.length == 0) return NO;
    return WolFoxAdsHostMatches(host, @"doubleclick.net") ||
        WolFoxAdsHostMatches(host, @"googleadservices.com") ||
        WolFoxAdsHostMatches(host, @"googlesyndication.com");
}

static BOOL WolFoxAdsURLIsBlocked(NSURL *URL) {
    NSString *host = URL.host.lowercaseString;
    if (WolFoxAdsHostIsBlocked(host)) return YES;
    if (WolFoxAdsHostMatches(host, @"youtube.com") ||
        WolFoxAdsHostMatches(host, @"google.com")) {
        NSString *path = URL.path.lowercaseString;
        return [path hasPrefix:@"/pagead/"] ||
            [path hasPrefix:@"/ads/"] ||
            [path hasPrefix:@"/api/stats/ads"];
    }
    return NO;
}

// AVFoundation download tasks (YouTube's offline downloads) throw on
// currentRequest, which crashed every launch while one was queued.
static NSURLRequest *WolFoxTaskRequest(NSURLSessionTask *task) {
    static Class assetTask, aggregateTask;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        assetTask = NSClassFromString(@"AVAssetDownloadTask");
        aggregateTask = NSClassFromString(@"AVAggregateAssetDownloadTask");
    });
    if ((assetTask != Nil && [task isKindOfClass:assetTask]) ||
        (aggregateTask != Nil && [task isKindOfClass:aggregateTask])) return nil;
    @try {
        return task.currentRequest ?: task.originalRequest;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void WolFoxURLSessionTaskResume(NSURLSessionTask *task, SEL selector) {
    NSURLRequest *request = WolFoxTaskRequest(task);
    if (WolFoxShouldBlockPlaybackHeartbeat(request.URL) ||
        (WolFoxFeatureEnabled(WolFoxNoAdsKey) && WolFoxAdsURLIsBlocked(request.URL))) {
        [task cancel];
        return;
    }
    if (OriginalURLSessionTaskResume != NULL) {
        ((void (*)(id, SEL))OriginalURLSessionTaskResume)(task, selector);
    }
}

static id WolFoxCallObjectGetter(IMP implementation, id receiver, SEL selector) {
    return implementation == NULL
        ? nil
        : ((id (*)(id, SEL))implementation)(receiver, selector);
}

static BOOL WolFoxCallBooleanGetter(IMP implementation, id receiver, SEL selector) {
    return implementation != NULL &&
        ((BOOL (*)(id, SEL))implementation)(receiver, selector);
}

static BOOL WolFoxShouldBlockUpgradeDialog(id receiver, SEL selector) {
    return WolFoxFeatureEnabled(WolFoxNoAdsKey)
        ? YES
        : WolFoxCallBooleanGetter(OriginalShouldBlockUpgradeDialog, receiver, selector);
}

static id WolFoxEmptyDictionary(IMP original, id receiver, SEL selector) {
    return WolFoxFeatureEnabled(WolFoxNoAdsKey)
        ? @{}
        : WolFoxCallObjectGetter(original, receiver, selector);
}

static id WolFoxAdShieldSignals(id receiver, SEL selector) {
    return WolFoxEmptyDictionary(OriginalAdShieldSignals, receiver, selector);
}

static id WolFoxAdShieldSignalsWithoutIDFA(id receiver, SEL selector) {
    return WolFoxEmptyDictionary(OriginalAdShieldSignalsWithoutIDFA, receiver, selector);
}

static void WolFoxAdsDecorateContext(id receiver, SEL selector, id context) {
    if (!WolFoxFeatureEnabled(WolFoxNoAdsKey) && OriginalAdsDecorateContext != NULL) {
        ((void (*)(id, SEL, id))OriginalAdsDecorateContext)(receiver, selector, context);
    }
}

static void WolFoxAccountAdsDecorateContext(id receiver, SEL selector, id context) {
    if (!WolFoxFeatureEnabled(WolFoxNoAdsKey) &&
        OriginalAccountAdsDecorateContext != NULL) {
        ((void (*)(id, SEL, id))OriginalAccountAdsDecorateContext)(
            receiver,
            selector,
            context
        );
    }
}

static IMP OriginalAccountAdsDecorateService;
static IMP OriginalAdsDecorateService;

static void WolFoxCallAdsDecorateService(IMP original,
                                         id receiver,
                                         SEL selector,
                                         id context,
                                         long long type) {
    if (!WolFoxFeatureEnabled(WolFoxNoAdsKey) && original != NULL) {
        ((void (*)(id, SEL, id, long long))original)(
            receiver,
            selector,
            context,
            type
        );
    }
}

static void WolFoxAccountAdsDecorateService(id receiver,
                                            SEL selector,
                                            id context,
                                            long long type) {
    WolFoxCallAdsDecorateService(OriginalAccountAdsDecorateService,
                                 receiver,
                                 selector,
                                 context,
                                 type);
}

static void WolFoxAdsDecorateService(id receiver,
                                     SEL selector,
                                     id context,
                                     long long type) {
    WolFoxCallAdsDecorateService(OriginalAdsDecorateService,
                                 receiver,
                                 selector,
                                 context,
                                 type);
}

static id WolFoxPlayerAdsArray(id receiver, SEL selector) {
    return WolFoxFeatureEnabled(WolFoxNoAdsKey)
        ? [NSMutableArray array]
        : WolFoxCallObjectGetter(OriginalPlayerAdsArray, receiver, selector);
}

static id WolFoxAdSlotsArray(id receiver, SEL selector) {
    return WolFoxFeatureEnabled(WolFoxNoAdsKey)
        ? [NSMutableArray array]
        : WolFoxCallObjectGetter(OriginalAdSlotsArray, receiver, selector);
}

static id WolFoxAdPlacementsArray(id receiver, SEL selector) {
    return WolFoxFeatureEnabled(WolFoxNoAdsKey)
        ? [NSMutableArray array]
        : WolFoxCallObjectGetter(OriginalAdPlacementsArray, receiver, selector);
}

static id WolFoxNilParameter(IMP original, id receiver, SEL selector) {
    return WolFoxFeatureEnabled(WolFoxNoAdsKey)
        ? nil
        : WolFoxCallObjectGetter(original, receiver, selector);
}

static id WolFoxAdBreakParams(id receiver, SEL selector) {
    return WolFoxNilParameter(OriginalAdBreakParams, receiver, selector);
}

static id WolFoxAdNextParams(id receiver, SEL selector) {
    return WolFoxNilParameter(OriginalAdNextParams, receiver, selector);
}

static id WolFoxAdParams(id receiver, SEL selector) {
    return WolFoxNilParameter(OriginalAdParams, receiver, selector);
}

static BOOL WolFoxEnableSkippableAd(id receiver, SEL selector) {
    return WolFoxFeatureEnabled(WolFoxNoAdsKey)
        ? YES
        : WolFoxCallBooleanGetter(OriginalEnableSkippableAd, receiver, selector);
}

static void WolFoxMDXSessionImplAdPlaying(id receiver,
                                          SEL selector,
                                          uintptr_t value) {
    if (!WolFoxFeatureEnabled(WolFoxNoAdsKey) &&
        OriginalMDXSessionImplAdPlaying != NULL) {
        ((void (*)(id, SEL, uintptr_t))OriginalMDXSessionImplAdPlaying)(
            receiver,
            selector,
            value
        );
    }
}

static BOOL WolFoxNotPlayingAd(IMP original, id receiver, SEL selector) {
    return WolFoxFeatureEnabled(WolFoxNoAdsKey)
        ? NO
        : WolFoxCallBooleanGetter(original, receiver, selector);
}

static BOOL WolFoxIsPlayingAd(id receiver, SEL selector) {
    return WolFoxNotPlayingAd(OriginalIsPlayingAd, receiver, selector);
}

static BOOL WolFoxIsPlayingAdSurvey(id receiver, SEL selector) {
    return WolFoxNotPlayingAd(OriginalIsPlayingAdSurvey, receiver, selector);
}

static BOOL WolFoxIsPlayingAdIntro(id receiver, SEL selector) {
    return WolFoxNotPlayingAd(OriginalIsPlayingAdIntro, receiver, selector);
}

static id WolFoxNoAdsPlaybackCoordinator(id receiver, SEL selector) {
    id coordinator = WolFoxCallObjectGetter(
        OriginalCreateAdsPlaybackCoordinator,
        receiver,
        selector
    );
    return WolFoxFeatureEnabled(WolFoxNoAdsKey) ? nil : coordinator;
}

static id WolFoxObjectValue(id object, NSString *selectorName) {
    if (object == nil) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL WolFoxObjectHasAd(id object) {
    if (object == nil) return NO;
    NSNumber *cached = objc_getAssociatedObject(object, WolFoxAdObjectAssociation);
    if (cached != nil) return cached.boolValue;
    SEL dataSelector = @selector(data);
    if (![object respondsToSelector:dataSelector]) return NO;
    id value = ((id (*)(id, SEL))objc_msgSend)(object, dataSelector);
    if (![value isKindOfClass:NSData.class]) return NO;
    BOOL ad = WolFoxAdBytes(value);
    objc_setAssociatedObject(object, WolFoxAdObjectAssociation, @(ad),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return ad;
}

static BOOL WolFoxObjectBool(id object, NSString *selectorName) {
    if (object == nil) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL WolFoxReelObjectLooksLikeAd(id object, NSUInteger depth) {
    if (object == nil || depth > 3) return NO;

    NSString *className = NSStringFromClass([object class]).lowercaseString;
    if ([className containsString:@"nonvideoad"] ||
        [className containsString:@"reelad"] ||
        [className containsString:@"adselection"] ||
        [className containsString:@"miniappad"]) {
        return YES;
    }

    for (NSString *selectorName in @[
        @"isAd", @"isAdVideo", @"isVideoAd", @"hasAdLoggingData"
    ]) {
        if (WolFoxObjectBool(object, selectorName)) return YES;
    }

    SEL videoTypeSelector = NSSelectorFromString(@"videoType");
    if ([object respondsToSelector:videoTypeSelector]) {
        NSInteger videoType = ((NSInteger (*)(id, SEL))objc_msgSend)(
            object,
            videoTypeSelector
        );
        if (videoType == 3) return YES;
    }

    for (NSString *selectorName in @[
        @"adLoggingData",
        @"adSlotRenderer",
        @"reelNonVideoAdRenderer",
        @"nonVideoAdRenderer",
        @"sequenceItemAdSelectionRenderer"
    ]) {
        if (WolFoxObjectValue(object, selectorName) != nil) return YES;
    }

    for (NSString *selectorName in @[
        @"reelModel", @"command", @"watchModel", @"parentWatchModel"
    ]) {
        id child = WolFoxObjectValue(object, selectorName);
        if (child != object && WolFoxReelObjectLooksLikeAd(child, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

static BOOL WolFoxReelShouldDisplay(id receiver, SEL selector) {
    BOOL shouldDisplay = OriginalReelShouldDisplay == NULL ||
        ((BOOL (*)(id, SEL))OriginalReelShouldDisplay)(receiver, selector);
    if (!shouldDisplay || !WolFoxFeatureEnabled(WolFoxNoAdsKey)) {
        return shouldDisplay;
    }
    if (WolFoxObjectValue(receiver, @"nonVideoContentModel") != nil) {
        return NO;
    }
    return !WolFoxReelObjectLooksLikeAd(receiver, 0);
}

static BOOL WolFoxShortsAdBytes(NSData *data) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    for (NSUInteger index = 0; index + 3 < length; index++) {
        if (bytes[index] != 0x82 || bytes[index + 1] != 0x01) continue;
        NSUInteger cursor = index + 2;
        NSUInteger size = 0;
        NSUInteger shift = 0;
        while (cursor < length && shift < 28) {
            uint8_t byte = bytes[cursor++];
            size |= (NSUInteger)(byte & 0x7f) << shift;
            if ((byte & 0x80) == 0) break;
            shift += 7;
        }
        if (size < 2 || cursor + size > length) continue;
        for (NSUInteger end = cursor + size; cursor + 1 < end; cursor++) {
            if (bytes[cursor] == 0x08 && bytes[cursor + 1] == 0x01) {
                return YES;
            }
        }
    }
    return NO;
}

static id WolFoxReelContentModel(id receiver, SEL selector, id entry) {
    if (WolFoxFeatureEnabled(WolFoxNoAdsKey)) {
        NSData *data = ((id (*)(id, SEL))objc_msgSend)(entry, @selector(data));
        if (WolFoxAdBytes(data) || WolFoxShortsAdBytes(data)) {
            return nil;
        }
    }
    return ((id (*)(id, SEL, id))OriginalReelContentModel)(
        receiver,
        selector,
        entry
    );
}

NSArray *WolFoxFilterAdSections(NSArray *sections) {
    if (!WolFoxFeatureEnabled(WolFoxNoAdsKey) ||
        ![sections isKindOfClass:NSArray.class] || sections.count == 0) {
        return sections;
    }
    NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];
    for (NSUInteger index = 0; index < sections.count; index++) {
        id section = sections[index];
        SEL contentsSelector = @selector(contentsArray);
        NSArray *contents = [section respondsToSelector:contentsSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(section, contentsSelector)
            : nil;
        if (![contents isKindOfClass:NSArray.class]) contents = nil;
        if (contents.count == 0) {
            if (WolFoxObjectHasAd(section)) {
                [drop addIndex:index];
            }
            continue;
        }
        NSArray *processedContents = objc_getAssociatedObject(
            section, WolFoxSectionContentsAssociation);
        NSNumber *processedCount = objc_getAssociatedObject(
            section, WolFoxSectionContentCountAssociation);
        NSUInteger contentCount = contents.count;
        NSUInteger startIndex = 0;
        if (processedContents == contents && processedCount != nil) {
            NSUInteger previousCount = processedCount.unsignedIntegerValue;
            if (previousCount == contentCount) continue;
            if (previousCount < contentCount) startIndex = previousCount;
        }
        NSMutableIndexSet *contentDrop = nil;
        for (NSUInteger contentIndex = startIndex;
             contentIndex < contentCount; contentIndex++) {
            if (WolFoxObjectHasAd(contents[contentIndex])) {
                if (contentDrop == nil) {
                    contentDrop = [NSMutableIndexSet indexSet];
                }
                [contentDrop addIndex:contentIndex];
            }
        }
        if (contentDrop.count != 0) {
            if (![contents isKindOfClass:NSMutableArray.class]) {
                if (contentDrop.count == contentCount) {
                    [drop addIndex:index];
                }
                objc_setAssociatedObject(section,
                                         WolFoxSectionContentsAssociation,
                                         contents,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(section,
                                         WolFoxSectionContentCountAssociation,
                                         @(contentCount),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                continue;
            }
            [(NSMutableArray *)contents removeObjectsAtIndexes:contentDrop];
        }
        objc_setAssociatedObject(section,
                                 WolFoxSectionContentsAssociation,
                                 contents,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(section,
                                 WolFoxSectionContentCountAssociation,
                                 @(contents.count),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (contents.count == 0) {
            [drop addIndex:index];
        }
    }
    if (drop.count == 0) {
        return sections;
    }
    NSMutableArray *filtered = [sections mutableCopy];
    [filtered removeObjectsAtIndexes:drop];
    return filtered;
}

static id WolFoxNoCompanionAd(id receiver, SEL selector) {
    return WolFoxFeatureEnabled(WolFoxNoAdsKey)
        ? nil
        : WolFoxCallObjectGetter(OriginalCompanionAd, receiver, selector);
}

static BOOL WolFoxNoCompanionFlag(IMP original, id receiver, SEL selector) {
    return WolFoxFeatureEnabled(WolFoxNoAdsKey)
        ? NO
        : WolFoxCallBooleanGetter(original, receiver, selector);
}

static BOOL WolFoxHasCompanionAdRenderer(id receiver, SEL selector) {
    return WolFoxNoCompanionFlag(
        OriginalHasCompanionAdRenderer,
        receiver,
        selector
    );
}

static BOOL WolFoxHasAppPromoCompanionAdRenderer(id receiver, SEL selector) {
    return WolFoxNoCompanionFlag(
        OriginalHasAppPromoCompanionAdRenderer,
        receiver,
        selector
    );
}

static BOOL WolFoxHasShoppingCompanionAdRenderer(id receiver, SEL selector) {
    return WolFoxNoCompanionFlag(
        OriginalHasShoppingCompanionAdRenderer,
        receiver,
        selector
    );
}

static void WolFoxInstallAdsDecorateServiceHook(NSString *className,
                                                IMP replacement,
                                                IMP *originalStorage) {
    Class cls = NSClassFromString(className);
    if (cls == Nil) return;

    Method method = class_getInstanceMethod(
        cls,
        NSSelectorFromString(@"decorateContext:serviceType:")
    );
    if (method == NULL) return;

    const char *types = method_getTypeEncoding(method);
    if (types == NULL || strcmp(types, "v32@0:8@16q24") != 0) {
        return;
    }

    WolFoxInstallInstanceHook(className,
                              @"decorateContext:serviceType:",
                              replacement,
                              originalStorage);
}

void WolFoxInstallAdsHooks(void) {
    WolFoxAdTrieBuild();
    WolFoxInstallInstanceHook(@"NSURLSessionTask",
                              @"resume",
                              (IMP)WolFoxURLSessionTaskResume,
                              &OriginalURLSessionTaskResume);
    WolFoxInstallInstanceHook(@"YTGlobalConfig",
                              @"shouldBlockUpgradeDialog",
                              (IMP)WolFoxShouldBlockUpgradeDialog,
                              &OriginalShouldBlockUpgradeDialog);
    WolFoxInstallClassHook(@"YTAdShieldUtils",
                           @"spamSignalsDictionary",
                           (IMP)WolFoxAdShieldSignals,
                           &OriginalAdShieldSignals);
    WolFoxInstallClassHook(@"YTAdShieldUtils",
                           @"spamSignalsDictionaryWithoutIDFA",
                           (IMP)WolFoxAdShieldSignalsWithoutIDFA,
                           &OriginalAdShieldSignalsWithoutIDFA);
    WolFoxInstallInstanceHook(@"YTAdsInnerTubeContextDecorator",
                              @"decorateContext:",
                              (IMP)WolFoxAdsDecorateContext,
                              &OriginalAdsDecorateContext);
    // Renamed to ...Impl in YouTube 21.46.
    NSString *accountDecorator =
        NSClassFromString(@"YTAccountScopedAdsInnerTubeContextDecoratorImpl") != Nil
            ? @"YTAccountScopedAdsInnerTubeContextDecoratorImpl"
            : @"YTAccountScopedAdsInnerTubeContextDecorator";
    WolFoxInstallInstanceHook(accountDecorator,
                              @"decorateContext:",
                              (IMP)WolFoxAccountAdsDecorateContext,
                              &OriginalAccountAdsDecorateContext);
    WolFoxInstallAdsDecorateServiceHook(
        accountDecorator,
        (IMP)WolFoxAccountAdsDecorateService,
        &OriginalAccountAdsDecorateService
    );
    WolFoxInstallAdsDecorateServiceHook(
        @"YTAdsInnerTubeContextDecoratorImpl",
        (IMP)WolFoxAdsDecorateService,
        &OriginalAdsDecorateService
    );

    WolFoxInstallInstanceHook(@"YTIPlayerResponse",
                              @"playerAdsArray",
                              (IMP)WolFoxPlayerAdsArray,
                              &OriginalPlayerAdsArray);
    WolFoxInstallInstanceHook(@"YTIPlayerResponse",
                              @"adSlotsArray",
                              (IMP)WolFoxAdSlotsArray,
                              &OriginalAdSlotsArray);
    WolFoxInstallInstanceHook(@"YTIPlayerResponse",
                              @"adPlacementsArray",
                              (IMP)WolFoxAdPlacementsArray,
                              &OriginalAdPlacementsArray);
    WolFoxInstallInstanceHook(@"YTIPlayerResponse",
                              @"adBreakParams",
                              (IMP)WolFoxAdBreakParams,
                              &OriginalAdBreakParams);
    WolFoxInstallInstanceHook(@"YTIPlayerResponse",
                              @"adNextParams",
                              (IMP)WolFoxAdNextParams,
                              &OriginalAdNextParams);
    WolFoxInstallInstanceHook(@"YTIPlayerResponse",
                              @"adParams",
                              (IMP)WolFoxAdParams,
                              &OriginalAdParams);
    WolFoxInstallInstanceHook(@"YTIClientMdxGlobalConfig",
                              @"enableSkippableAd",
                              (IMP)WolFoxEnableSkippableAd,
                              &OriginalEnableSkippableAd);
    WolFoxInstallInstanceHook(@"MDXSessionImpl",
                              @"adPlaying:",
                              (IMP)WolFoxMDXSessionImplAdPlaying,
                              &OriginalMDXSessionImplAdPlaying);
    WolFoxInstallInstanceHook(@"YTLocalPlaybackController",
                              @"isPlayingAd",
                              (IMP)WolFoxIsPlayingAd,
                              &OriginalIsPlayingAd);
    WolFoxInstallInstanceHook(@"YTLocalPlaybackController",
                              @"isPlayingAdSurvey",
                              (IMP)WolFoxIsPlayingAdSurvey,
                              &OriginalIsPlayingAdSurvey);
    WolFoxInstallInstanceHook(@"YTLocalPlaybackController",
                              @"isPlayingAdIntro",
                              (IMP)WolFoxIsPlayingAdIntro,
                              &OriginalIsPlayingAdIntro);
    WolFoxInstallInstanceHook(@"YTLocalPlaybackController",
                              @"createAdsPlaybackCoordinator",
                              (IMP)WolFoxNoAdsPlaybackCoordinator,
                              &OriginalCreateAdsPlaybackCoordinator);
    WolFoxInstallInstanceHook(@"YTReelDataSource",
                              @"makeContentModelForEntry:",
                              (IMP)WolFoxReelContentModel,
                              &OriginalReelContentModel);
    WolFoxInstallInstanceHook(@"YTReelContentModel",
                              @"shouldDisplay",
                              (IMP)WolFoxReelShouldDisplay,
                              &OriginalReelShouldDisplay);
    WolFoxInstallInstanceHook(@"YTIElementRenderer",
                              @"companionAd",
                              (IMP)WolFoxNoCompanionAd,
                              &OriginalCompanionAd);
    WolFoxInstallInstanceHook(@"YTIElementRenderer",
                              @"hasCompanionAdRenderer",
                              (IMP)WolFoxHasCompanionAdRenderer,
                              &OriginalHasCompanionAdRenderer);
    WolFoxInstallInstanceHook(@"YTIElementRenderer",
                              @"hasAppPromoCompanionAdRenderer",
                              (IMP)WolFoxHasAppPromoCompanionAdRenderer,
                              &OriginalHasAppPromoCompanionAdRenderer);
    WolFoxInstallInstanceHook(@"YTIElementRenderer",
                              @"hasShoppingCompanionAdRenderer",
                              (IMP)WolFoxHasShoppingCompanionAdRenderer,
                              &OriginalHasShoppingCompanionAdRenderer);
}

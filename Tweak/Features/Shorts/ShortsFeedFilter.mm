#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

// ReelVideoType values on YTIReelWatchEndpoint and YTReelModel.
// 2 = video, 3 = ad, 4 = live, 7 = live preview, 10 = post.
enum {
    WolFoxReelVideoTypeLive = 4,
    WolFoxReelVideoTypeLivePreview = 7,
    WolFoxReelVideoTypePost = 10
};

static IMP OriginalMakeContentModelForEntry;
static IMP OriginalShouldDisplay;
static IMP OriginalSetReels;
static IMP OriginalInsertContentModel;
static IMP OriginalInsertEndpoint;

static Class WolFoxReelModelClass(void) {
    static Class reelModelClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        reelModelClass = NSClassFromString(@"YTReelModel");
    });
    return reelModelClass;
}

static BOOL WolFoxHidesLiveShorts(void) {
    return WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.LiveHidden");
}

static BOOL WolFoxHidesPostShorts(void) {
    return WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.PostsHidden");
}

static BOOL WolFoxFiltersAnything(void) {
    return WolFoxHidesLiveShorts() || WolFoxHidesPostShorts();
}

static BOOL WolFoxFiltersVideoType(NSInteger videoType) {
    if (videoType == WolFoxReelVideoTypeLive ||
        videoType == WolFoxReelVideoTypeLivePreview) {
        return WolFoxHidesLiveShorts();
    }
    if (videoType == WolFoxReelVideoTypePost) return WolFoxHidesPostShorts();
    return NO;
}

static id WolFoxSafeObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSInteger WolFoxVideoTypeOf(id object) {
    SEL selector = NSSelectorFromString(@"videoType");
    if (![object respondsToSelector:selector]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL WolFoxFiltersModel(id model) {
    if (!WolFoxFiltersAnything()) return NO;
    if (![model isKindOfClass:WolFoxReelModelClass()]) return NO;
    return WolFoxFiltersVideoType(WolFoxVideoTypeOf(model));
}

static BOOL WolFoxFiltersEndpoint(id endpoint) {
    if (!WolFoxFiltersAnything()) return NO;
    id reelEndpoint = [endpoint respondsToSelector:NSSelectorFromString(@"videoType")]
        ? endpoint : WolFoxSafeObject(endpoint, @"reelWatchEndpoint");
    return WolFoxFiltersVideoType(WolFoxVideoTypeOf(reelEndpoint));
}

static BOOL WolFoxFiltersEntry(id entry) {
    if (!WolFoxFiltersAnything()) return NO;
    return WolFoxFiltersEndpoint(WolFoxSafeObject(entry, @"command"));
}

static id WolFoxMakeContentModelForEntry(id receiver, SEL selector, id entry) {
    if (WolFoxFiltersEntry(entry)) return nil;
    return ((id (*)(id, SEL, id))OriginalMakeContentModelForEntry)(
        receiver, selector, entry);
}

static BOOL WolFoxShouldDisplay(id receiver, SEL selector) {
    if (WolFoxFiltersModel(receiver)) return NO;
    return ((BOOL (*)(id, SEL))OriginalShouldDisplay)(receiver, selector);
}

static void WolFoxSetReels(id receiver, SEL selector, NSOrderedSet *reels) {
    if (!WolFoxFiltersAnything()) {
        ((void (*)(id, SEL, id))OriginalSetReels)(receiver, selector, reels);
        return;
    }
    NSMutableOrderedSet *filtered =
        [NSMutableOrderedSet orderedSetWithCapacity:reels.count];
    for (id reel in reels) {
        if (!WolFoxFiltersModel(reel)) [filtered addObject:reel];
    }
    ((void (*)(id, SEL, id))OriginalSetReels)(receiver, selector, filtered);
}

static BOOL WolFoxInsertContentModel(id receiver,
                                     SEL selector,
                                     id model,
                                     NSUInteger index) {
    if (WolFoxFiltersModel(model)) return NO;
    return ((BOOL (*)(id, SEL, id, NSUInteger))OriginalInsertContentModel)(
        receiver, selector, model, index);
}

static BOOL WolFoxInsertEndpoint(id receiver,
                                 SEL selector,
                                 id endpoint,
                                 NSUInteger index) {
    if (WolFoxFiltersEndpoint(endpoint)) return NO;
    return ((BOOL (*)(id, SEL, id, NSUInteger))OriginalInsertEndpoint)(
        receiver, selector, endpoint, index);
}

void WolFoxInstallShortsFeedFilterHooks(void) {
    WolFoxInstallClassHook(@"YTReelContentModel",
                           @"makeContentModelForEntry:",
                           (IMP)WolFoxMakeContentModelForEntry,
                           &OriginalMakeContentModelForEntry);
    WolFoxInstallInstanceHook(@"YTReelContentModel",
                              @"shouldDisplay",
                              (IMP)WolFoxShouldDisplay,
                              &OriginalShouldDisplay);
    WolFoxInstallInstanceHook(@"YTReelDataSource",
                              @"setReels:",
                              (IMP)WolFoxSetReels,
                              &OriginalSetReels);
    WolFoxInstallInstanceHook(@"YTReelDataSource",
                              @"insertContentModel:atIndex:",
                              (IMP)WolFoxInsertContentModel,
                              &OriginalInsertContentModel);
    WolFoxInstallInstanceHook(@"YTReelDataSource",
                              @"insertEndpoint:atIndex:",
                              (IMP)WolFoxInsertEndpoint,
                              &OriginalInsertEndpoint);
}

#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"
#import "AiSList.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>

static BOOL WolFoxShortsSuggestionPillHidden(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTKACE.Preference.Shorts.SuggestionPillHidden"];
    if (stored == nil) {
        BOOL legacy = [NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Preference.Overlay.CommentPreviewsHidden"];
        [NSUserDefaults.standardUserDefaults setBool:legacy forKey:@"YTKACE.Preference.Shorts.SuggestionPillHidden"];
    }
    return WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.SuggestionPillHidden");
}

static IMP OriginalDisplayViewDidMove;
static IMP OriginalActionCellPrepareForReuse;
static IMP OriginalFixedBarLayout;
static IMP OriginalDisplayViewSetIdentifier;
static IMP OriginalAddSections;
static IMP OriginalSectionControllers;
static IMP OriginalEnableSubheaderBar;
static IMP OriginalChipBarUpdate;
static IMP OriginalChipCloudSetEntry;
static IMP OriginalSubsChipFilter;
static IMP OriginalChipCloudLayout;
static IMP OriginalSubsSetChipFilterView;
static IMP OriginalMaximumSubheaderHeight;
static IMP OriginalMaximumSubheaderHeightGetter;
static IMP OriginalSubheaderDefaultHeight;
static IMP OriginalSetHeaderHeights;
static IMP OriginalShouldHideSubheader;
static IMP OriginalPaidContentLayout;
static IMP OriginalPaidContentDidAppear;
static IMP OriginalPaidContentPlaybackStarted;
static IMP OriginalSetPaidContentPlayerData;
static IMP OriginalSetPaidContentRenderer;
static IMP OriginalHasPaidContentOverlay;
static IMP OriginalPaidContentOverlay;
static IMP OriginalOverlayPaidContentPlayerData;
static IMP OriginalInlinePaidContentPlayerData;
static IMP OriginalDidInsertPlayerOverlay;
static IMP OriginalScrollableActionButtonsArray;
static IMP OriginalScrollableActionBarButtonsArray;
static IMP OriginalScrollableButtonsArray;
static IMP OriginalScrollableActionsArray;
static IMP OriginalActionButtonsArray;
static IMP OriginalActionBarButtonsArray;
static IMP OriginalButtonsArray;
static IMP OriginalActionsArray;
static IMP OriginalActionViewDidMove;
static IMP OriginalActionsViewDidMove;
static IMP OriginalActionCellDidMove;
static IMP OriginalCreateActionViews;
static IMP OriginalActionCellControllerInit;
static IMP OriginalActionCellSize;
static IMP OriginalActionCellSizeWithInsets;
static IMP OriginalASCollectionViewLayout;
static IMP OriginalContentHostCellLayout;
static const void *WolFoxContentHiddenAssociation = &WolFoxContentHiddenAssociation;
static const void *WolFoxHostCellAssociation = &WolFoxHostCellAssociation;
static _Atomic NSUInteger WolFoxHostCellCount;
static NSString *WolFoxNormalizedDescription(id object);
static const void *WolFoxActionCellPreferenceAssociation =
    &WolFoxActionCellPreferenceAssociation;
static const void *WolFoxActionLayoutRefreshAssociation =
    &WolFoxActionLayoutRefreshAssociation;
static const void *WolFoxActionGroupCompactAssociation =
    &WolFoxActionGroupCompactAssociation;
static BOOL WolFoxContentContains(NSString *token,
                                  NSArray<NSString *> *needles);
static id WolFoxContentValue(id object, NSString *key);
static NSArray<NSString *> *WolFoxProductsMarkers(void);
static BOOL WolFoxHideTopics(void);
static BOOL WolFoxEnsureStructuralActionHook(void);
static BOOL WolFoxEnsureActionCellControllerHooks(void);
static BOOL WolFoxEnsureActionCollectionLayoutHook(void);

static BOOL WolFoxViewIsInsideWatchActionBar(UIView *view) {
    for (UIView *candidate = view; candidate != nil; candidate = candidate.superview) {
        NSString *identifier = [candidate.accessibilityIdentifier lowercaseString] ?: @"";
        NSString *className = NSStringFromClass(candidate.class) ?: @"";
        if ([identifier containsString:@"scrollable_action_bar"] ||
            [className containsString:@"SlimVideoScrollableDetailsActionsView"] ||
            [className containsString:@"SlimVideoScrollableActionBarCell"]) {
            return YES;
        }
        if ([candidate isKindOfClass:UICollectionView.class] &&
            CGRectGetHeight(candidate.bounds) <= 64.0 &&
            CGRectGetHeight(candidate.bounds) > 0.0) {
            return YES;
        }
    }
    return NO;
}

static NSString *WolFoxActionPreference(id item) {
    NSString *token = [[[NSString stringWithFormat:@"%@ %@",
        NSStringFromClass([item class]), WolFoxNormalizedDescription(item)] lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"YTKACE.Preference.ActionBar.DislikeHidden", @"dislike"],
        @[@"YTKACE.Preference.ActionBar.ShareHidden", @"share"],
        @[@"YTKACE.Preference.ActionBar.DownloadHidden", @"offline", @"download"],
        @[@"YTKACE.Preference.ActionBar.SaveHidden", @"save", @"add_to"],
        @[@"YTKACE.Preference.ActionBar.ClipHidden", @"clip"],
        @[@"YTKACE.Preference.ActionBar.RemixHidden", @"remix"],
        @[@"YTKACE.Preference.ActionBar.ThanksHidden", @"thanks"],
        @[@"YTKACE.Preference.ActionBar.HypeHidden", @"hype"],
        @[@"YTKACE.Preference.ActionBar.ReportHidden", @"id_player_watch_flag_button", @"report"],
        @[@"YTKACE.Preference.ActionBar.AskHidden", @"ask", @"gemini"],
        @[@"YTKACE.Preference.ActionBar.OverflowHidden", @"overflow"],
        @[@"YTKACE.Preference.ActionBar.LikeHidden", @"like"]
    ];
    for (NSArray<NSString *> *rule in rules) {
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([token containsString:rule[index]]) return rule.firstObject;
        }
    }
    return nil;
}

static BOOL WolFoxAnyActionPreferenceEnabled(void) {
    for (NSString *key in @[
        @"YTKACE.Preference.ActionBar.LikeHidden",
        @"YTKACE.Preference.ActionBar.DislikeHidden",
        @"YTKACE.Preference.ActionBar.ShareHidden",
        @"YTKACE.Preference.ActionBar.DownloadHidden",
        @"YTKACE.Preference.ActionBar.SaveHidden",
        @"YTKACE.Preference.ActionBar.ClipHidden",
        @"YTKACE.Preference.ActionBar.RemixHidden",
        @"YTKACE.Preference.ActionBar.ThanksHidden",
        @"YTKACE.Preference.ActionBar.HypeHidden",
        @"YTKACE.Preference.ActionBar.ReportHidden",
        @"YTKACE.Preference.ActionBar.AskHidden",
        @"YTKACE.Preference.ActionBar.OverflowHidden"
    ]) {
        if (WolFoxFeatureEnabled(key)) return YES;
    }
    return NO;
}

static NSString *WolFoxIconPreferenceInView(UIView *view);

static NSString *WolFoxActionPreferenceForView(UIView *view) {
    if (view == nil || !WolFoxViewIsInsideWatchActionBar(view)) return nil;
    for (NSString *name in @[@"entry", @"renderer", @"buttonRenderer",
                             @"model", @"elementRenderer"]) {
        SEL selector = NSSelectorFromString(name);
        if (![view respondsToSelector:selector]) continue;
        id related = ((id (*)(id, SEL))objc_msgSend)(view, selector);
        if (related == nil || [related isKindOfClass:UIView.class]) continue;
        NSString *preference = WolFoxActionPreference(related);
        if (preference.length != 0) {
            return preference;
        }
    }
    NSString *token = [[[NSString stringWithFormat:@"%@ %@",
        NSStringFromClass(view.class), view.accessibilityIdentifier ?: @""]
        lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSString *wide = [[NSString stringWithFormat:@"%@ %@", token,
        view.accessibilityLabel ?: @""] lowercaseString];
    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"YTKACE.Preference.ActionBar.DislikeHidden", @"id_video_dislike_button", @"dislike"],
        @[@"YTKACE.Preference.ActionBar.ShareHidden", @"id_video_share_button", @"share"],
        @[@"YTKACE.Preference.ActionBar.DownloadHidden", @"offline", @"download"],
        @[@"YTKACE.Preference.ActionBar.SaveHidden", @"save", @"add_to"],
        @[@"YTKACE.Preference.ActionBar.ClipHidden", @"clip"],
        @[@"YTKACE.Preference.ActionBar.RemixHidden", @"remix"],
        @[@"YTKACE.Preference.ActionBar.ThanksHidden", @"thanks"],
        @[@"YTKACE.Preference.ActionBar.HypeHidden", @"hype"],
        @[@"YTKACE.Preference.ActionBar.ReportHidden", @"id_player_watch_flag_button", @"report"],
        @[@"YTKACE.Preference.ActionBar.AskHidden", @"ask", @"gemini"],
        @[@"YTKACE.Preference.ActionBar.LikeHidden", @"id_video_like_button", @"like"]
    ];
    BOOL dislikeToken = [token containsString:@"dislike"] ||
        [wide containsString:@"dislike"];
    for (NSArray<NSString *> *rule in rules) {
        if (dislikeToken &&
            [rule.firstObject isEqualToString:
                @"YTKACE.Preference.ActionBar.LikeHidden"]) {
            continue;
        }
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([token containsString:rule[index]]) {
                return rule.firstObject;
            }
        }
    }
    NSString *iconPreference = WolFoxIconPreferenceInView(view);
    if (iconPreference.length != 0) return iconPreference;
    for (NSArray<NSString *> *rule in rules) {
        if (dislikeToken &&
            [rule.firstObject isEqualToString:
                @"YTKACE.Preference.ActionBar.LikeHidden"]) {
            continue;
        }
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([wide containsString:rule[index]]) {
                NSMutableArray<NSString *> *shape = [NSMutableArray array];
                NSMutableArray<UIView *> *pending =
                    [NSMutableArray arrayWithObject:view];
                NSUInteger seen = 0;
                while (pending.count != 0 && seen < 40) {
                    UIView *node = pending.firstObject;
                    [pending removeObjectAtIndex:0];
                    seen++;
                    NSMutableString *entry = [NSMutableString stringWithString:
                        NSStringFromClass([node class])];
                    if (node.accessibilityIdentifier.length != 0) {
                        [entry appendFormat:@"#%@", node.accessibilityIdentifier];
                    }
                    for (NSString *probe in @[@"iconType", @"icon", @"image",
                                              @"renderer", @"entry", @"model"]) {
                        SEL selector = NSSelectorFromString(probe);
                        if (![node respondsToSelector:selector]) continue;
                        [entry appendFormat:@" %@?", probe];
                    }
                    [shape addObject:entry];
                    [pending addObjectsFromArray:node.subviews];
                }
                return rule.firstObject;
            }
        }
    }
    return nil;
}

static void WolFoxCreateActionViews(id receiver, SEL selector,
                                    NSArray *renderers) {
    NSArray *filtered = renderers;
    if ([renderers isKindOfClass:NSArray.class]) {
        static NSUInteger rendererLogged = 0;
        if (rendererLogged < 3) {
            rendererLogged++;
            NSMutableArray<NSString *> *shape = [NSMutableArray array];
            for (id renderer in renderers) {
                NSString *match = WolFoxActionPreference(renderer);
                NSMutableString *entry = [NSMutableString stringWithString:
                    NSStringFromClass([renderer class])];
                for (NSString *probe in @[@"likeButton", @"dislikeButton",
                                          @"segmentedLikeDislikeButton",
                                          @"buttonRenderer", @"targetId",
                                          @"trackingParams"]) {
                    SEL selector = NSSelectorFromString(probe);
                    if ([renderer respondsToSelector:selector]) {
                        [entry appendFormat:@" %@?", probe];
                    }
                }
                if (match.length != 0) {
                    [entry appendFormat:@" ->%@",
                        [match componentsSeparatedByString:@"."].lastObject];
                }
                [shape addObject:entry];
            }
        }
    }
    if ([renderers isKindOfClass:NSArray.class] &&
        renderers.count != 0 && WolFoxAnyActionPreferenceEnabled()) {
        NSMutableArray *kept = [NSMutableArray arrayWithCapacity:renderers.count];
        for (id renderer in renderers) {
            NSString *preference = WolFoxActionPreference(renderer);
            if (preference.length != 0 && WolFoxFeatureEnabled(preference)) {
                continue;
            }
            [kept addObject:renderer];
        }
        if (kept.count != renderers.count) filtered = kept;
    }
    if (OriginalCreateActionViews != NULL) {
        ((void (*)(id, SEL, id))OriginalCreateActionViews)(
            receiver, selector, filtered);
    }
}

static void WolFoxEnsureActionCellReuseHook(void);

static BOOL WolFoxEnsureStructuralActionHook(void) {
    WolFoxEnsureActionCellReuseHook();
    if (OriginalCreateActionViews != NULL) return YES;

    BOOL installed = WolFoxInstallInstanceHook(
        @"YTSlimVideoScrollableDetailsActionsView",
        @"createActionViewsFromSupportedRenderers:",
        (IMP)WolFoxCreateActionViews,
        &OriginalCreateActionViews
    );
    if (installed && OriginalCreateActionViews != NULL) return YES;
    return NO;
}

static NSString *WolFoxActionPreferenceForController(id controller) {
    NSString *cached = objc_getAssociatedObject(
        controller, WolFoxActionCellPreferenceAssociation);
    if (cached.length != 0) return cached;

    for (Class cls = [controller class]; cls != Nil; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            const char *name = ivar_getName(ivars[index]);
            if (type == NULL || type[0] != '@' || name == NULL) continue;
            NSString *ivarName = [[NSString stringWithUTF8String:name] lowercaseString];
            if (![ivarName containsString:@"entry"] &&
                ![ivarName containsString:@"render"] &&
                ![ivarName containsString:@"button"] &&
                ![ivarName containsString:@"cell"]) {
                continue;
            }
            id value = object_getIvar(controller, ivars[index]);
            if (value == nil) continue;
            NSString *preference = [value isKindOfClass:UIView.class]
                ? WolFoxActionPreferenceForView(value)
                : WolFoxActionPreference(value);
            if (preference.length == 0) continue;
            free(ivars);
            objc_setAssociatedObject(controller,
                                     WolFoxActionCellPreferenceAssociation,
                                     preference,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
            return preference;
        }
        free(ivars);
    }
    return nil;
}

static id WolFoxActionCellControllerInit(id receiver, SEL selector,
                                          id entry, id parentResponder) {
    id result = OriginalActionCellControllerInit == NULL ? receiver :
        ((id (*)(id, SEL, id, id))OriginalActionCellControllerInit)(
            receiver, selector, entry, parentResponder);
    NSString *preference = WolFoxActionPreference(entry);
    if (result != nil && preference.length != 0) {
        objc_setAssociatedObject(result,
                                 WolFoxActionCellPreferenceAssociation,
                                 preference,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return result;
}

static NSArray<NSString *> *WolFoxActionButtonIdentifiers(UIView *view);
static BOOL WolFoxIsActionButtonIdentifier(NSString *identifier);

// YouTube's server-driven buttons (Ask, Report, ...) have no identifier and a
// translated label, but every icon is loaded by a fixed resource name such as
// "youtube_fill_experimental/spark_24pt". Remember that name on the image node
// that asked for it, so buttons can be matched in any language.
static IMP OriginalLocalImage;
static IMP OriginalResourceImage;
static IMP OriginalResourceImageBoost;
static __thread void *WolFoxLoadingImageNode;
static const void *WolFoxIconNameAssociation = &WolFoxIconNameAssociation;

static void WolFoxTagLoadingNode(NSString *name) {
    void *node = WolFoxLoadingImageNode;
    if (node == NULL || ![name isKindOfClass:NSString.class]) return;
    objc_setAssociatedObject((__bridge id)node, WolFoxIconNameAssociation,
                             name, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static id WolFoxLocalImage(id node, SEL selector, const void *image,
                           BOOL *boosted) {
    void *previous = WolFoxLoadingImageNode;
    WolFoxLoadingImageNode = (__bridge void *)node;
    id result = ((id (*)(id, SEL, const void *, BOOL *))OriginalLocalImage)(
        node, selector, image, boosted);
    WolFoxLoadingImageNode = previous;
    return result;
}

static id WolFoxResourceImage(id loader, SEL selector, NSString *name,
                              id color, id bundle) {
    WolFoxTagLoadingNode(name);
    return ((id (*)(id, SEL, id, id, id))OriginalResourceImage)(
        loader, selector, name, color, bundle);
}

static id WolFoxResourceImageBoost(id loader, SEL selector, NSString *name,
                                   id color, id bundle, float ratio) {
    WolFoxTagLoadingNode(name);
    return ((id (*)(id, SEL, id, id, id, float))OriginalResourceImageBoost)(
        loader, selector, name, color, bundle, ratio);
}

static void WolFoxEnsureIconNameHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class node = NSClassFromString(@"ELMImageNode");
        Method local = node == Nil ? NULL : class_getInstanceMethod(node,
            NSSelectorFromString(@"localImageWithImage:boosted:"));
        const char *types = local == NULL ? NULL : method_getTypeEncoding(local);
        // Only hook the shape this was written for: (const void *, BOOL *).
        if (types == NULL || strcmp(types, "@32@0:8r^v16^B24") != 0) return;
        WolFoxInstallInstanceHook(@"YTELMResourceLoaderImpl",
                                  @"imageWithName:color:bundleId:",
                                  (IMP)WolFoxResourceImage,
                                  &OriginalResourceImage);
        WolFoxInstallInstanceHook(@"YTELMResourceLoaderImpl",
                                  @"imageWithName:color:bundleId:hdrUIBoostRatio:",
                                  (IMP)WolFoxResourceImageBoost,
                                  &OriginalResourceImageBoost);
        WolFoxInstallInstanceHook(@"ELMImageNode",
                                  @"localImageWithImage:boosted:",
                                  (IMP)WolFoxLocalImage,
                                  &OriginalLocalImage);
    });
}

static NSString *WolFoxPreferenceForIconName(NSString *name) {
    NSString *icon = name.lastPathComponent.lowercaseString;
    if (icon.length == 0) return nil;
    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"YTKACE.Preference.ActionBar.DislikeHidden", @"thumb_down", @"dislike"],
        @[@"YTKACE.Preference.ActionBar.LikeHidden", @"thumb_up", @"like"],
        @[@"YTKACE.Preference.ActionBar.ShareHidden", @"share"],
        @[@"YTKACE.Preference.ActionBar.DownloadHidden", @"download", @"offline"],
        @[@"YTKACE.Preference.ActionBar.SaveHidden", @"bookmark", @"playlist_add", @"library_add", @"save"],
        @[@"YTKACE.Preference.ActionBar.ClipHidden", @"scissors", @"clip"],
        @[@"YTKACE.Preference.ActionBar.RemixHidden", @"remix"],
        @[@"YTKACE.Preference.ActionBar.ThanksHidden", @"thanks", @"money_heart"],
        @[@"YTKACE.Preference.ActionBar.HypeHidden", @"hype"],
        @[@"YTKACE.Preference.ActionBar.ReportHidden", @"flag", @"report"],
        @[@"YTKACE.Preference.ActionBar.AskHidden", @"spark", @"gemini"],
        @[@"YTKACE.Preference.ActionBar.OverflowHidden", @"overflow"]
    ];
    for (NSArray<NSString *> *rule in rules) {
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([icon hasPrefix:rule[index]]) return rule.firstObject;
        }
    }
    return nil;
}

// Icon names of the ELM image nodes inside a view, closest first.
static NSArray<NSString *> *WolFoxIconNamesInView(UIView *view) {
    if (view == nil || OriginalLocalImage == NULL) return @[];
    SEL nodeSelector = NSSelectorFromString(@"asyncdisplaykit_node");
    id root = nil;
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:view];
    for (NSUInteger index = 0; views.count != 0 && index < 8 && root == nil; index++) {
        UIView *candidate = views.firstObject;
        [views removeObjectAtIndex:0];
        if ([candidate respondsToSelector:nodeSelector]) {
            root = ((id (*)(id, SEL))objc_msgSend)(candidate, nodeSelector);
        }
        [views addObjectsFromArray:candidate.subviews];
    }
    if (root == nil) return @[];
    SEL subnodesSelector = NSSelectorFromString(@"subnodes");
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray *pending = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 48) {
        id node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        NSString *name = objc_getAssociatedObject(node, WolFoxIconNameAssociation);
        if (name.length != 0) [names addObject:name];
        if (![node respondsToSelector:subnodesSelector]) continue;
        NSArray *subnodes = ((id (*)(id, SEL))objc_msgSend)(node, subnodesSelector);
        if ([subnodes isKindOfClass:NSArray.class]) [pending addObjectsFromArray:subnodes];
    }
    return names;
}

static NSString *WolFoxIconPreferenceInView(UIView *view) {
    for (NSString *name in WolFoxIconNamesInView(view)) {
        NSString *preference = WolFoxPreferenceForIconName(name);
        if (preference.length != 0) return preference;
    }
    return nil;
}

static NSString *WolFoxPreferenceForButtonIdentifier(NSString *identifier) {
    NSString *token = [[identifier lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    if (token.length == 0) return nil;
    if ([token containsString:@"dislike"]) {
        return @"YTKACE.Preference.ActionBar.DislikeHidden";
    }
    if ([token containsString:@"like"]) {
        return @"YTKACE.Preference.ActionBar.LikeHidden";
    }
    if ([token containsString:@"share"]) {
        return @"YTKACE.Preference.ActionBar.ShareHidden";
    }
    if ([token containsString:@"offline"] || [token containsString:@"download"]) {
        return @"YTKACE.Preference.ActionBar.DownloadHidden";
    }
    if ([token containsString:@"add_to"] || [token containsString:@"save"]) {
        return @"YTKACE.Preference.ActionBar.SaveHidden";
    }
    if ([token containsString:@"clip"]) {
        return @"YTKACE.Preference.ActionBar.ClipHidden";
    }
    if ([token containsString:@"remix"]) {
        return @"YTKACE.Preference.ActionBar.RemixHidden";
    }
    if ([token containsString:@"thanks"]) {
        return @"YTKACE.Preference.ActionBar.ThanksHidden";
    }
    if ([token containsString:@"hype"]) {
        return @"YTKACE.Preference.ActionBar.HypeHidden";
    }
    return nil;
}

static NSArray<NSString *> *WolFoxControllerButtonIdentifiers(id controller) {
    NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSet];
    for (Class cls = [controller class]; cls != Nil;
         cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            if (type == NULL || type[0] != '@') continue;
            id value = object_getIvar(controller, ivars[index]);
            if (![value isKindOfClass:UIView.class]) continue;
            [found addObjectsFromArray:
                WolFoxActionButtonIdentifiers((UIView *)value)];
        }
        free(ivars);
    }
    return found.array;
}

static BOOL WolFoxControllerCellCollapsed(id receiver) {
    static NSUInteger logged = 0;
    NSString *preference = WolFoxActionPreferenceForController(receiver);
    NSArray<NSString *> *identifiers = WolFoxControllerButtonIdentifiers(receiver);
    BOOL collapsed = preference.length != 0 && WolFoxFeatureEnabled(preference);
    if (identifiers.count > 1) {
        collapsed = YES;
        for (NSString *identifier in identifiers) {
            NSString *key = WolFoxPreferenceForButtonIdentifier(identifier);
            if (key.length == 0 || !WolFoxFeatureEnabled(key)) {
                collapsed = NO;
                break;
            }
        }
    }
    if (logged < 60) {
        logged++;
    }
    return collapsed;
}

static CGSize WolFoxActionCellSize(id receiver, SEL selector, CGSize size) {
    CGSize result = OriginalActionCellSize == NULL ? size :
        ((CGSize (*)(id, SEL, CGSize))OriginalActionCellSize)(
            receiver, selector, size);
    if (WolFoxControllerCellCollapsed(receiver)) {
        result.width = 0.0;
    }
    return result;
}

static CGSize WolFoxActionCellSizeWithInsets(id receiver, SEL selector,
                                               CGSize size,
                                               UIEdgeInsets insets) {
    CGSize result = OriginalActionCellSizeWithInsets == NULL ? size :
        ((CGSize (*)(id, SEL, CGSize, UIEdgeInsets))
            OriginalActionCellSizeWithInsets)(receiver, selector, size, insets);
    if (WolFoxControllerCellCollapsed(receiver)) {
        result.width = 0.0;
    }
    return result;
}

static BOOL WolFoxEnsureActionCellControllerHooks(void) {
    if (OriginalActionCellSize != NULL ||
        OriginalActionCellSizeWithInsets != NULL) return YES;

    WolFoxInstallInstanceHook(
        @"YTSlimVideoScrollableActionBarCellController",
        @"initWithEntry:parentResponder:",
        (IMP)WolFoxActionCellControllerInit,
        &OriginalActionCellControllerInit);
    WolFoxInstallInstanceHook(
        @"YTSlimVideoScrollableActionBarCellController",
        @"cellSizeWithSize:",
        (IMP)WolFoxActionCellSize,
        &OriginalActionCellSize);
    WolFoxInstallInstanceHook(
        @"YTSlimVideoScrollableActionBarCellController",
        @"cellSizeWithSize:safeAreaInsets:",
        (IMP)WolFoxActionCellSizeWithInsets,
        &OriginalActionCellSizeWithInsets);
    return OriginalActionCellSize != NULL ||
        OriginalActionCellSizeWithInsets != NULL;
}

static NSSet<NSString *> *WolFoxActionPreferencesInCell(UIView *cell) {
    NSMutableSet<NSString *> *preferences = [NSMutableSet set];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:cell];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 120) {
        UIView *candidate = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        NSString *identifier = candidate.accessibilityIdentifier ?: @"";
        NSString *label = candidate.accessibilityLabel ?: @"";
        if (identifier.length != 0 || label.length != 0) {
            NSString *preference = WolFoxActionPreference(
                [NSString stringWithFormat:@"%@ %@", identifier, label]);
            if (preference.length != 0) [preferences addObject:preference];
        }
        [pending addObjectsFromArray:candidate.subviews];
    }
    for (NSString *name in WolFoxIconNamesInView(cell)) {
        NSString *preference = WolFoxPreferenceForIconName(name);
        if (preference.length != 0) [preferences addObject:preference];
    }
    return preferences;
}

static void WolFoxHiddenActionWidths(UIView *cell,
                                     CGFloat *outTotal,
                                     CGFloat *outLeading,
                                     NSUInteger *outVisible,
                                     CGFloat *outVisibleRight,
                                     CGFloat *outInset) {
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:cell];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 160) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        if (WolFoxIsActionButtonIdentifier(node.accessibilityIdentifier)) {
            [buttons addObject:node];
        }
        [pending addObjectsFromArray:node.subviews];
    }
    buttons = [[buttons sortedArrayUsingComparator:
        ^NSComparisonResult(UIView *left, UIView *right) {
            CGFloat leftX = [left convertPoint:CGPointZero toView:cell].x;
            CGFloat rightX = [right convertPoint:CGPointZero toView:cell].x;
            if (leftX < rightX) return NSOrderedAscending;
            if (leftX > rightX) return NSOrderedDescending;
            return NSOrderedSame;
        }] mutableCopy];

    CGFloat separators = 0.0;
    UIView *group = buttons.firstObject.superview;
    for (UIView *child in group.subviews) {
        CGFloat width = CGRectGetWidth(child.bounds);
        if (width > 0.0 && width <= 3.0 &&
            CGRectGetHeight(child.bounds) >= 6.0) {
            separators += width;
        }
    }

    CGFloat total = 0.0;
    CGFloat leading = 0.0;
    NSUInteger visible = 0;
    CGFloat visibleRight = 0.0;
    BOOL seenVisible = NO;
    for (UIView *button in buttons) {
        NSString *key = WolFoxPreferenceForButtonIdentifier(
            button.accessibilityIdentifier);
        BOOL hidden = key.length != 0 && WolFoxFeatureEnabled(key);
        CGFloat width = CGRectGetWidth(button.bounds);
        if (!hidden) {
            visible++;
            seenVisible = YES;
            CGRect inCell = [button convertRect:button.bounds toView:cell];
            visibleRight = MAX(visibleRight, CGRectGetMaxX(inCell));
            continue;
        }
        total += width;
        if (!seenVisible) leading += width;
    }
    CGFloat inset = 0.0;
    if (group != nil) {
        inset = MAX(0.0, CGRectGetMinX([group convertRect:group.bounds
                                                  toView:cell]));
    }
    if (outVisibleRight != NULL) *outVisibleRight = visibleRight;
    if (outInset != NULL) *outInset = inset;
    if (total > 0.0) total += separators;
    if (leading > 0.0) leading += separators;
    if (outTotal != NULL) *outTotal = total;
    if (outLeading != NULL) *outLeading = leading;
    if (outVisible != NULL) *outVisible = visible;
}

// The like/dislike pill is one cell holding [like, separator, dislike] in a
// Yoga row. Hiding one half by shrinking the cell's frame left a hole (like)
// or squashed the other half (dislike). Collapse the hidden half and the
// separator inside Yoga instead, so the pill measures itself correctly.
typedef struct { NSInteger unit; CGFloat value; } WolFoxActionDimension;
typedef struct {
    WolFoxActionDimension top, left, bottom, right, start, end, horizontal, vertical, all;
} WolFoxActionEdges;
static const void *WolFoxActionCollapsedKey = &WolFoxActionCollapsedKey;
static const void *WolFoxActionWidthsKey = &WolFoxActionWidthsKey;
static const void *WolFoxActionEdgesKey = &WolFoxActionEdgesKey;

static id WolFoxActionNodeGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return object != nil && [object respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static void WolFoxActionNodeRelayout(id node) {
    for (id current = node; current != nil; current = WolFoxActionNodeGet(current, @"supernode")) {
        SEL invalidate = NSSelectorFromString(@"invalidateCalculatedLayout");
        if ([current respondsToSelector:invalidate]) ((void (*)(id, SEL))objc_msgSend)(current, invalidate);
        SEL needs = NSSelectorFromString(@"setNeedsLayout");
        if ([current respondsToSelector:needs]) ((void (*)(id, SEL))objc_msgSend)(current, needs);
    }
}

static BOOL WolFoxActionNodeCollapse(id node, BOOL collapse) {
    if (node == nil) return NO;
    if ([objc_getAssociatedObject(node, WolFoxActionCollapsedKey) boolValue] == collapse) return NO;
    id style = WolFoxActionNodeGet(node, @"style");
    NSArray<NSString *> *names = @[@"width", @"minWidth", @"maxWidth"];
    if (collapse) {
        NSMutableArray *saved = [NSMutableArray array];
        for (NSString *name in names) {
            SEL getter = NSSelectorFromString(name);
            WolFoxActionDimension value = {0, 0};
            if ([style respondsToSelector:getter]) {
                value = ((WolFoxActionDimension (*)(id, SEL))objc_msgSend)(style, getter);
            }
            [saved addObject:[NSValue valueWithBytes:&value objCType:@encode(WolFoxActionDimension)]];
        }
        objc_setAssociatedObject(node, WolFoxActionWidthsKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSArray<NSValue *> *saved = objc_getAssociatedObject(node, WolFoxActionWidthsKey);
    for (NSUInteger index = 0; index < names.count; index++) {
        NSString *name = names[index];
        SEL setter = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
            [name substringToIndex:1].uppercaseString, [name substringFromIndex:1]]);
        if (![style respondsToSelector:setter]) continue;
        WolFoxActionDimension value = {1, 0};
        if (!collapse) {
            value = (WolFoxActionDimension){0, 0};
            if (index < saved.count) [saved[index] getValue:&value];
        }
        ((void (*)(id, SEL, WolFoxActionDimension))objc_msgSend)(style, setter, value);
    }
    // Padding and margin would keep a zero-width node from shrinking fully.
    NSArray<NSString *> *edgeNames = @[@"padding", @"margin"];
    if (collapse) {
        NSMutableArray *savedEdges = [NSMutableArray array];
        for (NSString *name in edgeNames) {
            SEL getter = NSSelectorFromString(name);
            WolFoxActionEdges value = {};
            if ([style respondsToSelector:getter]) {
                value = ((WolFoxActionEdges (*)(id, SEL))objc_msgSend)(style, getter);
            }
            [savedEdges addObject:[NSValue valueWithBytes:&value objCType:@encode(WolFoxActionEdges)]];
        }
        objc_setAssociatedObject(node, WolFoxActionEdgesKey, savedEdges, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSArray<NSValue *> *savedEdges = objc_getAssociatedObject(node, WolFoxActionEdgesKey);
    for (NSUInteger index = 0; index < edgeNames.count; index++) {
        NSString *name = edgeNames[index];
        SEL setter = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
            [name substringToIndex:1].uppercaseString, [name substringFromIndex:1]]);
        if (![style respondsToSelector:setter]) continue;
        WolFoxActionEdges value = {};
        if (collapse) {
            WolFoxActionDimension zero = {1, 0};
            value = (WolFoxActionEdges){zero, zero, zero, zero, zero, zero, zero, zero, zero};
        } else if (index < savedEdges.count) {
            [savedEdges[index] getValue:&value];
        }
        ((void (*)(id, SEL, WolFoxActionEdges))objc_msgSend)(style, setter, value);
    }
    SEL hidden = NSSelectorFromString(@"setHidden:");
    if ([node respondsToSelector:hidden]) ((void (*)(id, SEL, BOOL))objc_msgSend)(node, hidden, collapse);
    objc_setAssociatedObject(node, WolFoxActionCollapsedKey, @(collapse), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}

static id WolFoxCellRootNode(UIView *cell) {
    SEL nodeSelector = NSSelectorFromString(@"asyncdisplaykit_node");
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:cell];
    for (NSUInteger index = 0; views.count != 0 && index < 12; index++) {
        UIView *candidate = views.firstObject;
        [views removeObjectAtIndex:0];
        if ([candidate respondsToSelector:nodeSelector]) {
            id node = ((id (*)(id, SEL))objc_msgSend)(candidate, nodeSelector);
            if (node != nil) return node;
        }
        [views addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

// Returns YES when the cell is the like/dislike pill. bothHidden says whether
// the whole pill should go (left to the normal cell collapse).
static BOOL WolFoxApplyPillHiding(UIView *cell, BOOL *bothHidden) {
    if (bothHidden != NULL) *bothHidden = NO;
    id root = WolFoxCellRootNode(cell);
    if (root == nil) return NO;
    id like = nil, dislike = nil;
    NSMutableArray *pending = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 40 && (like == nil || dislike == nil)) {
        id node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        id identifier = WolFoxActionNodeGet(node, @"accessibilityIdentifier");
        if ([identifier isEqual:@"id.video.like.button"]) like = node;
        else if ([identifier isEqual:@"id.video.dislike.button"]) dislike = node;
        NSArray *subnodes = WolFoxActionNodeGet(node, @"subnodes");
        if ([subnodes isKindOfClass:NSArray.class]) [pending addObjectsFromArray:subnodes];
    }
    id pill = WolFoxActionNodeGet(like, @"supernode");
    if (like == nil || dislike == nil || pill == nil ||
        WolFoxActionNodeGet(dislike, @"supernode") != pill) return NO;
    BOOL likeHidden = WolFoxFeatureEnabled(@"YTKACE.Preference.ActionBar.LikeHidden");
    BOOL dislikeHidden = WolFoxFeatureEnabled(@"YTKACE.Preference.ActionBar.DislikeHidden");
    BOOL both = likeHidden && dislikeHidden;
    if (bothHidden != NULL) *bothHidden = both;
    // When both go, the cell itself collapses; keep the halves intact so the
    // pill comes back whole if a setting is turned off.
    BOOL hideLike = likeHidden && !both;
    BOOL hideDislike = dislikeHidden && !both;
    BOOL changed = NO;
    changed |= WolFoxActionNodeCollapse(like, hideLike);
    changed |= WolFoxActionNodeCollapse(dislike, hideDislike);
    NSArray *children = WolFoxActionNodeGet(pill, @"subnodes");
    if ([children isKindOfClass:NSArray.class]) {
        for (id child in children) {
            if (child == like || child == dislike) continue;
            changed |= WolFoxActionNodeCollapse(child, hideLike || hideDislike);
        }
    }
    if (changed) WolFoxActionNodeRelayout(pill);
    return YES;
}

// The first cell (the like/dislike pill) carries the row's leading inset
// inside itself. When it collapses, the next visible cell should keep it.
static CGFloat WolFoxCellLeadingInset(UIView *cell) {
    id node = WolFoxCellRootNode(cell);
    for (NSUInteger depth = 0; node != nil && depth < 2; depth++) {
        NSArray *subnodes = WolFoxActionNodeGet(node, @"subnodes");
        node = [subnodes isKindOfClass:NSArray.class] ? subnodes.firstObject : nil;
    }
    if (node == nil || ![node respondsToSelector:@selector(frame)]) return 0.0;
    CGFloat inset = ((CGRect (*)(id, SEL))objc_msgSend)(node, @selector(frame)).origin.x;
    return inset > 0.5 && inset <= 32.0 ? inset : 0.0;
}

extern "C" void WolFoxNoteActionBarButtons(NSArray<NSString *> *names);

// Which action bar this device gets, for the editor's mock: "fixed" (the
// iPhone row of icons) or "chips" (the scrolling row of chips).
static void WolFoxNoteActionBarLayout(NSString *kind) {
    static NSString *noted;
    // The fixed row wins if both show up in one launch.
    if ([noted isEqualToString:kind] || [noted isEqualToString:@"fixed"]) return;
    noted = kind;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *key = @"WolFox.State.ActionBarLayout";
    if (![[defaults stringForKey:key] isEqualToString:kind]) [defaults setObject:kind forKey:key];
}

static void WolFoxASCollectionViewLayout(UICollectionView *receiver,
                                          SEL selector) {
    if (OriginalASCollectionViewLayout != NULL) {
        ((void (*)(id, SEL))OriginalASCollectionViewLayout)(receiver, selector);
    }
    if (receiver.window == nil) return;
    CGFloat height = CGRectGetHeight(receiver.bounds);
    if (height < 36.0 || height > 68.0) return;
    static BOOL notedChips;
    if (!notedChips) {
        for (UICollectionViewCell *cell in receiver.visibleCells) {
            for (NSString *identifier in WolFoxActionButtonIdentifiers(cell)) {
                if ([identifier containsString:@"like.button"]) notedChips = YES;
            }
        }
        if (notedChips) WolFoxNoteActionBarLayout(@"chips");
    }
    if (notedChips) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (UICollectionViewCell *cell in receiver.visibleCells) {
            for (NSString *preference in WolFoxActionPreferencesInCell(cell)) {
                NSString *name = [[preference componentsSeparatedByString:@"."].lastObject
                    stringByReplacingOccurrencesOfString:@"Hidden" withString:@""];
                if (name.length != 0) [names addObject:name];
            }
        }
        WolFoxNoteActionBarButtons(names);
    }
    if (!WolFoxAnyActionPreferenceEnabled()) return;

    NSArray<UICollectionViewCell *> *visible = [receiver.visibleCells
        sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewCell *left,
                                                       UICollectionViewCell *right) {
            NSIndexPath *leftPath = [receiver indexPathForCell:left];
            NSIndexPath *rightPath = [receiver indexPathForCell:right];
            if (leftPath != nil && rightPath != nil) {
                return [leftPath compare:rightPath];
            }
            CGFloat leftX = CGRectGetMinX(left.frame);
            CGFloat rightX = CGRectGetMinX(right.frame);
            if (leftX < rightX) return NSOrderedAscending;
            if (leftX > rightX) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    if (visible.count == 0) return;

    static NSUInteger layoutLogged = 0;
    CGFloat removedWidth = 0.0;
    NSUInteger matchedCells = 0;
    CGFloat leadingInset = 0.0;
    BOOL seenVisibleCell = NO;
    NSUInteger cellIndex = 0;
    for (UICollectionViewCell *cell in visible) {
        CGRect frame = cell.frame;
        NSArray<NSString *> *cellButtons = WolFoxActionButtonIdentifiers(cell);
        if (layoutLogged < 80 && cellButtons.count != 0) {
            layoutLogged++;
        }
        frame.origin.x -= removedWidth;
        BOOL pillBothHidden = NO;
        BOOL pill = WolFoxApplyPillHiding(cell, &pillBothHidden);
        NSSet<NSString *> *preferences = WolFoxActionPreferencesInCell(cell);
        if (pill && !pillBothHidden) {
            // Yoga already resized the pill; undo any old frame changes.
            preferences = [NSSet set];
            cell.hidden = NO;
            cell.userInteractionEnabled = YES;
            cell.clipsToBounds = NO;
            cell.contentView.clipsToBounds = NO;
        }
        if (preferences.count != 0) {
            matchedCells++;
            NSUInteger hiddenCount = 0;
            for (NSString *preference in preferences) {
                if (WolFoxFeatureEnabled(preference)) hiddenCount++;
            }
            if (hiddenCount != 0) {
                CGFloat oldWidth = CGRectGetWidth(frame);
                CGFloat measuredTotal = 0.0;
                CGFloat measuredLeading = 0.0;
                NSUInteger visibleButtons = 0;
                WolFoxHiddenActionWidths(cell, &measuredTotal,
                                         &measuredLeading, &visibleButtons,
                                         NULL, NULL);
                CGFloat newWidth = oldWidth;
                BOOL collapse = visibleButtons == 0;
                BOOL trailingOnly = measuredLeading <= 0.5 &&
                    measuredTotal > 0.5;
                if (collapse) {
                    newWidth = 0.0;
                } else if (trailingOnly) {
                    newWidth = floor(MAX(0.0, oldWidth - measuredTotal));
                }
                if (layoutLogged < 80) {
                    layoutLogged++;
                }
                removedWidth += oldWidth - newWidth;
                frame.size.width = newWidth;
                cell.hidden = collapse;
                cell.userInteractionEnabled = !collapse;
                cell.clipsToBounds = trailingOnly && !collapse;
                cell.contentView.clipsToBounds = cell.clipsToBounds;
                cell.contentView.transform = CGAffineTransformIdentity;
            } else {
                cell.hidden = NO;
                cell.userInteractionEnabled = YES;
                cell.clipsToBounds = NO;
                cell.contentView.clipsToBounds = NO;
                cell.contentView.transform = CGAffineTransformIdentity;
            }
        }
        if (cellIndex == 0) leadingInset = WolFoxCellLeadingInset(cell);
        if (!seenVisibleCell && !cell.hidden && CGRectGetWidth(frame) > 0.5) {
            seenVisibleCell = YES;
            if (cellIndex > 0 && leadingInset > 0.0 && removedWidth >= leadingInset) {
                frame.origin.x += leadingInset;
                removedWidth -= leadingInset;
            }
        }
        cellIndex++;
        cell.frame = frame;
    }

    if (matchedCells == 0 || removedWidth <= 0.0) return;

    CGSize contentSize = receiver.contentSize;
    contentSize.width = MAX(CGRectGetWidth(receiver.bounds),
                            contentSize.width - removedWidth);
    receiver.contentSize = contentSize;
}

static BOOL WolFoxEnsureActionCollectionLayoutHook(void) {
    if (OriginalASCollectionViewLayout != NULL) return YES;
    BOOL installed = WolFoxInstallInstanceHook(
        @"ASCollectionView", @"layoutSubviews",
        (IMP)WolFoxASCollectionViewLayout,
        &OriginalASCollectionViewLayout);
    if (installed && OriginalASCollectionViewLayout != NULL) return YES;
    return NO;
}

static void WolFoxScheduleStructuralActionHook(void) {
    NSArray<NSNumber *> *delays =
        @[@0.0, @0.5, @1.5, @3.0, @6.0, @9.0, @12.0, @18.0];
    for (NSNumber *delay in delays) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                WolFoxEnsureStructuralActionHook();
                WolFoxEnsureActionCellControllerHooks();
                WolFoxEnsureActionCollectionLayoutHook();
            }
        );
    }
}

static UICollectionView *WolFoxActionCollectionView(UIView *view) {
    for (UIView *candidate = view; candidate != nil; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UICollectionView.class]) {
            return (UICollectionView *)candidate;
        }
    }
    return nil;
}

static void WolFoxRefreshActionCollection(UIView *view) {
    if (!WolFoxEnsureActionCellControllerHooks()) return;
    UICollectionView *collectionView = WolFoxActionCollectionView(view);
    if (collectionView == nil || objc_getAssociatedObject(
            collectionView, WolFoxActionLayoutRefreshAssociation) != nil) {
        return;
    }
    objc_setAssociatedObject(collectionView,
                             WolFoxActionLayoutRefreshAssociation,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        [collectionView.collectionViewLayout invalidateLayout];
        [collectionView reloadData];
        [collectionView layoutIfNeeded];
    });
}

static BOOL WolFoxIsActionButtonIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSString *lower = identifier.lowercaseString;
    if (![lower hasPrefix:@"id."]) return NO;
    return [lower containsString:@"button"];
}

static NSArray<NSString *> *WolFoxActionButtonIdentifiers(UIView *view) {
    NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSet];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:view];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 160) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        if (WolFoxIsActionButtonIdentifier(node.accessibilityIdentifier)) {
            [found addObject:node.accessibilityIdentifier];
        }
        [pending addObjectsFromArray:node.subviews];
    }
    return found.array;
}

static void WolFoxHostCellCollapse(UIView *cell) {
    CGRect frame = cell.frame;
    if (frame.size.height == 0.0 && cell.hidden) return;
    frame.size.height = 0.0;
    cell.frame = frame;
    cell.hidden = YES;
    cell.userInteractionEnabled = NO;
    for (UIView *ancestor = cell.superview; ancestor != nil;
         ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UICollectionView.class]) {
            [((UICollectionView *)ancestor).collectionViewLayout invalidateLayout];
            break;
        }
    }
}

static void WolFoxCollapseHostCell(UIView *view) {
    if (view == nil) return;
    UIView *cell = view;
    while (cell != nil &&
           ![cell isKindOfClass:UICollectionViewCell.class] &&
           ![NSStringFromClass([cell class]) hasSuffix:@"CollectionViewCell"]) {
        cell = cell.superview;
    }
    view.hidden = YES;
    if (cell == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [view removeFromSuperview];
        });
        return;
    }
    BOOL associated = [objc_getAssociatedObject(
        cell, WolFoxHostCellAssociation) boolValue];
    objc_setAssociatedObject(cell, WolFoxHostCellAssociation, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!associated) atomic_fetch_add(&WolFoxHostCellCount, 1);
    WolFoxHostCellCollapse(cell);
}

static void WolFoxHostCellLayout(UIView *receiver, SEL selector) {
    if (OriginalContentHostCellLayout != NULL) {
        ((void (*)(id, SEL))OriginalContentHostCellLayout)(receiver, selector);
    }
    if (atomic_load(&WolFoxHostCellCount) == 0) return;
    if ([objc_getAssociatedObject(receiver, WolFoxHostCellAssociation) boolValue]) {
        WolFoxHostCellCollapse(receiver);
    }
}

static void WolFoxRestoreHiddenView(UIView *view) {
    NSNumber *baseline = objc_getAssociatedObject(
        view, WolFoxContentHiddenAssociation);
    if (baseline == nil) return;
    view.hidden = NO;
    view.userInteractionEnabled = YES;
    objc_setAssociatedObject(view,
                             WolFoxContentHiddenAssociation,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSUInteger WolFoxSizableChildCount(UIView *view) {
    NSUInteger count = 0;
    for (UIView *child in view.subviews) {
        if (child.hidden) continue;
        if (CGRectGetWidth(child.bounds) >= 40.0 &&
            CGRectGetHeight(child.bounds) >= 28.0) {
            count++;
        }
    }
    return count;
}

static void WolFoxActionCellPrepareForReuse(UIView *receiver, SEL selector) {
    if ([objc_getAssociatedObject(receiver, WolFoxHostCellAssociation) boolValue]) {
        objc_setAssociatedObject(receiver, WolFoxHostCellAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        atomic_fetch_sub(&WolFoxHostCellCount, 1);
        receiver.hidden = NO;
        receiver.userInteractionEnabled = YES;
    }
    NSNumber *baseline = objc_getAssociatedObject(
        receiver, WolFoxContentHiddenAssociation);
    if (baseline != nil) {
        receiver.hidden = NO;
        receiver.userInteractionEnabled = YES;
        objc_setAssociatedObject(receiver,
                                 WolFoxContentHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (OriginalActionCellPrepareForReuse != NULL) {
        ((void (*)(id, SEL))OriginalActionCellPrepareForReuse)(receiver, selector);
    }
}

static NSString *WolFoxBarSlotPreference(UIView *slot) {
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:slot];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 40) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        NSString *identifier = node.accessibilityIdentifier;
        if (WolFoxIsActionButtonIdentifier(identifier)) {
            NSString *preference =
                WolFoxPreferenceForButtonIdentifier(identifier);
            if (preference.length != 0) return preference;
        }
        if (node.accessibilityLabel.length != 0) {
            [labels addObject:node.accessibilityLabel.lowercaseString];
        }
        [pending addObjectsFromArray:node.subviews];
    }
    NSString *icon = WolFoxIconPreferenceInView(slot);
    if (icon.length != 0) return icon;
    NSString *joined = [labels componentsJoinedByString:@" "];
    if (joined.length == 0) return nil;
    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"YTKACE.Preference.ActionBar.DislikeHidden", @"dislike"],
        @[@"YTKACE.Preference.ActionBar.ShareHidden", @"share"],
        @[@"YTKACE.Preference.ActionBar.DownloadHidden", @"download"],
        @[@"YTKACE.Preference.ActionBar.SaveHidden", @"save"],
        @[@"YTKACE.Preference.ActionBar.ClipHidden", @"clip"],
        @[@"YTKACE.Preference.ActionBar.RemixHidden", @"remix"],
        @[@"YTKACE.Preference.ActionBar.ThanksHidden", @"thanks"],
        @[@"YTKACE.Preference.ActionBar.HypeHidden", @"hype"],
        @[@"YTKACE.Preference.ActionBar.ReportHidden", @"report"],
        @[@"YTKACE.Preference.ActionBar.AskHidden", @"ask"],
        @[@"YTKACE.Preference.ActionBar.OverflowHidden", @"overflow"],
        @[@"YTKACE.Preference.ActionBar.LikeHidden", @"like"]
    ];
    for (NSArray<NSString *> *rule in rules) {
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([joined containsString:rule[index]]) return rule.firstObject;
        }
    }
    return nil;
}

static void WolFoxFixedBarLayoutSubviews(UIView *receiver, SEL selector) {
    if (OriginalFixedBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalFixedBarLayout)(receiver, selector);
    }
    CGFloat height = CGRectGetHeight(receiver.bounds);
    if (height < 36.0 || height > 68.0) return;
    NSArray<UIView *> *slots = receiver.subviews;
    if (slots.count < 3 || slots.count > 10) return;
    NSString *identifier = receiver.accessibilityIdentifier;
    if (![identifier containsString:@"non_scrollable_action_bar"]) return;
    WolFoxNoteActionBarLayout(@"fixed");
    NSArray *order = WolFoxPreferenceObject(@"YTKACE.Preference.ActionBar.Order");
    if (![order isKindOfClass:NSArray.class]) order = nil;
    if (!WolFoxAnyActionPreferenceEnabled() && order.count == 0) return;

    CGFloat barWidth = CGRectGetWidth(receiver.bounds);
    if (barWidth <= 0.0) return;
    // Buttons that didn't fit are zero wide (they're in ⋯); only the
    // laid-out ones count.
    NSMutableArray<UIView *> *laidOut = [NSMutableArray array];
    CGFloat naturalSlot = 0.0;
    for (UIView *slot in slots) {
        if (CGRectGetWidth(slot.frame) < 1.0) continue;
        [laidOut addObject:slot];
        naturalSlot = MAX(naturalSlot, CGRectGetWidth(slot.frame));
    }
    if (laidOut.count == 0) return;
    slots = laidOut;
    // ⋯ items moved into the bar (ActionBarModel.mm) are menu rows with 16pt
    // side padding; a bar button's icon sits about 8.5pt in.
    for (UIView *slot in slots) {
        NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:slot];
        for (NSUInteger visited = 0; pending.count != 0 && visited < 12; visited++) {
            UIView *view = pending.firstObject;
            [pending removeObjectAtIndex:0];
            if ([view.accessibilityIdentifier isEqualToString:@"id.elements.list_item"]) {
                id node = WolFoxActionNodeGet(view, @"asyncdisplaykit_node");
                id style = WolFoxActionNodeGet(node, @"style");
                SEL getter = NSSelectorFromString(@"padding"), setter = NSSelectorFromString(@"setPadding:");
                if ([style respondsToSelector:getter] && [style respondsToSelector:setter]) {
                    WolFoxActionEdges padding = ((WolFoxActionEdges (*)(id, SEL))objc_msgSend)(style, getter);
                    if (padding.horizontal.unit == 1 && padding.horizontal.value > 9.0) {
                        padding.horizontal.value = 8.5;
                        ((void (*)(id, SEL, WolFoxActionEdges))objc_msgSend)(style, setter, padding);
                        WolFoxActionNodeRelayout(node);
                    }
                }
                break;
            }
            [pending addObjectsFromArray:view.subviews];
        }
    }
    NSMutableArray<UIView *> *keep = [NSMutableArray array];
    NSMapTable<UIView *, NSString *> *names = [NSMapTable strongToStrongObjectsMapTable];
    NSMutableArray<NSString *> *trace = [NSMutableArray array];
    for (UIView *slot in slots) {
        NSString *preference = WolFoxBarSlotPreference(slot);
        BOOL hidden = preference.length != 0 &&
            WolFoxFeatureEnabled(preference);
        [trace addObject:[NSString stringWithFormat:@"%@%@",
            preference.length == 0 ? @"-"
                : [preference componentsSeparatedByString:@"."].lastObject,
            hidden ? @"!" : @""]];
        if (!hidden) [keep addObject:slot];
        // "YTKACE.Preference.ActionBar.LikeHidden" -> "Like"
        NSString *name = [[preference componentsSeparatedByString:@"."].lastObject
            stringByReplacingOccurrencesOfString:@"Hidden" withString:@""];
        if (name.length != 0) [names setObject:name forKey:slot];
        // Hide here too: a button matched by its icon name may only be
        // recognised after the other hiding paths have already run.
        slot.hidden = hidden;
        slot.userInteractionEnabled = !hidden;
    }
    if (keep.count == 0 || (keep.count == slots.count && order.count == 0)) return;

    // Saved order first; buttons the order doesn't name keep YouTube's order
    // after them. Slots we can't name (⋯ items the model already moved into
    // place) stay where they are; only the named ones swap among themselves.
    if (order.count != 0) {
        NSMutableArray<UIView *> *named = [NSMutableArray array];
        NSMutableIndexSet *namedPositions = [NSMutableIndexSet indexSet];
        for (NSUInteger index = 0; index < keep.count; index++) {
            if ([names objectForKey:keep[index]] == nil) continue;
            [named addObject:keep[index]];
            [namedPositions addIndex:index];
        }
        NSArray<UIView *> *natural = [named copy];
        [named sortUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
            NSUInteger leftRank = [order indexOfObject:[names objectForKey:left] ?: @""];
            NSUInteger rightRank = [order indexOfObject:[names objectForKey:right] ?: @""];
            if (leftRank == NSNotFound) leftRank = order.count + [natural indexOfObject:left];
            if (rightRank == NSNotFound) rightRank = order.count + [natural indexOfObject:right];
            if (leftRank < rightRank) return NSOrderedAscending;
            if (leftRank > rightRank) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        [keep replaceObjectsAtIndexes:namedPositions withObjects:named];
    }

    // Keep YouTube's slot width and pack the remaining buttons to the right
    // edge, instead of stretching them across the whole bar.
    CGFloat x = barWidth - (CGFloat)keep.count * naturalSlot;
    for (UIView *slot in keep) {
        CGRect frame = slot.frame;
        frame.size.width = naturalSlot;
        frame.origin.x = x;
        x += naturalSlot;
        slot.frame = frame;
    }

    static NSTimeInterval lastLog = 0.0;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    static NSString *lastTrace = nil;
    NSMutableArray<NSString *> *final = [NSMutableArray array];
    for (UIView *slot in keep) [final addObject:[names objectForKey:slot] ?: @"?"];
    NSString *line = [NSString stringWithFormat:@"fixed slots=%@ final=%@ order=%@",
        [trace componentsJoinedByString:@","], [final componentsJoinedByString:@","],
        [order componentsJoinedByString:@","]];
    if (now - lastLog > 2.0 || ![line isEqualToString:lastTrace]) {
        lastLog = now;
        lastTrace = line;
        WolFoxDebugLog(@"actionbar", @"%@", line);
    }
}

static void WolFoxEnsureFixedBarHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WolFoxInstallInstanceHook(
            @"_ASDisplayView",
            @"layoutSubviews",
            (IMP)WolFoxFixedBarLayoutSubviews,
            &OriginalFixedBarLayout
        );
    });
}

static void WolFoxEnsureActionCellReuseHook(void) {
    WolFoxEnsureIconNameHooks();
    WolFoxEnsureFixedBarHook();
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WolFoxInstallInstanceHook(
            @"_ASCollectionViewCell",
            @"layoutSubviews",
            (IMP)WolFoxHostCellLayout,
            &OriginalContentHostCellLayout
        );
        WolFoxInstallInstanceHook(
            @"_ASCollectionViewCell",
            @"prepareForReuse",
            (IMP)WolFoxActionCellPrepareForReuse,
            &OriginalActionCellPrepareForReuse
        );
    });
}

static UIView *WolFoxActionContainer(UIView *view) {
    if (WolFoxIsActionButtonIdentifier(view.accessibilityIdentifier)) {
        return view;
    }
    UIView *candidate = view;
    UIView *best = view;
    for (NSUInteger index = 0; candidate.superview != nil && index < 7; index++) {
        UIView *parent = candidate.superview;
        NSArray<NSString *> *buttons = WolFoxActionButtonIdentifiers(parent);
        NSUInteger sizable = WolFoxSizableChildCount(parent);
        if ([parent isKindOfClass:UIStackView.class]) {
            WolFoxRestoreHiddenView(parent);
            best = candidate;
            break;
        }
        CGFloat width = CGRectGetWidth(parent.bounds);
        CGFloat height = CGRectGetHeight(parent.bounds);
        if (width <= 0.0 || height <= 0.0) {
            break;
        }
        if (width > 180.0 || height > 130.0) {
            break;
        }
        if (buttons.count > 1 || sizable > 1) {
            WolFoxRestoreHiddenView(parent);
            break;
        }
        best = parent;
        candidate = parent;
    }
    return best;
}

static void WolFoxCompactFixedActionGroup(UIView *target) {
    UIView *group = target.superview;
    if (group == nil || CGRectGetHeight(group.bounds) < 40.0 ||
        CGRectGetHeight(group.bounds) > 56.0 ||
        CGRectGetWidth(group.bounds) < 160.0 ||
        CGRectGetWidth(group.bounds) > 260.0) {
        return;
    }
    if (objc_getAssociatedObject(group,
            WolFoxActionGroupCompactAssociation) != nil) {
        return;
    }
    objc_setAssociatedObject(group,
                             WolFoxActionGroupCompactAssociation,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakGroup = group;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongGroup = weakGroup;
        if (strongGroup == nil) return;
        NSArray<UIView *> *slots = [strongGroup.subviews
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(UIView *view, __unused NSDictionary *bindings) {
                    CGFloat width = CGRectGetWidth(view.frame);
                    CGFloat height = CGRectGetHeight(view.frame);
                    return width >= 32.0 && width <= 56.0 &&
                           height >= 40.0 && height <= 56.0;
                }]];
        slots = [slots sortedArrayUsingComparator:
            ^NSComparisonResult(UIView *left, UIView *right) {
                CGFloat leftX = CGRectGetMinX(left.frame);
                CGFloat rightX = CGRectGetMinX(right.frame);
                if (leftX < rightX) return NSOrderedAscending;
                if (leftX > rightX) return NSOrderedDescending;
                return NSOrderedSame;
            }];
        if (slots.count < 3) {
            objc_setAssociatedObject(strongGroup,
                                     WolFoxActionGroupCompactAssociation,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        CGFloat cursor = CGRectGetMinX(slots.firstObject.frame);
        for (UIView *slot in slots) {
            if (slot.hidden || slot.alpha <= 0.01) continue;
            CGRect frame = slot.frame;
            frame.origin.x = cursor;
            slot.frame = frame;
            cursor += CGRectGetWidth(frame);
        }
        objc_setAssociatedObject(strongGroup,
                                 WolFoxActionGroupCompactAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

static NSArray *WolFoxFilterActionButtons(id receiver, SEL selector,
                                           IMP original) {
    NSArray *items = original == NULL ? nil :
        ((id (*)(id, SEL))original)(receiver, selector);
    if (![items isKindOfClass:NSArray.class] || items.count == 0) return items;
    if (!WolFoxAnyActionPreferenceEnabled()) return items;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        NSString *preference = WolFoxActionPreference(item);
        if (preference.length != 0 && WolFoxFeatureEnabled(preference)) continue;
        [filtered addObject:item];
    }
    return filtered.count == items.count ? items : filtered;
}

static void WolFoxActionViewDidMove(UIView *receiver, SEL selector) {
    if (OriginalActionViewDidMove != NULL) {
        ((void (*)(id, SEL))OriginalActionViewDidMove)(receiver, selector);
    }
}

static void WolFoxActionsViewDidMove(UIView *receiver, SEL selector) {
    if (OriginalActionsViewDidMove != NULL) {
        ((void (*)(id, SEL))OriginalActionsViewDidMove)(receiver, selector);
    }
}

static void WolFoxActionCellDidMove(UIView *receiver, SEL selector) {
    if (OriginalActionCellDidMove != NULL) {
        ((void (*)(id, SEL))OriginalActionCellDidMove)(receiver, selector);
    }
}

#define WOLFOX_ACTION_WRAPPER(name, storage) \
static NSArray *name(id receiver, SEL selector) { \
    return WolFoxFilterActionButtons(receiver, selector, storage); \
}

WOLFOX_ACTION_WRAPPER(WolFoxScrollableActionButtonsArray, OriginalScrollableActionButtonsArray)
WOLFOX_ACTION_WRAPPER(WolFoxScrollableActionBarButtonsArray, OriginalScrollableActionBarButtonsArray)
WOLFOX_ACTION_WRAPPER(WolFoxScrollableButtonsArray, OriginalScrollableButtonsArray)
WOLFOX_ACTION_WRAPPER(WolFoxScrollableActionsArray, OriginalScrollableActionsArray)
WOLFOX_ACTION_WRAPPER(WolFoxActionButtonsArray, OriginalActionButtonsArray)
WOLFOX_ACTION_WRAPPER(WolFoxActionBarButtonsArray, OriginalActionBarButtonsArray)
WOLFOX_ACTION_WRAPPER(WolFoxButtonsArray, OriginalButtonsArray)
WOLFOX_ACTION_WRAPPER(WolFoxActionsArray, OriginalActionsArray)

static id WolFoxContentValue(id object, NSString *key) {
    if (object == nil || key.length == 0) {
        return nil;
    }
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

static BOOL WolFoxClassContains(id object, NSArray<NSString *> *needles);


/// Field names on `cls` whose name matches something we filter, paired with the
/// generated -has<Field> selector. Computed once per class.



static const void *WolFoxStructuralTokenAssociation =
    &WolFoxStructuralTokenAssociation;




static const void *WolFoxClassTokenAssociation = &WolFoxClassTokenAssociation;

static NSString *WolFoxClassToken(id object) {
    if (object == nil) return @"";
    NSString *cached = objc_getAssociatedObject(object,
                                                WolFoxClassTokenAssociation);
    if (cached != nil) return cached;
    NSString *value = NSStringFromClass([object class]).lowercaseString;
    if (value == nil) value = @"";
    objc_setAssociatedObject(object, WolFoxClassTokenAssociation, value,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    return value;
}

__attribute__((unused))
static BOOL WolFoxClassLooksLikeContainer(id object) {
    NSString *token = WolFoxClassToken(object);
    return [token containsString:@"shelfrenderer"] ||
           [token containsString:@"richsectionrenderer"] ||
           [token containsString:@"itemsectionrenderer"] ||
           [token containsString:@"richshelfrenderer"] ||
           [token containsString:@"sectionrenderer"] ||
           [token containsString:@"elementrenderer"];
}

static BOOL WolFoxClassContains(id object, NSArray<NSString *> *needles) {
    NSString *token = WolFoxClassToken(object);
    if (token.length == 0) return NO;
    for (NSString *needle in needles) {
        if ([token containsString:needle]) return YES;
    }
    return NO;
}

__attribute__((unused))
static BOOL WolFoxChildClassContains(id section, NSArray<NSString *> *needles) {
    NSArray *entries = WolFoxContentValue(section, @"contentsArray");
    if ([entries isKindOfClass:NSArray.class]) {
        for (id entry in entries) {
            if (WolFoxClassContains(entry, needles)) return YES;
        }
    }
    return NO;
}

static const NSUInteger WolFoxFeedChildScanLimit = 64;

static _Atomic BOOL WolFoxFeedHideShorts = NO;
static _Atomic BOOL WolFoxFeedKeepHomeShorts = NO;
static _Atomic BOOL WolFoxFeedKeepSubsShorts = NO;
static _Atomic BOOL WolFoxFeedKeepSearchShorts = NO;
static _Atomic BOOL WolFoxFeedKeepChannelShorts = NO;
static _Atomic BOOL WolFoxFeedHideProducts = NO;
static _Atomic BOOL WolFoxFeedHideCommunity = NO;
static _Atomic BOOL WolFoxFeedHideHorizontalShelves = NO;
static _Atomic BOOL WolFoxFeedHideMixes = NO;
static _Atomic BOOL WolFoxFeedHideHomeLive = NO;
static _Atomic BOOL WolFoxFeedHidePlayables = NO;
static _Atomic BOOL WolFoxFeedHideAIBlock = NO;
static _Atomic BOOL WolFoxFeedHideAIWarn = NO;
static _Atomic BOOL WolFoxFeedHideAny = NO;
static _Atomic BOOL WolFoxFeedActionHideAny = NO;
static _Atomic BOOL WolFoxContentHideAny = NO;

static void WolFoxFeedRefreshFlags(void) {
    BOOL hideShorts =
        WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.FeedHidden");
    BOOL hideProducts =
        WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden");
    BOOL hideCommunity =
        WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.CommunityPostsHidden");
    BOOL hideHorizontalShelves =
        WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.HorizontalShelvesHidden");
    BOOL hideMixes =
        WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.MixesHidden");
    BOOL hideHomeLive =
        WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.HomeLiveHidden");
    BOOL hidePlayables =
        WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.PlayablesHidden");
    BOOL hideAIBlock = WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.AIChannelsHidden");
    BOOL hideAIWarn = WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.SuspectedAIChannelsHidden");
    if (hideAIBlock || hideAIWarn) WolFoxAiSListRefreshIfStale();
    BOOL hideAny = (hideShorts || hideProducts || hideHomeLive ||
        hideCommunity || hideHorizontalShelves || hideMixes || hidePlayables || hideAIBlock || hideAIWarn);
    BOOL actionHideAny = WolFoxAnyActionPreferenceEnabled();
    BOOL contentHideAny = (hideAny ||
        actionHideAny ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.CommentsHidden") ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.CommentPreviewsHidden") ||
        WolFoxShortsSuggestionPillHidden() ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.CommentGuidelinesHidden") ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.TopicsHidden") ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Privacy.SearchHistoryDisabled") ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Ads.PremiumPromosHidden") ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.App.UpdatePromptHidden") ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.SuggestedVideosHidden") ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ContinueWatchingDisabled") ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.PauseCardHidden") ||
        WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.StickerAdsHidden"));
    atomic_store(&WolFoxFeedHideShorts, hideShorts);
    atomic_store(&WolFoxFeedKeepHomeShorts,
        WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.HomeKept"));
    atomic_store(&WolFoxFeedKeepSubsShorts,
        WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.SubscriptionsKept"));
    atomic_store(&WolFoxFeedKeepSearchShorts,
        WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.SearchKept"));
    atomic_store(&WolFoxFeedKeepChannelShorts,
        WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.ChannelsKept"));
    atomic_store(&WolFoxFeedHideProducts, hideProducts);
    atomic_store(&WolFoxFeedHideCommunity, hideCommunity);
    atomic_store(&WolFoxFeedHideHorizontalShelves, hideHorizontalShelves);
    atomic_store(&WolFoxFeedHideMixes, hideMixes);
    atomic_store(&WolFoxFeedHideHomeLive, hideHomeLive);
    atomic_store(&WolFoxFeedHidePlayables, hidePlayables);
    atomic_store(&WolFoxFeedHideAIBlock, hideAIBlock);
    atomic_store(&WolFoxFeedHideAIWarn, hideAIWarn);
    atomic_store(&WolFoxFeedHideAny, hideAny);
    atomic_store(&WolFoxFeedActionHideAny, actionHideAny);
    atomic_store(&WolFoxContentHideAny, contentHideAny);
}

static void WolFoxFeedScheduleRefresh(void) {
    static BOOL pending = NO;
    if (pending) return;
    pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        pending = NO;
        WolFoxFeedRefreshFlags();
    });
}

static void WolFoxFeedEnsureFlagObserver(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WolFoxFeedRefreshFlags();
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:WolFoxPreferencesDidChangeNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
                            WolFoxFeedScheduleRefresh();
                        }];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
                            WolFoxFeedScheduleRefresh();
                        }];
    });
}

static SEL WolFoxSelContentsArray;
static SEL WolFoxSelItemsArray;
static SEL WolFoxSelContent;
static SEL WolFoxSelElementRenderer;
static SEL WolFoxSelShelfRenderer;
static SEL WolFoxSelHorizontalListRenderer;
static SEL WolFoxSelItemSectionRenderer;
static SEL WolFoxSelExpandedShelfContentsRenderer;
static SEL WolFoxSelElementIdentifier;
static SEL WolFoxSelSharedElementIdentifier;
static SEL WolFoxSelData;
static SEL WolFoxSelHasReelItemRenderer;
static SEL WolFoxSelHasMerchShelfRenderer;
static SEL WolFoxSelHasMerchItemRenderer;
static SEL WolFoxSelHasCommunity[5];
static SEL WolFoxSelHasGame[2];
static SEL WolFoxFeedContainerSels[8];

static void WolFoxFeedInitSels(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WolFoxSelContentsArray = @selector(contentsArray);
        WolFoxSelItemsArray = @selector(itemsArray);
        WolFoxSelContent = @selector(content);
        WolFoxSelElementRenderer = @selector(elementRenderer);
        WolFoxSelShelfRenderer = @selector(shelfRenderer);
        WolFoxSelHorizontalListRenderer = @selector(horizontalListRenderer);
        WolFoxSelItemSectionRenderer = @selector(itemSectionRenderer);
        WolFoxSelExpandedShelfContentsRenderer =
            @selector(expandedShelfContentsRenderer);
        WolFoxSelElementIdentifier = @selector(elementIdentifier);
        WolFoxSelSharedElementIdentifier = @selector(sharedElementIdentifier);
        WolFoxSelData = @selector(data);
        WolFoxSelHasReelItemRenderer = @selector(hasReelItemRenderer);
        WolFoxSelHasMerchShelfRenderer =
            @selector(hasMerchandiseShelfRenderer);
        WolFoxSelHasMerchItemRenderer =
            @selector(hasMerchandiseItemRenderer);
        WolFoxSelHasCommunity[0] =
            @selector(hasCommunityPostSectionRenderer);
        WolFoxSelHasCommunity[1] = @selector(hasCommunityPost);
        WolFoxSelHasCommunity[2] =
            @selector(hasBackstagePostElementRenderer);
        WolFoxSelHasCommunity[3] = @selector(hasPostsContainerRenderer);
        WolFoxSelHasCommunity[4] =
            @selector(hasChannelPostBulletinRenderer);
        WolFoxSelHasGame[0] = @selector(hasGameCardRenderer);
        WolFoxSelHasGame[1] = @selector(hasGameDetailsRenderer);
        WolFoxFeedContainerSels[0] = WolFoxSelContentsArray;
        WolFoxFeedContainerSels[1] = WolFoxSelItemsArray;
        WolFoxFeedContainerSels[2] = WolFoxSelContent;
        WolFoxFeedContainerSels[3] = WolFoxSelElementRenderer;
        WolFoxFeedContainerSels[4] = WolFoxSelShelfRenderer;
        WolFoxFeedContainerSels[5] = WolFoxSelHorizontalListRenderer;
        WolFoxFeedContainerSels[6] = WolFoxSelItemSectionRenderer;
        WolFoxFeedContainerSels[7] =
            WolFoxSelExpandedShelfContentsRenderer;
    });
}

static inline BOOL WolFoxFastHasSel(id object, SEL selector) {
    if (object == nil || selector == NULL) return NO;
    if (![object respondsToSelector:selector]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static inline BOOL WolFoxFastHasAnySel(id object, SEL *selectors,
                                       NSUInteger count) {
    for (NSUInteger i = 0; i < count; i++) {
        if (WolFoxFastHasSel(object, selectors[i])) return YES;
    }
    return NO;
}

static inline id WolFoxFastChildSel(id object, SEL selector) {
    if (object == nil || selector == NULL) return nil;
    if (![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray *WolFoxFastContents(id object) {
    if (object == nil) return nil;
    WolFoxFeedInitSels();
    id value = WolFoxFastChildSel(object, WolFoxSelContentsArray);
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static BOOL WolFoxFastEntryMatchesSel(id entry,
                                      SEL *flags, NSUInteger flagCount,
                                      NSArray<NSString *> *classes) {
    if (entry == nil) return NO;
    if (classes != nil && WolFoxClassContains(entry, classes)) return YES;
    if (flags != NULL && flagCount != 0 &&
        WolFoxFastHasAnySel(entry, flags, flagCount)) {
        return YES;
    }
    id nested = WolFoxFastChildSel(entry, WolFoxSelElementRenderer);
    if (nested != nil && nested != entry) {
        if (classes != nil && WolFoxClassContains(nested, classes)) return YES;
        if (flags != NULL && flagCount != 0 &&
            WolFoxFastHasAnySel(nested, flags, flagCount)) {
            return YES;
        }
    }
    return NO;
}

static BOOL WolFoxFastIdentifierMatches(id object,
                                         NSArray<NSString *> *markers) {
    if (object == nil || markers == nil || markers.count == 0) return NO;
    WolFoxFeedInitSels();
    SEL keys[2] = { WolFoxSelElementIdentifier,
                    WolFoxSelSharedElementIdentifier };
    for (NSUInteger k = 0; k < 2; k++) {
        id value = WolFoxFastChildSel(object, keys[k]);
        if (![value isKindOfClass:NSString.class] ||
            ((NSString *)value).length == 0) {
            continue;
        }
        NSString *valueStr = (NSString *)value;
        if ([valueStr rangeOfString:@"."].location == NSNotFound &&
            [valueStr canBeConvertedToEncoding:NSASCIIStringEncoding]) {
            for (NSString *marker in markers) {
                if (marker.length != 0 &&
                    [valueStr rangeOfString:marker
                                    options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
            }
        } else {
            NSString *token = [[valueStr lowercaseString]
                stringByReplacingOccurrencesOfString:@"." withString:@"_"];
            for (NSString *marker in markers) {
                if (marker.length != 0 && [token containsString:marker]) return YES;
            }
        }
    }
    return NO;
}

typedef NS_OPTIONS(NSUInteger, WolFoxFeedKind) {
    WolFoxFeedKindShorts    = 1 << 0,
    WolFoxFeedKindProducts  = 1 << 1,
    WolFoxFeedKindCommunity = 1 << 2,
    WolFoxFeedKindPlayable  = 1 << 3,
    WolFoxFeedKindHorizontalShelves = 1 << 4,
    WolFoxFeedKindLive      = 1 << 5,
};

static NSArray<NSString *> *WolFoxShortsClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"reelitemrenderer"]; });
    return v;
}
static NSArray<NSString *> *WolFoxShortsIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"shorts_shelf", @"reel_shelf",
        @"shorts_lockup", @"shortslockup",
        @"shorts_video_cell", @"reelwatchendpoint"]; });
    return v;
}
static NSArray<NSString *> *WolFoxProductsClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"merchandiseshelfrenderer",
        @"merchandiseitemrenderer"]; });
    return v;
}
static NSArray<NSString *> *WolFoxProductsIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"merchandise_shelf", @"merchandise_item",
        @"product_shelf", @"products_shelf", @"shopping_shelf",
        @"product_in_video", @"products_in_video",
        @"promoted_sparkles_text_product"]; });
    return v;
}
static NSArray<NSString *> *WolFoxCommunityClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"communitypostsectionrenderer",
        @"postscontainerrenderer", @"communitypostrenderer",
        @"backstagepostrenderer", @"backstageimagerenderer",
        @"sharedpostrenderer"]; });
    return v;
}
static NSArray<NSString *> *WolFoxCommunityIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"community_post", @"communitypost",
        @"backstage"]; });
    return v;
}
static NSArray<NSString *> *WolFoxPlayableClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"playablesshelfrenderer",
        @"playableitemrenderer", @"compactboxgamerenderer",
        @"playablegamerenderer", @"gamecardrenderer",
        @"gamedetailsrenderer"]; });
    return v;
}
static NSArray<NSString *> *WolFoxPlayableIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"playables_shelf", @"playableshelf",
        @"playable_game", @"playablegame",
        @"horizontal_gaming_shelf", @"mini_game_card"]; });
    return v;
}

static BOOL WolFoxFastShouldDescend(id object) {
    if (object == nil) return NO;
    if ([object isKindOfClass:NSString.class] ||
        [object isKindOfClass:NSNumber.class] ||
        [object isKindOfClass:NSData.class] ||
        [object isKindOfClass:NSDate.class] ||
        [object isKindOfClass:NSValue.class] ||
        [object isKindOfClass:NSURL.class]) {
        return NO;
    }
    return YES;
}

static inline WolFoxFeedKind WolFoxFeedKindForNode(id node,
                                                  WolFoxFeedKind wanted) {
    WolFoxFeedKind found = 0;
    if (wanted & WolFoxFeedKindShorts) {
        if (WolFoxClassContains(node, WolFoxShortsClasses()) ||
            WolFoxFastHasSel(node, WolFoxSelHasReelItemRenderer) ||
            WolFoxFastIdentifierMatches(node, WolFoxShortsIdentifiers())) {
            found |= WolFoxFeedKindShorts;
        } else {
            id nested = WolFoxFastChildSel(node, WolFoxSelElementRenderer);
            if (nested != nil && nested != node &&
                (WolFoxClassContains(nested, WolFoxShortsClasses()) ||
                 WolFoxFastHasSel(nested, WolFoxSelHasReelItemRenderer))) {
                found |= WolFoxFeedKindShorts;
            }
        }
    }
    if ((wanted & WolFoxFeedKindProducts) && !(found & WolFoxFeedKindProducts)) {
        SEL f[2] = { WolFoxSelHasMerchShelfRenderer,
                     WolFoxSelHasMerchItemRenderer };
        if (WolFoxFastEntryMatchesSel(node, f, 2,
                                      WolFoxProductsClasses()) ||
            WolFoxFastIdentifierMatches(node,
                                        WolFoxProductsIdentifiers())) {
            found |= WolFoxFeedKindProducts;
        }
    }
    if ((wanted & WolFoxFeedKindCommunity) &&
        !(found & WolFoxFeedKindCommunity)) {
        if (WolFoxFastEntryMatchesSel(node, WolFoxSelHasCommunity, 5,
                                      WolFoxCommunityClasses()) ||
            WolFoxFastIdentifierMatches(node,
                                        WolFoxCommunityIdentifiers())) {
            found |= WolFoxFeedKindCommunity;
        }
    }
    if ((wanted & WolFoxFeedKindPlayable) &&
        !(found & WolFoxFeedKindPlayable)) {
        if (WolFoxFastEntryMatchesSel(node, WolFoxSelHasGame, 2,
                                      WolFoxPlayableClasses()) ||
            WolFoxFastIdentifierMatches(node,
                                        WolFoxPlayableIdentifiers())) {
            found |= WolFoxFeedKindPlayable;
        }
    }
    return found;
}

static WolFoxFeedKind WolFoxFeedKindStructural(id section,
                                              WolFoxFeedKind wanted,
                                              BOOL *outTruncated) {
    if (outTruncated != NULL) *outTruncated = NO;
    if (section == nil || wanted == 0) return 0;
    WolFoxFeedInitSels();
    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality |
        NSPointerFunctionsWeakMemory];
    NSMutableArray *pending = [NSMutableArray arrayWithObject:section];
    NSMutableArray *depths = [NSMutableArray arrayWithObject:@0];
    WolFoxFeedKind found = 0;
    NSUInteger scanned = 0;
    while (pending.count != 0 && pending.count < 4096) {
        if (scanned >= WolFoxFeedChildScanLimit) {
            if (outTruncated != NULL) *outTruncated = YES;
            break;
        }
        id node = pending.lastObject;
        [pending removeLastObject];
        NSNumber *depth = depths.lastObject;
        [depths removeLastObject];
        if (node == nil || [visited containsObject:node]) continue;
        [visited addObject:node];
        scanned++;
        found |= WolFoxFeedKindForNode(node, wanted & ~found);
        if ((found & wanted) == wanted) return found;
        if (depth.unsignedIntegerValue >= 3) continue;
        NSNumber *next = @(depth.unsignedIntegerValue + 1);
        if ([node isKindOfClass:NSArray.class]) {
            for (id child in (NSArray *)node) {
                if (!WolFoxFastShouldDescend(child)) continue;
                if ([visited containsObject:child]) continue;
                [pending addObject:child];
                [depths addObject:next];
            }
            continue;
        }
        if (!WolFoxFastShouldDescend(node)) continue;
        for (NSUInteger i = 0; i < 8; i++) {
            id child = WolFoxFastChildSel(node, WolFoxFeedContainerSels[i]);
            if (child == nil || child == node) continue;
            if ([child isKindOfClass:NSArray.class]) {
                for (id grand in (NSArray *)child) {
                    if (!WolFoxFastShouldDescend(grand)) continue;
                    if ([visited containsObject:grand]) continue;
                    [pending addObject:grand];
                    [depths addObject:next];
                }
            } else {
                if (!WolFoxFastShouldDescend(child)) continue;
                if ([visited containsObject:child]) continue;
                [pending addObject:child];
                [depths addObject:next];
            }
        }
    }
    return found;
}

static BOOL WolFoxFastEntryIsReel(id entry) {
    if (entry == nil) return NO;
    WolFoxFeedInitSels();
    if (WolFoxClassContains(entry, WolFoxShortsClasses())) return YES;
    if (WolFoxFastHasSel(entry, WolFoxSelHasReelItemRenderer)) return YES;
    id nested = WolFoxFastChildSel(entry, WolFoxSelElementRenderer);
    if (nested != nil && nested != entry) {
        if (WolFoxClassContains(nested, WolFoxShortsClasses())) return YES;
        if (WolFoxFastHasSel(nested, WolFoxSelHasReelItemRenderer)) return YES;
    }
    return NO;
}

static BOOL WolFoxFastAllChildrenReel(id section) {
    NSArray *entries = WolFoxFastContents(section);
    if (![entries isKindOfClass:NSArray.class] || entries.count == 0) return NO;
    for (id entry in entries) {
        if (!WolFoxFastEntryIsReel(entry)) return NO;
    }
    return YES;
}



static const void *WolFoxNormalizedDescriptionAssociation =
    &WolFoxNormalizedDescriptionAssociation;

static NSString *WolFoxNormalizedDescription(id object) {
    if (object == nil) return @"";
    NSString *cached = objc_getAssociatedObject(
        object, WolFoxNormalizedDescriptionAssociation);
    if (cached != nil) return cached;
    NSString *value = [[[object description] lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    if (value == nil) value = @"";
    objc_setAssociatedObject(object, WolFoxNormalizedDescriptionAssociation, value,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return value;
}

static const void *WolFoxSectionBytesAssociation =
    &WolFoxSectionBytesAssociation;

static NSData *WolFoxSectionBytes(id section) {
    if (section == nil) return nil;
    NSData *cached = objc_getAssociatedObject(section,
                                              WolFoxSectionBytesAssociation);
    if (cached != nil) {
        return cached.length == 0 ? nil : cached;
    }
    WolFoxFeedInitSels();
    id data = WolFoxFastChildSel(section, WolFoxSelData);
    if (![data isKindOfClass:NSData.class]) data = nil;
    objc_setAssociatedObject(section, WolFoxSectionBytesAssociation,
                             data ?: [NSData data],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return data;
}

static NSData *WolFoxDescendantBytes(id section) {
    WolFoxFeedInitSels();
    NSMutableData *combined = nil;
    for (NSUInteger i = 0; i < 8; i++) {
        id child = WolFoxFastChildSel(section, WolFoxFeedContainerSels[i]);
        if (child == nil) continue;
        NSArray *entries = [child isKindOfClass:NSArray.class]
            ? (NSArray *)child : @[child];
        NSUInteger taken = 0;
        for (id entry in entries) {
            if (taken >= 12) break;
            taken++;
            NSData *bytes = WolFoxSectionBytes(entry);
            if (bytes.length == 0) continue;
            if (combined == nil) combined = [NSMutableData data];
            [combined appendData:bytes];
        }
    }
    return combined;
}


static BOOL WolFoxBytesContain(NSData *haystack, NSArray<NSString *> *needles) {
    if (haystack.length == 0) return NO;
    for (NSString *needle in needles) {
        if ([needle containsString:@"renderer"] &&
            ![needle containsString:@"_"]) {
            continue;  // class-name style marker, never present in the wire form
        }
        NSData *pattern = [needle dataUsingEncoding:NSASCIIStringEncoding];
        if (pattern.length == 0) continue;
        if ([haystack rangeOfData:pattern
                           options:0
                             range:NSMakeRange(0, haystack.length)].location
                != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *WolFoxProductsMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"merchandise_shelf", @"merchandise_item",
        @"product_shelf", @"products_shelf", @"shopping_shelf",
        @"shopping_description_shelf",
        @"promoted_sparkles_text_product_watch",
        @"product_in_video", @"products_in_video"
    ]; });
    return v;
}

static NSArray<NSString *> *WolFoxShortsBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"/oar2.jpg", @"reel_shelf", @"reelwatchendpoint",
        @"shorts_lockup", @"shorts_shelf", @"shorts_video_cell",
        @"shortslockup", @"shortslockupviewmodel", @"shortsshelfeml"
    ]; });
    return v;
}
static NSArray<NSString *> *WolFoxCommunityBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"backstage_post",
        @"community_post",
        @"community_post_section",
        @"id.ui.backstage.original_post",
        @"id.ui.backstage.post",
        @"id.ui.backstage.post_menu_button",
        @"id_ui_backstage_original_post",
        @"image_post_root.eml",
        @"images_post_responsive_root",
        @"images_post_root",
        @"images_post_root.eml",
        @"images_post_root_slim",
        @"images_post_root_slim.eml",
        @"images_post_slim",
        @"options_post_responsive_root",
        @"options_post_root",
        @"poll_post_responsive_root",
        @"poll_post_root",
        @"post_base_wrapper",
        @"post_base_wrapper.eml",
        @"post_base_wrapper_slim",
        @"post_base_wrapper_slim.eml",
        @"post_shelf",
        @"post_shelf_slim",
        @"shared_post_responsive_root",
        @"shared_post_root",
        @"text_post_responsive_root",
        @"text_post_root",
        @"text_post_root.eml",
        @"text_post_root_slim",
        @"videos_post_responsive_root",
        @"videos_post_root"
    ]; });
    return v;
}
static NSArray<NSString *> *WolFoxMixBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"&list=RD"
    ]; });
    return v;
}
static NSArray<NSString *> *WolFoxPlayableBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"playables_shelf", @"playableshelf",
        @"playable_game", @"playablegame",
        @"playables.shelf", @"playable.game",
        @".com/playables/", @"playables_shelf.eml",
        @"playable_card.eml",
        @"horizontal_gaming_shelf", @"mini_game_card"
    ]; });
    return v;
}

// Live videos carry the LIVE badge's icon; their view count reads "N
// watching". The Live filter chip carries the icon too, but chip bars are
// never filtered (YTKACEFeedKindForSection).
static NSArray<NSString *> *WolFoxLiveBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"youtube_outline_experimental/live_24pt"
    ]; });
    return v;
}

static NSArray<NSString *> *WolFoxHorizontalShelfBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"horizontal_shelf.eml",
    ]; });
    return v;
}

static const void *WolFoxFeedKindKey = &WolFoxFeedKindKey;
static const void *WolFoxFeedSearchedKey = &WolFoxFeedSearchedKey;


static WolFoxFeedKind WolFoxFeedKindForSection(id section,
                                              WolFoxFeedKind wanted) {
    if (section == nil || wanted == 0) return 0;
    if ([NSStringFromClass([section class])
            isEqualToString:@"YTIFeedFilterChipBarRenderer"]) {
        return 0;
    }
    NSNumber *memo = objc_getAssociatedObject(section, WolFoxFeedKindKey);
    WolFoxFeedKind cached = memo.unsignedIntegerValue;
    WolFoxFeedKind searched = [objc_getAssociatedObject(
        section, WolFoxFeedSearchedKey) unsignedIntegerValue];
    if (memo != nil && ((searched & wanted) == wanted)) {
        return cached & wanted;
    }
    BOOL truncated = NO;
    WolFoxFeedKind structural = WolFoxFeedKindStructural(
        section, wanted & ~(WolFoxFeedKindHorizontalShelves | WolFoxFeedKindLive), &truncated);
    if ((wanted & WolFoxFeedKindShorts) &&
        !(structural & WolFoxFeedKindShorts)) {
        if (WolFoxFastAllChildrenReel(section)) {
            structural |= WolFoxFeedKindShorts;
        }
    }
    WolFoxFeedKind missing = wanted & ~structural;
    if (missing != 0) {
        NSData *bytes = WolFoxSectionBytes(section);
        if (bytes.length == 0) bytes = WolFoxDescendantBytes(section);
        if (bytes.length != 0) {
            if ((missing & WolFoxFeedKindShorts) &&
                WolFoxBytesContain(bytes, WolFoxShortsBytesMarkers())) {
                structural |= WolFoxFeedKindShorts;
            }
            if ((missing & WolFoxFeedKindProducts) &&
                WolFoxBytesContain(bytes, WolFoxProductsMarkers())) {
                structural |= WolFoxFeedKindProducts;
            }
            if ((missing & WolFoxFeedKindCommunity) &&
                WolFoxBytesContain(bytes, WolFoxCommunityBytesMarkers())) {
                structural |= WolFoxFeedKindCommunity;
            }
            if ((missing & WolFoxFeedKindPlayable) &&
                WolFoxBytesContain(bytes, WolFoxPlayableBytesMarkers())) {
                structural |= WolFoxFeedKindPlayable;
            }
            if ((missing & WolFoxFeedKindLive) &&
                WolFoxBytesContain(bytes, WolFoxLiveBytesMarkers())) {
                structural |= WolFoxFeedKindLive;
            }
            if ((missing & WolFoxFeedKindHorizontalShelves) &&
                WolFoxBytesContain(bytes,
                                   WolFoxHorizontalShelfBytesMarkers())) {
                structural |= WolFoxFeedKindHorizontalShelves;
            }
        }
    }
    objc_setAssociatedObject(section, WolFoxFeedKindKey, @(structural),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    const WolFoxFeedKind settled =
        truncated ? (searched | (wanted & structural)) : (searched | wanted);
    objc_setAssociatedObject(section, WolFoxFeedSearchedKey, @(settled),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return structural & wanted;
}

static BOOL WolFoxIsGuidelinesSection(id section);

typedef NS_ENUM(NSUInteger, WolFoxFeedSurface) {
    WolFoxFeedSurfaceUnknown = 0,
    WolFoxFeedSurfaceHome,
    WolFoxFeedSurfaceSubscriptions,
    WolFoxFeedSurfaceSearch,
    WolFoxFeedSurfaceChannel,
};

static NSString *WolFoxBrowseID(id object) {
    if (object == nil) return nil;
    static SEL browseSel;
    if (browseSel == NULL) browseSel = NSSelectorFromString(@"browseID");
    static SEL identifierSel;
    if (identifierSel == NULL) {
        identifierSel = NSSelectorFromString(@"browseIdentifier");
    }
    for (NSUInteger index = 0; index < 2; index++) {
        SEL selector = index == 0 ? browseSel : identifierSel;
        if (selector == NULL || ![object respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if ([value isKindOfClass:NSString.class] && ((NSString *)value).length != 0) {
            return (NSString *)value;
        }
    }
    return nil;
}

static BOOL WolFoxIsChannelBrowseID(NSString *browseID) {
    if ([browseID hasPrefix:@"UC"] || [browseID hasPrefix:@"@"]) return YES;
    // channels opened from a Short report this instead of the channel ID
    if ([browseID isEqualToString:@"CHANNELS"]) return YES;
    NSRange slash = [browseID rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound) return NO;
    static NSSet<NSString *> *tabs;
    if (tabs == nil) {
        tabs = [NSSet setWithArray:@[@"videos", @"shorts", @"streams", @"live",
            @"community", @"playlists", @"featured", @"home"]];
    }
    NSString *tab = [[browseID substringFromIndex:slash.location + 1]
        lowercaseString];
    return [tabs containsObject:tab];
}

static WolFoxFeedSurface WolFoxSurfaceForBrowseID(NSString *browseID) {
    if (browseID.length == 0) return WolFoxFeedSurfaceUnknown;
    if ([browseID isEqualToString:@"FEwhat_to_watch"]) {
        return WolFoxFeedSurfaceHome;
    }
    if ([browseID isEqualToString:@"FEsubscriptions"]) {
        return WolFoxFeedSurfaceSubscriptions;
    }
    if (WolFoxIsChannelBrowseID(browseID)) {
        return WolFoxFeedSurfaceChannel;
    }
    return WolFoxFeedSurfaceUnknown;
}

static id WolFoxSurfaceAncestor(id receiver, NSString *className) {
    if (receiver == nil || className.length == 0) return nil;
    Class cls = NSClassFromString(className);
    if (cls == Nil) return nil;
    SEL parentSel = NSSelectorFromString(@"parentViewController");
    id walk = receiver;
    for (NSUInteger depth = 0; walk != nil && depth < 12; depth++) {
        if ([walk isKindOfClass:cls]) return walk;
        id parent = [walk respondsToSelector:parentSel]
            ? ((id (*)(id, SEL))objc_msgSend)(walk, parentSel) : nil;
        if (parent == nil && [walk isKindOfClass:UIResponder.class]) {
            parent = ((UIResponder *)walk).nextResponder;
        }
        if (parent == walk) break;
        walk = parent;
    }
    return nil;
}

static const void *WolFoxFeedSurfaceAssociation = &WolFoxFeedSurfaceAssociation;

static WolFoxFeedSurface WolFoxShortsSurface(id receiver) {
    if (receiver == nil) return WolFoxFeedSurfaceUnknown;
    NSNumber *memo = objc_getAssociatedObject(receiver, WolFoxFeedSurfaceAssociation);
    if (memo != nil) return (WolFoxFeedSurface)memo.unsignedIntegerValue;

    WolFoxFeedSurface surface = WolFoxSurfaceForBrowseID(WolFoxBrowseID(receiver));
    if (surface == WolFoxFeedSurfaceUnknown) {
        if (WolFoxSurfaceAncestor(receiver, @"YTSearchResultsViewController") != nil) {
            surface = WolFoxFeedSurfaceSearch;
        }
    }
    if (surface == WolFoxFeedSurfaceUnknown) {
        surface = WolFoxSurfaceForBrowseID(
            WolFoxBrowseID(WolFoxSurfaceAncestor(receiver, @"YTBrowseViewController")));
    }
    if (surface != WolFoxFeedSurfaceUnknown) {
        objc_setAssociatedObject(receiver, WolFoxFeedSurfaceAssociation,
                                 @(surface), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return surface;
}

static BOOL WolFoxKeepsShortsInFeed(id receiver) {
    NSString *browseID = WolFoxBrowseID(receiver);
    static NSSet<NSString *> *personal;
    if (personal == nil) {
        personal = [NSSet setWithArray:@[@"FEhistory", @"FElibrary",
            @"FEplaylist_aggregation"]];
    }
    if ([personal containsObject:browseID]) return YES;
    WolFoxFeedSurface surface = WolFoxShortsSurface(receiver);
    BOOL keep = NO;
    switch (surface) {
        case WolFoxFeedSurfaceHome:
            keep = atomic_load(&WolFoxFeedKeepHomeShorts);
            break;
        case WolFoxFeedSurfaceSubscriptions:
            keep = atomic_load(&WolFoxFeedKeepSubsShorts);
            break;
        case WolFoxFeedSurfaceSearch:
            keep = atomic_load(&WolFoxFeedKeepSearchShorts);
            break;
        case WolFoxFeedSurfaceChannel:
            keep = atomic_load(&WolFoxFeedKeepChannelShorts);
            break;
        case WolFoxFeedSurfaceUnknown:
            break;
    }
    static NSString *const names[] = { @"unknown", @"home", @"subscriptions",
        @"search", @"channel" };
    WolFoxDebugLog(@"shorts", @"surface=%@ browse=%@ keep=%@ class=%@",
        names[surface], browseID.length == 0 ? @"-" : browseID,
        keep ? @"yes" : @"no", NSStringFromClass([receiver class]));
    return keep;
}

static BOOL WolFoxKeepsShelvesInFeed(id receiver) {
    static NSSet<NSString *> *personal;
    if (personal == nil) personal = [NSSet setWithArray:@[@"FEhistory", @"FElibrary"]];
    return [personal containsObject:WolFoxBrowseID(receiver)];
}

static const void *WolFoxAIChannelKey = &WolFoxAIChannelKey;

static BOOL WolFoxSectionIsAIChannel(id receiver, id section, BOOL blocklist, BOOL warnlist) {
    NSString *mode = blocklist && warnlist ? @"both" : blocklist ? @"block" : @"warn";
    NSString *memo = objc_getAssociatedObject(section, WolFoxAIChannelKey);
    if ([memo hasPrefix:mode]) return memo.length > mode.length;
    if (!WolFoxAiSListReady()) return NO;
    NSData *bytes = WolFoxSectionBytes(section);
    if (bytes.length == 0) bytes = WolFoxDescendantBytes(section);
    NSString *matched = nil;
    BOOL hit = WolFoxAiSListMatches(bytes, blocklist, warnlist, &matched);
    objc_setAssociatedObject(section, WolFoxAIChannelKey, hit ? [mode stringByAppendingString:matched] : mode,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!hit) {
        WolFoxFeedInitSels();
        id contents = WolFoxFastChildSel(section, WolFoxSelContentsArray);
        if ([contents isKindOfClass:NSMutableArray.class] && [contents count] > 1) {
            NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            [(NSArray *)contents enumerateObjectsUsingBlock:^(id entry, NSUInteger index, __unused BOOL *stop) {
                NSString *entryMatch = nil;
                if (WolFoxAiSListMatches(WolFoxSectionBytes(entry), blocklist, warnlist, &entryMatch)) {
                    [drop addIndex:index];
                    [names addObject:entryMatch];
                }
            }];
            if (drop.count != 0 && drop.count < [contents count]) {
                [(NSMutableArray *)contents removeObjectsAtIndexes:drop];
                WolFoxDebugLog(@"aislist", @"hid %lu of %lu items [%@] class=%@", (unsigned long)drop.count,
                                  (unsigned long)([contents count] + drop.count), [names componentsJoinedByString:@","],
                                  NSStringFromClass([section class]));
            } else if (drop.count != 0) {
                hit = YES;
                matched = names.firstObject;
                objc_setAssociatedObject(section, WolFoxAIChannelKey, [mode stringByAppendingString:matched],
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    if (hit) {
        WolFoxDebugLog(@"aislist", @"hid %@ in %@ (%@) class=%@", matched,
                          WolFoxBrowseID(receiver) ?: @"-",
                          NSStringFromClass([receiver class]), NSStringFromClass([section class]));
    }
    return hit;
}

static BOOL WolFoxEntryIsMix(id entry) {
    NSData *bytes = WolFoxSectionBytes(entry);
    if (bytes.length == 0) return NO;
    return WolFoxBytesContain(bytes, WolFoxMixBytesMarkers());
}

static BOOL WolFoxMixFilteredEntries(id section) {
    WolFoxFeedInitSels();
    NSData *bytes = WolFoxSectionBytes(section);
    if (bytes.length != 0 &&
        !WolFoxBytesContain(bytes, WolFoxMixBytesMarkers())) {
        return NO;
    }
    id contents = WolFoxFastChildSel(section, WolFoxSelContentsArray);
    if (![contents isKindOfClass:NSMutableArray.class]) return NO;
    NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];
    [(NSArray *)contents enumerateObjectsUsingBlock:^(id entry, NSUInteger index,
                                                      __unused BOOL *stop) {
        if (WolFoxEntryIsMix(entry)) [drop addIndex:index];
    }];
    if (drop.count == 0) return NO;
    WolFoxDebugLog(@"feed", @"removed %lu of %lu mixes", (unsigned long)drop.count, (unsigned long)[(NSArray *)contents count]);
    [(NSMutableArray *)contents removeObjectsAtIndexes:drop];
    return [(NSArray *)contents count] == 0;
}

static NSArray *WolFoxMixFilteredFeedSections(NSArray *sections) {
    if (!atomic_load(&WolFoxFeedHideMixes)) return sections;
    if (![sections isKindOfClass:NSArray.class]) return sections;
    NSMutableIndexSet *empty = [NSMutableIndexSet indexSet];
    for (NSUInteger index = 0; index < sections.count; index++) {
        if (WolFoxMixFilteredEntries(sections[index])) {
            [empty addIndex:index];
        }
    }
    if (empty.count == 0) return sections;
    NSMutableArray *kept = [sections mutableCopy];
    [kept removeObjectsAtIndexes:empty];
    return kept;
}

// A section holding many results (search) with a Shorts shelf among them:
// remove just the Shorts entries. Returns NO when the whole section should go.
static BOOL WolFoxDropShortsEntries(id section) {
    id contents = WolFoxFastChildSel(section, WolFoxSelContentsArray);
    if (![contents isKindOfClass:NSMutableArray.class] || [contents count] < 2) return NO;
    NSMutableIndexSet *drop = [NSMutableIndexSet indexSet];
    [(NSArray *)contents enumerateObjectsUsingBlock:^(id entry, NSUInteger index, __unused BOOL *stop) {
        if (WolFoxFeedKindForSection(entry, WolFoxFeedKindShorts) & WolFoxFeedKindShorts) [drop addIndex:index];
    }];
    if (drop.count == [contents count]) return NO;
    if (drop.count == 0) return YES;
    [(NSMutableArray *)contents removeObjectsAtIndexes:drop];
    WolFoxDebugLog(@"feed", @"removed %lu shorts of %lu in one section", (unsigned long)drop.count,
                   (unsigned long)([contents count] + drop.count));
    return YES;
}

static NSArray *WolFoxFilteredFeedSections(id receiver, NSArray *sections) {
    WolFoxFeedEnsureFlagObserver();
    NSArray *adFiltered = WolFoxMixFilteredFeedSections(
        WolFoxFilterAdSections(sections));
    if ([adFiltered isKindOfClass:NSArray.class] && adFiltered.count != 0 &&
        WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.CommentGuidelinesHidden")) {
        NSIndexSet *guidelines = [adFiltered indexesOfObjectsPassingTest:
            ^BOOL(id section, __unused NSUInteger index, __unused BOOL *stop) {
            return WolFoxIsGuidelinesSection(section);
        }];
        if (guidelines.count != 0) {
            NSMutableArray *kept = [adFiltered mutableCopy];
            [kept removeObjectsAtIndexes:guidelines];
            adFiltered = kept;
        }
    }
    if (!atomic_load(&WolFoxFeedHideAny) ||
        ![adFiltered isKindOfClass:NSArray.class]) {
        return adFiltered;
    }
    BOOL hideShorts = atomic_load(&WolFoxFeedHideShorts) && !WolFoxKeepsShortsInFeed(receiver);
    BOOL hideProducts = atomic_load(&WolFoxFeedHideProducts);
    BOOL hideCommunity = atomic_load(&WolFoxFeedHideCommunity);
    BOOL hideHorizontalShelves = atomic_load(&WolFoxFeedHideHorizontalShelves) &&
        !WolFoxKeepsShelvesInFeed(receiver);
    BOOL hidePlayables = atomic_load(&WolFoxFeedHidePlayables);
    BOOL hideLive = atomic_load(&WolFoxFeedHideHomeLive) &&
        WolFoxShortsSurface(receiver) == WolFoxFeedSurfaceHome;
    if (hideLive) {
        // Home's "Live" chip loads a page of live streams under Home's browse
        // ID, which the user opened on purpose. Its batches are half live
        // streams (the other sections aren't videos), while regular Home
        // batches have one or two, so a batch that is at least half live is kept.
        NSUInteger live = 0;
        for (id section in adFiltered) {
            if (WolFoxFeedKindForSection(section, WolFoxFeedKindLive) & WolFoxFeedKindLive) live++;
        }
        if (live >= 3 && live * 2 >= adFiltered.count) hideLive = NO;
    }
    WolFoxFeedKind wanted = 0;
    if (hideShorts) wanted |= WolFoxFeedKindShorts;
    if (hideProducts) wanted |= WolFoxFeedKindProducts;
    if (hideCommunity) wanted |= WolFoxFeedKindCommunity;
    if (hidePlayables) wanted |= WolFoxFeedKindPlayable;
    if (hideLive) wanted |= WolFoxFeedKindLive;
    if (hideHorizontalShelves) wanted |= WolFoxFeedKindHorizontalShelves;
    BOOL hideAIBlock = atomic_load(&WolFoxFeedHideAIBlock);
    BOOL hideAIWarn = atomic_load(&WolFoxFeedHideAIWarn);
    if (wanted == 0 && !hideAIBlock && !hideAIWarn) return adFiltered;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:adFiltered.count];
    for (id section in adFiltered) {
        WolFoxFeedKind kind = wanted != 0 ? WolFoxFeedKindForSection(section, wanted) : 0;
        NSString *cut = nil;
        if ((hideAIBlock || hideAIWarn) && WolFoxSectionIsAIChannel(receiver, section, hideAIBlock, hideAIWarn)) {
            continue;
        }
        if (hideShorts && (kind & WolFoxFeedKindShorts) && WolFoxDropShortsEntries(section)) {
            // Search puts every result in one section; only its Shorts were removed.
            [filtered addObject:section];
            continue;
        }
        if (hideShorts && (kind & WolFoxFeedKindShorts)) cut = @"shorts";
        else if (hideProducts && (kind & WolFoxFeedKindProducts)) cut = @"products";
        else if (hideCommunity && (kind & WolFoxFeedKindCommunity)) cut = @"community";
        else if (hidePlayables && (kind & WolFoxFeedKindPlayable)) cut = @"playables";
        else if (hideLive && (kind & WolFoxFeedKindLive)) cut = @"live";
        else if (hideHorizontalShelves &&
            (kind & WolFoxFeedKindHorizontalShelves)) cut = @"shelves";
        if (cut != nil) {
            WolFoxDebugLog(@"feed", @"removed %@ from %@", cut, WolFoxBrowseID(receiver) ?: @"-");
            continue;
        }
        [filtered addObject:section];
    }
    return filtered;
}

static id WolFoxSectionControllers(id receiver, SEL selector,
                                   NSArray *sections, id reloadMap) {
    if (OriginalSectionControllers == NULL) return nil;
    WolFoxEnsureStructuralActionHook();
    NSArray *filtered = WolFoxFilteredFeedSections(receiver, sections);
    return ((id (*)(id, SEL, id, id))OriginalSectionControllers)(
        receiver, selector, filtered, reloadMap);
}

static BOOL WolFoxContentContains(NSString *token,
                                  NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([token containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

static BOOL WolFoxViewInsideReelOverlay(UIView *view);

static BOOL WolFoxContentShouldHide(UIView *view, BOOL *hideSuperview) {
    NSString *identifier = [view.accessibilityIdentifier.lowercaseString
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
                       identifier ?: @"",
                       view.accessibilityLabel.lowercaseString ?: @"",
                       NSStringFromClass(view.class).lowercaseString];

    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.CommentsHidden")) {
        if ([identifier isEqualToString:@"id_comment_guidelines_text"]) {
            if (hideSuperview != NULL) {
                *hideSuperview = YES;
            }
            return YES;
        }
        if (WolFoxContentContains(token, @[
            @"id_ui_comments_composite_entry_point_teaser",
            @"id_ui_comments_entry_point_teaser",
            @"id_comment_channel_guidelines_bottom_sheet_container",
            @"id_comment_channel_guidelines_entry_banner_container"
        ])) {
            return YES;
        }
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.CommentPreviewsHidden") &&
        [identifier isEqualToString:@"id_ui_comments_entry_point_teaser"]) {
        return YES;
    }
    if (WolFoxShortsSuggestionPillHidden() &&
        [identifier isEqualToString:
            @"id_elements_components_suggested_action"] &&
        WolFoxViewInsideReelOverlay(view)) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.CommentGuidelinesHidden") &&
        WolFoxContentContains(token, @[
            @"id_comment_guidelines_text",
            @"id_comment_channel_guidelines_bottom_sheet_container",
            @"id_comment_channel_guidelines_entry_banner_container",
            @"channel_guidelines_entry_banner",
            @"community_guidelines",
            @"viewer_engagement_message"
        ])) {
        if ([identifier isEqualToString:@"id_comment_guidelines_text"] &&
            hideSuperview != NULL) {
            *hideSuperview = YES;
        }
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.TopicsHidden") &&
        WolFoxContentContains(token, @[@"topic_chip", @"feed_filter", @"chip_cloud"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Privacy.SearchHistoryDisabled") &&
        WolFoxContentContains(token, @[@"search_history", @"history_suggestion"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") &&
        WolFoxContentContains(token, @[@"paid_promotion", @"paidpromotion"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Ads.PremiumPromosHidden") &&
        WolFoxContentContains(token, @[@"premium_upsell", @"premium_promo"])) {
        return YES;
    }
    if ((WolFoxFeatureEnabled(@"YTKACE.Preference.Ads.PremiumPromosHidden") ||
         WolFoxFeatureEnabled(@"YTKACE.Preference.App.UpdatePromptHidden")) &&
        WolFoxContentContains(token, @[@"update_dialog", @"upgrade_dialog"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.SuggestedVideosHidden") &&
        WolFoxContentContains(token, @[@"suggested_video", @"related_video"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ContinueWatchingDisabled") &&
        WolFoxContentContains(token, @[
            @"continue_watching", @"continuewatching", @"resume_watching"
        ])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.PauseCardHidden") &&
        WolFoxContentContains(token, @[
            @"shorts_pause", @"reel_pause", @"pause_card", @"pausecard",
            @"paused_state_carousel", @"reelpausedstatecarousel"
        ])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        WolFoxContentContains(token, @[
            @"shorts_product", @"product_sticker", @"shopping_carousel",
            @"shopping_destination", @"tagged_product", @"creator_product"
        ])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Shorts.StickerAdsHidden") &&
        WolFoxContentContains(token, @[
            @"brand_link_sticker", @"product_sticker", @"promoted_sticker",
            @"sponsored_sticker", @"shorts_ads_shopping"
        ])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        WolFoxContentContains(token, WolFoxProductsMarkers())) {
        return YES;
    }
    if (WolFoxFeatureEnabled(
            @"YTKACE.Preference.Feed.CommunityPostsHidden") &&
        [identifier isEqualToString:@"id_ui_backstage_original_post"]) {
        WolFoxCollapseHostCell(view);
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Feed.MixesHidden") &&
        [identifier isEqualToString:@"feed_nudge_view"]) {
        return YES;
    }
    return NO;
}

static void WolFoxScheduleFixedBarLayout(UIView *view) {
    UIView *bar = nil;
    UIView *walk = view;
    for (NSUInteger depth = 0; walk != nil && depth < 8; depth++) {
        if ([walk.accessibilityIdentifier
                containsString:@"non_scrollable_action_bar"]) {
            bar = walk;
            break;
        }
        walk = walk.superview;
    }
    if (bar == nil) return;
    __weak UIView *weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongBar = weakBar;
        if (strongBar == nil) return;
        [strongBar setNeedsLayout];
        [strongBar layoutIfNeeded];
    });
}

static void WolFoxApplyContentVisibility(UIView *view) {
    WolFoxFeedEnsureFlagObserver();
    if (!atomic_load(&WolFoxContentHideAny) &&
        !atomic_load(&WolFoxFeedActionHideAny)) {
        NSNumber *idleBaseline = objc_getAssociatedObject(
            view, WolFoxContentHiddenAssociation);
        if (idleBaseline == nil) return;
        view.hidden = NO;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view, WolFoxContentHiddenAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSString *actionPreference = atomic_load(&WolFoxFeedActionHideAny)
        ? WolFoxActionPreferenceForView(view) : nil;
    if (actionPreference.length != 0) {
        WolFoxEnsureStructuralActionHook();
        UIView *target = WolFoxActionContainer(view);
        BOOL hidden = WolFoxFeatureEnabled(actionPreference);
        NSNumber *baseline = objc_getAssociatedObject(
            target,
            WolFoxContentHiddenAssociation
        );
        if (hidden) {
            if (baseline == nil) {
                objc_setAssociatedObject(target,
                                         WolFoxContentHiddenAssociation, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            target.hidden = YES;
            target.userInteractionEnabled = NO;
            WolFoxRefreshActionCollection(view);
        } else if (baseline != nil) {
            target.hidden = NO;
            target.userInteractionEnabled = YES;
            objc_setAssociatedObject(target,
                                     WolFoxContentHiddenAssociation,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        WolFoxCompactFixedActionGroup(target);
        WolFoxScheduleFixedBarLayout(view);
        return;
    }

    BOOL hideSuperview = NO;
    BOOL hidden = WolFoxContentShouldHide(view, &hideSuperview);

    UIView *target = hideSuperview ? view.superview : view;
    if (target == nil) {
        return;
    }

    NSNumber *baseline = objc_getAssociatedObject(
        target,
        WolFoxContentHiddenAssociation
    );
    if (hidden) {
        if (baseline == nil) {
            objc_setAssociatedObject(target,
                                     WolFoxContentHiddenAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        target.hidden = YES;
        target.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        target.hidden = NO;
        target.userInteractionEnabled = YES;
        objc_setAssociatedObject(target,
                                 WolFoxContentHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void WolFoxConsiderProductDisplayView(UIView *view, NSString *identifier) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        WolFoxProductIdentifierMatches(identifier)) {
        WolFoxHideProductSubtree(view);
    }
}




static void WolFoxDisplayViewDidMove(UIView *receiver, SEL selector) {
    if (OriginalDisplayViewDidMove != NULL) {
        ((void (*)(id, SEL))OriginalDisplayViewDidMove)(receiver, selector);
    }
    WolFoxApplyContentVisibility(receiver);
    WolFoxConsiderProductDisplayView(receiver, receiver.accessibilityIdentifier);
    WolFoxReturnDislikeConsiderView(receiver);
}




static BOOL WolFoxViewInsideReelOverlay(UIView *view) {
    UIView *walker = view;
    for (NSUInteger depth = 0; depth < 12 && walker != nil; depth++) {
        if ([walker.accessibilityIdentifier isEqualToString:@"id.reel_overlay"]) {
            return YES;
        }
        walker = walker.superview;
    }
    return NO;
}




static void WolFoxDisplayViewSetIdentifier(UIView *receiver,
                                           SEL selector,
                                           NSString *identifier) {
    if (OriginalDisplayViewSetIdentifier != NULL) {
        ((void (*)(id, SEL, id))OriginalDisplayViewSetIdentifier)(
            receiver,
            selector,
            identifier
        );
    }
    WolFoxApplyContentVisibility(receiver);
    WolFoxConsiderProductDisplayView(receiver, identifier);
}

BOOL WolFoxHomeTabsLayoutActive(void);

static BOOL WolFoxHideTopics(void) {
    return WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.TopicsHidden");
}

// The header hooks fold away the bar under the top bar. With the Home and
// Subscriptions tabs layout that bar holds the tabs, and folding it hangs or
// crashes YouTube at launch.
static BOOL WolFoxHideTopicsHeader(void) {
    if (!WolFoxHideTopics()) return NO;
    if (WolFoxHomeTabsLayoutActive()) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ WolFoxDebugLog(@"topics", @"tabs layout, header left alone"); });
        return NO;
    }
    return YES;
}

static char WolFoxTabsHeaderKey;

static BOOL WolFoxIsTabTitlesView(id view) {
    if (![view isKindOfClass:UIView.class]) return NO;
    if ([NSStringFromClass([view class]) containsString:@"TabTitles"]) return YES;
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) {
            return [NSStringFromClass(r.class) containsString:@"TabTitles"];
        }
    }
    return NO;
}

// Same as above for one header: also leaves it alone when its bar holds the
// Home and Subscriptions tabs, which YouTube can turn on from the server.
static BOOL WolFoxHideTopicsHeaderFor(id header) {
    if (!WolFoxHideTopicsHeader()) return NO;
    if (header == nil) return YES;
    if (objc_getAssociatedObject(header, &WolFoxTabsHeaderKey) != nil) return NO;
    SEL subheader = NSSelectorFromString(@"subheaderView");
    if ([header respondsToSelector:subheader] &&
        WolFoxIsTabTitlesView(((id (*)(id, SEL))objc_msgSend)(header, subheader))) {
        return NO;
    }
    return YES;
}

static void WolFoxCollapseSubheader(id receiver) {
    SEL height = NSSelectorFromString(@"setMaximumSubheaderHeight:");
    if ([receiver respondsToSelector:height]) {
        ((void (*)(id, SEL, double))objc_msgSend)(receiver, height, 0.0);
    }
    for (NSString *name in @[@"hideSubheaderBar", @"disableSubheaderBar",
                             @"setSubheaderHeightToZero",
                             @"resetScrollViewInsetOffset"]) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    SEL enabled = NSSelectorFromString(@"setSubheaderBarEnabled:");
    if ([receiver respondsToSelector:enabled]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(receiver, enabled, NO);
    }
}

static double WolFoxMaximumSubheaderHeightGetter(id receiver, SEL selector) {
    if (WolFoxHideTopicsHeaderFor(receiver)) return 0.0;
    return OriginalMaximumSubheaderHeightGetter == NULL
        ? 0.0
        : ((double (*)(id, SEL))OriginalMaximumSubheaderHeightGetter)(
            receiver, selector);
}

static double WolFoxSubheaderDefaultHeight(id receiver, SEL selector) {
    if (WolFoxHideTopicsHeaderFor(receiver)) return 0.0;
    return OriginalSubheaderDefaultHeight == NULL
        ? 0.0
        : ((double (*)(id, SEL))OriginalSubheaderDefaultHeight)(
            receiver, selector);
}

static void WolFoxPaidContentLayout(UIView *receiver, SEL selector) {
    if (OriginalPaidContentLayout != NULL) {
        ((void (*)(id, SEL))OriginalPaidContentLayout)(receiver, selector);
    }
    BOOL hide = WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden");
    NSNumber *baseline = objc_getAssociatedObject(
        receiver, WolFoxContentHiddenAssociation);
    if (hide) {
        if (baseline == nil) {
            objc_setAssociatedObject(receiver,
                                     WolFoxContentHiddenAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        receiver.hidden = YES;
        receiver.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        receiver.hidden = NO;
        receiver.userInteractionEnabled = YES;
        objc_setAssociatedObject(receiver,
                                 WolFoxContentHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void WolFoxPaidContentDidAppear(UIViewController *receiver,
                                       SEL selector,
                                       BOOL animated) {
    if (OriginalPaidContentDidAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPaidContentDidAppear)(
            receiver, selector, animated);
    }
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden")) return;
    receiver.view.hidden = YES;
    receiver.view.userInteractionEnabled = NO;
    for (NSString *name in @[@"hidePaidContent",
                             @"removePaidContentViewController"]) {
        SEL action = NSSelectorFromString(name);
        if ([receiver respondsToSelector:action]) {
            ((void (*)(id, SEL))objc_msgSend)(receiver, action);
        }
    }
}

static void WolFoxPaidContentPlaybackStarted(id receiver, SEL selector) {
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") &&
        OriginalPaidContentPlaybackStarted != NULL) {
        ((void (*)(id, SEL))OriginalPaidContentPlaybackStarted)(receiver, selector);
    }
}

static void WolFoxSetPaidContentPlayerData(id receiver, SEL selector, id data) {
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") &&
        OriginalSetPaidContentPlayerData != NULL) {
        ((void (*)(id, SEL, id))OriginalSetPaidContentPlayerData)(
            receiver, selector, data);
    }
}

static void WolFoxSetPaidContentRenderer(id receiver, SEL selector, id renderer) {
    if (OriginalSetPaidContentRenderer != NULL) {
        ((void (*)(id, SEL, id))OriginalSetPaidContentRenderer)(
            receiver, selector,
            WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") ? nil : renderer);
    }
}

static BOOL WolFoxHasPaidContentOverlay(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden")) return NO;
    return OriginalHasPaidContentOverlay != NULL &&
        ((BOOL (*)(id, SEL))OriginalHasPaidContentOverlay)(receiver, selector);
}

static id WolFoxPaidContentOverlay(id receiver, SEL selector) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden")) return nil;
    return OriginalPaidContentOverlay == NULL ? nil :
        ((id (*)(id, SEL))OriginalPaidContentOverlay)(receiver, selector);
}

static void WolFoxOverlayPaidContentPlayerData(id receiver, SEL selector, id data) {
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") &&
        OriginalOverlayPaidContentPlayerData != NULL) {
        ((void (*)(id, SEL, id))OriginalOverlayPaidContentPlayerData)(
            receiver, selector, data);
    }
}

static void WolFoxInlinePaidContentPlayerData(id receiver, SEL selector, id data) {
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") &&
        OriginalInlinePaidContentPlayerData != NULL) {
        ((void (*)(id, SEL, id))OriginalInlinePaidContentPlayerData)(
            receiver, selector, data);
    }
}

static void WolFoxDidInsertPlayerOverlay(id receiver, SEL selector,
                                         id provider, id overlay) {
    NSString *identifier = WolFoxContentValue(overlay, @"overlayIdentifier");
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.PaidPromotionHidden") &&
        [identifier isEqualToString:@"player_overlay_paid_content"]) {
        return;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        [identifier isEqualToString:@"player_overlay_product_in_video"]) {
        return;
    }
    if (OriginalDidInsertPlayerOverlay != NULL) {
        ((void (*)(id, SEL, id, id))OriginalDidInsertPlayerOverlay)(
            receiver, selector, provider, overlay);
    }
}

static NSString *WolFoxOwnerName(id view) {
    for (UIResponder *r = [view isKindOfClass:UIResponder.class] ? view : nil; r; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) return NSStringFromClass(r.class);
    }
    return @"-";
}

static void WolFoxEnableSubheaderBar(__unsafe_unretained id receiver, SEL selector,
                                     __unsafe_unretained id view) {
    WolFoxDebugLog(@"topics", @"enable subheader view=%@ owner=%@ sub0=%@ tabsActive=%d",
                   NSStringFromClass([view class]), WolFoxOwnerName(view),
                   [view isKindOfClass:UIView.class] && [(UIView *)view subviews].count
                       ? NSStringFromClass([(UIView *)view subviews].firstObject.class) : @"-",
                   WolFoxHomeTabsLayoutActive());
    if (WolFoxIsTabTitlesView(view)) {
        objc_setAssociatedObject(receiver, &WolFoxTabsHeaderKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL hide = WolFoxHideTopicsHeaderFor(receiver);
    if (hide) {
        WolFoxCollapseSubheader(receiver);
        return;
    }
    if (OriginalEnableSubheaderBar != NULL) {
        ((void (*)(id, SEL, id))OriginalEnableSubheaderBar)(receiver, selector, view);
    }
}

static IMP OriginalChipBarImplUpdate;

static void WolFoxChipBarForward(IMP original, id receiver, SEL selector, id collectionViewController,
                                 id host, id renderer, id browseIdentifier, id sectionList) {
    if (WolFoxHideTopicsHeader()) return;
    if (original != NULL) {
        ((void (*)(id, SEL, id, id, id, id, id))original)(
            receiver, selector, collectionViewController, host, renderer,
            browseIdentifier, sectionList);
    }
}

static void WolFoxChipBarUpdate(__unsafe_unretained id receiver, SEL selector,
                                __unsafe_unretained id collectionViewController,
                                __unsafe_unretained id host,
                                __unsafe_unretained id renderer,
                                __unsafe_unretained id browseIdentifier,
                                __unsafe_unretained id sectionList) {
    WolFoxChipBarForward(OriginalChipBarUpdate, receiver, selector, collectionViewController,
                         host, renderer, browseIdentifier, sectionList);
}

// Newer YouTube renamed the chip bar controller. Loading it reserves the chip
// row above the feed even when the chips are hidden.
static void WolFoxChipBarImplUpdate(__unsafe_unretained id receiver, SEL selector,
                                    __unsafe_unretained id collectionViewController,
                                    __unsafe_unretained id host,
                                    __unsafe_unretained id renderer,
                                    __unsafe_unretained id browseIdentifier,
                                    __unsafe_unretained id sectionList) {
    WolFoxChipBarForward(OriginalChipBarImplUpdate, receiver, selector, collectionViewController,
                         host, renderer, browseIdentifier, sectionList);
}

static void WolFoxChipCloudSetEntry(__unsafe_unretained id receiver, SEL selector,
                                    __unsafe_unretained id entry) {
    if (OriginalChipCloudSetEntry != NULL) {
        ((void (*)(id, SEL, id))OriginalChipCloudSetEntry)(receiver, selector, entry);
    }
    BOOL hide = WolFoxHideTopics();
    if (!hide) return;
    if ([receiver isKindOfClass:UIView.class]) {
        UIView *cell = (UIView *)receiver;
        cell.hidden = YES;
        cell.userInteractionEnabled = NO;
    }
}

static void WolFoxChipCloudLayout(__unsafe_unretained id receiver, SEL selector) {
    if (OriginalChipCloudLayout != NULL) {
        ((void (*)(id, SEL))OriginalChipCloudLayout)(receiver, selector);
    }
    BOOL hide = WolFoxHideTopics();
    if (!hide) return;
    if (![receiver isKindOfClass:UIView.class]) return;
    UIView *cell = (UIView *)receiver;
    cell.hidden = YES;
    cell.userInteractionEnabled = NO;
    CGRect frame = cell.frame;
    if (frame.size.height != 0.0) {
        frame.size.height = 0.0;
        cell.frame = frame;
    }
    for (UIView *subview in cell.subviews) {
        subview.hidden = YES;
    }
}

static IMP OriginalChipViewFrames;

static id WolFoxChipViewFrames(__unsafe_unretained id receiver, SEL selector, double width) {
    if (WolFoxHideTopics()) return nil;
    return OriginalChipViewFrames == NULL ? nil
        : ((id (*)(id, SEL, double))OriginalChipViewFrames)(receiver, selector, width);
}

static void WolFoxSubsSetChipFilterView(__unsafe_unretained id receiver, SEL selector,
                                        __unsafe_unretained id view) {
    BOOL hide = WolFoxHideTopics();
    if (hide) return;
    if (OriginalSubsSetChipFilterView != NULL) {
        ((void (*)(id, SEL, id))OriginalSubsSetChipFilterView)(receiver, selector, view);
    }
}

static void WolFoxSubsChipFilter(__unsafe_unretained id receiver, SEL selector,
                                 __unsafe_unretained id model) {
    BOOL hide = WolFoxHideTopics();
    if (hide) return;
    if (OriginalSubsChipFilter != NULL) {
        ((void (*)(id, SEL, id))OriginalSubsChipFilter)(receiver, selector, model);
    }
}

static void WolFoxMaximumSubheaderHeight(__unsafe_unretained id receiver,
                                        SEL selector, double height) {
    BOOL hide = WolFoxHideTopicsHeaderFor(receiver);
    if (hide) height = 0.0;
    if (OriginalMaximumSubheaderHeight != NULL) {
        ((void (*)(id, SEL, double))OriginalMaximumSubheaderHeight)(
            receiver, selector, height);
    }
}

static void WolFoxSetHeaderHeights(id receiver, SEL selector,
                                    double headerHeight,
                                    double subheaderHeight,
                                    double topOffset,
                                    BOOL animated) {
    if (WolFoxHideTopicsHeaderFor(receiver)) {
        subheaderHeight = 0.0;
    }
    if (OriginalSetHeaderHeights != NULL) {
        ((void (*)(id, SEL, double, double, double, BOOL))OriginalSetHeaderHeights)(
            receiver, selector, headerHeight, subheaderHeight, topOffset, animated);
    }
}

static BOOL WolFoxShouldHideSubheader(id receiver, SEL selector) {
    if (WolFoxHideTopicsHeaderFor(receiver)) return YES;
    return OriginalShouldHideSubheader != NULL &&
        ((BOOL (*)(id, SEL))OriginalShouldHideSubheader)(receiver, selector);
}

static void WolFoxAddSections(id receiver, SEL selector, NSArray *sections) {
    if (OriginalAddSections != NULL) {
        WolFoxEnsureStructuralActionHook();
        NSArray *filtered = WolFoxFilteredFeedSections(receiver, sections);
        ((void (*)(id, SEL, id))OriginalAddSections)(
            receiver, selector, filtered);
    }
}

static IMP OriginalSetupSectionList;

static BOOL WolFoxIsGuidelinesSection(id section) {
    NSData *pattern = [@"community_guidelines.eml" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *bytes = WolFoxSectionBytes(section) ?: WolFoxDescendantBytes(section);
    if (bytes.length == 0 ||
        [bytes rangeOfData:pattern options:0
                     range:NSMakeRange(0, bytes.length)].location == NSNotFound) {
        return NO;
    }
    id itemSection = WolFoxFastChildSel(section, WolFoxSelItemSectionRenderer) ?: section;
    return WolFoxFastContents(itemSection).count <= 1;
}

static void WolFoxStripGuidelinesSections(id model) {
    if (!WolFoxFeatureEnabled(@"YTKACE.Preference.Overlay.CommentGuidelinesHidden")) {
        return;
    }
    NSArray *sections = WolFoxFastContents(model);
    if (![sections isKindOfClass:NSMutableArray.class] || sections.count == 0) return;
    NSIndexSet *drop = [sections indexesOfObjectsPassingTest:
        ^BOOL(id section, __unused NSUInteger index, __unused BOOL *stop) {
        return WolFoxIsGuidelinesSection(section);
    }];
    if (drop.count == 0) return;
    [(NSMutableArray *)sections removeObjectsAtIndexes:drop];
}

static void WolFoxSetupSectionList(id receiver, SEL selector, id model, BOOL loadingMore,
                                   BOOL refreshing, BOOL preserveHeader) {
    WolFoxStripGuidelinesSections(model);
    if (OriginalSetupSectionList != NULL) {
        ((void (*)(id, SEL, id, BOOL, BOOL, BOOL))OriginalSetupSectionList)(
            receiver, selector, model, loadingMore, refreshing, preserveHeader);
    }
}

void WolFoxInstallContentVisibilityHooks(void) {
    WolFoxInstallInstanceHook(
        @"YTAppCollectionViewController",
        @"setupSectionListWithModel:isLoadingMore:isRefreshingFromContinuation:"
         "shouldPreserveHeaderOnRefresh:",
        (IMP)WolFoxSetupSectionList, &OriginalSetupSectionList);
    __unused NSArray<NSNumber *> *actionHooks = @[
        @(WolFoxInstallInstanceHook(@"YTISlimVideoScrollableActionBarRenderer",
                                    @"actionButtonsArray",
                                    (IMP)WolFoxScrollableActionButtonsArray,
                                    &OriginalScrollableActionButtonsArray)),
        @(WolFoxInstallInstanceHook(@"YTISlimVideoScrollableActionBarRenderer",
                                    @"actionBarButtonsArray",
                                    (IMP)WolFoxScrollableActionBarButtonsArray,
                                    &OriginalScrollableActionBarButtonsArray)),
        @(WolFoxInstallInstanceHook(@"YTISlimVideoScrollableActionBarRenderer",
                                    @"buttonsArray",
                                    (IMP)WolFoxScrollableButtonsArray,
                                    &OriginalScrollableButtonsArray)),
        @(WolFoxInstallInstanceHook(@"YTISlimVideoScrollableActionBarRenderer",
                                    @"actionsArray",
                                    (IMP)WolFoxScrollableActionsArray,
                                    &OriginalScrollableActionsArray)),
        @(WolFoxInstallInstanceHook(@"YTISlimVideoActionBarRenderer",
                                    @"actionButtonsArray",
                                    (IMP)WolFoxActionButtonsArray,
                                    &OriginalActionButtonsArray)),
        @(WolFoxInstallInstanceHook(@"YTISlimVideoActionBarRenderer",
                                    @"actionBarButtonsArray",
                                    (IMP)WolFoxActionBarButtonsArray,
                                    &OriginalActionBarButtonsArray)),
        @(WolFoxInstallInstanceHook(@"YTISlimVideoActionBarRenderer",
                                    @"buttonsArray",
                                    (IMP)WolFoxButtonsArray,
                                    &OriginalButtonsArray)),
        @(WolFoxInstallInstanceHook(@"YTISlimVideoActionBarRenderer",
                                    @"actionsArray",
                                    (IMP)WolFoxActionsArray,
                                    &OriginalActionsArray))
    ];
    WolFoxInstallInstanceHook(@"YTSlimVideoDetailsActionView",
                              @"didMoveToWindow",
                              (IMP)WolFoxActionViewDidMove,
                              &OriginalActionViewDidMove);
    WolFoxEnsureStructuralActionHook();
    WolFoxEnsureActionCellControllerHooks();
    WolFoxEnsureActionCollectionLayoutHook();
    WolFoxScheduleStructuralActionHook();
    WolFoxInstallInstanceHook(@"YTSlimVideoScrollableDetailsActionsView",
                              @"didMoveToWindow",
                              (IMP)WolFoxActionsViewDidMove,
                              &OriginalActionsViewDidMove);
    WolFoxInstallInstanceHook(@"YTSlimVideoScrollableActionBarCell",
                              @"didMoveToWindow",
                              (IMP)WolFoxActionCellDidMove,
                              &OriginalActionCellDidMove);
    WolFoxInstallInstanceHook(@"_ASDisplayView",
                              @"didMoveToWindow",
                              (IMP)WolFoxDisplayViewDidMove,
                              &OriginalDisplayViewDidMove);
    WolFoxInstallInstanceHook(@"_ASDisplayView",
                              @"setAccessibilityIdentifier:",
                              (IMP)WolFoxDisplayViewSetIdentifier,
                              &OriginalDisplayViewSetIdentifier);
    WolFoxInstallInstanceHook(@"YTInnerTubeCollectionViewController",
                              @"addSectionsFromArray:",
                              (IMP)WolFoxAddSections,
                              &OriginalAddSections);
    WolFoxInstallInstanceHook(@"YTInnerTubeCollectionViewController",
                              @"sectionControllersForSectionRenderers:reloadingSectionControllerByRenderer:",
                              (IMP)WolFoxSectionControllers,
                              &OriginalSectionControllers);
    WolFoxInstallInstanceHook(@"YTHeaderContentComboView",
                              @"enableSubheaderBarWithView:",
                              (IMP)WolFoxEnableSubheaderBar,
                              &OriginalEnableSubheaderBar);
    WolFoxInstallInstanceHook(@"YTFeedFilterChipBarController",
                              @"updateWithCollectionViewController:feedFilterChipBarHost:feedFilterChipBarRenderer:browseIdentifier:sectionList:",
                              (IMP)WolFoxChipBarUpdate,
                              &OriginalChipBarUpdate);
    WolFoxInstallInstanceHook(@"YTFeedFilterChipBarControllerImpl",
                              @"updateWithCollectionViewController:feedFilterChipBarHost:feedFilterChipBarRenderer:browseIdentifier:sectionList:",
                              (IMP)WolFoxChipBarImplUpdate,
                              &OriginalChipBarImplUpdate);
    WolFoxInstallInstanceHook(@"YTChipCloudCell",
                              @"setEntry:",
                              (IMP)WolFoxChipCloudSetEntry,
                              &OriginalChipCloudSetEntry);
    WolFoxInstallInstanceHook(@"YTMySubsFilterHeaderViewController",
                              @"loadChipFilterFromModel:",
                              (IMP)WolFoxSubsChipFilter,
                              &OriginalSubsChipFilter);
    WolFoxInstallInstanceHook(@"YTChipCloudCell",
                              @"layoutSubviews",
                              (IMP)WolFoxChipCloudLayout,
                              &OriginalChipCloudLayout);
    WolFoxInstallInstanceHook(@"YTChipCloudCell",
                              @"framesForChipViewsWithWidth:",
                              (IMP)WolFoxChipViewFrames,
                              &OriginalChipViewFrames);
    WolFoxInstallInstanceHook(@"YTHeaderContentComboView",
                              @"setMaximumSubheaderHeight:",
                              (IMP)WolFoxMaximumSubheaderHeight,
                              &OriginalMaximumSubheaderHeight);
    WolFoxInstallInstanceHook(@"YTHeaderContentComboView",
                              @"maximumSubheaderHeight",
                              (IMP)WolFoxMaximumSubheaderHeightGetter,
                              &OriginalMaximumSubheaderHeightGetter);
    WolFoxInstallInstanceHook(@"YTHeaderContentComboView",
                              @"subheaderDefaultHeight",
                              (IMP)WolFoxSubheaderDefaultHeight,
                              &OriginalSubheaderDefaultHeight);
    WolFoxInstallInstanceHook(@"YTHeaderContentComboView",
                              @"setHeaderHeight:subheaderHeight:topOffset:animated:",
                              (IMP)WolFoxSetHeaderHeights,
                              &OriginalSetHeaderHeights);
    WolFoxInstallInstanceHook(@"YTHeaderContentComboView",
                              @"shouldHideSubHeader",
                              (IMP)WolFoxShouldHideSubheader,
                              &OriginalShouldHideSubheader);
    WolFoxInstallInstanceHook(@"YTMySubsFilterHeaderView",
                              @"setChipFilterView:",
                              (IMP)WolFoxSubsSetChipFilterView,
                              &OriginalSubsSetChipFilterView);
    WolFoxInstallInstanceHook(@"YTPaidContentOverlayView",
                              @"layoutSubviews",
                              (IMP)WolFoxPaidContentLayout,
                              &OriginalPaidContentLayout);
    WolFoxInstallInstanceHook(@"YTPaidContentViewController",
                              @"viewDidAppear:",
                              (IMP)WolFoxPaidContentDidAppear,
                              &OriginalPaidContentDidAppear);
    WolFoxInstallInstanceHook(@"YTPaidContentController",
                              @"playbackDidStart",
                              (IMP)WolFoxPaidContentPlaybackStarted,
                              &OriginalPaidContentPlaybackStarted);
    WolFoxInstallInstanceHook(@"YTPaidContentController",
                              @"setPaidContentWithPlayerData:",
                              (IMP)WolFoxSetPaidContentPlayerData,
                              &OriginalSetPaidContentPlayerData);
    WolFoxInstallInstanceHook(@"YTPaidContentViewController",
                              @"setPaidContentRenderer:",
                              (IMP)WolFoxSetPaidContentRenderer,
                              &OriginalSetPaidContentRenderer);
    WolFoxInstallInstanceHook(@"YTIPlayerResponse",
                              @"hasPaidContentOverlay",
                              (IMP)WolFoxHasPaidContentOverlay,
                              &OriginalHasPaidContentOverlay);
    WolFoxInstallInstanceHook(@"YTIPlayerResponse",
                              @"paidContentOverlay",
                              (IMP)WolFoxPaidContentOverlay,
                              &OriginalPaidContentOverlay);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"setPaidContentWithPlayerData:",
                              (IMP)WolFoxOverlayPaidContentPlayerData,
                              &OriginalOverlayPaidContentPlayerData);
    WolFoxInstallInstanceHook(@"YTInlineMutedPlaybackPlayerOverlayViewController",
                              @"setPaidContentWithPlayerData:",
                              (IMP)WolFoxInlinePaidContentPlayerData,
                              &OriginalInlinePaidContentPlayerData);
    WolFoxInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"playerOverlayProvider:didInsertPlayerOverlay:",
                              (IMP)WolFoxDidInsertPlayerOverlay,
                              &OriginalDidInsertPlayerOverlay);
}

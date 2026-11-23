#import "NavigationVisibility.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>

static IMP OriginalHeaderLogoLayout;
static IMP OriginalLogoViewLayout;
static IMP OriginalHeaderLogoSetHidden;
static IMP OriginalLogoViewSetHidden;
static IMP OriginalYTImageSetHidden;
static IMP OriginalQTMButtonLayout;
static IMP OriginalQTMButtonSetHidden;
static IMP OriginalQTMButtonSetIdentifier;
static IMP OriginalQTMButtonDidMoveToWindow;
static IMP OriginalQTMButtonSetTint;
static IMP OriginalQTMButtonSetImage;
static IMP OriginalNavigationImageSetTint;
static IMP OriginalNavigationImageSetImage;
static IMP OriginalYTImageViewLayout;
static IMP OriginalMainWindowTraitChanged;
static IMP OriginalRightNavigationTraitChanged;
static NSMutableDictionary<NSString *, NSValue *> *WolFoxNavigationOriginals;
static const void *WolFoxNavigationHiddenAssociation = &WolFoxNavigationHiddenAssociation;
static BOOL WolFoxNavigationObserverInstalled;
static NSHashTable<UIView *> *WolFoxNavigationOwners;
static UIUserInterfaceStyle WolFoxNavigationStyle = UIUserInterfaceStyleUnspecified;

static void WolFoxApplyNavigationWindows(void);
static void WolFoxApplyNavigationSelectors(id owner);
static BOOL WolFoxInsideRightNavigation(UIView *view);
static BOOL WolFoxIsNavigationIcon(UIView *view);

static NSValue *WolFoxNavigationIMPValue(IMP implementation) {
    return [NSValue value:&implementation withObjCType:@encode(IMP)];
}

static IMP WolFoxNavigationIMP(NSValue *value) {
    IMP implementation = NULL;
    [value getValue:&implementation];
    return implementation;
}

static NSString *WolFoxNavigationHookKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@",
            NSStringFromClass(cls), NSStringFromSelector(selector)];
}

static IMP WolFoxNavigationOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        NSValue *value = WolFoxNavigationOriginals[
            WolFoxNavigationHookKey(cls, selector)
        ];
        if (value != nil) return WolFoxNavigationIMP(value);
    }
    return NULL;
}

static void WolFoxSetNavigationHidden(UIView *view, BOOL hidden) {
    if (view == nil ||
        [view.accessibilityLabel hasPrefix:@"WolFox"] ||
        [view.accessibilityIdentifier hasPrefix:@"WolFox"]) {
        return;
    }
    NSNumber *baseline = objc_getAssociatedObject(
        view,
        WolFoxNavigationHiddenAssociation
    );
    if (hidden) {
        if (baseline == nil) {
            objc_setAssociatedObject(view,
                                     WolFoxNavigationHiddenAssociation,
                                     @(view.hidden),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        view.hidden = baseline.boolValue;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view,
                                 WolFoxNavigationHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL WolFoxIsMessagesToken(NSString *token) {
    return [token containsString:@"id.connections.inbox.button"] ||
        [token containsString:@"connectionsinboxbutton"] ||
        [token containsString:@"connections_inbox"] ||
        [token containsString:@"messages_inbox"] ||
        [token containsString:@"messagebutton"] ||
        [token containsString:@"messages button"] ||
        [token containsString:@"chatbutton"] ||
        [token containsString:@"inboxbutton"];
}

static id WolFoxNavigationButton(id receiver, SEL selector) {
    IMP original = WolFoxNavigationOriginal(receiver, selector);
    id value = original == NULL
        ? nil
        : ((id (*)(id, SEL))original)(receiver, selector);
    if ([value isKindOfClass:UIView.class]) {
        NSString *selectorName = NSStringFromSelector(selector).lowercaseString;
        BOOL messages = WolFoxIsMessagesToken(selectorName) ||
            [selectorName isEqualToString:@"connectionsbutton"] ||
            [selectorName isEqualToString:@"messagesbutton"] ||
            [selectorName isEqualToString:@"messagebutton"] ||
            [selectorName isEqualToString:@"chatbutton"] ||
            [selectorName isEqualToString:@"inboxbutton"];
        WolFoxSetNavigationHidden(
            value,
            WolFoxFeatureEnabled(messages
                ? @"YTKACE.Preference.Navigation.MessagesHidden"
                : @"YTKACE.Preference.Navigation.NotificationsHidden")
        );
    }
    return value;
}

static void WolFoxInstallNavigationMethodHooks(void) {
    if (WolFoxNavigationOriginals == nil) {
        WolFoxNavigationOriginals = [NSMutableDictionary dictionary];
    }
    NSString *version = NSBundle.mainBundle
        .infoDictionary[@"CFBundleShortVersionString"] ?: @"unknown";
    NSString *cacheKey =
        [@"WolFoxNavigationHookTargets." stringByAppendingString:version];
    NSDictionary<NSString *, NSValue *> *replacements = @{
        @"notificationButton":
            WolFoxNavigationIMPValue((IMP)WolFoxNavigationButton),
        @"newNotificationButton":
            WolFoxNavigationIMPValue((IMP)WolFoxNavigationButton),
        @"connectionsButton":
            WolFoxNavigationIMPValue((IMP)WolFoxNavigationButton),
        @"messagesButton":
            WolFoxNavigationIMPValue((IMP)WolFoxNavigationButton),
        @"messageButton":
            WolFoxNavigationIMPValue((IMP)WolFoxNavigationButton),
        @"chatButton":
            WolFoxNavigationIMPValue((IMP)WolFoxNavigationButton),
        @"inboxButton":
            WolFoxNavigationIMPValue((IMP)WolFoxNavigationButton)
    };
    void (^applyTargets)(NSArray<NSString *> *) =
        ^(NSArray<NSString *> *targets) {
            for (NSString *target in targets) {
                NSArray<NSString *> *parts =
                    [target componentsSeparatedByString:@"|"];
                if (parts.count != 2) continue;
                Class cls = NSClassFromString(parts[0]);
                SEL selector = NSSelectorFromString(parts[1]);
                Method method = class_getInstanceMethod(cls, selector);
                NSValue *replacement = replacements[parts[1]];
                if (method == NULL || replacement == nil) continue;
                IMP hook = WolFoxNavigationIMP(replacement);
                IMP original = method_getImplementation(method);
                if (original == hook) continue;
                WolFoxNavigationOriginals[
                    WolFoxNavigationHookKey(cls, selector)
                ] = WolFoxNavigationIMPValue(original);
                method_setImplementation(method, hook);
            }
        };
    applyTargets([NSUserDefaults.standardUserDefaults arrayForKey:cacheKey]);
}

static void WolFoxDiscoverNavigationMethodHooks(void) {
    NSSet<NSString *> *selectors = [NSSet setWithArray:@[
        @"notificationButton",
        @"newNotificationButton",
        @"connectionsButton",
        @"messagesButton",
        @"messageButton",
        @"chatButton",
        @"inboxButton"
    ]];
    NSMutableOrderedSet<NSString *> *targets = [NSMutableOrderedSet orderedSet];
    for (NSString *scanName in WolFoxAppClassNames()) {
        Class cls = NSClassFromString(scanName);
        if (cls == Nil) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
            Method method = methods[methodIndex];
            SEL selector = method_getName(method);
            NSString *selectorName = NSStringFromSelector(selector);
            if (![selectors containsObject:selectorName]) continue;
            [targets addObject:[NSString stringWithFormat:@"%@|%@",
                NSStringFromClass(cls), selectorName]];
        }
        free(methods);
    }

    NSString *version = NSBundle.mainBundle
        .infoDictionary[@"CFBundleShortVersionString"] ?: @"unknown";
    NSString *cacheKey =
        [@"WolFoxNavigationHookTargets." stringByAppendingString:version];
    NSArray<NSString *> *result = targets.array;
    [NSUserDefaults.standardUserDefaults setObject:result forKey:cacheKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        WolFoxInstallNavigationMethodHooks();
        WolFoxApplyNavigationWindows();
    });
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

static BOOL WolFoxNavigationShouldHide(UIView *view) {
    if (!WolFoxIsNavigationIcon(view)) return NO;
    NSString *token = [[NSString stringWithFormat:@"%@ %@ %@",
                        NSStringFromClass(view.class),
                        view.accessibilityIdentifier ?: @"",
                        view.accessibilityLabel ?: @""] lowercaseString];
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.AccountHidden") &&
        ([token containsString:@"account"] ||
         [token containsString:@"avatar"] ||
         [token containsString:@"profile"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.SearchHidden") &&
        [token containsString:@"search"]) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.CastHidden") &&
        ([token containsString:@"cast"] ||
         [token containsString:@"airplay"] ||
         [token containsString:@"routebutton"] ||
         WolFoxMatchesAncestorButton(view, @"MDXButton"))) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.NotificationsHidden") &&
        ([token containsString:@"notification"] ||
         [token containsString:@"bell"])) {
        return YES;
    }
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.MessagesHidden") &&
        WolFoxInsideRightNavigation(view) && WolFoxIsMessagesToken(token)) {
        return YES;
    }
    return NO;
}

static BOOL WolFoxIsNavigationIcon(UIView *view) {
    NSString *token = [[NSString stringWithFormat:@"%@ %@ %@",
                        NSStringFromClass(view.class),
                        view.accessibilityIdentifier ?: @"",
                        view.accessibilityLabel ?: @""] lowercaseString];
    if ([token containsString:@"account"] ||
        [token containsString:@"avatar"] ||
        [token containsString:@"profile"] ||
        [token containsString:@"logo"]) return NO;
    if ([token containsString:@"notification"] ||
        [token containsString:@"bell"] ||
        [token containsString:@"search"] ||
        [token containsString:@"cast"] ||
        [token containsString:@"airplay"] ||
        [token containsString:@"routebutton"] ||
        (WolFoxInsideRightNavigation(view) && WolFoxIsMessagesToken(token))) {
        return YES;
    }
    if (![view isKindOfClass:UIButton.class] &&
        ![view isKindOfClass:UIImageView.class]) return NO;
    for (UIView *ancestor = view.superview; ancestor != nil;
         ancestor = ancestor.superview) {
        NSString *name = NSStringFromClass(ancestor.class).lowercaseString;
        if ([name containsString:@"rightnavigation"] ||
            [name containsString:@"headernavigation"] ||
            [name containsString:@"topbar"]) return YES;
    }
    return NO;
}

static UIColor *WolFoxNavigationForeground(UIView *view) {
    if (WolFoxInsideRightNavigation(view)) {
        UIUserInterfaceStyle style = WolFoxNavigationStyle;
        if (style == UIUserInterfaceStyleUnspecified) {
            style = view.window.traitCollection.userInterfaceStyle;
        }
        if (style == UIUserInterfaceStyleUnspecified) {
            style = view.traitCollection.userInterfaceStyle;
        }
        return style == UIUserInterfaceStyleDark
            ? UIColor.whiteColor : UIColor.blackColor;
    }
    for (UIView *current = view.superview; current != nil;
         current = current.superview) {
        UIColor *resolved = [current.backgroundColor
            resolvedColorWithTraitCollection:view.traitCollection];
        CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
        if ([resolved getRed:&red green:&green blue:&blue alpha:&alpha] &&
            alpha > 0.5) {
            CGFloat luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722;
            return luminance < 0.5 ? UIColor.whiteColor : UIColor.blackColor;
        }
    }
    return view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
        ? UIColor.whiteColor : UIColor.blackColor;
}

static BOOL WolFoxInsideRightNavigation(UIView *view) {
    for (UIView *current = view; current != nil; current = current.superview) {
        if ([NSStringFromClass(current.class)
                isEqualToString:@"YTRightNavigationButtons"]) return YES;
    }
    return NO;
}

static void WolFoxApplyNavigationTint(UIView *view, UIColor *color) {
    view.tintColor = color;
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        for (NSNumber *stateValue in @[@(UIControlStateNormal),
                                        @(UIControlStateHighlighted),
                                        @(UIControlStateSelected)]) {
            UIControlState state = (UIControlState)stateValue.unsignedIntegerValue;
            UIImage *image = [button imageForState:state];
            if (image != nil) {
                [button setImage:[image imageWithRenderingMode:
                    UIImageRenderingModeAlwaysTemplate] forState:state];
            }
        }
    } else if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *imageView = (UIImageView *)view;
        if (imageView.image != nil) {
            imageView.image = [imageView.image imageWithRenderingMode:
                UIImageRenderingModeAlwaysTemplate];
        }
    }
    for (UIView *subview in view.subviews) {
        WolFoxApplyNavigationTint(subview, color);
    }
}

static void WolFoxApplyNavigationTree(UIView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"YTRightNavigationButtons"]) {
        WolFoxApplyNavigationSelectors(view);
    }
    WolFoxSetNavigationHidden(view, WolFoxNavigationShouldHide(view));
    if (WolFoxFeatureEnabled(WolFoxOLEDKey) &&
        WolFoxIsNavigationIcon(view)) {
        WolFoxApplyNavigationTint(view, WolFoxNavigationForeground(view));
    }
    for (UIView *subview in view.subviews) {
        WolFoxApplyNavigationTree(subview);
    }
}

void WolFoxRefreshNavigationAppearance(void) {
    if (!WolFoxFeatureEnabled(WolFoxOLEDKey)) return;
    WolFoxApplyNavigationWindows();
    for (UIView *owner in WolFoxNavigationOwners.allObjects) {
        WolFoxApplyNavigationSelectors(owner);
    }
}

static void WolFoxApplyNavigationWindows(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden) WolFoxApplyNavigationTree(window);
        }
    }
}

static UIView *WolFoxNavigationValue(id owner, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if ([owner respondsToSelector:selector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(owner, selector);
        if ([value isKindOfClass:UIView.class]) return value;
    }
    @try {
        id value = [owner valueForKey:name];
        return [value isKindOfClass:UIView.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void WolFoxApplyNavigationSelectors(id owner) {
    NSDictionary<NSString *, NSArray<NSString *> *> *groups = @{
        @"YTKACE.Preference.Navigation.NotificationsHidden": @[
            @"notificationButton", @"newNotificationButton",
            @"notificationBellButton", @"notificationBellView"
        ],
        @"YTKACE.Preference.Navigation.MessagesHidden": @[
            @"connectionsButton", @"messagesButton", @"messageButton",
            @"chatButton", @"inboxButton"
        ],
        @"YTKACE.Preference.Navigation.SearchHidden": @[@"searchButton"],
        @"YTKACE.Preference.Navigation.CastHidden": @[@"castButton", @"MDXButton"],
        @"YTKACE.Preference.Navigation.AccountHidden": @[@"accountButton", @"avatarButton"]
    };
    for (NSString *key in groups) {
        BOOL hidden = WolFoxFeatureEnabled(key);
        for (NSString *name in groups[key]) {
            UIView *target = WolFoxNavigationValue(owner, name);
            WolFoxSetNavigationHidden(target, hidden);
            if (target != nil && !hidden &&
                WolFoxFeatureEnabled(WolFoxOLEDKey)) {
                WolFoxApplyNavigationTint(
                    target, WolFoxNavigationForeground(target));
            }
        }
    }
}

void WolFoxApplyRightNavigationVisibility(UIView *view) {
    if (WolFoxNavigationOwners == nil) {
        WolFoxNavigationOwners = [NSHashTable weakObjectsHashTable];
    }
    [WolFoxNavigationOwners addObject:view];
    WolFoxApplyNavigationSelectors(view);
    WolFoxApplyNavigationTree(view);
}

static void WolFoxHeaderLogoLayout(UIView *receiver, SEL selector) {
    if (OriginalHeaderLogoLayout != NULL) {
        ((void (*)(id, SEL))OriginalHeaderLogoLayout)(receiver, selector);
    }
    WolFoxSetNavigationHidden(
        receiver,
        WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.LogoHidden")
    );
}

static void WolFoxLogoViewLayout(UIView *receiver, SEL selector) {
    if (OriginalLogoViewLayout != NULL) {
        ((void (*)(id, SEL))OriginalLogoViewLayout)(receiver, selector);
    }
    WolFoxSetNavigationHidden(
        receiver,
        WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.LogoHidden")
    );
}

static void WolFoxHeaderLogoSetHidden(UIView *receiver,
                                      SEL selector,
                                      BOOL hidden) {
    if (hidden || !WolFoxFeatureEnabled(
            @"YTKACE.Preference.Navigation.LogoHidden")) {
        if (OriginalHeaderLogoSetHidden != NULL) {
            ((void (*)(id, SEL, BOOL))OriginalHeaderLogoSetHidden)(
                receiver, selector, hidden);
        }
        return;
    }
    if (OriginalHeaderLogoSetHidden != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalHeaderLogoSetHidden)(
            receiver, selector, YES);
    }
}

static void WolFoxLogoViewSetHidden(UIView *receiver,
                                    SEL selector,
                                    BOOL hidden) {
    if (hidden || !WolFoxFeatureEnabled(
            @"YTKACE.Preference.Navigation.LogoHidden")) {
        if (OriginalLogoViewSetHidden != NULL) {
            ((void (*)(id, SEL, BOOL))OriginalLogoViewSetHidden)(
                receiver, selector, hidden);
        }
        return;
    }
    if (OriginalLogoViewSetHidden != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalLogoViewSetHidden)(
            receiver, selector, YES);
    }
}

static void WolFoxYTImageSetHidden(UIView *receiver,
                                   SEL selector,
                                   BOOL hidden) {
    NSString *label = receiver.accessibilityLabel;
    if (hidden ||
        (![receiver.accessibilityIdentifier isEqualToString:@"id.youtube.logo"] &&
         !(label.length != 0 &&
           [label caseInsensitiveCompare:@"YouTube"] == NSOrderedSame)) ||
        !WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.LogoHidden")) {
        if (OriginalYTImageSetHidden != NULL) {
            ((void (*)(id, SEL, BOOL))OriginalYTImageSetHidden)(
                receiver, selector, hidden);
        }
        return;
    }
    if (OriginalYTImageSetHidden != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalYTImageSetHidden)(
            receiver, selector, YES);
    }
}

// The setting that hides this top bar button, if any. Ids first, since
// labels change with the app language.
static NSString *WolFoxQTMButtonHideKey(UIView *receiver) {
    NSString *identifier = receiver.accessibilityIdentifier.lowercaseString;
    NSString *label = receiver.accessibilityLabel.lowercaseString;
    if ([identifier isEqualToString:@"id.connections.inbox.button"] ||
        [label isEqualToString:@"messages"] ||
        [label isEqualToString:@"message"] ||
        [label isEqualToString:@"chat"] ||
        [label isEqualToString:@"inbox"]) {
        return @"YTKACE.Preference.Navigation.MessagesHidden";
    }
    if ([identifier isEqualToString:@"id.ui.navigation.search.button"] ||
        [label isEqualToString:@"search"]) {
        return @"YTKACE.Preference.Navigation.SearchHidden";
    }
    if ([label isEqualToString:@"notifications"] ||
        [label isEqualToString:@"notification"]) {
        return @"YTKACE.Preference.Navigation.NotificationsHidden";
    }
    return nil;
}

static void WolFoxQTMButtonLayout(UIView *receiver, SEL selector) {
    if (OriginalQTMButtonLayout != NULL) {
        ((void (*)(id, SEL))OriginalQTMButtonLayout)(receiver, selector);
    }
    NSString *key = WolFoxQTMButtonHideKey(receiver);
    if (key != nil) WolFoxSetNavigationHidden(receiver, WolFoxFeatureEnabled(key));
    if (WolFoxFeatureEnabled(WolFoxOLEDKey) &&
        WolFoxIsNavigationIcon(receiver)) {
        WolFoxApplyNavigationTint(receiver,
                                  WolFoxNavigationForeground(receiver));
    }
}

// Some tabs (You) show their top bar buttons again after layout, so keep
// hidden buttons hidden here too.
static void WolFoxQTMButtonSetHidden(UIView *receiver, SEL selector, BOOL hidden) {
    if (!hidden) {
        NSString *key = WolFoxQTMButtonHideKey(receiver);
        if (key != nil && WolFoxFeatureEnabled(key) &&
            WolFoxInsideRightNavigation(receiver)) hidden = YES;
    }
    ((void (*)(id, SEL, BOOL))OriginalQTMButtonSetHidden)(receiver, selector, hidden);
}

// YouTube sets the id after the button is laid out, so check again then.
static void WolFoxQTMButtonSetIdentifier(UIView *receiver, SEL selector, NSString *value) {
    ((void (*)(id, SEL, id))OriginalQTMButtonSetIdentifier)(receiver, selector, value);
    NSString *key = WolFoxQTMButtonHideKey(receiver);
    if (key != nil && WolFoxFeatureEnabled(key) && WolFoxInsideRightNavigation(receiver)) {
        WolFoxSetNavigationHidden(receiver, YES);
    }
}

static void WolFoxQTMButtonDidMoveToWindow(UIView *receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalQTMButtonDidMoveToWindow)(receiver, selector);
    if (receiver.window == nil) return;
    NSString *key = WolFoxQTMButtonHideKey(receiver);
    if (key != nil && WolFoxFeatureEnabled(key) && WolFoxInsideRightNavigation(receiver)) {
        WolFoxSetNavigationHidden(receiver, YES);
    }
}

static void WolFoxQTMButtonSetTint(UIView *receiver,
                                   SEL selector,
                                   UIColor *color) {
    if (WolFoxFeatureEnabled(WolFoxOLEDKey) &&
        WolFoxInsideRightNavigation(receiver)) {
        color = WolFoxNavigationForeground(receiver);
    }
    if (OriginalQTMButtonSetTint != NULL) {
        ((void (*)(id, SEL, id))OriginalQTMButtonSetTint)(
            receiver, selector, color);
    }
}

static void WolFoxNavigationImageSetTint(UIView *receiver,
                                         SEL selector,
                                         UIColor *color) {
    if (WolFoxFeatureEnabled(WolFoxOLEDKey) &&
        WolFoxInsideRightNavigation(receiver)) {
        color = WolFoxNavigationForeground(receiver);
    }
    if (OriginalNavigationImageSetTint != NULL) {
        ((void (*)(id, SEL, id))OriginalNavigationImageSetTint)(
            receiver, selector, color);
    }
}

static void WolFoxQTMButtonSetImage(UIButton *receiver,
                                    SEL selector,
                                    UIImage *image,
                                    UIControlState state) {
    BOOL styled = WolFoxFeatureEnabled(WolFoxOLEDKey) &&
        WolFoxInsideRightNavigation(receiver);
    if (styled && image != nil) {
        image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    if (OriginalQTMButtonSetImage != NULL) {
        ((void (*)(id, SEL, id, UIControlState))OriginalQTMButtonSetImage)(
            receiver, selector, image, state);
    }
    if (styled && OriginalQTMButtonSetTint != NULL) {
        ((void (*)(id, SEL, id))OriginalQTMButtonSetTint)(
            receiver, @selector(setTintColor:),
            WolFoxNavigationForeground(receiver));
    }
}

static void WolFoxNavigationImageSetImage(UIImageView *receiver,
                                          SEL selector,
                                          UIImage *image) {
    BOOL styled = WolFoxFeatureEnabled(WolFoxOLEDKey) &&
        WolFoxInsideRightNavigation(receiver);
    if (styled && image != nil) {
        image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    if (OriginalNavigationImageSetImage != NULL) {
        ((void (*)(id, SEL, id))OriginalNavigationImageSetImage)(
            receiver, selector, image);
    }
    if (styled && OriginalNavigationImageSetTint != NULL) {
        ((void (*)(id, SEL, id))OriginalNavigationImageSetTint)(
            receiver, @selector(setTintColor:),
            WolFoxNavigationForeground(receiver));
    }
}

static void WolFoxMainWindowTraitChanged(UIWindow *receiver,
                                         SEL selector,
                                         UITraitCollection *previous) {
    if (OriginalMainWindowTraitChanged != NULL) {
        ((void (*)(id, SEL, id))OriginalMainWindowTraitChanged)(
            receiver, selector, previous);
    }
    UIUserInterfaceStyle style = receiver.traitCollection.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified ||
        style == previous.userInterfaceStyle) return;
    WolFoxNavigationStyle = style;
    if (WolFoxFeatureEnabled(WolFoxOLEDKey)) {
        WolFoxRefreshNavigationAppearance();
    }
}

static void WolFoxRightNavigationTraitChanged(UIView *receiver,
                                              SEL selector,
                                              UITraitCollection *previous) {
    if (OriginalRightNavigationTraitChanged != NULL) {
        ((void (*)(id, SEL, id))OriginalRightNavigationTraitChanged)(
            receiver, selector, previous);
    }
    UIUserInterfaceStyle style = receiver.traitCollection.userInterfaceStyle;
    if (style != UIUserInterfaceStyleUnspecified) {
        WolFoxNavigationStyle = style;
    }
    if (WolFoxFeatureEnabled(WolFoxOLEDKey)) {
        WolFoxApplyRightNavigationVisibility(receiver);
    }
}

static void WolFoxYTImageViewLayout(UIView *receiver, SEL selector) {
    if (OriginalYTImageViewLayout != NULL) {
        ((void (*)(id, SEL))OriginalYTImageViewLayout)(receiver, selector);
    }
    NSString *label = receiver.accessibilityLabel;
    if ([receiver.accessibilityIdentifier isEqualToString:@"id.youtube.logo"] ||
        (label.length != 0 &&
         [label caseInsensitiveCompare:@"YouTube"] == NSOrderedSame)) {
        WolFoxSetNavigationHidden(
            receiver,
            WolFoxFeatureEnabled(@"YTKACE.Preference.Navigation.LogoHidden")
        );
    }
}

void WolFoxInstallNavigationVisibilityHooks(void) {
    WolFoxInstallNavigationMethodHooks();
    WolFoxInstallInstanceHook(@"YTHeaderLogoView",
                              @"layoutSubviews",
                              (IMP)WolFoxHeaderLogoLayout,
                              &OriginalHeaderLogoLayout);
    WolFoxInstallInstanceHook(@"YTHeaderLogoView",
                              @"setHidden:",
                              (IMP)WolFoxHeaderLogoSetHidden,
                              &OriginalHeaderLogoSetHidden);
    WolFoxInstallInstanceHook(@"YTLogoView",
                              @"layoutSubviews",
                              (IMP)WolFoxLogoViewLayout,
                              &OriginalLogoViewLayout);
    WolFoxInstallInstanceHook(@"YTLogoView",
                              @"setHidden:",
                              (IMP)WolFoxLogoViewSetHidden,
                              &OriginalLogoViewSetHidden);
    WolFoxInstallInstanceHook(@"YTQTMButton",
                              @"layoutSubviews",
                              (IMP)WolFoxQTMButtonLayout,
                              &OriginalQTMButtonLayout);
    WolFoxInstallInstanceHook(@"YTQTMButton",
                              @"setHidden:",
                              (IMP)WolFoxQTMButtonSetHidden,
                              &OriginalQTMButtonSetHidden);
    WolFoxInstallInstanceHook(@"YTQTMButton",
                              @"setAccessibilityIdentifier:",
                              (IMP)WolFoxQTMButtonSetIdentifier,
                              &OriginalQTMButtonSetIdentifier);
    WolFoxInstallInstanceHook(@"YTQTMButton",
                              @"didMoveToWindow",
                              (IMP)WolFoxQTMButtonDidMoveToWindow,
                              &OriginalQTMButtonDidMoveToWindow);
    WolFoxInstallInstanceHook(@"YTQTMButton",
                              @"setTintColor:",
                              (IMP)WolFoxQTMButtonSetTint,
                              &OriginalQTMButtonSetTint);
    WolFoxInstallInstanceHook(@"YTQTMButton",
                              @"setImage:forState:",
                              (IMP)WolFoxQTMButtonSetImage,
                              &OriginalQTMButtonSetImage);
    WolFoxInstallInstanceHook(@"UIImageView",
                              @"setTintColor:",
                              (IMP)WolFoxNavigationImageSetTint,
                              &OriginalNavigationImageSetTint);
    WolFoxInstallInstanceHook(@"UIImageView",
                              @"setImage:",
                              (IMP)WolFoxNavigationImageSetImage,
                              &OriginalNavigationImageSetImage);
    WolFoxInstallInstanceHook(@"YTImageView",
                              @"layoutSubviews",
                              (IMP)WolFoxYTImageViewLayout,
                              &OriginalYTImageViewLayout);
    WolFoxInstallInstanceHook(@"YTImageView",
                              @"setHidden:",
                              (IMP)WolFoxYTImageSetHidden,
                              &OriginalYTImageSetHidden);
    WolFoxInstallInstanceHook(@"YTMainWindow",
                              @"traitCollectionDidChange:",
                              (IMP)WolFoxMainWindowTraitChanged,
                              &OriginalMainWindowTraitChanged);
    WolFoxInstallInstanceHook(@"YTRightNavigationButtons",
                              @"traitCollectionDidChange:",
                              (IMP)WolFoxRightNavigationTraitChanged,
                              &OriginalRightNavigationTraitChanged);
    WolFoxApplyNavigationWindows();
    if (!WolFoxNavigationObserverInstalled) {
        WolFoxNavigationObserverInstalled = YES;
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *notification) {
                NSString *version = NSBundle.mainBundle
                    .infoDictionary[@"CFBundleShortVersionString"] ?: @"unknown";
                NSString *cacheKey = [@"WolFoxNavigationHookTargets."
                    stringByAppendingString:version];
                if ([NSUserDefaults.standardUserDefaults
                        arrayForKey:cacheKey].count == 0) {
                    static dispatch_once_t discoveryToken;
                    dispatch_once(&discoveryToken, ^{
                        dispatch_async(
                            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                                WolFoxDiscoverNavigationMethodHooks();
                            }
                        );
                    });
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        WolFoxApplyNavigationWindows();
                    });
            }];
    }
}

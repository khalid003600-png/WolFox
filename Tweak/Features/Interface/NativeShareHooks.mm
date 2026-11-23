#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

static IMP OriginalShowShareSheet;
static IMP OriginalShareEntityExecute;

static id WolFoxShareValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *WolFoxSerializedShareEntity(id receiver,
                                               id onAppear,
                                               id context) {
    NSRegularExpression *expression = [NSRegularExpression
        regularExpressionWithPattern:@"serialized_share_entity: \"([^\"]+)\""
        options:0 error:nil];
    if (expression == nil) return nil;
    for (id object in @[receiver ?: NSNull.null,
                        onAppear ?: NSNull.null,
                        context ?: NSNull.null]) {
        if (object == NSNull.null) continue;
        NSString *description = [object description];
        NSTextCheckingResult *match = [expression
            firstMatchInString:description options:0
            range:NSMakeRange(0, description.length)];
        if (match.numberOfRanges > 1) {
            return [description substringWithRange:[match rangeAtIndex:1]];
        }
    }
    return nil;
}

static BOOL WolFoxShareBool(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return object != nil && [object respondsToSelector:selector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static id WolFoxShareExtension(id object, id descriptor) {
    if (object == nil || descriptor == nil) return nil;
    SEL has = NSSelectorFromString(@"hasExtension:");
    SEL get = NSSelectorFromString(@"getExtension:");
    if (![object respondsToSelector:has] ||
        ![object respondsToSelector:get] ||
        !((BOOL (*)(id, SEL, id))objc_msgSend)(object, has, descriptor)) {
        return nil;
    }
    return ((id (*)(id, SEL, id))objc_msgSend)(object, get, descriptor);
}

static BOOL WolFoxShareVarint(const uint8_t *bytes, NSUInteger length, NSUInteger *offset, uint64_t *value) {
    uint64_t result = 0;
    for (NSUInteger shift = 0; shift < 64 && *offset < length; shift += 7) {
        uint8_t byte = bytes[(*offset)++];
        result |= (uint64_t)(byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) {
            *value = result;
            return YES;
        }
    }
    return NO;
}

static NSDictionary<NSNumber *, NSData *> *WolFoxShareFields(NSData *data) {
    NSMutableDictionary<NSNumber *, NSData *> *fields = [NSMutableDictionary dictionary];
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;
    NSUInteger offset = 0;
    while (offset < length) {
        uint64_t key = 0;
        if (!WolFoxShareVarint(bytes, length, &offset, &key)) break;
        NSNumber *number = @(key >> 3);
        switch (key & 7) {
            case 0: {
                uint64_t value = 0;
                if (!WolFoxShareVarint(bytes, length, &offset, &value)) return fields;
                if (fields[number] == nil) fields[number] = [NSData data];
                break;
            }
            case 2: {
                uint64_t size = 0;
                if (!WolFoxShareVarint(bytes, length, &offset, &size) || size > length - offset) return fields;
                if (fields[number] == nil) fields[number] = [NSData dataWithBytes:bytes + offset length:(NSUInteger)size];
                offset += (NSUInteger)size;
                break;
            }
            case 1: offset += 8; break;
            case 5: offset += 4; break;
            default: return fields;
        }
    }
    return fields;
}

static NSString *WolFoxShareText(NSData *data) {
    if (data.length == 0) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text.length != 0 ? text : nil;
}

static NSURL *WolFoxShareEntityURL(NSString *serialized) {
    if (serialized.length == 0) return nil;
    NSString *text = [serialized stringByRemovingPercentEncoding] ?: serialized;
    text = [[text stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
        stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (text.length % 4 != 0) text = [text stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:text options:0];
    if (data.length == 0) return nil;
    NSDictionary<NSNumber *, NSData *> *fields = WolFoxShareFields(data);
    NSString *clipID = WolFoxShareText(WolFoxShareFields(fields[@8])[@1]);
    if (clipID != nil) return [NSURL URLWithString:[@"https://youtube.com/clip/" stringByAppendingString:clipID]];
    NSString *channelID = WolFoxShareText(fields[@3]);
    if (channelID != nil) return [NSURL URLWithString:[@"https://youtube.com/channel/" stringByAppendingString:channelID]];
    NSString *postID = WolFoxShareText(fields[@6]);
    if (postID != nil) return [NSURL URLWithString:[@"https://youtube.com/post/" stringByAppendingString:postID]];
    NSString *playlistID = WolFoxShareText(fields[@2]);
    if (playlistID != nil) {
        NSString *suffix = [playlistID hasPrefix:@"PL"] || [playlistID hasPrefix:@"FL"] ? @"" : @"&playnext=1";
        return [NSURL URLWithString:[NSString stringWithFormat:@"https://youtube.com/playlist?list=%@%@", playlistID, suffix]];
    }
    NSString *videoID = WolFoxShareText(fields[@1]);
    if (videoID == nil) return nil;
    NSString *format = fields[@10] != nil ? @"https://youtube.com/shorts/%@" : @"https://youtube.com/watch?v=%@";
    return [NSURL URLWithString:[NSString stringWithFormat:format, videoID]];
}

static id WolFoxFindPlayerController(UIViewController *controller, NSString *videoID, NSUInteger depth) {
    if (controller == nil || depth > 14) return nil;
    SEL current = NSSelectorFromString(@"currentVideoID");
    if ([NSStringFromClass(controller.class) isEqualToString:@"YTPlayerViewController"] &&
        [controller respondsToSelector:current]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(controller, current);
        if ([value isKindOfClass:NSString.class] && [value isEqualToString:videoID]) return controller;
    }
    for (UIViewController *child in controller.childViewControllers) {
        id found = WolFoxFindPlayerController(child, videoID, depth + 1);
        if (found != nil) return found;
    }
    return WolFoxFindPlayerController(controller.presentedViewController, videoID, depth + 1);
}

static NSURL *WolFoxShareURLWithTime(NSURL *URL) {
    if (URL == nil || !WolFoxFeatureEnabled(@"YTKACE.Preference.Sharing.Timestamp")) return URL;
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (![components.path isEqualToString:@"/watch"]) return URL;
    NSString *videoID = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"v"]) videoID = item.value;
    }
    if (videoID.length == 0) return URL;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            id player = WolFoxFindPlayerController(window.rootViewController, videoID, 0);
            SEL timeSel = NSSelectorFromString(@"currentVideoMediaTime");
            if (player == nil || ![player respondsToSelector:timeSel]) continue;
            double time = ((double (*)(id, SEL))objc_msgSend)(player, timeSel);
            if (time < 1.0) return URL;
            NSMutableArray *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
            [items addObject:[NSURLQueryItem queryItemWithName:@"t"
                                                         value:[NSString stringWithFormat:@"%lds", (long)time]]];
            components.queryItems = items;
            return components.URL ?: URL;
        }
    }
    return URL;
}

static UIViewController *WolFoxSharePresenter(void) {
    Class utils = NSClassFromString(@"YTUIUtils");
    SEL top = NSSelectorFromString(@"topViewControllerForPresenting");
    if ([utils respondsToSelector:top]) {
        UIViewController *native =
            ((id (*)(id, SEL))objc_msgSend)(utils, top);
        if (native != nil) return native;
    }
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window != nil) break;
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).visibleViewController;
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        controller = ((UITabBarController *)controller).selectedViewController;
    }
    return controller;
}

static void WolFoxPresentNativeShare(NSURL *URL, UIView *source) {
    if (URL == nil) return;
    URL = WolFoxShareURLWithTime(URL);
    __weak UIView *weakSource = source;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = WolFoxSharePresenter();
        if (presenter == nil) return;
        UIActivityViewController *sheet =
            [[UIActivityViewController alloc] initWithActivityItems:@[URL]
                                              applicationActivities:nil];
        sheet.excludedActivityTypes = @[
            UIActivityTypeAssignToContact,
            UIActivityTypePrint
        ];
        UIPopoverPresentationController *popover = sheet.popoverPresentationController;
        if (popover != nil) {
            UIView *anchor = weakSource;
            if (anchor.window != nil) {
                popover.sourceView = anchor;
                popover.sourceRect = anchor.bounds;
            } else {
                UIView *host = presenter.view.window ?: presenter.view;
                popover.sourceView = host;
                popover.sourceRect = CGRectMake(
                    CGRectGetMidX(host.bounds),
                    CGRectGetMidY(host.bounds), 1.0, 1.0);
                popover.permittedArrowDirections = 0;
            }
        }
        [presenter presentViewController:sheet animated:YES completion:nil];
    });
}

static void WolFoxShareEntityExecute(id receiver, SEL selector, id command,
                                     id entry, UIView *fromView, id sender) {
    if (WolFoxFeatureEnabled(@"YTKACE.Preference.Sharing.NativeSheet")) {
        NSString *serialized = WolFoxSerializedShareEntity(command, nil, nil);
        NSURL *URL = WolFoxShareEntityURL(serialized);
        if (URL != nil) {
            WolFoxPresentNativeShare(URL, fromView);
            return;
        }
    }
    if (OriginalShareEntityExecute != NULL) {
        ((void (*)(id, SEL, id, id, id, id))OriginalShareEntityExecute)(
            receiver, selector, command, entry, fromView, sender);
    }
}

static void WolFoxShowShareSheet(id receiver, SEL selector,
                                 id context, id handler) {
    BOOL enabled = WolFoxFeatureEnabled(@"YTKACE.Preference.Sharing.NativeSheet");
    BOOL hasOnAppear = WolFoxShareBool(receiver, @"hasOnAppear");

    if (!enabled || !hasOnAppear) {
        if (OriginalShowShareSheet != NULL) {
            ((void (*)(id, SEL, id, id))OriginalShowShareSheet)(
                receiver, selector, context, handler);
        }
        return;
    }
    id onAppear = WolFoxShareValue(receiver, @"onAppear");
    Class rootClass = NSClassFromString(@"YTIInnertubeCommandExtensionRoot");
    Class updateClass = NSClassFromString(@"YTIUpdateShareSheetCommand");
    SEL rootSelector = NSSelectorFromString(@"innertubeCommand");
    SEL updateSelector = NSSelectorFromString(@"updateShareSheetCommand");
    id rootDescriptor = [rootClass respondsToSelector:rootSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(rootClass, rootSelector) : nil;
    id updateDescriptor = [updateClass respondsToSelector:updateSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(updateClass, updateSelector) : nil;
    id command = WolFoxShareExtension(onAppear, rootDescriptor);
    id update = WolFoxShareExtension(command, updateDescriptor);
    NSString *serialized = WolFoxShareValue(update, @"serializedShareEntity");
    if (serialized.length == 0) {
        serialized = WolFoxSerializedShareEntity(receiver, onAppear, context);
    }
    if (update == nil && serialized.length == 0) {
        if (OriginalShowShareSheet != NULL) {
            ((void (*)(id, SEL, id, id))OriginalShowShareSheet)(
                receiver, selector, context, handler);
        }
        return;
    }
    NSURL *URL = WolFoxShareEntityURL(serialized);
    if (URL == nil) {
        if (OriginalShowShareSheet != NULL) {
            ((void (*)(id, SEL, id, id))OriginalShowShareSheet)(
                receiver, selector, context, handler);
        }
        return;
    }
    WolFoxPresentNativeShare(URL, nil);
}

void WolFoxInstallNativeShareHooks(void) {
    WolFoxInstallInstanceHook(
        @"ELMPBShowActionSheetCommand",
        @"executeWithCommandContext:handler:",
        (IMP)WolFoxShowShareSheet,
        &OriginalShowShareSheet);
    // Renamed to ...Impl in YouTube 21.46.
    NSString *shareHandler =
        NSClassFromString(@"YTShareEntityEndpointCommandHandlerImpl") != Nil
            ? @"YTShareEntityEndpointCommandHandlerImpl"
            : @"YTShareEntityEndpointCommandHandler";
    WolFoxInstallInstanceHook(shareHandler,
                              @"executeWithCommand:entry:fromView:sender:",
                              (IMP)WolFoxShareEntityExecute,
                              &OriginalShareEntityExecute);
}

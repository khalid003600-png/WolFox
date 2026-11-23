#import "../../WolFox.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const WolFoxCleanLinksKey = @"YTKACE.Preference.Sharing.CleanLinks";
static NSString * const WolFoxDirectLinksKey = @"YTKACE.Preference.Sharing.DirectLinks";
static const NSUInteger WolFoxCopyTextField = 90198251;

static IMP OriginalCopyShareObject;
static IMP OriginalCopyShare;
static IMP OriginalTextShareObject;
static IMP OriginalMailShareObject;
static IMP OriginalSystemShareObject;
static IMP OriginalSystemShareText;
static IMP OriginalSystemItem;
static IMP OriginalSystemPlaceholder;
static IMP OriginalMessageSetBody;
static IMP OriginalMailSetBody;
static IMP OriginalOpenURL;

static BOOL WolFoxCleanLinksEnabled(void) {
    return WolFoxFeatureEnabled(WolFoxCleanLinksKey);
}

static BOOL WolFoxIsYouTubeHost(NSString *host) {
    host = host.lowercaseString;
    return [host isEqualToString:@"youtu.be"] || [host isEqualToString:@"youtube.com"] ||
        [host hasSuffix:@".youtube.com"];
}

static BOOL WolFoxIsTrackingParameter(NSString *name) {
    NSString *lower = name.lowercaseString;
    static NSSet<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[@"si", @"is", @"pp", @"feature", @"gclid", @"kw", @"ab_channel"]];
    });
    return [names containsObject:lower] || [lower hasPrefix:@"utm_"];
}

NSString *WolFoxCleanYouTubeLink(NSString *link) {
    if (![link isKindOfClass:NSString.class] || link.length == 0 || link.length > 8192) return link;
    NSURLComponents *components = [NSURLComponents componentsWithString:link];
    if (components == nil || !WolFoxIsYouTubeHost(components.host)) return link;
    NSArray<NSURLQueryItem *> *items = components.queryItems;
    if (items.count == 0) return link;
    NSMutableArray<NSURLQueryItem *> *kept = [NSMutableArray array];
    for (NSURLQueryItem *item in items) {
        if (!WolFoxIsTrackingParameter(item.name)) [kept addObject:item];
    }
    if (kept.count == items.count) return link;
    components.queryItems = kept.count != 0 ? kept : nil;
    return components.string ?: link;
}

static BOOL WolFoxIsWebScheme(NSString *scheme) {
    scheme = scheme.lowercaseString;
    return [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"];
}

static NSURL *WolFoxDirectLinkURL(NSURL *URL) {
    if (![URL isKindOfClass:NSURL.class] || !WolFoxIsWebScheme(URL.scheme)) return URL;
    NSString *host = URL.host.lowercaseString;
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (!([host isEqualToString:@"youtube.com"] || [host hasSuffix:@".youtube.com"]) ||
        ![components.path isEqualToString:@"/redirect"]) {
        return URL;
    }
    for (NSURLQueryItem *item in components.queryItems) {
        if (![item.name isEqualToString:@"q"]) continue;
        NSURL *target = item.value.length != 0 ? [NSURL URLWithString:item.value] : nil;
        return target.host.length != 0 && WolFoxIsWebScheme(target.scheme) ? target : URL;
    }
    return URL;
}

static NSString *WolFoxCleanLinksInText(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length == 0 || [text rangeOfString:@"http"].location == NSNotFound) {
        return text;
    }
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s\"'<>]+" options:0 error:NULL];
    });
    NSMutableString *result = [text mutableCopy];
    NSArray<NSTextCheckingResult *> *matches = [expression matchesInString:text options:0
                                                                     range:NSMakeRange(0, text.length)];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *link = [text substringWithRange:match.range];
        NSString *cleaned = WolFoxCleanYouTubeLink(link);
        if (![cleaned isEqualToString:link]) [result replaceCharactersInRange:match.range withString:cleaned];
    }
    return result;
}

static id WolFoxCleanLinkObject(id value) {
    if (!WolFoxCleanLinksEnabled()) return value;
    if ([value isKindOfClass:NSURL.class]) {
        NSString *cleaned = WolFoxCleanYouTubeLink([value absoluteString]);
        return [NSURL URLWithString:cleaned] ?: value;
    }
    if ([value isKindOfClass:NSString.class]) return WolFoxCleanLinksInText(value);
    return value;
}

static void WolFoxCleanCopyEndpoint(id sharer) {
    id endpoint = nil;
    @try {
        endpoint = [sharer valueForKey:@"_navigationEndpoint"];
    } @catch (__unused NSException *exception) {
        return;
    }
    SEL extension = NSSelectorFromString(@"messageForFieldNumber:");
    if (![endpoint respondsToSelector:extension]) return;
    id copyText = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(endpoint, extension, WolFoxCopyTextField);
    SEL getText = NSSelectorFromString(@"text");
    SEL setText = NSSelectorFromString(@"setText:");
    if (![copyText respondsToSelector:getText] || ![copyText respondsToSelector:setText]) return;
    NSString *text = ((id (*)(id, SEL))objc_msgSend)(copyText, getText);
    NSString *cleaned = WolFoxCleanLinksInText(text);
    WolFoxDebugLog(@"links", @"copy text %@ -> %@", text ?: @"-", cleaned ?: @"-");
    if (cleaned != nil && ![cleaned isEqualToString:text]) {
        ((void (*)(id, SEL, id))objc_msgSend)(copyText, setText, cleaned);
    }
}

#define WOLFOX_SHARE_OBJECT_HOOK(name, original) \
static void name(id receiver, SEL selector, id objectID, long long type, id URL, id title, id success, id failure) { \
    id cleaned = WolFoxCleanLinkObject(URL); \
    WolFoxDebugLog(@"links", @"%@ url %@ -> %@", NSStringFromClass([receiver class]), URL, cleaned); \
    ((void (*)(id, SEL, id, long long, id, id, id, id))original)(receiver, selector, objectID, type, cleaned, title, \
                                                                  success, failure); \
}

WOLFOX_SHARE_OBJECT_HOOK(WolFoxCopyShareObject, OriginalCopyShareObject)
WOLFOX_SHARE_OBJECT_HOOK(WolFoxTextShareObject, OriginalTextShareObject)
WOLFOX_SHARE_OBJECT_HOOK(WolFoxMailShareObject, OriginalMailShareObject)
WOLFOX_SHARE_OBJECT_HOOK(WolFoxSystemShareObject, OriginalSystemShareObject)

static void WolFoxCopyShare(id receiver, SEL selector, id success, id failure) {
    if (WolFoxCleanLinksEnabled()) WolFoxCleanCopyEndpoint(receiver);
    ((void (*)(id, SEL, id, id))OriginalCopyShare)(receiver, selector, success, failure);
}

static void WolFoxSystemShareText(id receiver, SEL selector, id text, id URL, id subject, id entity,
                                  id success, id failure) {
    id cleanedText = WolFoxCleanLinkObject(text);
    id cleanedURL = WolFoxCleanLinkObject(URL);
    WolFoxDebugLog(@"links", @"system text %@ url %@ -> %@", text, URL, cleanedURL);
    ((void (*)(id, SEL, id, id, id, id, id, id))OriginalSystemShareText)(receiver, selector, cleanedText, cleanedURL,
                                                                         subject, entity, success, failure);
}

static id WolFoxSystemItem(id receiver, SEL selector, id controller, id activityType) {
    id item = ((id (*)(id, SEL, id, id))OriginalSystemItem)(receiver, selector, controller, activityType);
    id cleaned = WolFoxCleanLinkObject(item);
    WolFoxDebugLog(@"links", @"system item %@ %@ -> %@", activityType, item, cleaned);
    return cleaned;
}

static id WolFoxSystemPlaceholder(id receiver, SEL selector, id controller) {
    id item = ((id (*)(id, SEL, id))OriginalSystemPlaceholder)(receiver, selector, controller);
    return WolFoxCleanLinkObject(item);
}

static void WolFoxMessageSetBody(id receiver, SEL selector, id body) {
    ((void (*)(id, SEL, id))OriginalMessageSetBody)(receiver, selector, WolFoxCleanLinkObject(body));
}

static void WolFoxMailSetBody(id receiver, SEL selector, id body, BOOL html) {
    ((void (*)(id, SEL, id, BOOL))OriginalMailSetBody)(receiver, selector, WolFoxCleanLinkObject(body), html);
}

static void WolFoxOpenURL(id receiver, SEL selector, id URL, id options, id completion) {
    id target = URL;
    if (WolFoxFeatureEnabled(WolFoxDirectLinksKey)) {
        target = WolFoxDirectLinkURL(URL);
        if (target != URL) WolFoxDebugLog(@"links", @"open redirect %@ -> %@", ((NSURL *)URL).host ?: @"-", ((NSURL *)target).host ?: @"-");
    }
    ((void (*)(id, SEL, id, id, id))OriginalOpenURL)(receiver, selector, target, options, completion);
}

static BOOL WolFoxLinkMethodTypes(NSString *className, NSString *selector, const char *prefix) {
    Method method = class_getInstanceMethod(NSClassFromString(className), NSSelectorFromString(selector));
    const char *types = method != NULL ? method_getTypeEncoding(method) : NULL;
    return types != NULL && strncmp(types, prefix, strlen(prefix)) == 0;
}

static BOOL WolFoxInstallLinkHook(NSString *className, NSString *selector, const char *prefix, IMP replacement,
                                  IMP *original) {
    return WolFoxLinkMethodTypes(className, selector, prefix) &&
        WolFoxInstallInstanceHook(className, selector, replacement, original);
}

void WolFoxInstallLinkCleaningHooks(void) {
    NSString *shareObject = @"shareObjectWithID:shareType:URL:title:successBlock:errorBlock:";
    const char *shareObjectTypes = "v64@0:8@16q24@32@40";
    BOOL copyObject = WolFoxInstallLinkHook(@"YTCopyLinkSharer", shareObject, shareObjectTypes,
                                            (IMP)WolFoxCopyShareObject, &OriginalCopyShareObject);
    BOOL copyPlain = WolFoxInstallLinkHook(@"YTCopyLinkSharer", @"shareWithSuccessBlock:errorBlock:", "v32@0:8",
                                           (IMP)WolFoxCopyShare, &OriginalCopyShare);
    BOOL textObject = WolFoxInstallLinkHook(@"YTTextMessageSharer", shareObject, shareObjectTypes,
                                            (IMP)WolFoxTextShareObject, &OriginalTextShareObject);
    BOOL mailObject = WolFoxInstallLinkHook(@"YTEmailSharer", shareObject, shareObjectTypes,
                                            (IMP)WolFoxMailShareObject, &OriginalMailShareObject);
    BOOL systemObject = WolFoxInstallLinkHook(@"YTSystemActivityDialogSharer", shareObject, shareObjectTypes,
                                              (IMP)WolFoxSystemShareObject, &OriginalSystemShareObject);
    BOOL systemText = WolFoxInstallLinkHook(@"YTSystemActivityDialogSharer",
        @"shareWithText:url:subject:serializedShareEntity:successBlock:errorBlock:", "v64@0:8@16@24@32@40",
        (IMP)WolFoxSystemShareText, &OriginalSystemShareText);
    BOOL systemItem = WolFoxInstallLinkHook(@"YTSystemActivityDialogSharer",
        @"activityViewController:itemForActivityType:", "@32@0:8@16@24",
        (IMP)WolFoxSystemItem, &OriginalSystemItem);
    BOOL systemPlaceholder = WolFoxInstallLinkHook(@"YTSystemActivityDialogSharer",
        @"activityViewControllerPlaceholderItem:", "@24@0:8@16",
        (IMP)WolFoxSystemPlaceholder, &OriginalSystemPlaceholder);
    BOOL messageBody = WolFoxInstallLinkHook(@"MFMessageComposeViewController", @"setBody:", "v24@0:8@16",
                                             (IMP)WolFoxMessageSetBody, &OriginalMessageSetBody);
    BOOL mailBody = WolFoxInstallLinkHook(@"MFMailComposeViewController", @"setMessageBody:isHTML:", "v28@0:8@16B24",
                                          (IMP)WolFoxMailSetBody, &OriginalMailSetBody);
    BOOL openURL = WolFoxInstallLinkHook(@"UIApplication", @"openURL:options:completionHandler:", "v40@0:8@16@24",
                                         (IMP)WolFoxOpenURL, &OriginalOpenURL);
    WolFoxDownloadLog(@"links", @"hooks copy=%d/%d text=%d mail=%d system=%d/%d/%d/%d compose=%d/%d open=%d",
                      copyObject, copyPlain, textObject, mailObject, systemObject, systemText, systemItem,
                      systemPlaceholder, messageBody, mailBody, openURL);
}

#import "DeArrow.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <stdatomic.h>

NSString * const WolFoxDeArrowThumbModeKey = @"YTKACE.Preference.DeArrow.ThumbnailMode";
NSString * const WolFoxDeArrowTitlesKey = @"YTKACE.Preference.DeArrow.Titles";

static NSString * const WolFoxBrandingStoreKey = @"YTKACE.Preference.DeArrow.Branding";

static const NSUInteger WolFoxStoreLimit = 800;
static const NSUInteger WolFoxMaxConcurrent = 4;
static const NSUInteger WolFoxRequestsPerMinute = 90;
static const NSUInteger WolFoxPendingLimit = 300;
static const NSUInteger WolFoxAncestorDepth = 12;
static const NSUInteger WolFoxCellTextDepth = 10;
static const NSUInteger WolFoxMaxCellText = 10;
static const NSTimeInterval WolFoxNegativeTTL = 7 * 24 * 60 * 60;
static const NSInteger WolFoxStoreVersion = 2;

static IMP OriginalDownloadImage;
static IMP OriginalCachedImage;
static IMP OriginalApplyProperties;

static const void *WolFoxNodeVideoIDKey = &WolFoxNodeVideoIDKey;
static const void *WolFoxCellVideoIDKey = &WolFoxCellVideoIDKey;

static os_unfair_lock WolFoxLock = OS_UNFAIR_LOCK_INIT;
static NSUInteger WolFoxActiveRequests;
static NSUInteger WolFoxWindowCount;
static NSTimeInterval WolFoxWindowStart;
static NSMutableSet<NSString *> *WolFoxInFlight;
static NSMutableSet<NSString *> *WolFoxThumbInFlight;
static NSMutableArray<NSString *> *WolFoxPendingIDs;
static NSMapTable *WolFoxPendingNodes;
static NSMapTable *WolFoxPendingCells;
static NSMutableDictionary<NSString *, NSDictionary *> *WolFoxStore;
static NSCache<NSString *, UIImage *> *WolFoxImageCache;

static atomic_int WolFoxModeCache = -1;
static atomic_int WolFoxTitlesCache = -1;

static void WolFoxPumpQueue(void);
static void WolFoxApplyTitleToCell(id root, NSString *videoID);

static NSInteger WolFoxThumbMode(void) {
    int cached = atomic_load(&WolFoxModeCache);
    if (cached >= 0) return cached;
    id stored = WolFoxPreferenceObject(WolFoxDeArrowThumbModeKey);
    NSInteger mode = [stored respondsToSelector:@selector(integerValue)]
        ? MAX(0, MIN([stored integerValue], 1)) : 0;
    atomic_store(&WolFoxModeCache, (int)mode);
    return mode;
}

static BOOL WolFoxReplacingTitles(void) {
    int cached = atomic_load(&WolFoxTitlesCache);
    if (cached >= 0) return cached != 0;
    BOOL enabled = WolFoxFeatureEnabled(WolFoxDeArrowTitlesKey);
    atomic_store(&WolFoxTitlesCache, enabled ? 1 : 0);
    return enabled;
}

static BOOL WolFoxReplacingThumbs(void) {
    return WolFoxThumbMode() > 0;
}

static BOOL WolFoxAnyFeatureOn(void) {
    return WolFoxReplacingThumbs() || WolFoxReplacingTitles();
}

static id WolFoxSend(id object, SEL selector) {
    if (object == nil || selector == NULL) return nil;
    @try {
        if (![object respondsToSelector:selector]) return nil;
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id WolFoxSupernode(id node) {
    return WolFoxSend(node, @selector(supernode));
}

static NSArray *WolFoxSubnodes(id node) {
    id value = WolFoxSend(node, @selector(subnodes));
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static NSString *WolFoxNodeText(id node) {
    id value = WolFoxSend(node, @selector(attributedText));
    if ([value isKindOfClass:NSAttributedString.class]) {
        return ((NSAttributedString *)value).string;
    }
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id WolFoxCellRoot(id node) {
    static Class cellClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cellClass = NSClassFromString(@"ELMCellNode");
    });
    if (cellClass == Nil) return nil;
    id current = node;
    for (NSUInteger level = 0; level < WolFoxAncestorDepth; level++) {
        if ([current isKindOfClass:cellClass]) return current;
        current = WolFoxSupernode(current);
        if (current == nil) break;
    }
    return nil;
}

static NSString *WolFoxVideoIDFromURL(NSString *absolute) {
    if (absolute.length == 0) return nil;
    if ([absolute rangeOfString:@"/vi"].location == NSNotFound) return nil;
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"/(?:vi|vi_webp)/([A-Za-z0-9_-]{11})/" options:0 error:nil];
    });
    NSTextCheckingResult *match =
        [expression firstMatchInString:absolute options:0
                                 range:NSMakeRange(0, absolute.length)];
    if (match.numberOfRanges < 2) return nil;
    return [absolute substringWithRange:[match rangeAtIndex:1]];
}

static NSString *WolFoxURLString(id value) {
    if ([value isKindOfClass:NSURL.class]) return ((NSURL *)value).absoluteString;
    if ([value isKindOfClass:NSString.class]) return (NSString *)value;
    id resolved = WolFoxSend(value, @selector(absoluteString));
    return [resolved isKindOfClass:NSString.class] ? resolved : nil;
}

static void WolFoxLoadStore(void) {
    if (WolFoxStore != nil) return;
    NSDictionary *stored =
        [NSUserDefaults.standardUserDefaults dictionaryForKey:WolFoxBrandingStoreKey];
    WolFoxStore = [stored isKindOfClass:NSDictionary.class]
        ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    WolFoxImageCache = [NSCache new];
    WolFoxImageCache.countLimit = 160;
    WolFoxInFlight = [NSMutableSet set];
    WolFoxThumbInFlight = [NSMutableSet set];
    WolFoxPendingIDs = [NSMutableArray array];
    WolFoxPendingNodes = [NSMapTable strongToWeakObjectsMapTable];
    WolFoxPendingCells = [NSMapTable strongToWeakObjectsMapTable];
}

static void WolFoxEvictLocked(void) {
    if (WolFoxStore.count <= WolFoxStoreLimit) return;
    NSArray<NSString *> *ordered = [WolFoxStore.allKeys sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *left, NSString *right) {
            double a = [WolFoxStore[left][@"a"] doubleValue];
            double b = [WolFoxStore[right][@"a"] doubleValue];
            if (a < b) return NSOrderedAscending;
            if (a > b) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    NSUInteger drop = WolFoxStore.count - (WolFoxStoreLimit * 3 / 4);
    if (drop > ordered.count) drop = ordered.count;
    for (NSUInteger index = 0; index < drop; index++) {
        [WolFoxStore removeObjectForKey:ordered[index]];
    }
}

static void WolFoxPersistStore(void) {
    os_unfair_lock_lock(&WolFoxLock);
    WolFoxEvictLocked();
    NSDictionary *snapshot = [WolFoxStore copy];
    os_unfair_lock_unlock(&WolFoxLock);
    if (snapshot != nil) {
        [NSUserDefaults.standardUserDefaults setObject:snapshot
                                                forKey:WolFoxBrandingStoreKey];
    }
}

static NSDictionary *WolFoxFreshEntryLocked(NSString *videoID) {
    NSDictionary *entry = WolFoxStore[videoID];
    if (entry == nil) return nil;
    if ([entry[@"v"] integerValue] < WolFoxStoreVersion) {
        [WolFoxStore removeObjectForKey:videoID];
        return nil;
    }
    if (entry[@"t"] != nil || entry[@"ti"] != nil) return entry;
    double added = [entry[@"a"] doubleValue];
    if (NSDate.date.timeIntervalSince1970 - added > WolFoxNegativeTTL) {
        [WolFoxStore removeObjectForKey:videoID];
        return nil;
    }
    return entry;
}

static void WolFoxStoreBranding(NSString *videoID, NSNumber *timestamp,
                                NSString *title) {
    if (videoID.length == 0) return;
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"a"] = @(NSDate.date.timeIntervalSince1970);
    entry[@"v"] = @(WolFoxStoreVersion);
    if (timestamp != nil) entry[@"t"] = timestamp;
    if (title.length != 0) entry[@"ti"] = title;
    if (timestamp == nil && title.length == 0) entry[@"n"] = @YES;
    os_unfair_lock_lock(&WolFoxLock);
    WolFoxStore[videoID] = entry;
    [WolFoxInFlight removeObject:videoID];
    if (WolFoxActiveRequests > 0) WolFoxActiveRequests--;
    os_unfair_lock_unlock(&WolFoxLock);
    WolFoxPersistStore();
    WolFoxPumpQueue();
}

static NSString *WolFoxStoredTitle(NSString *videoID) {
    if (videoID.length == 0) return nil;
    os_unfair_lock_lock(&WolFoxLock);
    id title = WolFoxStore[videoID][@"ti"];
    os_unfair_lock_unlock(&WolFoxLock);
    return [title isKindOfClass:NSString.class] ? title : nil;
}

static void WolFoxApplyImage(id node, NSString *videoID, UIImage *image) {
    if (node == nil || image == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        id current = objc_getAssociatedObject(node, WolFoxNodeVideoIDKey);
        if (![current isEqual:videoID]) return;
        SEL setter = NSSelectorFromString(@"setImage:");
        if (![node respondsToSelector:setter]) return;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(node, setter, image);
        } @catch (__unused NSException *exception) {
        }
    });
}

static void WolFoxFetchThumbnail(NSString *videoID, double timestamp, id node) {
    if (!WolFoxReplacingThumbs()) return;
    os_unfair_lock_lock(&WolFoxLock);
    BOOL busy = [WolFoxThumbInFlight containsObject:videoID];
    if (!busy) [WolFoxThumbInFlight addObject:videoID];
    os_unfair_lock_unlock(&WolFoxLock);
    if (busy) return;

    NSString *address = [NSString stringWithFormat:
        @"https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=%@&time=%.3f",
        videoID, timestamp];
    NSURL *URL = [NSURL URLWithString:address];
    if (URL == nil) {
        os_unfair_lock_lock(&WolFoxLock);
        [WolFoxThumbInFlight removeObject:videoID];
        os_unfair_lock_unlock(&WolFoxLock);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.timeoutInterval = 20.0;
    __weak id weakNode = node;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        os_unfair_lock_lock(&WolFoxLock);
        [WolFoxThumbInFlight removeObject:videoID];
        os_unfair_lock_unlock(&WolFoxLock);
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;
        UIImage *decoded = (error == nil && http.statusCode == 200 && data.length != 0)
            ? [UIImage imageWithData:data] : nil;
        if (decoded == nil) return;
        os_unfair_lock_lock(&WolFoxLock);
        [WolFoxImageCache setObject:decoded forKey:videoID];
        os_unfair_lock_unlock(&WolFoxLock);
        WolFoxApplyImage(weakNode, videoID, decoded);
    }] resume];
}

static void WolFoxCollectTextNodes(id node, NSUInteger depth, NSMutableArray *out) {
    if (node == nil || depth > WolFoxCellTextDepth ||
        out.count >= WolFoxMaxCellText) {
        return;
    }
    static Class textClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        textClass = NSClassFromString(@"ELMTextNode");
    });
    if (textClass != Nil && [node isKindOfClass:textClass]) {
        if (WolFoxNodeText(node).length != 0) [out addObject:node];
    }
    for (id child in WolFoxSubnodes(node)) {
        WolFoxCollectTextNodes(child, depth + 1, out);
    }
}

static BOOL WolFoxLooksLikeDuration(NSString *text) {
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"^\\d{1,2}:\\d{2}(:\\d{2})?$" options:0 error:nil];
    });
    return [expression numberOfMatchesInString:text options:0
                                         range:NSMakeRange(0, text.length)] != 0;
}

static void WolFoxWriteTitle(id textNode, NSString *title) {
    void (^work)(void) = ^{
        id current = WolFoxSend(textNode, @selector(attributedText));
        if (![current isKindOfClass:NSAttributedString.class]) return;
        NSAttributedString *existing = current;
        if ([existing.string isEqualToString:title]) return;
        NSDictionary *attributes = existing.length != 0
            ? [existing attributesAtIndex:0 effectiveRange:NULL] : nil;
        NSAttributedString *replacement =
            [[NSAttributedString alloc] initWithString:title attributes:attributes];
        SEL setter = NSSelectorFromString(@"setAttributedText:");
        if (![textNode respondsToSelector:setter]) return;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(textNode, setter, replacement);
        } @catch (__unused NSException *exception) {
        }
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

static void WolFoxApplyTitleToCell(id root, NSString *videoID) {
    if (root == nil || videoID.length == 0 || !WolFoxReplacingTitles()) return;

    NSString *title = WolFoxStoredTitle(videoID);
    if (title.length == 0) {
        os_unfair_lock_lock(&WolFoxLock);
        [WolFoxPendingCells setObject:root forKey:videoID];
        os_unfair_lock_unlock(&WolFoxLock);
        return;
    }

    NSMutableArray *nodes = [NSMutableArray array];
    WolFoxCollectTextNodes(root, 0, nodes);
    if (nodes.count < 2) return;
    id candidate = nodes[nodes.count - 2];
    NSString *text = WolFoxNodeText(candidate);
    if ([text isEqualToString:title]) return;
    if (WolFoxLooksLikeDuration(text)) return;
    WolFoxWriteTitle(candidate, title);
}

static void WolFoxApplyPendingTitle(NSString *videoID) {
    if (videoID.length == 0 || !WolFoxReplacingTitles()) return;
    os_unfair_lock_lock(&WolFoxLock);
    id root = [WolFoxPendingCells objectForKey:videoID];
    os_unfair_lock_unlock(&WolFoxLock);
    if (root != nil) WolFoxApplyTitleToCell(root, videoID);
}

static BOOL WolFoxClaimSlotLocked(void) {
    if (WolFoxActiveRequests >= WolFoxMaxConcurrent) return NO;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - WolFoxWindowStart >= 60.0) {
        WolFoxWindowStart = now;
        WolFoxWindowCount = 0;
    }
    if (WolFoxWindowCount >= WolFoxRequestsPerMinute) return NO;
    WolFoxWindowCount++;
    WolFoxActiveRequests++;
    return YES;
}

static void WolFoxFetchBranding(NSString *videoID, id node) {
    NSString *address = [NSString stringWithFormat:
        @"https://sponsor.ajay.app/api/branding?videoID=%@", videoID];
    NSURL *URL = [NSURL URLWithString:address];
    if (URL == nil) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.timeoutInterval = 15.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    __weak id weakNode = node;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;
        if (error != nil) {
            os_unfair_lock_lock(&WolFoxLock);
            [WolFoxInFlight removeObject:videoID];
            if (WolFoxActiveRequests > 0) WolFoxActiveRequests--;
            os_unfair_lock_unlock(&WolFoxLock);
            WolFoxPumpQueue();
            return;
        }
        id json = (http.statusCode == 200 && data.length != 0)
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class]) {
            WolFoxStoreBranding(videoID, nil, nil);
            return;
        }
        NSDictionary *payload = json;
        NSArray *titles = [payload[@"titles"] isKindOfClass:NSArray.class]
            ? payload[@"titles"] : @[];
        NSArray *thumbnails = [payload[@"thumbnails"] isKindOfClass:NSArray.class]
            ? payload[@"thumbnails"] : @[];

        NSString *useTitle = nil;
        NSDictionary *bestTitle = titles.firstObject;
        if ([bestTitle isKindOfClass:NSDictionary.class]) {
            BOOL trusted = [bestTitle[@"locked"] boolValue] ||
                [bestTitle[@"votes"] integerValue] >= 0;
            id text = bestTitle[@"title"];
            if (trusted && ![bestTitle[@"original"] boolValue] &&
                [text isKindOfClass:NSString.class]) {
                NSString *cleaned = [(NSString *)text
                    stringByReplacingOccurrencesOfString:@">" withString:@""];
                cleaned = [cleaned stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (cleaned.length != 0) useTitle = cleaned;
            }
        }

        NSNumber *useTimestamp = nil;
        NSDictionary *bestThumb = thumbnails.firstObject;
        if ([bestThumb isKindOfClass:NSDictionary.class]) {
            BOOL trusted = [bestThumb[@"locked"] boolValue] ||
                [bestThumb[@"votes"] integerValue] >= 0;
            id timestamp = bestThumb[@"timestamp"];
            if (trusted && ![bestThumb[@"original"] boolValue] &&
                [timestamp isKindOfClass:NSNumber.class]) {
                useTimestamp = timestamp;
            }
        }

        WolFoxStoreBranding(videoID, useTimestamp, useTitle);
        if (useTitle.length != 0) WolFoxApplyPendingTitle(videoID);
        if (useTimestamp != nil) {
            WolFoxFetchThumbnail(videoID, useTimestamp.doubleValue, weakNode);
        }
    }] resume];
}

static void WolFoxPumpQueue(void) {
    while (YES) {
        NSString *videoID = nil;
        id node = nil;
        os_unfair_lock_lock(&WolFoxLock);
        while (WolFoxPendingIDs.count != 0 && videoID == nil) {
            NSString *candidate = WolFoxPendingIDs.firstObject;
            [WolFoxPendingIDs removeObjectAtIndex:0];
            if (WolFoxFreshEntryLocked(candidate) != nil ||
                [WolFoxInFlight containsObject:candidate]) {
                [WolFoxPendingNodes removeObjectForKey:candidate];
                continue;
            }
            if (!WolFoxClaimSlotLocked()) {
                [WolFoxPendingIDs insertObject:candidate atIndex:0];
                break;
            }
            [WolFoxInFlight addObject:candidate];
            node = [WolFoxPendingNodes objectForKey:candidate];
            [WolFoxPendingNodes removeObjectForKey:candidate];
            videoID = candidate;
        }
        os_unfair_lock_unlock(&WolFoxLock);
        if (videoID == nil) return;
        WolFoxFetchBranding(videoID, node);
    }
}

static void WolFoxEnqueueLookup(NSString *videoID, id node) {
    os_unfair_lock_lock(&WolFoxLock);
    BOOL known = WolFoxFreshEntryLocked(videoID) != nil ||
        [WolFoxInFlight containsObject:videoID] ||
        [WolFoxPendingIDs containsObject:videoID];
    if (!known) {
        if (WolFoxPendingIDs.count >= WolFoxPendingLimit) {
            [WolFoxPendingIDs removeObjectAtIndex:0];
        }
        [WolFoxPendingIDs addObject:videoID];
        if (node != nil) [WolFoxPendingNodes setObject:node forKey:videoID];
    }
    os_unfair_lock_unlock(&WolFoxLock);
    if (!known) WolFoxPumpQueue();
}

static void WolFoxConsiderVideo(id node, NSString *videoID) {
    BOOL replacing = WolFoxReplacingThumbs();
    os_unfair_lock_lock(&WolFoxLock);
    WolFoxLoadStore();
    UIImage *ready = replacing ? [WolFoxImageCache objectForKey:videoID] : nil;
    NSDictionary *known = WolFoxFreshEntryLocked(videoID);
    os_unfair_lock_unlock(&WolFoxLock);

    if (ready != nil) {
        WolFoxApplyImage(node, videoID, ready);
        return;
    }
    if (known != nil) {
        NSNumber *timestamp = known[@"t"];
        if (replacing && [timestamp isKindOfClass:NSNumber.class]) {
            WolFoxFetchThumbnail(videoID, timestamp.doubleValue, node);
        }
        return;
    }
    WolFoxEnqueueLookup(videoID, node);
}

static void WolFoxNoteImage(id receiver, id URL) {
    NSString *videoID = WolFoxVideoIDFromURL(WolFoxURLString(URL));
    if (videoID.length == 0) return;

    objc_setAssociatedObject(receiver, WolFoxNodeVideoIDKey, videoID,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    id root = WolFoxCellRoot(receiver);
    if (root != nil) {
        objc_setAssociatedObject(root, WolFoxCellVideoIDKey, videoID,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    WolFoxConsiderVideo(receiver, videoID);
    if (root != nil) WolFoxApplyTitleToCell(root, videoID);
}

static id WolFoxDownloadImage(id receiver, SEL selector, id URL, BOOL shouldRetry,
                              id callbackQueue, id progress, id completion) {
    if (WolFoxAnyFeatureOn()) WolFoxNoteImage(receiver, URL);
    if (OriginalDownloadImage == NULL) return nil;
    return ((id (*)(id, SEL, id, BOOL, id, id, id))OriginalDownloadImage)(
        receiver, selector, URL, shouldRetry, callbackQueue, progress, completion);
}

static void WolFoxCachedImage(id receiver, SEL selector, id URL,
                              id callbackQueue, id completion) {
    if (WolFoxAnyFeatureOn()) WolFoxNoteImage(receiver, URL);
    if (OriginalCachedImage == NULL) return;
    ((void (*)(id, SEL, id, id, id))OriginalCachedImage)(
        receiver, selector, URL, callbackQueue, completion);
}

static void WolFoxApplyProperties(id receiver, SEL selector) {
    if (OriginalApplyProperties != NULL) {
        ((void (*)(id, SEL))OriginalApplyProperties)(receiver, selector);
    }
    if (!WolFoxReplacingTitles()) return;
    id root = WolFoxCellRoot(receiver);
    if (root == nil) return;
    id stored = objc_getAssociatedObject(root, WolFoxCellVideoIDKey);
    if (![stored isKindOfClass:NSString.class]) return;
    if (WolFoxStoredTitle(stored).length == 0) return;
    WolFoxApplyTitleToCell(root, stored);
}

void WolFoxDeArrowClearCache(void) {
    os_unfair_lock_lock(&WolFoxLock);
    [WolFoxStore removeAllObjects];
    [WolFoxImageCache removeAllObjects];
    [WolFoxPendingIDs removeAllObjects];
    [WolFoxPendingCells removeAllObjects];
    os_unfair_lock_unlock(&WolFoxLock);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:WolFoxBrandingStoreKey];
}

void WolFoxInstallDeArrow(void) {
    os_unfair_lock_lock(&WolFoxLock);
    WolFoxLoadStore();
    os_unfair_lock_unlock(&WolFoxLock);

    WolFoxInstallInstanceHook(@"ELMImageNode",
        @"downloadImageWithURL:shouldRetry:callbackQueue:downloadProgress:completion:",
        (IMP)WolFoxDownloadImage, &OriginalDownloadImage);
    WolFoxInstallInstanceHook(@"ELMImageNode",
        @"cachedImageWithURL:callbackQueue:completion:",
        (IMP)WolFoxCachedImage, &OriginalCachedImage);
    WolFoxInstallInstanceHook(@"ELMTextNode",
        @"controllerDidApplyProperties", (IMP)WolFoxApplyProperties,
        &OriginalApplyProperties);

    [NSNotificationCenter.defaultCenter
        addObserverForName:WolFoxPreferencesDidChangeNotification
                    object:nil queue:nil
                usingBlock:^(__unused NSNotification *note) {
        atomic_store(&WolFoxModeCache, -1);
        atomic_store(&WolFoxTitlesCache, -1);
    }];
}

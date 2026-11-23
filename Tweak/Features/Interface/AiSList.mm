#import "AiSList.h"
#import "../Downloads/DownloadLog.h"

#import <os/lock.h>

static NSString * const WolFoxAiSListBlockURL =
    @"https://raw.githubusercontent.com/Override92/AiSList/main/AiSList/aislist_blocklist.txt";
static NSString * const WolFoxAiSListWarnURL =
    @"https://raw.githubusercontent.com/Override92/AiSList/main/AiSList/aislist_warnlist.txt";
static NSString * const WolFoxAiSListFetchedKey = @"WolFox.AiSList.LastFetch";
static const NSTimeInterval WolFoxAiSListMaxAge = 4 * 60 * 60;

static os_unfair_lock WolFoxAiSListLock = OS_UNFAIR_LOCK_INIT;
static NSSet<NSString *> *WolFoxAiSListBlock;
static NSSet<NSString *> *WolFoxAiSListWarn;
static BOOL WolFoxAiSListLoading;

static NSURL *WolFoxAiSListFile(NSString *name) {
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                       inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [base URLByAppendingPathComponent:@"YTKACE" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
                                            attributes:nil error:nil];
    return [directory URLByAppendingPathComponent:name];
}

static NSSet<NSString *> *WolFoxAiSListParse(NSString *text) {
    NSMutableSet<NSString *> *entries = [NSMutableSet set];
    [text enumerateLinesUsingBlock:^(NSString *line, __unused BOOL *stop) {
        NSString *entry = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (entry.length < 3 || [entry hasPrefix:@"!"]) return;
        if ([entry hasPrefix:@"@"]) [entries addObject:entry.lowercaseString];
        else if ([entry hasPrefix:@"UC"] && entry.length == 24) [entries addObject:entry];
    }];
    return entries;
}

static void WolFoxAiSListLoadCached(void) {
    NSString *block = [NSString stringWithContentsOfURL:WolFoxAiSListFile(@"aislist_blocklist.txt")
                                               encoding:NSUTF8StringEncoding error:nil];
    NSString *warn = [NSString stringWithContentsOfURL:WolFoxAiSListFile(@"aislist_warnlist.txt")
                                              encoding:NSUTF8StringEncoding error:nil];
    NSSet *blockSet = block.length != 0 ? WolFoxAiSListParse(block) : nil;
    NSSet *warnSet = warn.length != 0 ? WolFoxAiSListParse(warn) : nil;
    os_unfair_lock_lock(&WolFoxAiSListLock);
    if (blockSet != nil) WolFoxAiSListBlock = blockSet;
    if (warnSet != nil) WolFoxAiSListWarn = warnSet;
    os_unfair_lock_unlock(&WolFoxAiSListLock);
    WolFoxDownloadLog(@"aislist", @"loaded block=%lu warn=%lu", (unsigned long)blockSet.count,
                      (unsigned long)warnSet.count);
}

static NSData *WolFoxAiSListDownload(NSString *url) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.timeoutInterval = 30.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    __block NSInteger status = 0;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
        if ([response isKindOfClass:NSHTTPURLResponse.class]) status = ((NSHTTPURLResponse *)response).statusCode;
        if (status == 200 && data.length != 0 && data.length < 8 * 1024 * 1024) body = data;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_SEC)));
    WolFoxDownloadLog(@"aislist", @"fetch %@ status=%ld bytes=%lu", url.lastPathComponent, (long)status,
                      (unsigned long)body.length);
    return body;
}

void WolFoxAiSListRefreshIfStale(void) {
    os_unfair_lock_lock(&WolFoxAiSListLock);
    BOOL busy = WolFoxAiSListLoading;
    BOOL loaded = WolFoxAiSListBlock != nil || WolFoxAiSListWarn != nil;
    if (!busy) WolFoxAiSListLoading = YES;
    os_unfair_lock_unlock(&WolFoxAiSListLock);
    if (busy) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!loaded) WolFoxAiSListLoadCached();
        double last = [NSUserDefaults.standardUserDefaults doubleForKey:WolFoxAiSListFetchedKey];
        BOOL stale = NSDate.date.timeIntervalSince1970 - last > WolFoxAiSListMaxAge;
        os_unfair_lock_lock(&WolFoxAiSListLock);
        BOOL empty = WolFoxAiSListBlock == nil && WolFoxAiSListWarn == nil;
        os_unfair_lock_unlock(&WolFoxAiSListLock);
        if (stale || empty) {
            NSData *block = WolFoxAiSListDownload(WolFoxAiSListBlockURL);
            NSData *warn = WolFoxAiSListDownload(WolFoxAiSListWarnURL);
            if (block != nil) [block writeToURL:WolFoxAiSListFile(@"aislist_blocklist.txt") atomically:YES];
            if (warn != nil) [warn writeToURL:WolFoxAiSListFile(@"aislist_warnlist.txt") atomically:YES];
            if (block != nil || warn != nil) {
                [NSUserDefaults.standardUserDefaults setDouble:NSDate.date.timeIntervalSince1970
                                                        forKey:WolFoxAiSListFetchedKey];
                WolFoxAiSListLoadCached();
            }
        }
        os_unfair_lock_lock(&WolFoxAiSListLock);
        WolFoxAiSListLoading = NO;
        os_unfair_lock_unlock(&WolFoxAiSListLock);
    });
}

BOOL WolFoxAiSListReady(void) {
    os_unfair_lock_lock(&WolFoxAiSListLock);
    BOOL ready = WolFoxAiSListBlock.count != 0 || WolFoxAiSListWarn.count != 0;
    os_unfair_lock_unlock(&WolFoxAiSListLock);
    return ready;
}

static BOOL WolFoxAiSListHandleByte(unsigned char byte) {
    return isalnum(byte) || byte == '_' || byte == '-' || byte == '.' || byte >= 0x80;
}

BOOL WolFoxAiSListMatches(NSData *bytes, BOOL blocklist, BOOL warnlist, NSString **matched) {
    if (bytes.length == 0 || (!blocklist && !warnlist)) return NO;
    os_unfair_lock_lock(&WolFoxAiSListLock);
    NSSet<NSString *> *block = blocklist ? WolFoxAiSListBlock : nil;
    NSSet<NSString *> *warn = warnlist ? WolFoxAiSListWarn : nil;
    os_unfair_lock_unlock(&WolFoxAiSListLock);
    if (block.count == 0 && warn.count == 0) return NO;
    const unsigned char *raw = (const unsigned char *)bytes.bytes;
    NSUInteger length = bytes.length;
    NSMutableSet<NSString *> *handles = [NSMutableSet set];
    NSMutableSet<NSString *> *channels = [NSMutableSet set];
    for (NSUInteger i = 2; i < length; i++) {
        if (raw[i] == '@') {
            NSUInteger size = 0;
            if (raw[i - 1] == '/' && i >= 3 && (raw[i - 3] & 0x07) == 2) size = (NSUInteger)raw[i - 2] - 1;
            else if ((raw[i - 2] & 0x07) == 2) size = raw[i - 1];
            if (size < 4 || size > 100 || i + size > length) continue;
            BOOL valid = YES;
            for (NSUInteger k = i + 1; k < i + size && valid; k++) valid = WolFoxAiSListHandleByte(raw[k]);
            if (!valid) continue;
            NSString *handle = [[NSString alloc] initWithBytes:raw + i length:size encoding:NSUTF8StringEncoding];
            if (handle != nil) [handles addObject:handle.lowercaseString];
        } else if (raw[i] == 'U' && i + 24 <= length && raw[i + 1] == 'C' &&
                   (raw[i - 1] == 24 || raw[i - 1] == '/')) {
            BOOL valid = YES;
            for (NSUInteger k = i + 2; k < i + 24 && valid; k++)
                valid = isalnum(raw[k]) || raw[k] == '_' || raw[k] == '-';
            if (!valid) continue;
            NSString *channel = [[NSString alloc] initWithBytes:raw + i length:24 encoding:NSASCIIStringEncoding];
            if (channel != nil) [channels addObject:channel];
        }
    }
    if (channels.count > 1) return NO;
    for (NSSet<NSString *> *candidates in @[handles, channels]) {
        for (NSString *candidate in candidates) {
            if ([block containsObject:candidate] || [warn containsObject:candidate]) {
                if (matched != NULL) *matched = candidate;
                return YES;
            }
        }
    }
    return NO;
}

#import "DownloadLog.h"



static const NSUInteger WolFoxDownloadLogLimit = 512 * 1024;

static NSURL *WolFoxDownloadLogURL(void) {
    static NSURL *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSNumber *> *candidates = @[@(NSDocumentDirectory),
                                            @(NSApplicationSupportDirectory),
                                            @(NSCachesDirectory)];
        for (NSNumber *candidate in candidates) {
            NSURL *base = [NSFileManager.defaultManager
                URLsForDirectory:(NSSearchPathDirectory)candidate.unsignedIntegerValue
                       inDomains:NSUserDomainMask].firstObject;
            if (base == nil) continue;
            NSURL *directory = [[base URLByAppendingPathComponent:@"YTKACE" isDirectory:YES]
                URLByAppendingPathComponent:@"Logs" isDirectory:YES];
            NSError *error = nil;
            if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&error]) {
                continue;
            }
            NSURL *probe = [directory URLByAppendingPathComponent:@"downloads.log"];
            if (![NSFileManager.defaultManager fileExistsAtPath:probe.path] &&
                ![[NSData data] writeToURL:probe atomically:YES]) {
                continue;
            }
            cached = probe;
            break;
        }
        if (cached == nil) {
            cached = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:@"ytkace-downloads.log"]];
        }
        [NSUserDefaults.standardUserDefaults setObject:cached.path
                                                forKey:@"WolFoxLogPath"];
    });
    return cached;
}

static dispatch_queue_t WolFoxDownloadLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ytkace.download-log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString * const WolFoxDebugLogsKey = @"YTKACE.Preference.Developer.DebugLogs";

// -1 until read once; the settings toggle is the only thing that changes it.
static _Atomic int WolFoxDebugLogsState = -1;

BOOL WolFoxDebugLogsEnabled(void) {
    int state = WolFoxDebugLogsState;
    if (state < 0) {
        state = [NSUserDefaults.standardUserDefaults boolForKey:WolFoxDebugLogsKey] ? 1 : 0;
        WolFoxDebugLogsState = state;
    }
    return state == 1;
}

void WolFoxSetDebugLogsEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:WolFoxDebugLogsKey];
    WolFoxDebugLogsState = enabled ? 1 : 0;
}

static void WolFoxWriteLogLine(NSString *identifier, NSString *message);

void WolFoxDownloadLog(NSString *identifier, NSString *format, ...) {
    if (format.length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    WolFoxWriteLogLine(identifier, message);
}

void WolFoxDebugLogWrite(NSString *identifier, NSString *format, ...) {
    if (format.length == 0 || !WolFoxDebugLogsEnabled()) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    WolFoxWriteLogLine(identifier, message);
}

// Lines are collected on the log queue and written in batches about every
// half second, so logging never waits on the disk. A line that repeats the
// last one within a second is counted instead of written again.
static NSMutableData *WolFoxLogBuffer;
static BOOL WolFoxLogFlushScheduled;
static NSString *WolFoxLastLogLine;
static CFAbsoluteTime WolFoxLastLogTime;
static NSUInteger WolFoxLogRepeats;
static const NSUInteger WolFoxLogBufferLimit = 32 * 1024;

static NSString *WolFoxLogStamp(CFAbsoluteTime time) {
    static NSDateFormatter *formatter;
    if (formatter == nil) {
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss '+0000'";
    }
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSinceReferenceDate:time]];
}

static void WolFoxBufferLogLine(NSString *line) {
    if (WolFoxLogBuffer == nil) WolFoxLogBuffer = [NSMutableData data];
    [WolFoxLogBuffer appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
}

static void WolFoxNoteLogRepeats(void) {
    if (WolFoxLogRepeats == 0) return;
    WolFoxBufferLogLine([NSString stringWithFormat:@"%@ [log] last line repeated %lu more times\n",
                         WolFoxLogStamp(WolFoxLastLogTime), (unsigned long)WolFoxLogRepeats]);
    WolFoxLogRepeats = 0;
}

// Runs on the log queue.
static void WolFoxFlushLog(void) {
    WolFoxLogFlushScheduled = NO;
    WolFoxNoteLogRepeats();
    NSData *bytes = WolFoxLogBuffer;
    if (bytes.length == 0) return;
    WolFoxLogBuffer = nil;
    NSURL *URL = WolFoxDownloadLogURL();
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:URL error:nil];
    unsigned long long size = 0;
    if (handle == nil ||
        ![handle seekToEndReturningOffset:&size error:nil] ||
        ![handle writeData:bytes error:nil]) {
        [handle closeAndReturnError:nil];
        NSMutableData *data = [([NSData dataWithContentsOfURL:URL] ?: NSData.data) mutableCopy];
        [data appendData:bytes];
        [data writeToURL:URL atomically:YES];
        return;
    }
    [handle closeAndReturnError:nil];
    if (size + bytes.length <= WolFoxDownloadLogLimit) return;
    NSData *data = [NSData dataWithContentsOfURL:URL];
    NSUInteger keep = WolFoxDownloadLogLimit * 3 / 4;
    if (data.length > keep) {
        [[data subdataWithRange:NSMakeRange(data.length - keep, keep)] writeToURL:URL atomically:YES];
    }
}

static void WolFoxWriteLogLine(NSString *identifier, NSString *message) {
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent();
    if (message.length > 4096) message = [message substringToIndex:4096];
    dispatch_async(WolFoxDownloadLogQueue(), ^{
        NSString *body = [NSString stringWithFormat:@"[%@] %@",
                          identifier.length == 0 ? @"download" : identifier, message];
        if (WolFoxLastLogLine != nil && [body isEqualToString:WolFoxLastLogLine] &&
            time - WolFoxLastLogTime < 1.0) {
            WolFoxLogRepeats++;
            WolFoxLastLogTime = time;
            return;
        }
        WolFoxNoteLogRepeats();
        WolFoxLastLogLine = body;
        WolFoxLastLogTime = time;
        WolFoxBufferLogLine([NSString stringWithFormat:@"%@ %@\n", WolFoxLogStamp(time), body]);
        if (WolFoxLogBuffer.length >= WolFoxLogBufferLimit) {
            WolFoxFlushLog();
        } else if (!WolFoxLogFlushScheduled) {
            WolFoxLogFlushScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           WolFoxDownloadLogQueue(), ^{ WolFoxFlushLog(); });
        }
    });
}

NSString *WolFoxDownloadLogContents(void) {
    __block NSString *contents = @"No download activity yet.";
    dispatch_sync(WolFoxDownloadLogQueue(), ^{
        WolFoxFlushLog();
        NSString *value = [NSString stringWithContentsOfURL:WolFoxDownloadLogURL()
            encoding:NSUTF8StringEncoding error:nil];
        if (value.length != 0) contents = value;
    });
    return contents;
}

void WolFoxClearDownloadLog(void) {
    dispatch_sync(WolFoxDownloadLogQueue(), ^{
        WolFoxLogBuffer = nil;
        WolFoxLogRepeats = 0;
        WolFoxLastLogLine = nil;
        [NSFileManager.defaultManager removeItemAtURL:WolFoxDownloadLogURL() error:nil];
    });
}

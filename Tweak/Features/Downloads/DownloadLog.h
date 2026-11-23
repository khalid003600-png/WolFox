#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void WolFoxDownloadLog(NSString *identifier,
                                         NSString *format, ...)
    NS_FORMAT_FUNCTION(2, 3);
FOUNDATION_EXPORT BOOL WolFoxDebugLogsEnabled(void);
FOUNDATION_EXPORT void WolFoxSetDebugLogsEnabled(BOOL enabled);
FOUNDATION_EXPORT void WolFoxDebugLogWrite(NSString *identifier,
                                           NSString *format, ...)
    NS_FORMAT_FUNCTION(2, 3);
FOUNDATION_EXPORT NSString *WolFoxDownloadLogContents(void);
FOUNDATION_EXPORT void WolFoxClearDownloadLog(void);

NS_ASSUME_NONNULL_END

// Debug lines cost nothing while debug logging is off: the check comes first,
// so the message and its arguments are never built.
#define WolFoxDebugLog(identifier, ...) \
    do { \
        if (WolFoxDebugLogsEnabled()) WolFoxDebugLogWrite(identifier, __VA_ARGS__); \
    } while (0)

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void WolFoxAiSListRefreshIfStale(void);
FOUNDATION_EXPORT BOOL WolFoxAiSListReady(void);
FOUNDATION_EXPORT BOOL WolFoxAiSListReportingEnabled(void);
FOUNDATION_EXPORT void WolFoxLookupChannelHandle(NSString *videoID,
                                                 void (^completion)(NSString * _Nullable handle,
                                                                    NSString * _Nullable channel,
                                                                    NSString * _Nullable title));
FOUNDATION_EXPORT void WolFoxAiSListReportVideo(NSString *videoID);
FOUNDATION_EXPORT id _Nullable WolFoxAiSListAppendMenuAction(id _Nullable renderers, id _Nullable actions);
FOUNDATION_EXPORT BOOL WolFoxAiSListMatches(NSData *bytes, BOOL blocklist, BOOL warnlist,
                                           NSString * _Nullable * _Nullable matched);

NS_ASSUME_NONNULL_END

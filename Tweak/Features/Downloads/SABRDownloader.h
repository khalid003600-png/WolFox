#import <Foundation/Foundation.h>

@class WolFoxStreamOption;

NS_ASSUME_NONNULL_BEGIN

typedef void (^WolFoxSABRProgress)(double audioProgress,
                                  double videoProgress,
                                  int64_t audioBytes,
                                  int64_t videoBytes,
                                  NSInteger mediaPhase);
typedef void (^WolFoxSABRCompletion)(NSURL * _Nullable videoURL,
                                    NSURL * _Nullable audioURL,
                                    NSError * _Nullable error);
typedef void (^WolFoxPlayerReloadCompletion)(id _Nullable playerResponse,
                                             NSError * _Nullable error);
typedef void (^WolFoxNativeRequestCompletion)(
    NSURLRequest * _Nullable request,
    NSInteger requestNumber,
    NSError * _Nullable error);

FOUNDATION_EXPORT void WolFoxSABRSetPoToken(id _Nullable token);
FOUNDATION_EXPORT void WolFoxSABRSetStandaloneClient(NSString *identifier,
    NSData * _Nullable clientInfo, NSDictionary<NSString *, NSString *> * _Nullable headers);
FOUNDATION_EXPORT NSString *_Nullable WolFoxSABRPoTokenString(void);
FOUNDATION_EXPORT NSUInteger WolFoxSABRPoTokenLength(void);
FOUNDATION_EXPORT void WolFoxSABRSetNativeHeaders(
    NSDictionary<NSString *, NSString *> *headers);
FOUNDATION_EXPORT void WolFoxSABRSetNativeRequest(NSURLRequest *request);
FOUNDATION_EXPORT void WolFoxSABRSetCurrentVideoID(NSString * _Nullable videoID);
FOUNDATION_EXPORT id _Nullable WolFoxCachedPlayerResponse(NSString *videoID);
FOUNDATION_EXPORT void WolFoxStorePlayerResponse(NSString *videoID, id response);
FOUNDATION_EXPORT NSString * _Nullable WolFoxSABRCurrentVideoIDValue(void);
FOUNDATION_EXPORT NSUInteger WolFoxPurgeDownloadScratch(BOOL includeActive);
FOUNDATION_EXPORT void WolFoxPreparePlayerWithRoute(NSString *videoID,
                                                    BOOL forcePlayerRoute,
                                                    WolFoxPlayerReloadCompletion completion);
FOUNDATION_EXPORT void WolFoxPreparePlayer(NSString *videoID,
                                           WolFoxPlayerReloadCompletion completion);
FOUNDATION_EXPORT BOOL WolFoxPlaybackTemplateReady(void);
FOUNDATION_EXPORT void WolFoxSABRRestoreSeed(void);
FOUNDATION_EXPORT void WolFoxRestorePlayerRequest(void);
FOUNDATION_EXPORT void WolFoxInstallFeedDownloadHooks(void);
FOUNDATION_EXPORT void WolFoxDiscardRestoredRequest(void);
FOUNDATION_EXPORT void WolFoxResolvePlayerResponse(
    NSString *videoID,
    WolFoxPlayerReloadCompletion completion);
FOUNDATION_EXPORT void WolFoxReloadPlayer(NSString * _Nullable videoID,
                                         NSString *token,
                                         WolFoxPlayerReloadCompletion completion);
FOUNDATION_EXPORT BOOL WolFoxHasNativeOnesieSession(NSString *videoID);
FOUNDATION_EXPORT void WolFoxBuildNativeOnesieRequest(
    NSString *videoID,
    WolFoxNativeRequestCompletion completion);

@interface WolFoxSABRTask : NSObject
- (void)cancel;
@end

@interface WolFoxSABRDownloader : NSObject

+ (WolFoxSABRTask *)downloadPlayerResponse:(id)playerResponse
                   videoOption:(WolFoxStreamOption *)videoOption
                   audioOption:(WolFoxStreamOption *)audioOption
                     audioOnly:(BOOL)audioOnly
                       videoID:(NSString *)videoID
                     identifier:(NSString *)identifier
                      progress:(nullable WolFoxSABRProgress)progress
                    completion:(WolFoxSABRCompletion)completion;

@end

NS_ASSUME_NONNULL_END

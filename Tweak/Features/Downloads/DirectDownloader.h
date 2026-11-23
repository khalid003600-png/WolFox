#import <Foundation/Foundation.h>
#import "SABRDownloader.h"

@class WolFoxStreamOption;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const WolFoxDownloadMethodKey;
FOUNDATION_EXPORT BOOL WolFoxDirectDownloadsEnabled(void);
FOUNDATION_EXPORT BOOL WolFoxTVDownloadsEnabled(void);

@interface WolFoxDirectTask : NSObject
- (void)cancel;
@end

@interface WolFoxDirectDownloader : NSObject

+ (void)fetchOptionsForVideoID:(NSString *)videoID
                    completion:(void (^)(NSArray<WolFoxStreamOption *> *options))completion;
+ (NSString *)codecNameForOption:(WolFoxStreamOption *)option;

+ (WolFoxDirectTask *)downloadVideoID:(NSString *)videoID
                          videoOption:(nullable WolFoxStreamOption *)videoOption
                          audioOption:(WolFoxStreamOption *)audioOption
                            audioOnly:(BOOL)audioOnly
                           identifier:(NSString *)identifier
                             progress:(nullable WolFoxSABRProgress)progress
                           completion:(WolFoxSABRCompletion)completion;

@end

NS_ASSUME_NONNULL_END

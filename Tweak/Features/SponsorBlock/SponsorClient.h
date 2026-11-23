#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WolFoxSponsorCompletion)(
    NSArray<NSDictionary<NSString *, id> *> *segments
);

@interface WolFoxSponsorClient : NSObject
+ (instancetype)sharedClient;
- (void)segmentsForVideoID:(NSString *)videoID
                completion:(WolFoxSponsorCompletion)completion;
- (void)segmentsForVideoID:(NSString *)videoID
                categories:(NSArray<NSString *> *)categories
                completion:(WolFoxSponsorCompletion)completion;
@end

NS_ASSUME_NONNULL_END

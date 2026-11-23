#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WolFoxFFmpegCompletion)(NSError * _Nullable error);
typedef void (^WolFoxFFmpegProgress)(double fraction);

FOUNDATION_EXPORT void WolFoxFFmpegCancelConversion(NSString *identifier);

@interface WolFoxFFmpegMuxer : NSObject
+ (void)remuxAudioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
           completion:(WolFoxFFmpegCompletion)completion;
+ (void)remuxVideoURL:(NSURL *)videoURL
             audioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
           completion:(WolFoxFFmpegCompletion)completion;
+ (void)normalizeMediaURL:(NSURL *)mediaURL
                outputURL:(NSURL *)outputURL
               completion:(WolFoxFFmpegCompletion)completion;
+ (void)videoFromAudioURL:(NSURL *)audioURL
             artworkData:(nullable NSData *)artworkData
                outputURL:(NSURL *)outputURL
                 progress:(nullable WolFoxFFmpegProgress)progress
               completion:(WolFoxFFmpegCompletion)completion;
+ (void)muxSubtitlesIntoURL:(NSURL *)mediaURL
                       cues:(NSArray<NSDictionary *> *)cues
                   language:(nullable NSString *)language
                  outputURL:(NSURL *)outputURL
                 completion:(WolFoxFFmpegCompletion)completion;
+ (void)embedArtworkData:(NSData *)artworkData
                 mediaURL:(NSURL *)mediaURL
               completion:(WolFoxFFmpegCompletion)completion;
@end

NS_ASSUME_NONNULL_END

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class WolFoxDownloadPlaybackSession;

@interface WolFoxAudioPlayerController : UIViewController
- (instancetype)initWithSession:(WolFoxDownloadPlaybackSession *)session;
@property(nonatomic, copy, nullable) dispatch_block_t minimizeHandler;
@end

NS_ASSUME_NONNULL_END

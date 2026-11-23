#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT CGFloat WolFoxDownloadProgressRatio(NSURL *URL);
FOUNDATION_EXPORT UIView *WolFoxLibraryVideoView(void);

@class AVPlayer;
@class AVPlayerLayer;

extern NSNotificationName const WolFoxDownloadPlaybackDidChangeNotification;
extern NSNotificationName const WolFoxDownloadPlaybackDidStopNotification;
extern NSNotificationName const WolFoxDownloadSponsorDidSkipNotification;
extern NSNotificationName const WolFoxDownloadSponsorPromptNotification;
extern NSNotificationName const WolFoxLibraryPiPDidChangeNotification;
extern NSNotificationName const WolFoxLibraryFullPlayerWillShowNotification;
extern NSNotificationName const WolFoxLibraryFullPlayerWillHideNotification;

@interface WolFoxDownloadPlaybackSession : NSObject

+ (instancetype)sharedSession;
+ (nullable instancetype)existingSession;

@property(nonatomic, strong, readonly) AVPlayer *player;
@property(nonatomic, copy, readonly, nullable) NSURL *currentURL;
@property(nonatomic, copy, readonly) NSArray<NSURL *> *playlist;
@property(nonatomic, assign, readonly) NSInteger currentIndex;
@property(nonatomic, assign) BOOL autoplayEnabled;
@property(nonatomic, assign) BOOL gesturesEnabled;
@property(nonatomic, assign) BOOL repeatEnabled;
@property(nonatomic, assign) BOOL pauseAtEnd;
@property(nonatomic, assign) float playbackRate;
@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, id> *> *sponsorSegments;
@property(nonatomic, copy, readonly, nullable) NSDictionary<NSString *, id> *promptedSegment;

- (void)loadURL:(NSURL *)URL
       playlist:(NSArray<NSURL *> *)playlist
          index:(NSInteger)index;
- (void)updatePlaylist:(NSArray<NSURL *> *)playlist;
- (void)play;
- (void)pause;
- (void)togglePlayback;
- (void)seekBy:(NSTimeInterval)seconds;
- (void)playNext;
- (void)playPrevious;
- (void)stop;
- (void)skipSegment:(NSDictionary<NSString *, id> *)segment;
- (void)seekToTime:(NSTimeInterval)seconds;

@end

@interface WolFoxLibraryPiP : NSObject

+ (instancetype)sharedPiP;

@property(nonatomic, assign, readonly) BOOL active;
@property(nonatomic, assign) BOOL automatic;
@property(nonatomic, copy, nullable) void (^restoreHandler)(UIView * _Nullable owner);

- (void)useLayer:(AVPlayerLayer *)layer owner:(UIView *)owner;
- (BOOL)isUsingLayer:(AVPlayerLayer *)layer;
- (void)silenceOtherControllers;
- (void)start;
- (void)stop;

@end

@interface WolFoxDownloadPlayerController : UIViewController

- (instancetype)initWithSession:(WolFoxDownloadPlaybackSession *)session;
@property(nonatomic, copy, nullable) dispatch_block_t minimizeHandler;
@property(nonatomic, assign) CGRect sourceFrame;

@end

NS_ASSUME_NONNULL_END

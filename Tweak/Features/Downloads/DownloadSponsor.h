#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const WolFoxDownloadInfoDidChangeNotification;

FOUNDATION_EXPORT void WolFoxAttachSponsorSegments(NSURL *fileURL, NSString *videoID,
                                                 NSString * _Nullable author);
FOUNDATION_EXPORT NSString * _Nullable WolFoxStoredChannelName(NSURL *fileURL);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *WolFoxStoredSponsorSegments(NSURL *fileURL);
FOUNDATION_EXPORT void WolFoxRefreshSponsorSegments(
    NSURL *fileURL, void (^completion)(NSArray<NSDictionary<NSString *, id> *> *segments));

NS_ASSUME_NONNULL_END

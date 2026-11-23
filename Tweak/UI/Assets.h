#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT UIColor *WolFoxAccentColor(void);
FOUNDATION_EXPORT NSBundle * _Nullable WolFoxAssetsBundle(void);
FOUNDATION_EXPORT UIImage * _Nullable WolFoxAssetImage(
    NSString *name,
    NSString * _Nullable fallbackSymbol
);
FOUNDATION_EXPORT UIImage * _Nullable WolFoxYouTubeImage(
    NSArray<NSString *> *names,
    NSString * _Nullable fallbackSymbol
);
FOUNDATION_EXPORT UIImage * _Nullable WolFoxGearImage(void);
FOUNDATION_EXPORT UIImage * _Nullable WolFoxShortsImage(BOOL selected);
FOUNDATION_EXPORT UIImage * _Nullable WolFoxDownloadTabImage(BOOL selected);

NS_ASSUME_NONNULL_END

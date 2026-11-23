#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Where our player buttons sit: in YouTube's top row, in our row under it,
// or next to the fullscreen button. Hidden buttons are the ones switched off.
FOUNDATION_EXPORT NSString *const WolFoxOverlayZoneTop;
FOUNDATION_EXPORT NSString *const WolFoxOverlayZoneBelow;
FOUNDATION_EXPORT NSString *const WolFoxOverlayZoneBottom;
// In fullscreen, after the pill of buttons under the progress bar.
FOUNDATION_EXPORT NSString *const WolFoxOverlayZoneFullscreen;
// A column down the left edge of the player.
FOUNDATION_EXPORT NSString *const WolFoxOverlayZoneLeft;

// Each entry: id (the overlay configurator id), title, symbol, optional text.
FOUNDATION_EXPORT NSArray<NSDictionary *> *WolFoxOverlayButtonCatalog(void);

FOUNDATION_EXPORT NSArray<NSString *> *WolFoxOverlayZones(void);
FOUNDATION_EXPORT NSString *WolFoxOverlayButtonZone(NSString *identifier);
// Button ids in a zone, left to right, including switched-off ones.
FOUNDATION_EXPORT NSArray<NSString *> *WolFoxOverlayZoneOrder(NSString *zone);
FOUNDATION_EXPORT void WolFoxSetOverlayLayout(NSDictionary<NSString *, NSArray<NSString *> *> *_Nullable layout);

FOUNDATION_EXPORT BOOL WolFoxOverlayButtonEnabled(NSString *identifier);
FOUNDATION_EXPORT void WolFoxSetOverlayButtonEnabled(NSString *identifier, BOOL enabled);

// YouTube's own top-right buttons (autoplay, cast, captions, gear), left to
// right. Nil order means YouTube's.
FOUNDATION_EXPORT NSArray<NSString *> *WolFoxNativeTopDefaultOrder(void);
FOUNDATION_EXPORT NSArray<NSString *> *WolFoxNativeTopOrder(void);
FOUNDATION_EXPORT void WolFoxSetNativeTopOrder(NSArray<NSString *> *_Nullable order);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *WolFoxNativeTopIdentifiers(void);
// The saved top row as stored: YouTube's names and YTKACE's ids, left to right.
FOUNDATION_EXPORT NSArray<NSString *> *WolFoxTopRowOrder(void);

NS_ASSUME_NONNULL_END

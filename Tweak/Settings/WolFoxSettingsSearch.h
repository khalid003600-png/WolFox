#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSArray<NSDictionary *> *WolFoxFilterSettings(NSString *query);
FOUNDATION_EXPORT void WolFoxPresentSettingsSearchOverlay(UIViewController *host);
FOUNDATION_EXPORT NSArray<NSArray<NSDictionary *> *> *WolFoxSearchResultSections(
    NSString *query, NSArray<NSString *> *_Nullable *_Nullable sectionTitles);
FOUNDATION_EXPORT void WolFoxOpenSettingsRecord(NSDictionary *record,
                                                UIViewController *presenter);

NS_ASSUME_NONNULL_END

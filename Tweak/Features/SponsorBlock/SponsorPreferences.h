#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *WolFoxSponsorCategoryDefinitions(void);
FOUNDATION_EXPORT NSString *WolFoxSponsorBehaviorKey(NSString *category);
FOUNDATION_EXPORT NSString *WolFoxSponsorColorKey(NSString *category);
FOUNDATION_EXPORT NSInteger WolFoxSponsorCategoryBehavior(NSString *category);
FOUNDATION_EXPORT NSArray<NSString *> *WolFoxSponsorEnabledCategories(void);
FOUNDATION_EXPORT UIColor *WolFoxSponsorCategoryColor(NSString *category);
FOUNDATION_EXPORT NSInteger WolFoxSponsorNotificationMode(void);
FOUNDATION_EXPORT NSTimeInterval WolFoxSponsorSkipAlertDuration(void);
FOUNDATION_EXPORT NSTimeInterval WolFoxSponsorUnskipAlertDuration(void);
FOUNDATION_EXPORT NSTimeInterval WolFoxSponsorMinimumSegmentLength(void);

NS_ASSUME_NONNULL_END

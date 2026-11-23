#import "SponsorPreferences.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"

NSArray<NSDictionary<NSString *, NSString *> *> *WolFoxSponsorCategoryDefinitions(void) {
    static NSArray *definitions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        definitions = @[
            @{@"id": @"sponsor", @"title": WolFoxLocalized(@"Sponsor"), @"color": @"#00D400"},
            @{@"id": @"selfpromo", @"title": WolFoxLocalized(@"Self Promotion"), @"color": @"#FFFF00"},
            @{@"id": @"interaction", @"title": WolFoxLocalized(@"Interaction Reminder"), @"color": @"#CC00FF"},
            @{@"id": @"intro", @"title": WolFoxLocalized(@"Intermission / Intro"), @"color": @"#00FFFF"},
            @{@"id": @"outro", @"title": WolFoxLocalized(@"Endcards / Credits"), @"color": @"#0202ED"},
            @{@"id": @"preview", @"title": WolFoxLocalized(@"Preview / Recap"), @"color": @"#008FD6"},
            @{@"id": @"music_offtopic", @"title": WolFoxLocalized(@"Non-Music Section"), @"color": @"#FF9900"},
            @{@"id": @"filler", @"title": WolFoxLocalized(@"Filler"), @"color": @"#7300FF"},
            @{@"id": @"poi_highlight", @"title": WolFoxLocalized(@"Highlight"), @"color": @"#FF1684"}
        ];
    });
    return definitions;
}

NSString *WolFoxSponsorBehaviorKey(NSString *category) {
    return [@"YTKACE.Preference.SponsorBlock.Behavior."
        stringByAppendingString:category ?: @""];
}

NSString *WolFoxSponsorColorKey(NSString *category) {
    return [@"YTKACE.Preference.SponsorBlock.Color."
        stringByAppendingString:category ?: @""];
}

static NSDictionary<NSString *, NSString *> *WolFoxSponsorDefinition(NSString *category) {
    for (NSDictionary *definition in WolFoxSponsorCategoryDefinitions()) {
        if ([definition[@"id"] isEqualToString:category]) return definition;
    }
    return nil;
}

NSInteger WolFoxSponsorCategoryBehavior(NSString *category) {
    id stored = WolFoxPreferenceObject(WolFoxSponsorBehaviorKey(category));
    if ([stored respondsToSelector:@selector(integerValue)]) {
        return MAX(0, MIN([stored integerValue], 3));
    }
    if ([category isEqualToString:@"sponsor"]) {
        id legacy = WolFoxPreferenceObject(@"YTKACE.Preference.SponsorBlock.Mode");
        return [legacy respondsToSelector:@selector(integerValue)] &&
            [legacy integerValue] == 1 ? 1 : 0;
    }
    return 2;
}

NSArray<NSString *> *WolFoxSponsorEnabledCategories(void) {
    NSMutableArray *categories = [NSMutableArray array];
    for (NSDictionary *definition in WolFoxSponsorCategoryDefinitions()) {
        NSString *category = definition[@"id"];
        if (WolFoxSponsorCategoryBehavior(category) != 2) {
            [categories addObject:category];
        }
    }
    return categories;
}

static UIColor *WolFoxColorFromHex(NSString *hex) {
    NSString *value = [[hex ?: @"" stringByReplacingOccurrencesOfString:@"#"
                                                              withString:@""] uppercaseString];
    if (value.length != 6) return UIColor.systemGreenColor;
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:value] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

UIColor *WolFoxSponsorCategoryColor(NSString *category) {
    NSDictionary *definition = WolFoxSponsorDefinition(category);
    NSString *stored = WolFoxPreferenceObject(WolFoxSponsorColorKey(category));
    NSString *hex = [stored isKindOfClass:NSString.class] && stored.length != 0
        ? stored : definition[@"color"];
    return WolFoxColorFromHex(hex);
}

NSInteger WolFoxSponsorNotificationMode(void) {
    id stored = WolFoxPreferenceObject(@"YTKACE.Preference.SponsorBlock.NotificationMode");
    return [stored respondsToSelector:@selector(integerValue)]
        ? MAX(0, MIN([stored integerValue], 2)) : 0;
}

static NSTimeInterval WolFoxSponsorDuration(NSString *key) {
    id stored = WolFoxPreferenceObject(key);
    double value = [stored respondsToSelector:@selector(doubleValue)]
        ? [stored doubleValue] : 4.0;
    return MAX(1.0, MIN(value, 10.0));
}

NSTimeInterval WolFoxSponsorSkipAlertDuration(void) {
    return WolFoxSponsorDuration(@"YTKACE.Preference.SponsorBlock.SkipAlertSeconds");
}

NSTimeInterval WolFoxSponsorUnskipAlertDuration(void) {
    return WolFoxSponsorDuration(@"YTKACE.Preference.SponsorBlock.UnskipAlertSeconds");
}

NSTimeInterval WolFoxSponsorMinimumSegmentLength(void) {
    id stored = WolFoxPreferenceObject(@"YTKACE.Preference.SponsorBlock.MinimumSeconds");
    double value = [stored respondsToSelector:@selector(doubleValue)]
        ? [stored doubleValue] : 0.0;
    return MAX(0.0, MIN(value, 20.0));
}

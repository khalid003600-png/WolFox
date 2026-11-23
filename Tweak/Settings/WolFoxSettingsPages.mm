#import "WolFoxSettingsPages.h"
#import "../UI/OverlayButtonHost.h"
#import "WolFoxSettingsSearch.h"
#import "../Features/Downloads/SABRDownloader.h"
#import "WolFoxRootOptionsController.h"
#import "WolFoxTabEditorController.h"
#import "WolFoxActionBarLayoutView.h"
#import "WolFoxButtonLayoutView.h"
#import "../Runtime/Preferences.h"
#import "../WolFox.h"
#import "DuoKit.h"
#import "../Runtime/Localization.h"
#import "../UI/Assets.h"
#import "../UI/Notice.h"
#import "../Features/Downloads/WolFoxBackupManager.h"
#import "../Features/Downloads/WolFoxMediaImporter.h"
#import "../Features/SponsorBlock/SponsorPreferences.h"
#import "../Features/SponsorBlock/DeArrow.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>

typedef UIViewController * _Nonnull (^WolFoxControllerBuilder)(void);
typedef void (^WolFoxAction)(UIViewController *controller);

static const void *WolFoxItemAssociation = &WolFoxItemAssociation;
static const void *WolFoxValueLabelAssociation = &WolFoxValueLabelAssociation;

static NSArray<NSString *> *WolFoxLocalizedList(NSArray<NSString *> *titles) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSString *title in titles) {
        [out addObject:WolFoxLocalized(title)];
    }
    return out;
}

static NSDictionary *WolFoxToggle(NSString *title,
                                   NSString *key,
                                   NSString *asset,
                                   NSString *symbol) {
    return @{
        @"type": @"toggle",
        @"title": WolFoxLocalized(title),
        @"en": title,
        @"key": key,
        @"asset": asset ?: @"",
        @"symbol": symbol ?: @""
    };
}

static NSDictionary *WolFoxWithFooter(NSDictionary *item, NSString *footer) {
    NSMutableDictionary *copy = [item mutableCopy];
    copy[@"footer"] = WolFoxLocalized(footer);
    return copy;
}

static NSDictionary *WolFoxInput(NSString *title, NSString *subtitle, NSString *key, NSString *placeholder) {
    return @{
        @"type": @"input",
        @"title": WolFoxLocalized(title),
        @"en": title,
        @"subtitle": WolFoxLocalized(subtitle ?: @""),
        @"key": key,
        @"placeholder": WolFoxLocalized(placeholder ?: @""),
        @"asset": @"",
        @"symbol": @""
    };
}

static NSDictionary *WolFoxToggleDetail(NSString *title,
                                         NSString *subtitle,
                                         NSString *key) {
    return @{
        @"type": @"toggle",
        @"title": WolFoxLocalized(title),
        @"en": title,
        @"subtitle": WolFoxLocalized(subtitle ?: @""),
        @"key": key,
        @"asset": @"",
        @"symbol": @""
    };
}

static NSDictionary *WolFoxPickerDetail(NSString *title,
                                        NSString *subtitle,
                                        NSString *key,
                                        NSArray<NSString *> *titles,
                                        NSArray *values,
                                        NSUInteger defaultIndex) {
    return @{
        @"type": @"picker",
        @"title": WolFoxLocalized(title),
        @"en": title,
        @"subtitle": WolFoxLocalized(subtitle ?: @""),
        @"key": key,
        @"titles": WolFoxLocalizedList(titles),
        @"values": values,
        @"default": @(defaultIndex),
        @"asset": @"",
        @"symbol": @""
    };
}

static NSDictionary *WolFoxPicker(NSString *title,
                                   NSString *key,
                                   NSArray<NSString *> *titles,
                                   NSArray *values,
                                   NSUInteger defaultIndex,
                                   NSString *asset,
                                   NSString *symbol) {
    return @{
        @"type": @"picker",
        @"title": WolFoxLocalized(title),
        @"en": title,
        @"key": key,
        @"titles": WolFoxLocalizedList(titles),
        @"values": values,
        @"default": @(defaultIndex),
        @"asset": asset ?: @"",
        @"symbol": symbol ?: @""
    };
}

static NSString *WolFoxStepperText(NSDictionary *item, double value) {
    NSString *number = [NSString stringWithFormat:@"%.0f", value];
    if ([item[@"unit"] isEqualToString:@"count"]) {
        return [NSString stringWithFormat:@"%@: %@",
                item[@"title"] ?: WolFoxLocalized(@"Limit"), number];
    }
    return [NSString stringWithFormat:WolFoxLocalized(@"Seconds: %@"), number];
}

static NSDictionary *WolFoxStepper(NSString *title,
                                    NSString *key,
                                    double minimum,
                                    double maximum,
                                    double step,
                                    double fallback) {
    return @{
        @"type": @"stepper",
        @"title": WolFoxLocalized(title),
        @"en": title,
        @"key": key,
        @"minimum": @(minimum),
        @"maximum": @(maximum),
        @"step": @(step),
        @"fallback": @(fallback)
    };
}

static NSDictionary *WolFoxCountStepper(NSString *title,
                                        NSString *key,
                                        double minimum,
                                        double maximum,
                                        double step,
                                        double fallback) {
    NSMutableDictionary *row =
        [WolFoxStepper(title, key, minimum, maximum, step, fallback) mutableCopy];
    row[@"unit"] = @"count";
    return row;
}

static NSDictionary *WolFoxSegmentedStacked(NSString *title,
                                            NSString *key,
                                            NSArray<NSString *> *titles,
                                            NSArray *values,
                                            NSUInteger defaultIndex) {
    return @{
        @"type": @"segmented",
        @"stacked": @YES,
        @"title": WolFoxLocalized(title),
        @"en": title,
        @"key": key,
        @"titles": WolFoxLocalizedList(titles),
        @"values": values,
        @"default": @(defaultIndex)
    };
}

static NSDictionary *WolFoxSlider(NSString *title,
                                   NSString *key,
                                   double minimum,
                                   double maximum,
                                   double step,
                                   double fallback) {
    return @{
        @"type": @"slider",
        @"title": WolFoxLocalized(title),
        @"en": title,
        @"key": key,
        @"minimum": @(minimum),
        @"maximum": @(maximum),
        @"step": @(step),
        @"fallback": @(fallback)
    };
}

static const void *WolFoxStepTargetAssociation = &WolFoxStepTargetAssociation;

static NSDictionary *WolFoxStackedSlider(NSString *title,
                                         NSString *key,
                                         double minimum,
                                         double maximum,
                                         double step,
                                         double fallback,
                                         NSString *unit) {
    NSMutableDictionary *row =
        [WolFoxSlider(title, key, minimum, maximum, step, fallback) mutableCopy];
    row[@"unit"] = unit ?: @"";
    row[@"stacked"] = @YES;
    return row;
}

static NSDictionary *WolFoxPercentSlider(NSString *title,
                                         NSString *key,
                                         double minimum,
                                         double maximum,
                                         double step,
                                         double fallback) {
    NSMutableDictionary *item =
        [WolFoxSlider(title, key, minimum, maximum, step, fallback) mutableCopy];
    item[@"unit"] = @"percent";
    item[@"stacked"] = @YES;
    return item;
}

static UIButton *WolFoxStepControl(BOOL increment,
                                   UISlider *slider,
                                   id target,
                                   SEL action) {
    UIImageSymbolConfiguration *glyph =
        [UIImageSymbolConfiguration configurationWithPointSize:14.0
                                                        weight:UIImageSymbolWeightSemibold];
    UIButton *control = [UIButton buttonWithType:UIButtonTypeSystem];
    control.tag = increment ? 1 : -1;
    control.tintColor = WolFoxAccentColor();
    [control setImage:[UIImage systemImageNamed:increment ? @"plus" : @"minus"
                              withConfiguration:glyph]
             forState:UIControlStateNormal];
    [control.widthAnchor constraintEqualToConstant:30.0].active = YES;
    objc_setAssociatedObject(control, WolFoxStepTargetAssociation, slider,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [control addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return control;
}

static NSString *WolFoxTrimmedNumber(double value) {
    NSString *text = [NSString stringWithFormat:@"%.2f", value];
    while ([text containsString:@"."] && [text hasSuffix:@"0"]) {
        text = [text substringToIndex:text.length - 1];
    }
    if ([text hasSuffix:@"."]) text = [text substringToIndex:text.length - 1];
    return text;
}

static NSString *WolFoxSliderValueText(NSDictionary *item, double value) {
    NSString *unit = item[@"unit"];
    if ([unit isEqualToString:@"percent"]) {
        return [NSString stringWithFormat:@"%.0f%%", value];
    }
    if ([unit isEqualToString:@"speed"]) {
        return [WolFoxTrimmedNumber(value) stringByAppendingString:@"x"];
    }
    return [NSString stringWithFormat:WolFoxLocalized(@"%@ seconds"),
            [NSString stringWithFormat:@"%.0f", value]];
}

static NSDictionary *WolFoxColor(NSString *title,
                                 NSString *key,
                                 NSString *fallback) {
    return @{
        @"type": @"color",
        @"title": WolFoxLocalized(title),
        @"en": title,
        @"key": key,
        @"fallback": fallback
    };
}

static NSDictionary *WolFoxColorDetail(NSString *title, NSString *subtitle, NSString *key, NSString *fallback) {
    NSMutableDictionary *item = [WolFoxColor(title, key, fallback) mutableCopy];
    item[@"subtitle"] = WolFoxLocalized(subtitle ?: @"");
    return item;
}

static NSString *WolFoxHexFromColor(UIColor *color) {
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return @"#00D400";
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)lround(red * 255.0), (int)lround(green * 255.0),
            (int)lround(blue * 255.0)];
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

static NSDictionary *WolFoxActionDetail(NSString *title,
                                         NSString *subtitle,
                                         WolFoxAction action) {
    return @{
        @"type": @"action",
        @"title": WolFoxLocalized(title),
        @"en": title,
        @"subtitle": WolFoxLocalized(subtitle ?: @""),
        @"asset": @"",
        @"symbol": @"",
        @"action": [action copy]
    };
}

typedef NSString *_Nonnull (^WolFoxInfoProvider)(void);

// A read-only row: title with a value under it that's worked out each time
// the page shows.
static NSDictionary *WolFoxInfo(NSString *title, WolFoxInfoProvider provider) {
    return @{
        @"type": @"info",
        @"title": WolFoxLocalized(title),
        @"en": title,
        @"subtitle": @" ",
        @"asset": @"",
        @"symbol": @"",
        @"provider": [provider copy]
    };
}

static NSString *const WolFoxLastBackupDateKey = @"WolFox.Backup.LastDate";
static NSString *const WolFoxLastBackupSizeKey = @"WolFox.Backup.LastSize";

static UIColor *WolFoxSettingsBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return WolFoxInterfaceBackgroundColor(traits);
    }];
}

static UIColor *WolFoxSettingsCellBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return WolFoxInterfaceBackgroundColor(traits);
    }];
}

BOOL WolFoxPreferenceNeedsRestart(NSString *key) {
    return [@[
        WolFoxOLEDKey,
        @"YTKACE.Preference.Navigation.PremiumLogo",
        @"YTKACE.Preference.Navigation.LogoHidden",
        @"YTKACE.Preference.App.LayoutIdiom",
        @"YTKACE.Preference.App.RTLDisabled",
        @"YTKACE.Preference.Playback.LegacyQualityMenu",
        @"YTKACE.Preference.Navigation.StatusBarHidden",
        @"YTKACE.Preference.Tabs.Glass",
        @"YTKACE.Preference.Tabs.GlassMode",
        @"YTKACE.Preference.Glass.TopBar",
        @"YTKACE.Preference.Glass.Menus",
        @"YTKACE.Preference.Glass.Notices",
        @"YTKACE.Preference.Glass.Player",
        @"YTKACE.Preference.Tabs.Startup",
        @"YTKACE.Preference.Playback.CaptionsAlwaysOn",
        @"YTKACE.Preference.Playback.CaptionsMode",
        @"YTKACE.Preference.Feed.HomeTabsHidden",
        @"YTKACE.Preference.Shorts.LiveHidden",
        @"YTKACE.Preference.Shorts.PostsHidden",
        @"YTKACE.Preference.Language",
        @"YTKACE.Preference.Navigation.NotificationsHidden"
    ] containsObject:key];
}

void WolFoxShowRestartNotice(UIViewController *controller) {
    UIView *host = controller.navigationController.view ?: controller.view;
    UIView *old = [host viewWithTag:0x594B524E];
    [old removeFromSuperview];
    UIView *notice = [UIView new];
    notice.tag = 0x594B524E;
    notice.backgroundColor = [UIColor colorWithWhite:0.72 alpha:0.96];
    notice.layer.cornerRadius = 8.0;
    notice.layer.masksToBounds = YES;
    notice.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *label = [UILabel new];
    label.text = WolFoxLocalized(@"Your changes take effect once YouTube restarts.");
    label.textColor = UIColor.labelColor;
    label.font = [UIFont systemFontOfSize:13.0];
    label.numberOfLines = 2;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [notice addSubview:label];
    if (WolFoxApplyGlassBackground(notice, NO)) notice.layer.cornerRadius = 16.0;
    [host addSubview:notice];
    UILayoutGuide *safe = host.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [notice.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8.0],
        [notice.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8.0],
        [notice.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0],
        [notice.heightAnchor constraintEqualToConstant:48.0],
        [label.leadingAnchor constraintEqualToAnchor:notice.leadingAnchor constant:14.0],
        [label.trailingAnchor constraintEqualToAnchor:notice.trailingAnchor constant:-14.0],
        [label.centerYAnchor constraintEqualToAnchor:notice.centerYAnchor]
    ]];
    notice.alpha = 0.0;
    [UIView animateWithDuration:0.2 animations:^{ notice.alpha = 1.0; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.2 animations:^{ notice.alpha = 0.0; }
                         completion:^(__unused BOOL finished) { [notice removeFromSuperview]; }];
    });
}

static void WolFoxStorePickerValue(NSString *key, id value,
                                   __unused NSUInteger index) {
    WolFoxSetPreferenceObject(key, value);
}

static UIImage *WolFoxBlankChoiceIcon(void) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(24.0, 24.0), NO, 0.0);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

void WolFoxPresentSelectionMenu(UIViewController *presenter,
                                UIView *sourceView,
                                NSString *title,
                                NSArray<NSString *> *titles,
                                NSUInteger selectedIndex,
                                WolFoxChoiceHandler handler) {
    (void)title;
    (void)sourceView;
    if (titles.count == 0) {
        return;
    }
    selectedIndex = MIN(selectedIndex, titles.count - 1);
    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    SEL makeAction = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    id sheet = [actionClass respondsToSelector:makeAction] ? WolFoxMakeSheet(nil, nil) : nil;
    if (sheet != nil) {
        UIImage *check = [[UIImage systemImageNamed:@"checkmark"]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIImage *blank = WolFoxBlankChoiceIcon();
        [titles enumerateObjectsUsingBlock:^(NSString *choice, NSUInteger index, BOOL *stop) {
            (void)stop;
            dispatch_block_t selection = ^{
                if (handler != nil) {
                    handler(index);
                }
            };
            id action = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
                actionClass, makeAction, choice,
                index == selectedIndex ? check : blank, 0, selection);
            SEL addAction = NSSelectorFromString(@"addAction:");
            if ([sheet respondsToSelector:addAction]) {
                ((void (*)(id, SEL, id))objc_msgSend)(sheet, addAction, action);
            }
        }];
        WolFoxShowSheet(sheet, presenter);
        return;
    }
    WolFoxShowNotice(WolFoxLocalized(@"YouTube menu unavailable"));
}

void WolFoxPresentChoiceMenu(UIViewController *presenter,
                             UIView *sourceView,
                             NSString *title,
                             NSArray<NSString *> *titles,
                             NSArray *values,
                             NSString *key,
                             NSUInteger defaultIndex,
                             WolFoxChoiceHandler handler) {
    id selected = WolFoxPreferenceObject(key);
    NSUInteger selectedIndex = [values indexOfObject:selected];
    if (selectedIndex == NSNotFound) {
        selectedIndex = MIN(defaultIndex, values.count - 1);
    }
    WolFoxPresentSelectionMenu(presenter, sourceView, title, titles, selectedIndex,
        ^(NSUInteger index) {
            WolFoxStorePickerValue(key, values[index], index);
            if (([key isEqualToString:@"YTKACE.Preference.Gestures.BrightnessSide"] ||
                 [key isEqualToString:@"YTKACE.Preference.Gestures.VolumeSide"]) && index < 2) {
                NSString *otherKey = [key isEqualToString:@"YTKACE.Preference.Gestures.BrightnessSide"]
                    ? @"YTKACE.Preference.Gestures.VolumeSide" : @"YTKACE.Preference.Gestures.BrightnessSide";
                id otherValue = WolFoxPreferenceObject(otherKey);
                NSInteger otherSide = otherValue == nil
                    ? ([otherKey isEqualToString:@"YTKACE.Preference.Gestures.BrightnessSide"] ? 1 : 0)
                    : [otherValue integerValue];
                if (otherSide == [values[index] integerValue] || otherSide == 3) {
                    WolFoxStorePickerValue(otherKey, @([values[index] integerValue] == 0),
                                           [values[index] integerValue] == 0 ? 1 : 0);
                }
            }
            if ([key isEqualToString:@"YTKACE.Preference.Gestures.VolumeSide"] &&
                [values[index] integerValue] == 3) {
                WolFoxStorePickerValue(@"YTKACE.Preference.Gestures.BrightnessSide", @2, 2);
            }
            if (handler != nil) handler(index);
        });
}

NSString *WolFoxPickerSummary(NSString *key,
                              NSArray<NSString *> *titles,
                              NSArray *values,
                              NSUInteger defaultIndex) {
    id selected = WolFoxPreferenceObject(key);
    NSUInteger index = [values indexOfObject:selected];
    if (index == NSNotFound || index >= titles.count) {
        index = MIN(defaultIndex, titles.count - 1);
    }
    return titles.count == 0 ? @"" : titles[index];
}

@interface WolFoxPickerController : UITableViewController
- (instancetype)initWithTitle:(NSString *)title
                           key:(NSString *)key
                        titles:(NSArray<NSString *> *)titles
                        values:(NSArray *)values
                  defaultIndex:(NSUInteger)defaultIndex;
@end

@implementation WolFoxPickerController {
    NSString *_preferenceKey;
    NSArray<NSString *> *_titles;
    NSArray *_values;
    NSUInteger _defaultIndex;
}

- (instancetype)initWithTitle:(NSString *)title
                           key:(NSString *)key
                        titles:(NSArray<NSString *> *)titles
                        values:(NSArray *)values
                  defaultIndex:(NSUInteger)defaultIndex {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        self.title = title;
        _preferenceKey = [key copy];
        _titles = [titles copy];
        _values = [values copy];
        _defaultIndex = defaultIndex;
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (WolFoxOwnsNavigationController(self.navigationController)) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
    }
    WolFoxApplyAppearance(self);
    self.tableView.backgroundColor = WolFoxSettingsBackground();
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)_titles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WolFoxPickerCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];
    }
    id selected = WolFoxPreferenceObject(_preferenceKey);
    NSUInteger selectedIndex = [_values indexOfObject:selected];
    if (selectedIndex == NSNotFound) {
        selectedIndex = MIN(_defaultIndex, _values.count - 1);
    }
    cell.textLabel.text = _titles[(NSUInteger)indexPath.row];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.backgroundColor = WolFoxSettingsCellBackground();
    cell.accessoryType = (NSUInteger)indexPath.row == selectedIndex
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id value = _values[(NSUInteger)indexPath.row];
    WolFoxStorePickerValue(_preferenceKey, value, (NSUInteger)indexPath.row);
    [tableView reloadData];
}

@end

@interface WolFoxOptionsController : UITableViewController
    <UIDocumentPickerDelegate, UIColorPickerViewControllerDelegate>
- (instancetype)initWithTitle:(NSString *)title
                      sections:(NSArray<NSArray<NSDictionary *> *> *)sections
                sectionTitles:(NSArray<NSString *> *)sectionTitles;
- (void)replaceSections:(NSArray<NSArray<NSDictionary *> *> *)sections
          sectionTitles:(NSArray<NSString *> *)sectionTitles;
@end

@implementation WolFoxOptionsController {
    NSArray<NSArray<NSDictionary *> *> *_sections;
    NSArray<NSString *> *_sectionTitles;
    NSInteger _pickerMode;
    NSString *_importCategory;
    NSString *_colorKey;
    NSIndexPath *_colorPath;
    UIView *_backupOverlay;
    UILabel *_backupOverlayLabel;
    NSURL *_pendingBackupURL;
    BOOL _backupRunning;
    BOOL _restoreRunning;
    WolFoxButtonLayoutView *_layoutView;
    WolFoxActionBarLayoutView *_actionLayoutView;
}

- (instancetype)initWithTitle:(NSString *)title
                      sections:(NSArray<NSArray<NSDictionary *> *> *)sections
                sectionTitles:(NSArray<NSString *> *)sectionTitles {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        self.title = title;
        _sections = [sections copy];
        _sectionTitles = [sectionTitles copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.cellLayoutMarginsFollowReadableWidth = NO;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 50.0;
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0.0;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (WolFoxOwnsNavigationController(self.navigationController)) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
    }
    WolFoxApplyAppearance(self);
    self.tableView.backgroundColor = WolFoxSettingsBackground();
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return (NSInteger)_sections[(NSUInteger)section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if ((NSUInteger)section >= _sectionTitles.count) {
        return nil;
    }
    NSString *title = _sectionTitles[(NSUInteger)section];
    return title.length == 0 ? nil : title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    id footer = _sections[(NSUInteger)section].lastObject[@"footer"];
    return [footer isKindOfClass:NSString.class] ? footer : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    id footer = _sections[(NSUInteger)section].lastObject[@"footer"];
    return [footer isKindOfClass:NSString.class] ? UITableViewAutomaticDimension : tableView.sectionFooterHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    NSString *title = (NSUInteger)section < _sectionTitles.count
        ? _sectionTitles[(NSUInteger)section]
        : @"";
    return title.length == 0 ? 18.0 : 38.0;
}

- (WolFoxButtonLayoutView *)layoutView {
    if (_layoutView != nil) return _layoutView;
    _layoutView = [WolFoxButtonLayoutView new];
    __weak WolFoxOptionsController *weakSelf = self;
    _layoutView.changeHandler = ^{
        WolFoxOptionsController *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        // the hidden tray can grow a line, and the button toggles follow along
        UITableView *table = strongSelf.tableView;
        NSMutableArray *paths = [NSMutableArray array];
        for (NSIndexPath *path in table.indexPathsForVisibleRows) {
            if (![strongSelf->_sections[(NSUInteger)path.section][(NSUInteger)path.row][@"type"] isEqualToString:@"layout"]) {
                [paths addObject:path];
            }
        }
        [UIView performWithoutAnimation:^{
            [table reloadRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationNone];
        }];
        [table beginUpdates];
        [table endUpdates];
    };
    _layoutView.heightHandler = ^{
        UITableView *table = weakSelf.tableView;
        [table beginUpdates];
        [table endUpdates];
    };
    return _layoutView;
}

- (WolFoxActionBarLayoutView *)actionLayoutView {
    if (_actionLayoutView != nil) return _actionLayoutView;
    _actionLayoutView = [WolFoxActionBarLayoutView new];
    __weak WolFoxOptionsController *weakSelf = self;
    // the Remove toggles below follow along
    _actionLayoutView.changeHandler = ^{
        WolFoxOptionsController *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        UITableView *table = strongSelf.tableView;
        NSMutableArray *paths = [NSMutableArray array];
        for (NSIndexPath *path in table.indexPathsForVisibleRows) {
            if (![strongSelf->_sections[(NSUInteger)path.section][(NSUInteger)path.row][@"type"] isEqualToString:@"actionlayout"]) {
                [paths addObject:path];
            }
        }
        [UIView performWithoutAnimation:^{
            [table reloadRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationNone];
        }];
        [table beginUpdates];
        [table endUpdates];
    };
    _actionLayoutView.heightHandler = ^{
        UITableView *table = weakSelf.tableView;
        [UIView performWithoutAnimation:^{
            [table beginUpdates];
            [table endUpdates];
        }];
    };
    return _actionLayoutView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    NSString *type = item[@"type"];
    if ([type isEqualToString:@"layout"]) {
        return [[self layoutView] heightForWidth:CGRectGetWidth(tableView.bounds)];
    }
    if ([type isEqualToString:@"actionlayout"]) {
        return [[self actionLayoutView] heightForWidth:CGRectGetWidth(tableView.bounds)];
    }
    if ([type isEqualToString:@"text"]) {
        return 92.0;
    }
    if ([type isEqualToString:@"slider"]) {
        return [item[@"stacked"] boolValue] ? 78.0 : 58.0;
    }
    if ([type isEqualToString:@"segmented"] && [item[@"stacked"] boolValue]) {
        return 74.0;
    }
    return [item[@"subtitle"] length] == 0 ? 40.0 : 56.0;
}

- (void)tableView:(UITableView *)tableView
willDisplayHeaderView:(UIView *)view
        forSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
        header.textLabel.textColor = UIColor.secondaryLabelColor;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    NSString *type = item[@"type"];
    if ([type isEqualToString:@"layout"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WolFoxLayout"];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"WolFoxLayout"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        cell.backgroundColor = WolFoxSettingsCellBackground();
        WolFoxButtonLayoutView *view = [self layoutView];
        view.frame = cell.contentView.bounds;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cell.contentView addSubview:view];
        return cell;
    }
    if ([type isEqualToString:@"actionlayout"]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"WolFoxActionLayout"];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"WolFoxActionLayout"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        cell.backgroundColor = WolFoxSettingsCellBackground();
        WolFoxActionBarLayoutView *view = [self actionLayoutView];
        view.frame = cell.contentView.bounds;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cell.contentView addSubview:view];
        return cell;
    }
    UITableViewCellStyle style;
    if ([type isEqualToString:@"picker"]) {
        style = [item[@"subtitle"] length] == 0
            ? UITableViewCellStyleValue1
            : UITableViewCellStyleSubtitle;
    } else {
        style = [item[@"subtitle"] length] == 0
            ? UITableViewCellStyleDefault
            : UITableViewCellStyleSubtitle;
    }
    NSString *identifier = [NSString stringWithFormat:@"WolFoxOption-%ld", (long)style];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:identifier];
    }

    [[cell.contentView viewWithTag:8801] removeFromSuperview];
    [[cell.contentView viewWithTag:8802] removeFromSuperview];
    [[cell.contentView viewWithTag:4271] removeFromSuperview];

    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"subtitle"];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 2;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.backgroundColor = WolFoxSettingsCellBackground();
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.imageView.image = nil;

    if ([type isEqualToString:@"toggle"]) {
        UISwitch *toggle = [UISwitch new];
        toggle.transform = CGAffineTransformMakeScale(0.95, 0.95);
        toggle.onTintColor = WolFoxAccentColor();
        id stored = WolFoxPreferenceObject(item[@"key"]);
        toggle.on = [stored respondsToSelector:@selector(boolValue)] && [stored boolValue];
        objc_setAssociatedObject(toggle,
                                 WolFoxItemAssociation,
                                 item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toggle addTarget:self
                   action:@selector(toggleChanged:)
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"segmented"]) {
        UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:item[@"titles"]];
        id selected = WolFoxPreferenceObject(item[@"key"]);
        NSUInteger selectedIndex = [item[@"values"] indexOfObject:selected];
        control.selectedSegmentIndex = selectedIndex == NSNotFound
            ? [item[@"default"] unsignedIntegerValue]
            : selectedIndex;
        objc_setAssociatedObject(control,
                                 WolFoxItemAssociation,
                                 item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [control addTarget:self
                    action:@selector(segmentChanged:)
          forControlEvents:UIControlEventValueChanged];
        if ([item[@"stacked"] boolValue]) {
            UILabel *caption = [UILabel new];
            caption.tag = 8802;
            caption.text = item[@"title"];
            caption.font = [UIFont systemFontOfSize:16.0];
            caption.textColor = UIColor.labelColor;
            caption.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:caption];
            control.tag = 8801;
            control.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:control];
            UILayoutGuide *guide = cell.contentView.layoutMarginsGuide;
            [NSLayoutConstraint activateConstraints:@[
                [caption.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
                [caption.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
                [caption.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor
                                                  constant:8.0],
                [control.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
                [control.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
                [control.topAnchor constraintEqualToAnchor:caption.bottomAnchor
                                                  constant:8.0],
                [control.heightAnchor constraintEqualToConstant:30.0]
            ]];
            cell.textLabel.text = nil;
            cell.accessoryView = nil;
        } else {
            CGFloat width = MAX(128.0, [item[@"titles"] count] * 68.0);
            control.frame = CGRectMake(0.0, 0.0, width, 30.0);
            cell.accessoryView = control;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"stepper"]) {
        double stored = [WolFoxPreferenceObject(item[@"key"]) doubleValue];
        double value = stored > 0.0 ? stored : [item[@"fallback"] doubleValue];
        cell.textLabel.text = WolFoxStepperText(item, value);
        UIStepper *stepper = [UIStepper new];
        stepper.tintColor = WolFoxAccentColor();
        stepper.minimumValue = [item[@"minimum"] doubleValue];
        stepper.maximumValue = [item[@"maximum"] doubleValue];
        stepper.stepValue = [item[@"step"] doubleValue];
        stepper.value = value;
        objc_setAssociatedObject(stepper,
                                 WolFoxItemAssociation,
                                 item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(stepper,
                                 WolFoxValueLabelAssociation,
                                 cell,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [stepper addTarget:self
                    action:@selector(stepperChanged:)
          forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = stepper;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"slider"] && [item[@"stacked"] boolValue]) {
        double stored = [WolFoxPreferenceObject(item[@"key"]) doubleValue];
        double value = stored > 0.0 ? stored : [item[@"fallback"] doubleValue];

        UILabel *caption = [UILabel new];
        caption.text = item[@"title"];
        caption.font = [UIFont systemFontOfSize:16.0];
        caption.textColor = UIColor.labelColor;

        UILabel *readout = [UILabel new];
        readout.font = [UIFont monospacedDigitSystemFontOfSize:15.0
                                                        weight:UIFontWeightSemibold];
        readout.textColor = WolFoxAccentColor();
        readout.textAlignment = NSTextAlignmentRight;
        readout.text = WolFoxSliderValueText(item, value);
        [readout setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                 forAxis:UILayoutConstraintAxisHorizontal];

        UISlider *slider = [UISlider new];
        slider.minimumTrackTintColor = WolFoxAccentColor();
        slider.minimumValue = [item[@"minimum"] floatValue];
        slider.maximumValue = [item[@"maximum"] floatValue];
        slider.value = (float)value;
        objc_setAssociatedObject(slider, WolFoxItemAssociation, item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(slider, WolFoxValueLabelAssociation, readout,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [slider addTarget:self
                   action:@selector(sliderChanged:)
         forControlEvents:UIControlEventValueChanged];

        UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[caption, readout]];
        heading.axis = UILayoutConstraintAxisHorizontal;
        heading.spacing = 8.0;

        UIStackView *track = [[UIStackView alloc] initWithArrangedSubviews:@[
            WolFoxStepControl(NO, slider, self, @selector(sliderStepped:)),
            slider,
            WolFoxStepControl(YES, slider, self, @selector(sliderStepped:))
        ]];
        track.axis = UILayoutConstraintAxisHorizontal;
        track.alignment = UIStackViewAlignmentCenter;
        track.spacing = 10.0;

        UIStackView *container = [[UIStackView alloc] initWithArrangedSubviews:@[heading, track]];
        container.tag = 4271;
        container.axis = UILayoutConstraintAxisVertical;
        container.spacing = 6.0;
        container.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:container];

        UILayoutGuide *guide = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [container.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
            [container.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
            [container.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor
                                                constant:8.0],
            [container.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor
                                                   constant:-8.0]
        ]];
        cell.textLabel.text = nil;
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"slider"]) {
        double stored = [WolFoxPreferenceObject(item[@"key"]) doubleValue];
        double value = stored > 0.0 ? stored : [item[@"fallback"] doubleValue];
        UIView *accessory = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 158.0, 46.0)];
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0.0, 0.0, 158.0, 30.0)];
        slider.minimumTrackTintColor = WolFoxAccentColor();
        slider.minimumValue = [item[@"minimum"] floatValue];
        slider.maximumValue = [item[@"maximum"] floatValue];
        slider.value = (float)value;
        UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 28.0, 158.0, 14.0)];
        valueLabel.font = [UIFont systemFontOfSize:10.0];
        valueLabel.textColor = UIColor.tertiaryLabelColor;
        valueLabel.textAlignment = NSTextAlignmentRight;
        valueLabel.text = WolFoxSliderValueText(item, value);
        objc_setAssociatedObject(slider, WolFoxItemAssociation, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(slider, WolFoxValueLabelAssociation, valueLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [accessory addSubview:slider];
        [accessory addSubview:valueLabel];
        cell.accessoryView = accessory;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"picker"]) {
        NSString *summary = WolFoxPickerSummary(
            item[@"key"],
            item[@"titles"],
            item[@"values"],
            [item[@"default"] unsignedIntegerValue]
        );
        if ([item[@"subtitle"] length] == 0) {
            cell.detailTextLabel.text = summary;
            cell.detailTextLabel.textColor = WolFoxAccentColor();
        } else {
            UILabel *value = [UILabel new];
            value.text = summary;
            value.font = [UIFont systemFontOfSize:15.0];
            value.textColor = WolFoxAccentColor();
            value.textAlignment = NSTextAlignmentRight;
            [value sizeToFit];
            cell.accessoryView = value;
        }
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if ([type isEqualToString:@"input"]) {
        id stored = WolFoxPreferenceObject(item[@"key"]);
        UILabel *value = [UILabel new];
        value.text = [stored isKindOfClass:NSString.class] && [stored length] != 0 ? stored : item[@"placeholder"];
        value.font = [UIFont systemFontOfSize:15.0];
        value.textColor = WolFoxAccentColor();
        value.textAlignment = NSTextAlignmentRight;
        [value sizeToFit];
        if (CGRectGetWidth(value.frame) > 160.0) value.frame = CGRectMake(0.0, 0.0, 160.0, CGRectGetHeight(value.frame));
        value.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.accessoryView = value;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if ([type isEqualToString:@"color"]) {
        NSString *stored = WolFoxPreferenceObject(item[@"key"]);
        UIColor *color = WolFoxColorFromHex(
            [stored isKindOfClass:NSString.class] ? stored : item[@"fallback"]);
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 28.0, 28.0)];
        dot.backgroundColor = color;
        dot.layer.cornerRadius = 14.0;
        dot.layer.borderWidth = 2.0;
        dot.layer.borderColor = UIColor.secondaryLabelColor.CGColor;
        cell.accessoryView = dot;
    } else if ([type isEqualToString:@"info"]) {
        WolFoxInfoProvider provider = item[@"provider"];
        cell.detailTextLabel.text = provider != nil ? provider() : @"";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"text"]) {
        cell.textLabel.font = [UIFont systemFontOfSize:10.0];
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.textLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, WolFoxItemAssociation);
    NSArray *values = item[@"values"];
    if ((NSUInteger)sender.selectedSegmentIndex < values.count) {
        WolFoxSetPreferenceObject(item[@"key"], values[(NSUInteger)sender.selectedSegmentIndex]);
        if (WolFoxPreferenceNeedsRestart(item[@"key"])) {
            WolFoxShowRestartNotice(self);
        }
    }
}

- (void)toggleChanged:(UISwitch *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, WolFoxItemAssociation);
    NSString *key = item[@"key"];
    WolFoxSetPreference(key, sender.isOn);
    if ([key isEqualToString:WolFoxOLEDKey]) {
        WolFoxApplyAppearance(self);
        self.tableView.backgroundColor = WolFoxSettingsBackground();
        [self.tableView reloadData];
    }
    if (WolFoxPreferenceNeedsRestart(key)) {
        WolFoxShowRestartNotice(self);
    }
}

- (void)stepperChanged:(UIStepper *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, WolFoxItemAssociation);
    UITableViewCell *cell = objc_getAssociatedObject(sender, WolFoxValueLabelAssociation);
    WolFoxSetPreferenceObject(item[@"key"], @(sender.value));
    cell.textLabel.text = WolFoxStepperText(item, sender.value);
}

- (void)sliderStepped:(UIButton *)sender {
    UISlider *slider = objc_getAssociatedObject(sender, WolFoxStepTargetAssociation);
    NSDictionary *item = objc_getAssociatedObject(slider, WolFoxItemAssociation);
    if (slider == nil || item == nil) return;
    const double step = MAX(0.01, [item[@"step"] doubleValue]);
    const double lower = [item[@"minimum"] doubleValue];
    const double upper = [item[@"maximum"] doubleValue];
    double shifted = slider.value + step * (double)sender.tag;
    shifted = MIN(upper, MAX(lower, shifted));
    slider.value = (float)shifted;
    [self sliderChanged:slider];
}

- (void)sliderChanged:(UISlider *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, WolFoxItemAssociation);
    UILabel *label = objc_getAssociatedObject(sender, WolFoxValueLabelAssociation);
    double step = MAX(0.01, [item[@"step"] doubleValue]);
    double value = round(round(sender.value / step) * step * 100.0) / 100.0;
    WolFoxSetPreferenceObject(item[@"key"], @(value));
    label.text = WolFoxSliderValueText(item, value);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    NSString *type = item[@"type"];
    UIViewController *controller = nil;
    if ([type isEqualToString:@"controller"]) {
        WolFoxControllerBuilder builder = item[@"builder"];
        controller = builder();
    } else if ([type isEqualToString:@"picker"]) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        WolFoxPresentChoiceMenu(self, cell, item[@"title"], item[@"titles"],
            item[@"values"], item[@"key"],
            [item[@"default"] unsignedIntegerValue], ^(__unused NSUInteger index) {
                NSString *key = item[@"key"];
                if ([key isEqualToString:@"YTKACE.Preference.Gestures.BrightnessSide"] ||
                    [key isEqualToString:@"YTKACE.Preference.Gestures.VolumeSide"]) {
                    [self.tableView reloadData];
                } else {
                    [self.tableView reloadRowsAtIndexPaths:@[indexPath]
                                          withRowAnimation:UITableViewRowAnimationNone];
                }
                if (WolFoxPreferenceNeedsRestart(item[@"key"])) {
                    WolFoxShowRestartNotice(self);
                }
            });
    } else if ([type isEqualToString:@"action"]) {
        WolFoxAction action = item[@"action"];
        action(self);
    } else if ([type isEqualToString:@"input"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:item[@"title"]
                                                                       message:item[@"subtitle"]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            id stored = WolFoxPreferenceObject(item[@"key"]);
            field.text = [stored isKindOfClass:NSString.class] ? stored : @"";
            field.placeholder = item[@"placeholder"];
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:WolFoxLocalized(@"Cancel")
                                                  style:UIAlertActionStyleCancel handler:nil]];
        __weak UIAlertController *weakAlert = alert;
        [alert addAction:[UIAlertAction actionWithTitle:WolFoxLocalized(@"Save") style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            NSString *text = [weakAlert.textFields.firstObject.text
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            WolFoxSetPreferenceObject(item[@"key"], text ?: @"");
            [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if ([type isEqualToString:@"color"]) {
        NSString *stored = WolFoxPreferenceObject(item[@"key"]);
        UIColorPickerViewController *picker = [UIColorPickerViewController new];
        picker.title = item[@"title"];
        picker.supportsAlpha = NO;
        picker.selectedColor = WolFoxColorFromHex(
            [stored isKindOfClass:NSString.class] ? stored : item[@"fallback"]);
        picker.delegate = self;
        _colorKey = [item[@"key"] copy];
        _colorPath = indexPath;
        [self presentViewController:picker animated:YES completion:nil];
    }
    if (controller != nil) {
        [self.navigationController pushViewController:controller animated:YES];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (_pickerMode == 3) {
        if (_pendingBackupURL != nil) {
            NSNumber *size = nil;
            [_pendingBackupURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            [defaults setObject:NSDate.date forKey:WolFoxLastBackupDateKey];
            [defaults setObject:size ?: @0 forKey:WolFoxLastBackupSizeKey];
            [NSFileManager.defaultManager removeItemAtURL:_pendingBackupURL error:nil];
            [self.tableView reloadData];
        }
        _pendingBackupURL = nil;
        _pickerMode = 0;
        return;
    }
    if (urls.count == 0) return;
    NSMutableArray<NSURL *> *scoped = [NSMutableArray array];
    for (NSURL *URL in urls) {
        if ([URL startAccessingSecurityScopedResource]) [scoped addObject:URL];
    }
    if (_pickerMode == 1) {
        _restoreRunning = YES;
        [self setBackupProgressVisible:YES message:WolFoxLocalized(@"Restoring Backup...")];
        [WolFoxBackupManager restoreBackupFromURL:urls.firstObject
            completion:^(NSError *error) {
                for (NSURL *URL in scoped) [URL stopAccessingSecurityScopedResource];
                self->_restoreRunning = NO;
                [self setBackupProgressVisible:NO message:nil];
                [self showResult:error == nil ? WolFoxLocalized(@"Backup Restored") : WolFoxLocalized(@"Restore Failed")
                          message:error.localizedDescription];
            }];
        _pickerMode = 0;
        return;
    }
    NSString *category = _importCategory ?: WolFoxLocalized(@"Video");
    [WolFoxMediaImporter importURLs:urls category:category
        completion:^(NSUInteger count, NSError *error) {
            for (NSURL *URL in scoped) [URL stopAccessingSecurityScopedResource];
            NSString *message = error.localizedDescription ?: [NSString
                stringWithFormat:WolFoxLocalized(@"%lu items added to %@."),
                (unsigned long)count, category];
            [self showResult:error == nil ? WolFoxLocalized(@"Import Complete") : WolFoxLocalized(@"Import Failed")
                      message:message];
        }];
}

- (void)colorPickerViewController:(UIColorPickerViewController *)viewController
                   didSelectColor:(UIColor *)color
                     continuously:(BOOL)continuously {
    (void)continuously;
    if (_colorKey.length == 0 || color == nil) return;
    WolFoxSetPreferenceObject(_colorKey, WolFoxHexFromColor(color));
    if (_colorPath != nil) {
        [self.tableView reloadRowsAtIndexPaths:@[_colorPath]
                              withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    if (_colorKey.length != 0) {
        WolFoxSetPreferenceObject(_colorKey, WolFoxHexFromColor(viewController.selectedColor));
        if (_colorPath != nil) {
            [self.tableView reloadRowsAtIndexPaths:@[_colorPath]
                                  withRowAnimation:UITableViewRowAnimationNone];
        }
    }
    _colorKey = nil;
    _colorPath = nil;
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    NSInteger mode = _pickerMode;
    _pickerMode = 0;
    if (mode == 3) {
        if (_pendingBackupURL != nil) {
            [NSFileManager.defaultManager removeItemAtURL:_pendingBackupURL error:nil];
        }
        _pendingBackupURL = nil;
        NSString *message = WolFoxLocalized(@"The backup was not saved to the Files app.");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (!WolFoxShowYouTubeDialog(WolFoxLocalized(@"Backup Not Saved"), message)) {
                    WolFoxShowNotice(WolFoxLocalized(@"Warning: Backup was not saved to Files app."));
                }
            });
    }
}

- (void)setBackupProgressVisible:(BOOL)visible message:(NSString *)message {
    if (!visible) {
        UIView *overlay = _backupOverlay;
        _backupOverlay = nil;
        _backupOverlayLabel = nil;
        [UIView animateWithDuration:0.18 animations:^{
            overlay.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            [overlay removeFromSuperview];
        }];
        return;
    }
    if (_backupOverlay != nil) {
        _backupOverlayLabel.text = message.length == 0 ? WolFoxLocalized(@"Please Wait...") : message;
        return;
    }
    UIView *host = self.navigationController.view ?: self.view;
    UIView *overlay = [UIView new];
    overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.alpha = 0.0;

    UIView *card = [UIView new];
    card.backgroundColor = WolFoxInterfaceSurfaceColor(self.traitCollection);
    card.layer.cornerRadius = 12.0;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = UIColor.labelColor;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];

    UILabel *label = [UILabel new];
    label.text = message.length == 0 ? WolFoxLocalized(@"Please Wait...") : message;
    label.textColor = UIColor.labelColor;
    label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:spinner];
    [card addSubview:label];
    [overlay addSubview:card];
    [host addSubview:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:host.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:190.0],
        [card.heightAnchor constraintEqualToConstant:94.0],
        [spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [spinner.topAnchor constraintEqualToAnchor:card.topAnchor constant:17.0],
        [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
        [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-17.0]
    ]];
    _backupOverlay = overlay;
    _backupOverlayLabel = label;
    [UIView animateWithDuration:0.18 animations:^{ overlay.alpha = 1.0; }];
}

- (void)performBackup {
    if (_backupRunning) return;
    _backupRunning = YES;
    [self setBackupProgressVisible:YES message:WolFoxLocalized(@"Preparing Backup...")];
    __weak WolFoxOptionsController *weakSelf = self;
    [WolFoxBackupManager createBackupWithCompletion:^(NSURL *URL, NSError *error) {
        WolFoxOptionsController *controller = weakSelf;
        if (controller == nil) return;
        controller->_backupRunning = NO;
        [controller setBackupProgressVisible:NO message:nil];
        if (URL == nil || error != nil) {
            NSString *message = error.localizedDescription ?: WolFoxLocalized(@"The backup could not be created.");
            if (!WolFoxShowYouTubeDialog(WolFoxLocalized(@"Backup Failed"), message)) {
                [controller showResult:WolFoxLocalized(@"Backup Failed") message:message];
            }
            return;
        }
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForExportingURLs:@[URL] asCopy:YES];
        controller->_pickerMode = 3;
        controller->_pendingBackupURL = URL;
        picker.delegate = controller;
        [controller presentViewController:picker animated:YES completion:nil];
    }];
}

- (void)beginBackup {
    if (_backupRunning) return;
    __weak WolFoxOptionsController *weakSelf = self;
    BOOL shown = WolFoxShowYouTubeConfirmation(
        @"WolFox",
        WolFoxLocalized(@"Do you want to create a backup?"),
        WolFoxLocalized(@"Create"),
        ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf performBackup];
            });
        }
    );
    if (!shown) {
        WolFoxShowNotice(WolFoxLocalized(@"Backup confirmation unavailable"));
    }
}

- (void)beginRestore {
    if (_restoreRunning) return;
    _pickerMode = 1;
    UTType *zip = [UTType typeWithFilenameExtension:@"zip"] ?: UTTypeData;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[zip] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)beginImportForCategory:(NSString *)category {
    _pickerMode = 2;
    _importCategory = [category copy];
    NSMutableArray<UTType *> *types = [NSMutableArray arrayWithObjects:
        UTTypeMovie, UTTypeAudio, UTTypeImage, nil];
    UTType *srt = [UTType typeWithFilenameExtension:@"srt"];
    UTType *vtt = [UTType typeWithFilenameExtension:@"vtt"];
    if (srt != nil) [types addObject:srt];
    if (vtt != nil) [types addObject:vtt];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseImportCategory {
    WolFoxPresentChoiceMenu(self, self.view, WolFoxLocalized(@"Import Media"),
        @[WolFoxLocalized(@"Video"), WolFoxLocalized(@"Audio"), WolFoxLocalized(@"Shorts")],
        @[@"Video", @"Audio", @"Shorts"],
        @"WolFoxImportMediaType", 0, ^(NSUInteger index) {
            NSArray *categories = @[@"Video", @"Audio", @"Shorts"];
            [self beginImportForCategory:categories[index]];
        });
}

- (void)showResult:(NSString *)title message:(NSString *)message {
    NSString *notice = message.length != 0
        ? [NSString stringWithFormat:@"%@\n%@", title, message] : title;
    WolFoxShowNotice(notice);
}

- (void)replaceSections:(NSArray<NSArray<NSDictionary *> *> *)sections
          sectionTitles:(NSArray<NSString *> *)sectionTitles {
    _sections = [sections copy];
    _sectionTitles = [sectionTitles copy];
    [self.tableView reloadData];
}

@end

UIViewController *WolFoxMakeSettingsResultsController(
        NSArray<NSArray<NSDictionary *> *> *sections,
        NSArray<NSString *> *sectionTitles) {
    return [[WolFoxOptionsController alloc] initWithTitle:@""
                                                 sections:sections
                                            sectionTitles:sectionTitles];
}

void WolFoxUpdateSettingsResultsController(UIViewController *controller,
        NSArray<NSArray<NSDictionary *> *> *sections,
        NSArray<NSString *> *sectionTitles) {
    if (![controller isKindOfClass:WolFoxOptionsController.class]) return;
    [(WolFoxOptionsController *)controller replaceSections:sections
                                            sectionTitles:sectionTitles];
}

static WolFoxOptionsController *WolFoxPage(NSString *title,
                                           NSArray *sections,
                                           NSArray *sectionTitles) {
    return [[WolFoxOptionsController alloc] initWithTitle:WolFoxLocalized(title)
                                                 sections:sections
                                           sectionTitles:WolFoxLocalizedList(sectionTitles)];
}

static NSArray<NSString *> *WolFoxQualityTitles(void) {
    return @[WolFoxLocalized(@"Auto"), @"2160p60", @"2160p", @"1440p60", @"1440p", @"1080p60",
             @"1080p", @"720p60", @"720p", @"480p", @"360p", @"240p", @"144p"];
}

static NSArray *WolFoxQualityValues(void) {
    return @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12];
}

static NSArray *WolFoxFilterDeviceRows(NSArray *sections) {
    NSMutableSet<NSString *> *hiddenKeys = [NSMutableSet set];
    if (!DUOIsDuo()) {
        [hiddenKeys addObjectsFromArray:@[
            @"YTKACE.Preference.Tabs.DuoNativeBar",
            @"YTKACE.Preference.Player.DuoDeskSplit",
            @"YTKACE.Preference.Player.DuoStatusBarHidden"
        ]];
    }
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) {
        [hiddenKeys addObject:WolFoxFullscreenOrientationKey];
        [hiddenKeys addObject:@"YTKACE.Preference.Player.NotchSafeVideo"];
    }
    if (hiddenKeys.count == 0) return sections;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:sections.count];
    for (id section in sections) {
        if (![section isKindOfClass:NSArray.class]) {
            [filtered addObject:section];
            continue;
        }
        NSMutableArray *rows = [NSMutableArray array];
        for (id row in (NSArray *)section) {
            if ([row isKindOfClass:NSDictionary.class] &&
                [hiddenKeys containsObject:((NSDictionary *)row)[@"key"] ?: @""]) {
                continue;
            }
            [rows addObject:row];
        }
        [filtered addObject:rows];
    }
    return filtered;
}

static NSDictionary *WolFoxPageDefinition(NSString *pageID,
                                          NSString *title,
                                          NSArray *sections,
                                          NSArray *headers) {
    sections = WolFoxFilterDeviceRows(sections);
    return @{
        @"id": pageID,
        @"title": title,
        @"sections": sections,
        @"headers": headers
    };
}

static WolFoxOptionsController *WolFoxPageFromDefinition(NSDictionary *definition) {
    return WolFoxPage(definition[@"title"],
                      definition[@"sections"],
                      definition[@"headers"]);
}

void WolFoxStartupDestinations(NSArray<NSString *> * _Nullable * _Nullable outTitles,
                               NSArray<NSString *> * _Nullable * _Nullable outValues) {
    NSArray<NSArray<NSString *> *> *destinations = @[
        @[@"", WolFoxLocalized(@"Default"), @""],
        @[@"home", WolFoxLocalized(@"Home"), @"YTKACE.Preference.Tabs.Hidden.Home"],
        @[@"explore", WolFoxLocalized(@"Explore"), @""],
        @[@"subscriptions", WolFoxLocalized(@"Subscriptions"), @"YTKACE.Preference.Tabs.Hidden.Subscriptions"],
        @[@"shorts", WolFoxLocalized(@"Shorts"), @"YTKACE.Preference.Tabs.Hidden.Shorts"],
        @[@"library", WolFoxLocalized(@"You"), @"YTKACE.Preference.Tabs.Hidden.Library"],
        @[@"ytkace", @"WolFox", @"YTKACE.Preference.Tabs.Hidden.YTKACETab"],
        @[@"create", WolFoxLocalized(@"Create"), @"YTKACE.Preference.Tabs.Hidden.Create"],
        @[@"music", WolFoxLocalized(@"Music"), @"YTKACE.Preference.Tabs.Hidden.Music"],
        @[@"live", WolFoxLocalized(@"Live"), @"YTKACE.Preference.Tabs.Hidden.Live"],
        @[@"gaming", WolFoxLocalized(@"Gaming"), @"YTKACE.Preference.Tabs.Hidden.Gaming"],
        @[@"news", WolFoxLocalized(@"News"), @"YTKACE.Preference.Tabs.Hidden.News"],
        @[@"posts", WolFoxLocalized(@"Posts"), @"YTKACE.Preference.Tabs.Hidden.Posts"],
        @[@"sports", WolFoxLocalized(@"Sports"), @"YTKACE.Preference.Tabs.Hidden.Sports"],
        @[@"learning", WolFoxLocalized(@"Learning"), @"YTKACE.Preference.Tabs.Hidden.Learning"],
        @[@"fashion", WolFoxLocalized(@"Fashion"), @"YTKACE.Preference.Tabs.Hidden.Fashion"],
        @[@"playlists", WolFoxLocalized(@"Playlists"), @"YTKACE.Preference.Tabs.Hidden.Playlists"],
        @[@"history", WolFoxLocalized(@"History"), @"YTKACE.Preference.Tabs.Hidden.History"],
        @[@"notifications", WolFoxLocalized(@"Notifs"), @"YTKACE.Preference.Tabs.Hidden.Notifs"],
        @[@"watchlater", WolFoxLocalized(@"WLater"), @"YTKACE.Preference.Tabs.Hidden.WatchLater"],
        @[@"customplaylist", WolFoxLocalized(@"Playlist"), @"YTKACE.Preference.Tabs.Hidden.CustomPlaylist"]
    ];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *selected = [defaults stringForKey:@"YTKACE.Preference.Tabs.Startup"];
    NSArray<NSString *> *known = [defaults arrayForKey:@"YTKACE.Preference.Tabs.Known"];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    for (NSArray<NSString *> *entry in destinations) {
        NSString *token = entry[0];
        NSString *hideKey = entry[2];
        BOOL hidden = hideKey.length != 0 && [defaults boolForKey:hideKey];
        NSString *canonical =
            [token isEqualToString:@"library"] ? @"you" : token;
        if (token.length != 0 && known.count != 0 &&
            ![known containsObject:canonical] && ![token isEqualToString:selected]) {
            continue;
        }
        if (hidden && ![token isEqualToString:selected]) continue;
        [titles addObject:entry[1]];
        [values addObject:token];
    }
    if (outTitles != NULL) *outTitles = titles;
    if (outValues != NULL) *outValues = values;
}

UIViewController *WolFoxMakeStartupPickerController(void) {
    NSArray<NSString *> *titles = nil;
    NSArray<NSString *> *values = nil;
    WolFoxStartupDestinations(&titles, &values);
    return [[WolFoxPickerController alloc]
        initWithTitle:WolFoxLocalized(@"Startup Page")
                   key:@"YTKACE.Preference.Tabs.Startup"
                titles:titles
                values:values
          defaultIndex:0];
}

UIViewController *WolFoxMakeWiFiQualityController(void) {
    return [[WolFoxPickerController alloc] initWithTitle:WolFoxLocalized(@"Wi-Fi Quality")
                                                    key:@"YTKACE.Preference.Playback.WiFiQuality"
                                                 titles:WolFoxQualityTitles()
                                                 values:WolFoxQualityValues()
                                           defaultIndex:0];
}

UIViewController *WolFoxMakeCellularQualityController(void) {
    return [[WolFoxPickerController alloc] initWithTitle:WolFoxLocalized(@"Cellular Quality")
                                                    key:@"YTKACE.Preference.Playback.CellularQuality"
                                                 titles:WolFoxQualityTitles()
                                                 values:WolFoxQualityValues()
                                           defaultIndex:0];
}

// Channels whitelisted from the SponsorBlock player menu. Swipe to remove.
@interface WolFoxSponsorWhitelistController : UITableViewController
@end

@implementation WolFoxSponsorWhitelistController {
    NSMutableArray<NSString *> *_handles;
}

static NSString * const WolFoxSponsorWhitelistListKey = @"YTKACE.Preference.SponsorBlock.Whitelist";

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self != nil) self.title = WolFoxLocalized(@"Whitelisted Channels");
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (WolFoxOwnsNavigationController(self.navigationController)) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
    }
    WolFoxApplyAppearance(self);
    self.tableView.backgroundColor = WolFoxSettingsBackground();
    NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:WolFoxSponsorWhitelistListKey];
    _handles = [NSMutableArray array];
    for (id handle in stored) {
        if ([handle isKindOfClass:NSString.class]) [_handles addObject:handle];
    }
    [_handles sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)MAX(_handles.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return _handles.count == 0
        ? WolFoxLocalized(@"Whitelist a channel from the shield button in the player.")
        : WolFoxLocalized(@"Swipe left to remove a channel.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"WolFoxWhitelistCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    cell.backgroundColor = WolFoxSettingsCellBackground();
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    if (_handles.count == 0) {
        cell.textLabel.text = WolFoxLocalized(@"No channels");
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
    } else {
        cell.textLabel.text = _handles[(NSUInteger)indexPath.row];
        cell.textLabel.textColor = UIColor.labelColor;
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    (void)indexPath;
    return _handles.count != 0;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete || _handles.count == 0) return;
    [_handles removeObjectAtIndex:(NSUInteger)indexPath.row];
    [NSUserDefaults.standardUserDefaults setObject:[_handles copy] forKey:WolFoxSponsorWhitelistListKey];
    if (_handles.count == 0) {
        [tableView reloadData];
    } else {
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }
}

@end

static NSDictionary *WolFoxSponsorBlockDefinition(void) {
    NSMutableArray *sections = [NSMutableArray arrayWithObject:@[
        WolFoxToggleDetail(@"SponsorBlock",
                           @"Skip or mark video segments. Set each category below.",
                           WolFoxSponsorBlockKey),
        WolFoxToggleDetail(@"Player Button",
                           @"Adds a shield to the player to whitelist channels, vote on segments and submit new ones.",
                           @"YTKACE.Preference.SponsorBlock.OverlayButton"),
        WolFoxPickerDetail(@"Skip Notice", @"Shown after a segment is skipped.",
                     @"YTKACE.Preference.SponsorBlock.NotificationMode",
                     @[@"With Unskip", @"Text Only", @"Off"],
                     @[@0, @1, @2], 0),
        WolFoxToggleDetail(@"Skip Sound", @"Play a sound and vibrate when a segment is skipped.",
                           @"YTKACE.Preference.SponsorBlock.AudioFeedback"),
        WolFoxSlider(@"Notice Duration", @"YTKACE.Preference.SponsorBlock.SkipAlertSeconds",
                     1.0, 10.0, 1.0, 4.0),
        WolFoxSlider(@"Unskip Duration", @"YTKACE.Preference.SponsorBlock.UnskipAlertSeconds",
                     1.0, 10.0, 1.0, 4.0),
        WolFoxSlider(@"Minimum Segment Length", @"YTKACE.Preference.SponsorBlock.MinimumSeconds",
                     0.0, 20.0, 1.0, 0.0),
        WolFoxActionDetail(@"Whitelisted Channels", @"Channels where segments aren't skipped.",
                           ^(UIViewController *controller) {
            [controller.navigationController pushViewController:[WolFoxSponsorWhitelistController new]
                                                       animated:YES];
        })
    ]];
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithObject:WolFoxLocalized(@"MAIN")];

    [sections addObject:@[
        WolFoxToggleDetail(@"DeArrow Thumbnails",
                           @"Replace clickbait thumbnails with community-picked "
                            "frames from DeArrow. Videos without a submission are "
                            "left untouched.",
                           WolFoxDeArrowThumbModeKey),
        WolFoxToggleDetail(@"DeArrow Titles",
                           @"Replace clickbait titles with community-written ones "
                            "from DeArrow. Videos without a submission keep their "
                            "original title.",
                           WolFoxDeArrowTitlesKey)
    ]];
    [titles addObject:WolFoxLocalized(@"DEARROW")];

    for (NSDictionary<NSString *, NSString *> *definition in
         WolFoxSponsorCategoryDefinitions()) {
        NSString *category = definition[@"id"];
        BOOL highlight = [category isEqualToString:@"poi_highlight"];
        [sections addObject:@[
            highlight
                ? WolFoxPicker(@"Behavior", WolFoxSponsorBehaviorKey(category),
                               @[@"Show Marker", @"Disabled"], @[@3, @2], 1, @"", @"")
                : WolFoxPicker(@"Behavior", WolFoxSponsorBehaviorKey(category),
                               @[@"Auto-skip", @"Ask", @"Show Marker", @"Disabled"],
                               @[@0, @1, @3, @2],
                               [category isEqualToString:@"sponsor"] ? 0 : 3,
                               @"", @""),
            WolFoxColor(@"Segment Color", WolFoxSponsorColorKey(category),
                        definition[@"color"])
        ]];
        [titles addObject:WolFoxLocalized([definition[@"title"] uppercaseString])];
    }
    return WolFoxPageDefinition(@"sponsorblock", @"SponsorBlock", sections, titles);
}

static NSDictionary *WolFoxPlayerDefinition(void) {
    return WolFoxPageDefinition(@"player", @"Player", @[
        @[
            @{@"type": @"layout", @"title": WolFoxLocalized(@"Button Layout"), @"en": @"Button Layout", @"subtitle": @""},
            WolFoxToggleDetail(@"PiP Button", @"Add a button that opens the video in picture in picture.", WolFoxPiPKey),
            WolFoxToggleDetail(@"iPhone Duo Laptop Layout", @"Half open like a laptop, full-screen video plays above the crease with the controls below.", @"YTKACE.Preference.Player.DuoDeskSplit"),
            WolFoxToggleDetail(@"iPhone Duo Status Bar Over Video", @"Hide the clock and status icons while the watch page's video is under them.", @"YTKACE.Preference.Player.DuoStatusBarHidden"),
            WolFoxToggle(@"Loop Button", WolFoxLoopKey, @"", @""),
            WolFoxToggleDetail(@"Quality Button", @"Add a button that opens the quality menu.", @"YTKACE.Preference.Player.QualityButton"),
            WolFoxPicker(@"Quality Button Style", @"YTKACE.Preference.Player.QualityButtonStyle",
                         @[@"Standard", @"Compact"], @[@0, @1], 0, @"", @""),
            WolFoxToggle(@"Sleep Timer Button", WolFoxSleepTimerKey, @"", @""),
            WolFoxToggle(@"Speed Button", WolFoxSpeedKey, @"", @""),
            WolFoxPickerDetail(@"Speed Button Style",
                @"Speed Menu shows the current speed and opens YouTube's speed menu with speeds up to 5x.",
                @"YTKACE.Preference.Player.SpeedButtonStyle",
                @[@"− / +", @"Speed Menu"], @[@0, @1], 0)
        ],
        @[
            WolFoxPicker(@"Default Playback Speed",
                         @"YTKACE.Preference.Player.StartRate",
                         @[@"Follow YouTube", @"Match last used", @"Custom"],
                         @[@0, @(-1), @(-2)], 0, @"", @""),
            WolFoxStackedSlider(@"Custom speed",
                                @"YTKACE.Preference.Player.CustomRate",
                                0.25, 5.0, 0.05, 1.0, @"speed"),
            WolFoxToggleDetail(@"Custom Hold Speed",
                               @"Change the speed used when you hold to speed up. "
                               @"Restart YouTube after changing.",
                               @"YTKACE.Preference.Player.HoldSpeedEnabled"),
            WolFoxStackedSlider(@"Hold speed",
                                @"YTKACE.Preference.Player.HoldSpeedRate",
                                0.25, 5.0, 0.25, 2.0, @"speed"),
            WolFoxToggleDetail(@"Swipe to Change Speed",
                               @"While holding, swipe up or down to change the speed.",
                               @"YTKACE.Preference.Player.HoldSpeedSwipe")
        ],
        @[
            WolFoxToggleDetail(@"Background Audio",
                               @"Keep playing when you leave the app or lock the screen.",
                               WolFoxBackgroundPlaybackKey),
            WolFoxToggleDetail(@"Disable PiP for Miniplayer",
                               @"Don't open picture in picture when you leave the app from the miniplayer.",
                               @"YTKACE.Preference.Playback.MiniplayerPiPDisabled"),
            WolFoxToggleDetail(@"Stop Autoplay Next",
                               @"Do not roll into the next video when one ends.",
                               @"YTKACE.Preference.Playback.AutoplayDisabled"),
            WolFoxToggleDetail(@"Open Videos Paused",
                               @"Videos load without starting playback.",
                               @"YTKACE.Preference.Playback.OpenPaused"),
            WolFoxToggleDetail(@"Keep Playing",
                               @"Don't stop to ask if you're still watching.",
                               @"YTKACE.Preference.Playback.YouThereDisabled"),
            WolFoxToggleDetail(@"Bypass Premium Device Limit",
                               @"Stop YouTube counting this device toward your plan's stream limit.",
                               @"YTKACE.Preference.Playback.BlockHeartbeat"),
            WolFoxToggleDetail(@"Auto Fullscreen",
                               @"Videos open in fullscreen.",
                               @"YTKACE.Preference.Player.AutoFullscreen"),
            WolFoxPickerDetail(@"Charging Port in Fullscreen",
                               @"Keep landscape fullscreen on one side.",
                               WolFoxFullscreenOrientationKey,
                               @[@"Off", @"Left", @"Right"],
                               @[@(WolFoxFullscreenOrientationNeither), @(WolFoxFullscreenOrientationLeft),
                                 @(WolFoxFullscreenOrientationRight)], 0),
            WolFoxToggleDetail(@"Fit Video Around Notch",
                               @"Don't let the notch or Dynamic Island cover wide videos in fullscreen.",
                               @"YTKACE.Preference.Player.NotchSafeVideo"),
            WolFoxToggleDetail(@"Exit Fullscreen at End",
                               @"Leave fullscreen when a video ends.",
                               @"YTKACE.Preference.Player.ExitFullscreenAtEnd"),
            WolFoxToggleDetail(@"Local Queue",
                               @"Play next and play last without Premium.",
                               @"YTKACE.Preference.Playback.LocalQueue"),
            WolFoxPickerDetail(@"Lock Screen Skip",
                @"Replace next and previous on the lock screen and in Control Center with skip buttons.",
                @"YTKACE.Preference.Playback.RemoteSkip",
                @[@"Off", @"10 seconds", @"15 seconds", @"30 seconds"], @[@0, @10, @15, @30], 0),
            WolFoxToggle(@"Remove Ads", WolFoxNoAdsKey, @"", @""),
            WolFoxPickerDetail(@"Playback Fix",
                @"Try this if videos won't load or keep buffering. Restart YouTube after changing.",
                @"YTKACE.Preference.Playback.FixMode",
                @[@"Off", @"Reload", @"HLS Streams"],
                @[@0, @1, @2], (NSUInteger)WolFoxPlaybackFixMode())
        ],
        @[
            WolFoxToggleDetail(@"Keep Controls Visible", @"Player controls never fade out.",
                               @"YTKACE.Preference.Overlay.AlwaysShowControls"),
            WolFoxToggle(@"Keep Play Button Visible", @"YTKACE.Preference.Overlay.AlwaysShowPlayPause", @"", @""),
            WolFoxToggle(@"Keep Progress Bar Visible", @"YTKACE.Preference.Overlay.ProgressAlwaysVisible", @"", @""),
            WolFoxToggleDetail(@"Remove Player Dimming",
                               @"Stop the video from darkening when the controls show.",
                               @"YTKACE.Preference.Overlay.DimmingRemoved"),
            WolFoxToggle(@"Show Status Bar in Fullscreen", @"YTKACE.Preference.Overlay.StatusBarVisible", @"", @""),
            WolFoxPickerDetail(@"Video Zoom",
                @"Stop pinch zoom at fill, or zoom past YouTube's 8x limit.",
                @"YTKACE.Preference.Playback.VideoZoom",
                @[@"Original", @"Cap to Fill", @"Unlimited"],
                @[@0, @1, @2], 0)
        ],
        @[
            WolFoxPickerDetail(@"Previous/Next Skip",
                @"Previous and next skip back and forward in the video instead.",
                @"YTKACE.Preference.Overlay.PreviousNextSeek",
                @[@"Off", @"5 seconds", @"10 seconds", @"15 seconds", @"30 seconds"], @[@0, @5, @10, @15, @30], 0),
            WolFoxToggleDetail(@"Disable Previous/Next", @"Grey out previous and next so they can't be tapped.",
                               @"YTKACE.Preference.Overlay.PreviousNextDisabled"),
            WolFoxToggle(@"Smaller Previous/Next", @"YTKACE.Preference.Overlay.CompactPreviousNext", @"", @""),
            WolFoxToggle(@"Remove Previous/Next", @"YTKACE.Preference.Overlay.PreviousNextHidden", @"", @"")
        ],
        @[
            WolFoxToggle(@"Remove Play Button", @"YTKACE.Preference.Overlay.PlayPauseHidden", @"", @""),
            WolFoxToggle(@"Remove Settings Button", @"YTKACE.Preference.Overlay.MoreButtonHidden", @"", @""),
            WolFoxToggle(@"Remove Captions Button", @"YTKACE.Preference.Overlay.CaptionsButtonHidden", @"", @""),
            WolFoxToggle(@"Remove Cast Button", @"YTKACE.Preference.Overlay.CastHidden", @"", @""),
            WolFoxToggle(@"Remove Autoplay Switch", @"YTKACE.Preference.Overlay.AutoplayHidden", @"", @""),
            WolFoxToggle(@"Remove Info Cards", @"YTKACE.Preference.Overlay.InfoCardsHidden", @"", @""),
            WolFoxToggle(@"Remove Channel Watermark", @"YTKACE.Preference.Overlay.WatermarkHidden", @"", @""),
            WolFoxToggle(@"Remove End Screen", @"YTKACE.Preference.Overlay.EndScreenHidden", @"", @""),
            WolFoxToggleDetail(@"Remove Autoplay Prompt",
                               @"Hides the Suggested video and Suggested music prompts at the end of a video.",
                               @"YTKACE.Preference.Overlay.AutoplayPromptHidden"),
            WolFoxToggle(@"Remove Quick Actions", @"YTKACE.Preference.Overlay.QuickActionsHidden", @"", @""),
            WolFoxToggle(@"Remove Continue Watching", @"YTKACE.Preference.Overlay.ContinueWatchingDisabled", @"", @"")
        ],
        @[
            WolFoxToggleDetail(@"Remove Fullscreen Actions",
                               @"Hide the whole row under the progress bar in fullscreen.",
                               @"YTKACE.Preference.Overlay.FullscreenActionsHidden"),
            WolFoxToggleDetail(@"Remove More Videos",
                               @"Hide the More videos button and the swipe up that opens it.",
                               @"YTKACE.Preference.Overlay.MoreVideosHidden"),
            WolFoxToggle(@"Remove Like", @"YTKACE.Preference.Fullscreen.LikeHidden", @"", @""),
            WolFoxToggle(@"Remove Dislike", @"YTKACE.Preference.Fullscreen.DislikeHidden", @"", @""),
            WolFoxToggle(@"Remove Comments", @"YTKACE.Preference.Fullscreen.CommentsHidden", @"", @""),
            WolFoxToggle(@"Remove Save", @"YTKACE.Preference.Fullscreen.SaveHidden", @"", @""),
            WolFoxToggle(@"Remove Share", @"YTKACE.Preference.Fullscreen.ShareHidden", @"", @""),
            WolFoxToggle(@"Remove Ask Button", @"YTKACE.Preference.Fullscreen.AskHidden", @"", @""),
            WolFoxToggle(@"Remove ⋯ Button", @"YTKACE.Preference.Fullscreen.OverflowHidden", @"", @"")
        ],
        @[
            WolFoxSegmentedStacked(@"Progress bar style", @"YTKACE.Preference.Progress.Style",
                                   @[@"Default", @"Solid color", @"Gradient"], @[@0, @1, @2], 0),
            WolFoxColor(@"Main color", @"YTKACE.Preference.Progress.MainColor", @"#FF0000"),
            WolFoxColorDetail(@"Gradient highlight", @"Used only with Gradient.",
                              @"YTKACE.Preference.Progress.HighlightColor", @"#8E8EFF"),
            WolFoxColorDetail(@"Scrubber color", @"Not used with the Default style.",
                              @"YTKACE.Preference.Progress.ScrubberColor", @"#FF0000")
        ]
    ], @[WolFoxLocalized(@"BUTTONS"), WolFoxLocalized(@"SPEED"), WolFoxLocalized(@"PLAYBACK"),
         WolFoxLocalized(@"CONTROLS"), WolFoxLocalized(@"PREVIOUS & NEXT"),
         WolFoxLocalized(@"HIDE FROM PLAYER"), WolFoxLocalized(@"FULLSCREEN BAR"),
         WolFoxLocalized(@"PROGRESS BAR")]);
}

static NSDictionary *WolFoxQualityDefinition(void) {
    NSArray *qualities = @[@"Auto", @"2160p60", @"2160p", @"1440p60", @"1440p",
                           @"1080p60", @"1080p", @"720p60", @"720p", @"480p",
                           @"360p", @"240p", @"144p"];
    NSArray *values = @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12];
    // Off uses the Wi-Fi or Mobile Data quality.
    NSArray *overrideQualities = [@[@"Off"] arrayByAddingObjectsFromArray:qualities];
    NSArray *overrideValues = [@[@(-1)] arrayByAddingObjectsFromArray:values];
    return WolFoxPageDefinition(@"quality", @"Video Quality", @[
        @[
            WolFoxPicker(@"Wi-Fi Quality", @"YTKACE.Preference.Playback.WiFiQuality",
                         qualities, values, 0, @"", @""),
            WolFoxPicker(@"Mobile Data Quality", @"YTKACE.Preference.Playback.CellularQuality",
                         qualities, values, 0, @"", @""),
            WolFoxToggleDetail(@"HD on Mobile Data", @"Remove YouTube's quality limit on mobile data.",
                               @"YTKACE.Preference.Playback.HDOnCellular")
        ],
        @[
            WolFoxPicker(@"AirPlay on Wi-Fi", @"YTKACE.Preference.Playback.AirPlayWiFiQuality",
                         overrideQualities, overrideValues, 0, @"", @""),
            WolFoxPicker(@"AirPlay on Mobile Data", @"YTKACE.Preference.Playback.AirPlayCellularQuality",
                         overrideQualities, overrideValues, 0, @"", @""),
            WolFoxPicker(@"Low Power Mode", @"YTKACE.Preference.Playback.LowPowerQuality",
                         overrideQualities, overrideValues, 0, @"", @"")
        ],
        @[
            WolFoxToggleDetail(@"Classic Quality Menu", @"Show the full resolution list instead of YouTube's simple menu.",
                               @"YTKACE.Preference.Playback.LegacyQualityMenu"),
            WolFoxToggleDetail(@"Hide Premium Quality",
                               @"Removes 1080p Premium from the quality menu.",
                               @"YTKACE.Preference.Playback.PremiumQualityHidden"),
            WolFoxToggleDetail(@"Disable HDR",
                               @"Play videos in standard dynamic range.",
                               @"YTKACE.Preference.Playback.HDRDisabled")
        ]
    ], @[WolFoxLocalized(@"DEFAULT QUALITY"), WolFoxLocalized(@"AIRPLAY & LOW POWER"), WolFoxLocalized(@"QUALITY MENU")]);
}

static NSDictionary *WolFoxCaptionsDefinition(void) {
    return WolFoxPageDefinition(@"captions", @"Captions", @[
        @[
            WolFoxPickerDetail(@"Captions",
                @"Default follows YouTube. Restart YouTube after changing.",
                @"YTKACE.Preference.Playback.CaptionsMode",
                @[@"Default", @"Always On", @"Always Off"], @[@0, @1, @2], 0),
            WolFoxPickerDetail(@"Caption Language",
                         @"Turns captions on in this language when a video has them.",
                         @"YTKACE.Preference.Playback.CaptionLanguage",
                         @[@"Default", @"English", @"Spanish", @"Portuguese",
                           @"French", @"German", @"Italian", @"Dutch",
                           @"Polish", @"Turkish", @"Russian", @"Arabic",
                           @"Hindi", @"Indonesian", @"Vietnamese", @"Thai",
                           @"Japanese", @"Korean", @"Chinese"],
                         @[@"", @"en", @"es", @"pt", @"fr", @"de", @"it",
                           @"nl", @"pl", @"tr", @"ru", @"ar", @"hi", @"id",
                           @"vi", @"th", @"ja", @"ko", @"zh"],
                         0)
        ],
        @[
            WolFoxToggleDetail(@"Transcript Button",
                               @"Copy or share a video's captions from the player.",
                               @"YTKACE.Preference.Playback.Transcript")
        ]
    ], @[WolFoxLocalized(@"CAPTIONS"), WolFoxLocalized(@"TRANSCRIPT")]);
}

static NSDictionary *WolFoxWatchPageDefinition(void) {
    return WolFoxPageDefinition(@"watch", @"Watch Page", @[
        @[
            WolFoxToggle(@"Remove Suggested Videos", @"YTKACE.Preference.Overlay.SuggestedVideosHidden", @"", @""),
            WolFoxToggleDetail(@"Remove Comments", @"Hide the comments box under the video.",
                               @"YTKACE.Preference.Overlay.CommentsHidden"),
            WolFoxToggle(@"Remove Comment Preview", @"YTKACE.Preference.Overlay.CommentPreviewsHidden", @"", @""),
            WolFoxToggle(@"Remove Comment Guidelines", @"YTKACE.Preference.Overlay.CommentGuidelinesHidden", @"", @""),
            WolFoxToggle(@"Remove Paid Promotion Label", @"YTKACE.Preference.Overlay.PaidPromotionHidden", @"", @""),
            WolFoxToggleDetail(@"Remove Products", @"Hide shopping and product tags in videos, Shorts and feeds.",
                               @"YTKACE.Preference.Overlay.ProductsHidden")
        ],
        @[
            @{@"type": @"actionlayout", @"title": WolFoxLocalized(@"Action Bar"), @"en": @"Action Bar", @"subtitle": @""},
            WolFoxToggleDetail(@"Return YouTube Dislike", @"Show dislike counts from returnyoutubedislike.com.",
                               @"YTKACE.Preference.ActionBar.ReturnDislike"),
            WolFoxToggleDetail(@"Submit Votes", @"Send your likes and dislikes to Return YouTube Dislike with an anonymous ID.",
                               @"YTKACE.Preference.ActionBar.ReturnDislikeVotes")
        ]
    ], @[WolFoxLocalized(@"UNDER THE VIDEO"), WolFoxLocalized(@"ACTION BAR")]);
}

static NSDictionary *WolFoxFeedDefinition(void) {
    return WolFoxPageDefinition(@"feed", @"Home & Feed", @[
        @[
            WolFoxToggleDetail(@"Normal Home Layout",
                               @"Switches the tabbed Home redesign some accounts get back to the normal layout.",
                               @"YTKACE.Preference.Feed.HomeTabsHidden"),
            WolFoxToggleDetail(@"Remove Filter Chips", @"Hide the filter chips at the top of Home and Subscriptions.",
                               @"YTKACE.Preference.Navigation.TopicsHidden")
        ],
        @[
            WolFoxToggle(@"Remove Shorts Shelves", @"YTKACE.Preference.Shorts.FeedHidden", @"", @""),
            WolFoxToggleDetail(@"Keep Shorts in Home",
                @"Still show Shorts on the Home feed when shelves are removed.",
                @"YTKACE.Preference.Shorts.HomeKept"),
            WolFoxToggleDetail(@"Keep Shorts in Subscriptions",
                @"Still show Shorts in the Subscriptions feed when shelves are removed.",
                @"YTKACE.Preference.Shorts.SubscriptionsKept"),
            WolFoxToggleDetail(@"Keep Shorts in Search",
                @"Still show Shorts in search results when shelves are removed.",
                @"YTKACE.Preference.Shorts.SearchKept"),
            WolFoxToggleDetail(@"Keep Shorts on Channels",
                @"Still show Shorts on channel pages when shelves are removed.",
                @"YTKACE.Preference.Shorts.ChannelsKept"),
            WolFoxToggleDetail(@"Remove Horizontal Shelves",
                               @"Removes horizontal shelves like Watch again from the feed.",
                               @"YTKACE.Preference.Feed.HorizontalShelvesHidden"),
            WolFoxToggleDetail(@"Remove Community Posts",
                               @"Removes community posts from the feed.",
                               @"YTKACE.Preference.Feed.CommunityPostsHidden"),
            WolFoxToggleDetail(@"Remove AI Summaries",
                               @"Hide the AI summary under videos in Home, search and suggestions.",
                               @"YTKACE.Preference.Feed.AISummariesHidden"),
            WolFoxToggleDetail(@"Remove Live Videos from Home",
                               @"Removes live streams from the Home feed. Subscriptions, search and channels keep them.",
                               @"YTKACE.Preference.Feed.HomeLiveHidden"),
            WolFoxToggleDetail(@"Remove Mixes",
                               @"Removes YouTube Mix playlists from the feed.",
                               @"YTKACE.Preference.Feed.MixesHidden"),
            WolFoxToggleDetail(@"Remove Playables",
                               @"Removes playable games from the feed.",
                               @"YTKACE.Preference.Feed.PlayablesHidden")
        ],
        @[
            WolFoxToggle(@"Remove Play on Different Device", @"YTKACE.Preference.Menu.CastHidden", @"", @""),
            WolFoxToggle(@"Remove Play Next in Queue", @"YTKACE.Preference.Menu.PlayNextHidden", @"", @""),
            WolFoxToggle(@"Remove Play Last in Queue", @"YTKACE.Preference.Menu.PlayLastHidden", @"", @""),
            WolFoxToggle(@"Remove Save to Watch Later", @"YTKACE.Preference.Menu.WatchLaterHidden", @"", @""),
            WolFoxToggle(@"Remove Save to Playlist", @"YTKACE.Preference.Menu.SaveHidden", @"", @""),
            WolFoxToggleDetail(@"Remove Download", @"Also removes WolFox's download from this menu.",
                               @"YTKACE.Preference.Menu.DownloadHidden"),
            WolFoxToggle(@"Remove Share", @"YTKACE.Preference.Menu.ShareHidden", @"", @""),
            WolFoxToggle(@"Remove Not Interested", @"YTKACE.Preference.Menu.NotInterestedHidden", @"", @""),
            WolFoxToggle(@"Remove Don't Recommend Channel", @"YTKACE.Preference.Menu.DontRecommendHidden", @"", @""),
            WolFoxToggle(@"Remove Report", @"YTKACE.Preference.Menu.ReportHidden", @"", @""),
            WolFoxToggle(@"Remove Listen with YouTube Music", @"YTKACE.Preference.Menu.YouTubeMusicHidden", @"", @"")
        ],
        @[
            WolFoxToggleDetail(@"Hide AI Channels",
                               @"Hides videos from channels on the AiSList blocklist.",
                               @"YTKACE.Preference.Feed.AIChannelsHidden"),
            WolFoxToggleDetail(@"Hide Suspected AI Channels",
                               @"Also hides channels on the AiSList warnlist.",
                               @"YTKACE.Preference.Feed.SuspectedAIChannelsHidden"),
            WolFoxToggleDetail(@"Report AI Channels",
                               @"Adds Report AI Channel to the ⋯ menu of videos.",
                               @"YTKACE.Preference.Feed.AIChannelReporting"),
            WolFoxWithFooter(WolFoxInput(@"Report Name", @"Sent with your reports to AiSList.",
                                         @"YTKACE.Preference.Feed.AIReportName", @"WolFox"),
                             @"List from aisloplist.com, updates automatically.")
        ]
    ], @[WolFoxLocalized(@"HOME"), WolFoxLocalized(@"FEED"), WolFoxLocalized(@"VIDEO MENU"),
          WolFoxLocalized(@"AI CHANNELS")]);
}

static NSDictionary *WolFoxShortsOptionsDefinition(void) {
    return WolFoxPageDefinition(@"shorts", @"Shorts", @[
        @[
            WolFoxToggleDetail(@"Shorts Progress Bar", @"Show a thin progress line at the bottom of Shorts.", @"shortsProgress"),
            WolFoxToggle(@"Auto-Scroll to Next Short", @"autoSkipShorts", @"", @""),
            WolFoxPicker(@"Auto-Scroll Delay", @"YTKACE.Preference.Shorts.AutoScrollDelay",
                         @[@"Off", @"0.5s", @"1s", @"2s", @"3s"],
                         @[@0, @0.5, @1, @2, @3], 0, @"", @""),
            WolFoxToggleDetail(@"Wait While Reading Comments",
                               @"Don't auto-scroll while comments are open.",
                               @"YTKACE.Preference.Shorts.AutoScrollWaitForComments"),
            WolFoxToggleDetail(@"Shorts Dislike Count",
                               @"Show dislikes from returnyoutubedislike.com under Like.",
                               @"YTKACE.Preference.Shorts.DislikeCount"),
            WolFoxToggleDetail(@"Play Shorts Once",
                               @"Pause at the end instead of replaying.",
                               @"YTKACE.Preference.Shorts.LoopDisabled"),
            WolFoxPicker(@"Shorts Speed", @"YTKACE.Preference.Shorts.PlaybackRate",
                         @[@"Same as videos", @"0.5x", @"0.75x", @"1x", @"1.25x",
                           @"1.5x", @"1.75x", @"2x"],
                         @[@0, @0.5, @0.75, @1, @1.25, @1.5, @1.75, @2], 0, @"", @""),
            WolFoxToggleDetail(@"Pinch to Fullscreen",
                               @"Pinch out in Shorts to hide the overlay and tab bar.",
                               @"YTKACE.Preference.Shorts.PinchFullscreen"),
            WolFoxToggle(@"Disable PiP for Shorts", @"YTKACE.Preference.Shorts.PiPDisabled", @"", @""),
            WolFoxPickerDetail(@"Download Button Position", @"Needs Download Button turned on in Downloads.",
                         @"YTKACE.Preference.Shorts.DownloadPosition",
                         @[@"Top Corner", @"Action Buttons"], @[@0, @1], 0)
        ],
        @[
            WolFoxToggleDetail(@"Limit Shorts",
                @"Stop scrolling after a set number of Shorts. Resets when YouTube restarts.",
                @"YTKACE.Preference.Shorts.LimitEnabled"),
            WolFoxCountStepper(@"Shorts limit", @"YTKACE.Preference.Shorts.LimitCount",
                               5.0, 200.0, 5.0, 20.0)
        ],
        @[
            WolFoxToggleDetail(@"Remove Live Shorts",
                               @"Hide live broadcasts from the Shorts feed.",
                               @"YTKACE.Preference.Shorts.LiveHidden"),
            WolFoxToggleDetail(@"Remove Posts from Shorts",
                               @"Hide community posts shown in the Shorts feed.",
                               @"YTKACE.Preference.Shorts.PostsHidden"),
            WolFoxToggleDetail(@"Remove Pause Suggestions", @"Hide the videos shown when you pause a Short.",
                               @"YTKACE.Preference.Shorts.PauseCardHidden"),
            WolFoxToggle(@"Remove Sticker Ads", @"YTKACE.Preference.Shorts.StickerAdsHidden", @"", @""),
            WolFoxToggleDetail(@"Remove Suggestion Pill",
                               @"Hide the suggestion pill above a Short's title.",
                               @"YTKACE.Preference.Shorts.SuggestionPillHidden"),
            WolFoxToggle(@"Remove Like", @"YTKACE.Preference.Shorts.LikeHidden", @"", @""),
            WolFoxToggle(@"Remove Comments", @"YTKACE.Preference.Shorts.CommentsHidden", @"", @""),
            WolFoxToggle(@"Remove Share", @"YTKACE.Preference.Shorts.ShareHidden", @"", @""),
            WolFoxToggle(@"Remove Save", @"YTKACE.Preference.Shorts.SaveHidden", @"", @""),
            WolFoxToggle(@"Remove Remix", @"YTKACE.Preference.Shorts.RemixHidden", @"", @""),
            WolFoxToggle(@"Remove Sound Button", @"YTKACE.Preference.Shorts.SoundHidden", @"", @"")
        ]
    ], @[WolFoxLocalized(@"PLAYBACK"), WolFoxLocalized(@"SCREEN TIME"), WolFoxLocalized(@"HIDE FROM SHORTS")]);
}

static NSDictionary *WolFoxTopBarDefinition(void) {
    return WolFoxPageDefinition(@"topbar", @"Top Bar", @[
        @[
            WolFoxToggle(@"Premium Logo", @"YTKACE.Preference.Navigation.PremiumLogo", @"", @""),
            WolFoxToggle(@"Remove YouTube Logo", @"YTKACE.Preference.Navigation.LogoHidden", @"", @"")
        ],
        @[
            WolFoxToggle(@"Remove Notifications Button", @"YTKACE.Preference.Navigation.NotificationsHidden", @"", @""),
            WolFoxToggle(@"Remove Messages Button", @"YTKACE.Preference.Navigation.MessagesHidden", @"", @""),
            WolFoxToggle(@"Remove Search Button", @"YTKACE.Preference.Navigation.SearchHidden", @"", @""),
            WolFoxToggle(@"Remove Account Button", @"YTKACE.Preference.Navigation.AccountHidden", @"", @""),
            WolFoxToggle(@"Remove Cast Button", @"YTKACE.Preference.Navigation.CastHidden", @"", @""),
            WolFoxToggleDetail(@"Confirm Before Casting", @"Ask before opening the Cast menu.",
                               @"YTKACE.Preference.Navigation.CastConfirmation")
        ],
        @[
            WolFoxToggle(@"Hide Status Bar", @"YTKACE.Preference.Navigation.StatusBarHidden", @"", @"")
        ]
    ], @[WolFoxLocalized(@"LOGO"), WolFoxLocalized(@"BUTTONS"), WolFoxLocalized(@"STATUS BAR")]);
}

static NSDictionary *WolFoxGlassOptionsDefinition(void) {
    return WolFoxPageDefinition(@"glass", @"Liquid Glass", @[
        @[
            WolFoxPickerDetail(@"Tab Bar", @"Default leaves YouTube's own tab bar as is.",
                               @"YTKACE.Preference.Tabs.GlassMode",
                               @[@"Default", @"WolFox", @"YouTube", @"Off"], @[@0, @1, @2, @3],
                               WolFoxTabBarOwnGlass() ? 1 : 0),
            WolFoxToggle(@"Top Bar Buttons", @"YTKACE.Preference.Glass.TopBar", @"", @""),
            WolFoxToggle(@"Menus and Sheets", @"YTKACE.Preference.Glass.Menus", @"", @""),
            WolFoxToggle(@"WolFox Toasts and Popups", @"YTKACE.Preference.Glass.Notices", @"", @""),
            WolFoxToggle(@"Player Buttons", @"YTKACE.Preference.Glass.Player", @"", @"")
        ],
        @[
            WolFoxToggleDetail(@"Shrink Tab Bar When Scrolling", @"Needs the Liquid Glass tab bar.",
                               @"YTKACE.Preference.Tabs.GlassMinimize"),
            WolFoxPicker(@"Selected Tab Color", @"YTKACE.Preference.Tabs.SelectedTint",
                         @[@"Off", @"Text Only", @"Text and Icon"],
                         @[@0, @1, @2], 0, @"", @""),
            WolFoxColor(@"Color", @"YTKACE.Preference.Tabs.SelectedTintColor", @"#0A84FF")
        ]
    ], @[WolFoxLocalized(@"GLASS"), WolFoxLocalized(@"EXTRAS")]);
}

static NSDictionary *WolFoxGeneralDefinition(void) {
    NSMutableArray *languageTitles = [NSMutableArray array];
    for (NSString *code in WolFoxAvailableLanguages()) {
        [languageTitles addObject:[code isEqualToString:@"system"]
            ? @"System" : WolFoxLanguageDisplayName(code)];
    }
    return WolFoxPageDefinition(@"general", @"General", @[
        @[
            WolFoxPickerDetail(@"Language",
                @"Language for WolFox menus. System follows your iPhone.",
                WolFoxLanguageKey, languageTitles, WolFoxAvailableLanguages(), 0)
        ],
        @[
            WolFoxToggleDetail(@"OLED Black", @"Pure black background in dark mode.", WolFoxOLEDKey),
            WolFoxPercentSlider(@"Extra Dim",
                                @"YTKACE.Preference.Appearance.ExtraDim",
                                0.0, 80.0, 5.0, 0.0),
            WolFoxToggleDetail(@"Skip Launch Animation", @"Starts YouTube faster.",
                               @"YTKACE.Preference.Appearance.LaunchAnimationDisabled"),
            WolFoxPickerDetail(@"Device Layout",
                @"Force the iPhone or iPad layout instead of following the device.",
                @"YTKACE.Preference.App.LayoutIdiom",
                @[@"Default", @"iPhone", @"iPad"],
                @[@0, @1, @2], 0),
            WolFoxToggleDetail(@"Force Left-to-Right Layout", @"Keep a left-to-right layout in right-to-left languages.",
                               @"YTKACE.Preference.App.RTLDisabled"),
            WolFoxToggleDetail(@"Block Drag and Drop", @"Stop thumbnails and text from being dragged.",
                               @"YTKACE.Preference.App.DragDropDisabled"),
            WolFoxToggleDetail(@"Turn Off Haptics", @"Stops vibration feedback in YouTube, including WolFox's own.",
                               @"YTKACE.Preference.App.HapticsDisabled")
        ],
        @[
            WolFoxToggleDetail(@"Use iOS Share Sheet", @"Use the iOS share sheet instead of YouTube's.",
                               @"YTKACE.Preference.Sharing.NativeSheet"),
            WolFoxToggleDetail(@"Share at Current Time",
                               @"Links shared from the iOS share sheet start where you are in the video.",
                               @"YTKACE.Preference.Sharing.Timestamp"),
            WolFoxToggleDetail(@"Clean Copied Links",
                               @"Removes tracking like si= from links you copy or share.",
                               @"YTKACE.Preference.Sharing.CleanLinks"),
            WolFoxToggleDetail(@"Open Links Directly",
                               @"Skips YouTube's redirect page when you open a link from a description or comment.",
                               @"YTKACE.Preference.Sharing.DirectLinks"),
            WolFoxToggle(@"Hold Avatar to Enlarge", @"YTKACE.Preference.Profiles.Preview", @"", @""),
            WolFoxToggleDetail(@"Save Post Images",
                @"Adds a save button when you open an image from a community post.",
                @"YTKACE.Preference.Posts.SaveImage"),
            WolFoxToggleDetail(@"Hold to Copy Text", @"Hold a post or comment to copy its text.",
                               @"YTKACE.Preference.Posts.CopyText"),
            WolFoxToggleDetail(@"Mini Player for Kids Videos",
                @"Allow the mini player on made-for-kids videos.",
                @"YTKACE.Preference.Playback.KidsMiniPlayer")
        ],
        @[
            WolFoxToggleDetail(@"Remove Search History", @"Hides past searches. Searches are still saved.",
                               @"YTKACE.Preference.Privacy.SearchHistoryDisabled"),
            WolFoxToggleDetail(@"Block Premium Prompts", @"Also hides \"Are you still watching?\" and upgrade dialogs.",
                               @"YTKACE.Preference.Ads.PremiumPromosHidden"),
            WolFoxToggleDetail(@"Hide YouTube Pop-up Messages",
                @"Hides the small messages YouTube shows at the bottom, like Saved to Watch later.",
                @"YTKACE.Preference.App.HUDAlertsHidden"),
            WolFoxToggleDetail(@"Skip Age Gate", @"Skip the age check screen. Some videos may still be blocked.",
                               @"YTKACE.Preference.Content.AgeGateBypass")
        ]
    ], @[WolFoxLocalized(@"LANGUAGE"), WolFoxLocalized(@"APPEARANCE"), WolFoxLocalized(@"SHARING & EXTRAS"),
         WolFoxLocalized(@"PRIVACY & PROMPTS")]);
}

static NSDictionary *WolFoxBackupDefinition(void) {
    WolFoxAction backup = ^(UIViewController *controller) {
        [(WolFoxOptionsController *)controller beginBackup];
    };
    WolFoxAction restore = ^(UIViewController *controller) {
        [(WolFoxOptionsController *)controller beginRestore];
    };
    WolFoxInfoProvider last = ^NSString *{
        NSDate *date = [NSUserDefaults.standardUserDefaults objectForKey:WolFoxLastBackupDateKey];
        if (![date isKindOfClass:NSDate.class]) return WolFoxLocalized(@"Never");
        NSString *when = [NSDateFormatter localizedStringFromDate:date
                                                        dateStyle:NSDateFormatterMediumStyle
                                                        timeStyle:NSDateFormatterShortStyle];
        long long size = [[NSUserDefaults.standardUserDefaults objectForKey:WolFoxLastBackupSizeKey] longLongValue];
        if (size <= 0) return when;
        return [NSString stringWithFormat:@"%@ · %@", when,
            [NSByteCountFormatter stringFromByteCount:size countStyle:NSByteCountFormatterCountStyleFile]];
    };
    WolFoxInfoProvider settings = ^NSString *{
        // Only values that differ from YTKACE's defaults.
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSDictionary *values = defaults.dictionaryRepresentation;
        NSDictionary *registered = [defaults volatileDomainForName:NSRegistrationDomain];
        NSUInteger count = 0;
        for (NSString *key in values) {
            if (![key hasPrefix:@"YTKACE.Preference."]) continue;
            if (![values[key] isEqual:registered[key]]) count++;
        }
        return [NSString stringWithFormat:WolFoxLocalized(@"%lu changed"), (unsigned long)count];
    };
    WolFoxInfoProvider downloads = ^NSString *{
        NSURL *folder = [WolFoxApplicationSupportDirectory() URLByAppendingPathComponent:@"Downloads"
                                                                             isDirectory:YES];
        NSDirectoryEnumerator<NSURL *> *items = [NSFileManager.defaultManager enumeratorAtURL:folder
            includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                               options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        unsigned long long bytes = 0;
        NSUInteger files = 0;
        for (NSURL *URL in items) {
            NSNumber *regular = nil, *size = nil;
            [URL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            if (!regular.boolValue) continue;
            [URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            bytes += size.unsignedLongLongValue;
            files++;
        }
        NSString *total = [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                                         countStyle:NSByteCountFormatterCountStyleFile];
        if (files == 1) return [NSString stringWithFormat:WolFoxLocalized(@"1 file · %@"), total];
        return [NSString stringWithFormat:WolFoxLocalized(@"%lu files · %@"), (unsigned long)files, total];
    };
    return WolFoxPageDefinition(@"backup", @"Backup", @[
        @[
            WolFoxActionDetail(@"Back Up", @"Save settings and media to a ZIP file.", backup),
            WolFoxActionDetail(@"Restore", @"Open a WolFox backup from Files.", restore)
        ],
        @[
            WolFoxInfo(@"Last Backup", last),
            WolFoxInfo(@"Settings", settings),
            WolFoxInfo(@"Downloads", downloads)
        ]
    ], @[WolFoxLocalized(@"BACKUP"), WolFoxLocalized(@"INCLUDED")]);
}

static NSDictionary *WolFoxDownloadsDefinition(void) {
    WolFoxAction importMedia = ^(UIViewController *controller) {
        [(WolFoxOptionsController *)controller chooseImportCategory];
    };
    WolFoxAction clearCache = ^(UIViewController *controller) {
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *cache = [WolFoxApplicationSupportDirectory()
            URLByAppendingPathComponent:@"Cache"
                            isDirectory:YES];
        NSUInteger freed = 0;
        NSDirectoryEnumerator *walker = [manager enumeratorAtURL:cache
            includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey]
                               options:0 errorHandler:nil];
        for (NSURL *child in walker) {
            NSNumber *size = nil;
            [child getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey
                              error:nil];
            freed += size.unsignedIntegerValue;
        }
        [manager removeItemAtURL:cache error:nil];
        freed += WolFoxPurgeDownloadScratch(YES);
        freed += WolFoxPurgeSystemCaches();
        NSString *summary = freed == 0
            ? WolFoxLocalized(@"Nothing to clear.")
            : [NSString stringWithFormat:WolFoxLocalized(@"Freed %@."),
               [NSByteCountFormatter stringFromByteCount:(long long)freed
                   countStyle:NSByteCountFormatterCountStyleFile]];
        [(WolFoxOptionsController *)controller
            showResult:WolFoxLocalized(@"Cache Cleared") message:summary];
    };
    return WolFoxPageDefinition(@"downloads", @"Downloads", @[
        @[
            WolFoxPickerDetail(@"Download Button",
                         @"Off turns off all downloads, including Shorts and playlists.",
                         @"YTKACE.Preference.Downloads.Placement",
                         @[@"Off", @"Player overlay", @"YouTube's button", @"Both"],
                         @[@0, @1, @2, @3], 0),
            WolFoxToggle(@"Playlist Download Button",
                         @"YTKACE.Preference.Downloads.PlaylistEnabled", @"", @""),
            WolFoxPicker(@"Save Videos To",
                         @"YTKACE.Preference.Downloads.SaveLocation",
                         @[@"WolFox Library", @"Photos", @"Ask", @"Share Sheet"],
                         @[@0, @1, @2, @3], 0, @"", @""),
            WolFoxPicker(@"Save Audio To",
                         @"YTKACE.Preference.Downloads.AudioSaveLocation",
                         @[@"WolFox Library", @"Photos", @"Ask", @"Share Sheet"],
                         @[@0, @1, @2, @3], 0, @"", @""),
            WolFoxPickerDetail(@"Video Quality",
                @"Skip the quality list and use the best at or below this.",
                @"YTKACE.Preference.Downloads.DefaultQuality",
                @[@"Ask", @"Best", @"2160p", @"1440p", @"1080p", @"720p", @"480p", @"360p"],
                @[@0, @(-1), @2160, @1440, @1080, @720, @480, @360], 0),
            WolFoxPickerDetail(@"Audio Language",
                @"Skip the language list and use the video's default audio.",
                @"YTKACE.Preference.Downloads.DefaultAudio",
                @[@"Ask", @"Default Track"], @[@0, @1], 0),
            WolFoxToggleDetail(@"Include Subtitles",
                               @"Embed captions into downloaded videos.",
                               @"YTKACE.Preference.Downloads.Subtitles"),
            WolFoxPickerDetail(@"Download Method",
                @"SABR is the default. Use TV Client or Direct if downloads fail.",
                @"YTKACE.Preference.Downloads.Method",
                @[@"SABR", @"TV Client", @"Direct"], @[@0, @2, @1], 0),
            WolFoxActionDetail(@"Import", @"Add video, audio, Shorts, artwork, or subtitles.", importMedia)
        ],
        @[
            WolFoxToggleDetail(@"Clear Cache at Launch", @"Clear cache when YouTube opens, at most once a day.",
                               @"YTKACE.Preference.Downloads.ClearOnStartup"),
            WolFoxActionDetail(@"Clear Cache Now", @"Delete temporary files and YouTube's cache.", clearCache)
        ]
    ], @[WolFoxLocalized(@"DOWNLOADS"), WolFoxLocalized(@"STORAGE")]);
}

static NSDictionary *WolFoxGestureOptionsDefinition(void) {
    NSArray *actionTitles = @[@"None", @"Brightness", @"Volume", @"Brightness + Volume"];
    NSArray *actionValues = @[@0, @1, @2, @3];
    return WolFoxPageDefinition(@"gestures", @"Gestures", @[
        @[
            WolFoxPicker(@"Left Side", @"YTKACE.Preference.Gestures.LeftAction",
                         actionTitles, actionValues, 0, @"", @""),
            WolFoxPicker(@"Right Side", @"YTKACE.Preference.Gestures.RightAction",
                         actionTitles, actionValues, 0, @"", @""),
            WolFoxPercentSlider(@"Edge Width",
                                @"YTKACE.Preference.Gestures.ActivationArea",
                                10.0, 50.0, 5.0, 20.0),
            WolFoxToggleDetail(@"Landscape Only",
                               @"Disable gestures while the player is in portrait.",
                               @"YTKACE.Preference.Gestures.LandscapeOnly")
        ],
        @[
            WolFoxToggleDetail(@"Level Indicator",
                               @"Show the current brightness or volume level.",
                               @"YTKACE.Preference.Gestures.HUDEnabled"),
            WolFoxPicker(@"Indicator Size", @"YTKACE.Preference.Gestures.HUDSize",
                         @[@"Compact", @"Standard", @"Large"], @[@0, @1, @2],
                         1, @"", @""),
            WolFoxPicker(@"Indicator Position", @"YTKACE.Preference.Gestures.HUDPosition",
                         @[@"Top", @"Center", @"Bottom"], @[@0, @1, @2],
                         0, @"", @"")
        ],
        @[
            WolFoxToggleDetail(@"Turn Off Double Tap", @"Double tapping the video does nothing.",
                               @"YTKACE.Preference.Overlay.DoubleTapDisabled"),
            WolFoxToggle(@"Custom Double-Tap Skip", @"YTKACE.Preference.Playback.CustomDoubleTap", @"", @""),
            WolFoxStepper(@"Seconds", @"YTKACE.Preference.Playback.DoubleTapSeconds", 5.0, 60.0, 5.0, 10.0)
        ],
        @[
            WolFoxToggleDetail(@"Hold to Seek", @"Hold the left or right side to rewind or fast-forward.",
                               @"YTKACE.Preference.Gestures.HoldToSeek"),
            WolFoxSlider(@"Seek Step", @"YTKACE.Preference.Gestures.HoldSeekSeconds", 1.0, 60.0, 1.0, 10.0),
            WolFoxToggleDetail(@"Tap to Seek", @"Tap the progress bar to jump to that point.",
                               @"YTKACE.Preference.Playback.TapToSeek"),
            WolFoxToggleDetail(@"Swipe to Seek", @"Swipe left or right on the video to rewind or fast-forward.",
                               @"YTKACE.Preference.Gestures.SwipeToSeek"),
            WolFoxPickerDetail(@"Swipe Range", @"How far a swipe across the video seeks.",
                @"YTKACE.Preference.Gestures.SwipeSeekRange",
                @[@"30 Seconds", @"1 Minute", @"90 Seconds", @"3 Minutes", @"5 Minutes", @"Whole Video"],
                @[@30, @60, @90, @180, @300, @0], 2),
            WolFoxToggleDetail(@"Two-Finger Tap to Pause",
                               @"Tap the video with two fingers to pause or play.",
                               @"YTKACE.Preference.Gestures.TwoFingerTap")
        ]
    ], @[WolFoxLocalized(@"SWIPE ON EDGES"), WolFoxLocalized(@"LEVEL INDICATOR"),
         WolFoxLocalized(@"DOUBLE TAP"), WolFoxLocalized(@"SEEK")]);
}

UIViewController *WolFoxMakeTabBarOptionsController(void) {
    return [WolFoxTabEditorController new];
}

NSArray<NSDictionary *> *WolFoxSettingsMenu(void) {
    NSMutableArray *look = [NSMutableArray arrayWithArray:@[
        @{@"id": @"watch", @"title": @"Watch Page", @"detail": @"Comments, suggestions, and the button row", @"symbol": @"rectangle.on.rectangle"},
        @{@"id": @"feed", @"title": @"Home & Feed", @"detail": @"Home redesign, shelves, mixes, and posts", @"symbol": @"house"},
        @{@"id": @"shorts", @"title": @"Shorts", @"detail": @"Playback, limit, and buttons", @"symbol": @"shorts"},
        @{@"id": @"tabs", @"title": @"Tabs", @"detail": @"Choose, reorder, and rename tabs", @"symbol": @"rectangle.bottomthird.inset.filled"},
        @{@"id": @"topbar", @"title": @"Top Bar", @"detail": @"Logo, buttons, and status bar", @"symbol": @"rectangle.topthird.inset.filled"}
    ]];
    if (WolFoxLiquidGlassAvailable()) {
        [look addObject:@{@"id": @"glass", @"title": @"Liquid Glass", @"detail": @"Tab bar, menus, toasts, and player", @"symbol": @"drop"}];
    }
    return @[
        @{@"header": @"PLAYBACK", @"rows": @[
            @{@"id": @"player", @"title": @"Player", @"detail": @"Buttons, speed, background audio, and controls", @"symbol": @"play.rectangle"},
            @{@"id": @"quality", @"title": @"Video Quality", @"detail": @"Default quality on Wi-Fi and mobile data", @"symbol": @"sparkles.tv"},
            @{@"id": @"captions", @"title": @"Captions", @"detail": @"Captions on or off, language, and transcript", @"symbol": @"captions.bubble"},
            @{@"id": @"gestures", @"title": @"Gestures", @"detail": @"Brightness, volume, double tap, and seeking", @"symbol": @"hand.draw"},
            @{@"id": @"sponsorblock", @"title": @"SponsorBlock", @"detail": @"Skip or mark sponsored segments", @"symbol": @"sponsor"}
        ]},
        @{@"header": @"LOOK & LAYOUT", @"rows": look},
        @{@"header": @"APP", @"rows": @[
            @{@"id": @"downloads", @"title": @"Downloads", @"detail": @"Download button, where to save, and storage", @"symbol": @"arrow.down.circle"},
            @{@"id": @"backup", @"title": @"Backup", @"detail": @"Back up and restore settings and downloads", @"symbol": @"arrow.clockwise.icloud"},
            @{@"id": @"general", @"title": @"General", @"detail": @"Language, appearance, privacy, and prompts", @"symbol": @"gearshape"}
        ]}
    ];
}

static NSDictionary *WolFoxDefinitionForPage(NSString *pageID) {
    if ([pageID isEqualToString:@"sponsorblock"]) return WolFoxSponsorBlockDefinition();
    if ([pageID isEqualToString:@"player"]) return WolFoxPlayerDefinition();
    if ([pageID isEqualToString:@"quality"]) return WolFoxQualityDefinition();
    if ([pageID isEqualToString:@"captions"]) return WolFoxCaptionsDefinition();
    if ([pageID isEqualToString:@"gestures"]) return WolFoxGestureOptionsDefinition();
    if ([pageID isEqualToString:@"watch"]) return WolFoxWatchPageDefinition();
    if ([pageID isEqualToString:@"feed"]) return WolFoxFeedDefinition();
    if ([pageID isEqualToString:@"shorts"]) return WolFoxShortsOptionsDefinition();
    if ([pageID isEqualToString:@"topbar"]) return WolFoxTopBarDefinition();
    if ([pageID isEqualToString:@"glass"]) return WolFoxGlassOptionsDefinition();
    if ([pageID isEqualToString:@"general"]) return WolFoxGeneralDefinition();
    if ([pageID isEqualToString:@"downloads"]) return WolFoxDownloadsDefinition();
    if ([pageID isEqualToString:@"backup"]) return WolFoxBackupDefinition();
    return nil;
}

UIViewController *WolFoxMakeSettingsPage(NSString *pageID) {
    if ([pageID isEqualToString:@"tabs"]) return WolFoxMakeTabBarOptionsController();
    NSDictionary *definition = WolFoxDefinitionForPage(pageID);
    return definition != nil ? WolFoxPageFromDefinition(definition) : nil;
}

UIViewController *WolFoxMakeSponsorBlockController(void) { return WolFoxMakeSettingsPage(@"sponsorblock"); }
UIViewController *WolFoxMakePlayerControlsController(void) { return WolFoxMakeSettingsPage(@"player"); }
UIViewController *WolFoxMakeOverlayOptionsController(void) { return WolFoxMakeSettingsPage(@"watch"); }
UIViewController *WolFoxMakeStreamingOptionsController(void) { return WolFoxMakeSettingsPage(@"quality"); }
UIViewController *WolFoxMakeNavigationOptionsController(void) { return WolFoxMakeSettingsPage(@"topbar"); }
UIViewController *WolFoxMakeGlassOptionsController(void) { return WolFoxMakeSettingsPage(@"glass"); }
UIViewController *WolFoxMakeShortsOptionsController(void) { return WolFoxMakeSettingsPage(@"shorts"); }
UIViewController *WolFoxMakeMiscOptionsController(void) { return WolFoxMakeSettingsPage(@"general"); }
UIViewController *WolFoxMakeGestureOptionsController(void) { return WolFoxMakeSettingsPage(@"gestures"); }

NSArray<NSDictionary *> *WolFoxAllPageDefinitions(void) {
    NSMutableArray *pages = [NSMutableArray array];
    for (NSDictionary *section in WolFoxSettingsMenu()) {
        for (NSDictionary *row in section[@"rows"]) {
            NSDictionary *definition = WolFoxDefinitionForPage(row[@"id"]);
            if (definition != nil) [pages addObject:definition];
        }
    }
    [pages addObject:WolFoxPageDefinition(@"tabs", @"Tabs", @[
        @[
            WolFoxWithFooter(WolFoxToggle(@"iPhone Duo System Tab Bar", @"YTKACE.Preference.Tabs.DuoNativeBar", @"", @""),
                             @"Shows the tabs in the iPhone Duo's own tab bar: the vertical bar, which expands with labels when held, or the floating bar at the bottom when unfolded upright."),
            WolFoxToggle(@"Hide Tab Labels", @"YTKACE.Preference.Tabs.LabelsHidden", @"", @""),
            WolFoxToggle(@"Don't Open App in Shorts", @"YTKACE.Preference.Shorts.PreventAutoOpen", @"", @""),
            WolFoxPicker(@"Frosted Tab Bar", @"YTKACE.Preference.Tabs.Frosted",
                         @[@"Default", @"On", @"Off"], @[@0, @1, @2], 0, @"", @""),
            WolFoxPicker(@"Selected Tab Color", @"YTKACE.Preference.Tabs.SelectedTint",
                         @[@"Off", @"Text Only", @"Text and Icon"],
                         @[@0, @1, @2], 0, @"", @""),
            WolFoxColor(@"Color", @"YTKACE.Preference.Tabs.SelectedTintColor", @"#0A84FF")
        ]
    ], @[WolFoxLocalized(@"MAIN")])];
    return pages;
}

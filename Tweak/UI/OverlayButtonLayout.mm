#import "OverlayButtonLayout.h"
#import "../Runtime/Preferences.h"

NSString *const WolFoxOverlayZoneTop = @"top";
NSString *const WolFoxOverlayZoneBelow = @"below";
NSString *const WolFoxOverlayZoneBottom = @"bottom";
NSString *const WolFoxOverlayZoneFullscreen = @"fullscreen";
NSString *const WolFoxOverlayZoneLeft = @"left";

static NSString *const WolFoxOverlayLayoutKey = @"YTKACE.Preference.Player.ButtonLayout";
static NSString *const WolFoxDownloadPlacementKey = @"YTKACE.Preference.Downloads.Placement";

NSArray<NSDictionary *> *WolFoxOverlayButtonCatalog(void) {
    return @[
        @{@"id": @"loop", @"title": @"Loop", @"symbol": @"repeat", @"key": WolFoxLoopKey},
        @{@"id": @"quality", @"title": @"Quality", @"symbol": @"slider.horizontal.3", @"text": @"720p",
          @"key": @"YTKACE.Preference.Player.QualityButton"},
        @{@"id": @"speed", @"title": @"Speed", @"symbol": @"speedometer", @"key": WolFoxSpeedKey},
        @{@"id": @"sponsorblock", @"title": @"SponsorBlock", @"symbol": @"shield.lefthalf.filled",
          @"key": @"YTKACE.Preference.SponsorBlock.OverlayButton"},
        @{@"id": @"sleeptimer", @"title": @"Sleep Timer", @"symbol": @"moon.zzz", @"key": WolFoxSleepTimerKey},
        @{@"id": @"pip", @"title": @"Picture in Picture", @"symbol": @"pip", @"key": WolFoxPiPKey},
        @{@"id": @"transcript", @"title": @"Transcript", @"symbol": @"doc.plaintext",
          @"key": @"YTKACE.Preference.Playback.Transcript"},
        @{@"id": @"downloads", @"title": @"Download", @"symbol": @"arrow.down.circle"}
    ];
}

NSArray<NSString *> *WolFoxOverlayZones(void) {
    return @[WolFoxOverlayZoneTop, WolFoxOverlayZoneBelow, WolFoxOverlayZoneBottom, WolFoxOverlayZoneFullscreen,
             WolFoxOverlayZoneLeft];
}

// Saved layout with every catalog button in exactly one zone; new or
// unknown buttons go in the row under YouTube's, like before.
static NSDictionary<NSString *, NSArray<NSString *> *> *WolFoxOverlayLayout(void) {
    static NSDictionary *cachedStored;
    static NSDictionary *cachedLayout;
    id stored = WolFoxPreferenceObject(WolFoxOverlayLayoutKey);
    if (![stored isKindOfClass:NSDictionary.class]) stored = @{};
    if (cachedLayout != nil && [cachedStored isEqualToDictionary:stored]) return cachedLayout;

    NSMutableSet<NSString *> *known = [NSMutableSet set];
    for (NSDictionary *button in WolFoxOverlayButtonCatalog()) [known addObject:button[@"id"]];
    NSMutableSet<NSString *> *placed = [NSMutableSet set];
    NSMutableDictionary *layout = [NSMutableDictionary dictionary];
    for (NSString *zone in WolFoxOverlayZones()) {
        NSMutableArray *ids = [NSMutableArray array];
        id list = stored[zone];
        for (id identifier in [list isKindOfClass:NSArray.class] ? list : @[]) {
            if (![identifier isKindOfClass:NSString.class] || ![known containsObject:identifier] ||
                [placed containsObject:identifier]) continue;
            [ids addObject:identifier];
            [placed addObject:identifier];
        }
        layout[zone] = ids;
    }
    for (NSDictionary *button in WolFoxOverlayButtonCatalog()) {
        if (![placed containsObject:button[@"id"]]) [layout[WolFoxOverlayZoneBelow] addObject:button[@"id"]];
    }
    cachedStored = [stored copy];
    cachedLayout = [layout copy];
    return cachedLayout;
}

NSString *WolFoxOverlayButtonZone(NSString *identifier) {
    NSDictionary *layout = WolFoxOverlayLayout();
    for (NSString *zone in WolFoxOverlayZones()) {
        if ([layout[zone] containsObject:identifier]) return zone;
    }
    return WolFoxOverlayZoneBelow;
}

NSArray<NSString *> *WolFoxOverlayZoneOrder(NSString *zone) {
    return WolFoxOverlayLayout()[zone] ?: @[];
}

void WolFoxSetOverlayLayout(NSDictionary<NSString *, NSArray<NSString *> *> *layout) {
    WolFoxSetPreferenceObject(WolFoxOverlayLayoutKey, layout.count != 0 ? layout : nil);
}

static NSString *WolFoxOverlayButtonKey(NSString *identifier) {
    for (NSDictionary *button in WolFoxOverlayButtonCatalog()) {
        if ([button[@"id"] isEqualToString:identifier]) return button[@"key"];
    }
    return nil;
}

// The download button's placement also covers YouTube's own download button.
BOOL WolFoxOverlayButtonEnabled(NSString *identifier) {
    if ([identifier isEqualToString:@"downloads"]) {
        const NSInteger placement = WolFoxDownloadPlacement();
        return placement == 1 || placement == 3;
    }
    NSString *key = WolFoxOverlayButtonKey(identifier);
    return key != nil && [NSUserDefaults.standardUserDefaults boolForKey:key];
}

void WolFoxSetOverlayButtonEnabled(NSString *identifier, BOOL enabled) {
    if (WolFoxOverlayButtonEnabled(identifier) == enabled) return;
    if ([identifier isEqualToString:@"downloads"]) {
        // hiding our button keeps downloads on through YouTube's button
        const NSInteger placement = WolFoxDownloadPlacement();
        WolFoxSetPreferenceObject(WolFoxDownloadPlacementKey,
                                  @(enabled ? (placement == 2 ? 3 : 1) : 2));
        return;
    }
    NSString *key = WolFoxOverlayButtonKey(identifier);
    if (key != nil) WolFoxSetPreference(key, enabled);
}

static NSString *const WolFoxNativeTopOrderKey = @"YTKACE.Preference.Player.TopOrder";

NSArray<NSString *> *WolFoxNativeTopDefaultOrder(void) {
    return @[@"autoplay", @"cast", @"captions", @"gear"];
}

NSDictionary<NSString *, NSString *> *WolFoxNativeTopIdentifiers(void) {
    return @{@"autoplay": @"id.autoplay.toggle.button", @"cast": @"id.mdx.playbackroute.button",
             @"captions": @"id.player.watch.captions.button", @"gear": @"id.player.overflow.button"};
}

NSArray<NSString *> *WolFoxNativeTopOrder(void) {
    NSMutableArray *order = [NSMutableArray array];
    id stored = WolFoxPreferenceObject(WolFoxNativeTopOrderKey);
    for (id name in [stored isKindOfClass:NSArray.class] ? stored : @[]) {
        if ([WolFoxNativeTopDefaultOrder() containsObject:name] && ![order containsObject:name]) [order addObject:name];
    }
    for (NSString *name in WolFoxNativeTopDefaultOrder()) {
        if (![order containsObject:name]) [order addObject:name];
    }
    return order;
}

NSArray<NSString *> *WolFoxTopRowOrder(void) {
    NSMutableArray *order = [NSMutableArray array];
    id stored = WolFoxPreferenceObject(WolFoxNativeTopOrderKey);
    for (id name in [stored isKindOfClass:NSArray.class] ? stored : @[]) {
        if ([name isKindOfClass:NSString.class] && ![order containsObject:name]) [order addObject:name];
    }
    return order;
}

void WolFoxSetNativeTopOrder(NSArray<NSString *> *order) {
    const BOOL standard = order == nil || [order isEqualToArray:WolFoxNativeTopDefaultOrder()];
    WolFoxSetPreferenceObject(WolFoxNativeTopOrderKey, standard ? nil : [order copy]);
}

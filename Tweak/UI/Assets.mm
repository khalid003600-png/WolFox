#import "Assets.h"

#import <dlfcn.h>

static NSString *WolFoxLoadedImagePath(void) {
    Dl_info image;
    memset(&image, 0, sizeof(image));
    if (dladdr((const void *)&WolFoxAssetsBundle, &image) == 0) return nil;
    if (image.dli_fname == NULL) return nil;
    return [NSString stringWithUTF8String:image.dli_fname];
}

static NSArray<NSString *> *WolFoxCandidateBundlePaths(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *loaded = WolFoxLoadedImagePath();
    NSArray<NSString *> *bundleNames = @[@"WolFox.bundle", @"YTKACE.bundle"];
    if (loaded.length != 0) {
        for (NSString *bundleName in bundleNames) {
            for (NSString *marker in @[@"/Library/MobileSubstrate/DynamicLibraries/", @"/usr/lib/TweakInject/"]) {
                NSRange range = [loaded rangeOfString:marker];
                if (range.location == NSNotFound) continue;
                NSString *root = [loaded substringToIndex:range.location];
                [candidates addObject:[[root stringByAppendingPathComponent:
                    @"Library/Application Support"] stringByAppendingPathComponent:bundleName]];
            }
            NSString *directory = loaded.stringByDeletingLastPathComponent;
            for (NSUInteger level = 0; level < 2 && directory.length > 1; level++) {
                [candidates addObject:[directory stringByAppendingPathComponent:bundleName]];
                directory = directory.stringByDeletingLastPathComponent;
            }
        }
    }
    for (NSString *bundleName in bundleNames) {
        NSString *resourceName = [bundleName stringByDeletingPathExtension];
        NSString *packaged = [NSBundle.mainBundle pathForResource:resourceName
                                                           ofType:@"bundle"];
        if (packaged.length != 0) [candidates addObject:packaged];
        [candidates addObject:[[ @"/var/jb/Library/Application Support"
            stringByAppendingPathComponent:bundleName] copy]];
        [candidates addObject:[[ @"/Library/Application Support"
            stringByAppendingPathComponent:bundleName] copy]];
        [candidates addObject:[[ @"/var/jb/Library/MobileSubstrate/DynamicLibraries"
            stringByAppendingPathComponent:bundleName] copy]];
    }
    return candidates;
}

NSBundle *WolFoxAssetsBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        for (NSString *path in WolFoxCandidateBundlePaths()) {
            BOOL directory = NO;
            if (![manager fileExistsAtPath:path isDirectory:&directory]) continue;
            if (!directory) continue;
            bundle = [NSBundle bundleWithPath:path];
            if (bundle != nil) break;
        }
    });
    return bundle;
}

UIImage *WolFoxAssetImage(NSString *name, NSString *fallbackSymbol) {
    UIImage *image = nil;
    NSBundle *bundle = WolFoxAssetsBundle();
    if (bundle != nil && name.length != 0) {
        image = [UIImage imageNamed:name
                           inBundle:bundle
      compatibleWithTraitCollection:nil];
    }
    if (image == nil && fallbackSymbol.length != 0) {
        if (@available(iOS 13.0, *)) {
            image = [UIImage systemImageNamed:fallbackSymbol];
        }
    }
    return image;
}

UIImage *WolFoxYouTubeImage(NSArray<NSString *> *names, NSString *fallbackSymbol) {
    for (NSString *name in names) {
        UIImage *image = [UIImage imageNamed:name];
        if (image != nil) return image;
    }
    return fallbackSymbol.length == 0 ? nil : [UIImage systemImageNamed:fallbackSymbol];
}

UIImage *WolFoxGearImage(void) {
    return WolFoxYouTubeImage(@[
        @"yt_outline_gear_24pt",
        @"yt_outline_gear_vd_theme_24",
        @"yt_outline_experimental_gear_vd_theme_24"
    ], @"gearshape");
}

UIImage *WolFoxShortsImage(BOOL selected) {
    return selected
        ? WolFoxYouTubeImage(@[
            @"yt_fill_youtube_shorts_24pt",
            @"yt_fill_youtube_shorts_vd_theme_24"
        ], @"play.rectangle.fill")
        : WolFoxYouTubeImage(@[
            @"yt_outline_youtube_shorts_24pt",
            @"yt_outline_youtube_shorts_vd_theme_24"
        ], @"play.rectangle");
}

UIImage *WolFoxDownloadTabImage(BOOL selected) {
    return [UIImage systemImageNamed:selected
        ? @"arrow.down.square.fill" : @"arrow.down.square"];
}

UIColor *WolFoxAccentColor(void) {
    return [UIColor colorWithRed:0.85 green:0.12 blue:0.20 alpha:1.0];
}

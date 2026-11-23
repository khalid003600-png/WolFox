#import "Localization.h"
#import "Preferences.h"
#import "../UI/Assets.h"

#import <UIKit/UIKit.h>

NSString * const WolFoxLanguageKey = @"YTKACE.Preference.Language";

NSArray<NSString *> *WolFoxAvailableLanguages(void) {
    return @[@"system", @"en", @"ar", @"ckb", @"de", @"es", @"fr", @"it",
             @"ja", @"ko", @"pl", @"pt-BR", @"ru", @"tr", @"vi", @"zh-Hans", @"zh-Hant"];
}

NSString *WolFoxLanguageDisplayName(NSString *code) {
    if ([code isEqualToString:@"system"]) return @"System";
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @"en": @"English",
            @"ar": @"العربية",
            @"ckb": @"کوردی",
            @"de": @"Deutsch",
            @"es": @"Español",
            @"fr": @"Français",
            @"it": @"Italiano",
            @"ja": @"日本語",
            @"ko": @"한국어",
            @"pl": @"Polski",
            @"pt-BR": @"Português (Brasil)",
            @"ru": @"Русский",
            @"tr": @"Türkçe",
            @"vi": @"Tiếng Việt",
            @"zh-Hans": @"简体中文",
            @"zh-Hant": @"繁體中文"
        };
    });
    return names[code] ?: code;
}

static NSString *WolFoxPreferredLanguage(void) {
    id stored = WolFoxPreferenceObject(WolFoxLanguageKey);
    NSString *choice = [stored isKindOfClass:NSString.class] ? stored : @"system";
    if (![choice isEqualToString:@"system"]) return choice;

    NSArray<NSString *> *available = WolFoxAvailableLanguages();
    for (NSString *preferred in NSLocale.preferredLanguages) {
        NSString *code = preferred;
        if ([code hasPrefix:@"zh-Hans"] || [code hasPrefix:@"zh-CN"] ||
            [code hasPrefix:@"zh-SG"]) {
            return @"zh-Hans";
        }
        if ([code hasPrefix:@"zh"]) return @"zh-Hant";
        if ([code hasPrefix:@"pt"]) return @"pt-BR";
        NSRange separator = [code rangeOfString:@"-"];
        if (separator.location != NSNotFound) {
            code = [code substringToIndex:separator.location];
        }
        if ([available containsObject:code]) return code;
    }
    return @"en";
}

static NSDictionary<NSString *, NSString *> *WolFoxStringsForLanguage(NSString *code) {
    NSBundle *bundle = WolFoxAssetsBundle();
    if (bundle == nil) return nil;
    NSString *path = [bundle pathForResource:@"Localizable"
                                      ofType:@"strings"
                                 inDirectory:nil
                             forLocalization:code];
    if (path == nil) {
        path = [bundle.resourcePath stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.lproj/Localizable.strings", code]];
    }
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

static NSDictionary<NSString *, NSString *> *WolFoxActiveStrings;
static NSString *WolFoxActiveLanguage;

void WolFoxResetLocalizationCache(void) {
    WolFoxActiveStrings = nil;
    WolFoxActiveLanguage = nil;
}

NSString *WolFoxLocalized(NSString *key) {
    if (key.length == 0) return key;
    NSString *language = WolFoxPreferredLanguage();
    if (![language isEqualToString:WolFoxActiveLanguage]) {
        WolFoxActiveLanguage = language;
        WolFoxActiveStrings = WolFoxStringsForLanguage(language);
    }
    NSString *value = WolFoxActiveStrings[key];
    return value.length != 0 ? value : key;
}

#import "MTThemeInfoMetadataMapper.h"

#import <CoreFoundation/CoreFoundation.h>

#import "MTCalendarIconConfiguration.h"
#import "MTCalendarIconsModule.h"
#import "MTDiagnostic.h"
#import "MTIconMaskConfiguration.h"
#import "MTIconMaskContract.h"
#import "MTSafePropertyListReader.h"
#import "MTStaticIconConfiguration.h"
#import "MTThemeInfoMetadataMapperInternal.h"
#import "MTThemeManifest.h"

NSString *const MTThemeInfoMetadataMapperErrorDomain =
    @"com.hmmzzz.marktheme.theme-info-metadata-mapper";
NSString *const MTThemeInfoMetadataProfileCoreFoundationBundleV1 =
    @"metadata.corefoundation-bundle-v1";
NSString *const MTThemeInfoMetadataProfileSnowBoardCalendarV1 =
    @"metadata.snowboard-calendar-v1";
NSString *const MTThemeInfoMetadataProfileIconBundlesMaskV1 =
    @"metadata.iconbundles-mask-v1";

@interface MTThemeDisplayMetadata ()
- (instancetype)initWithDisplayName:(NSString *)displayName
                              author:(NSString *)author
                        themeVersion:(NSString *)themeVersion
                           profileID:(NSString *)profileID
                displayNameSourceKey:(NSString *)displayNameSourceKey
               themeVersionSourceKey:(NSString *)themeVersionSourceKey
               recognizedFieldCount:(NSUInteger)recognizedFieldCount
              usedSourceNameFallback:(BOOL)usedSourceNameFallback
                         diagnostics:(NSArray<MTDiagnostic *> *)diagnostics;
@end

@interface MTThemeImportMetadata ()
- (instancetype)initWithDisplayMetadata:
                    (MTThemeDisplayMetadata *)displayMetadata
                     moduleConfigurations:
    (NSDictionary<NSString *, NSDictionary<NSString *, id> *> *)
        moduleConfigurations
      recognizedModuleConfigurationCount:
          (NSUInteger)recognizedModuleConfigurationCount
                              diagnostics:
                                  (NSArray<MTDiagnostic *> *)diagnostics;
@end

@implementation MTThemeDisplayMetadata

- (instancetype)initWithDisplayName:(NSString *)displayName
                              author:(NSString *)author
                        themeVersion:(NSString *)themeVersion
                           profileID:(NSString *)profileID
                displayNameSourceKey:(NSString *)displayNameSourceKey
               themeVersionSourceKey:(NSString *)themeVersionSourceKey
               recognizedFieldCount:(NSUInteger)recognizedFieldCount
              usedSourceNameFallback:(BOOL)usedSourceNameFallback
                         diagnostics:(NSArray<MTDiagnostic *> *)diagnostics {
    self = [super init];
    if (self == nil) return nil;
    _displayName = [displayName copy];
    _author = [author copy];
    _themeVersion = [themeVersion copy];
    _profileID = [profileID copy];
    _displayNameSourceKey = [displayNameSourceKey copy];
    _themeVersionSourceKey = [themeVersionSourceKey copy];
    _recognizedFieldCount = recognizedFieldCount;
    _usedSourceNameFallback = usedSourceNameFallback;
    _diagnostics = [diagnostics copy];
    return self;
}

@end

@implementation MTThemeImportMetadata

- (instancetype)initWithDisplayMetadata:
                    (MTThemeDisplayMetadata *)displayMetadata
                     moduleConfigurations:
    (NSDictionary<NSString *,NSDictionary<NSString *,id> *> *)
        moduleConfigurations
      recognizedModuleConfigurationCount:
          (NSUInteger)recognizedModuleConfigurationCount
                              diagnostics:
                                  (NSArray<MTDiagnostic *> *)diagnostics {
    self = [super init];
    if (self == nil) return nil;
    _displayMetadata = displayMetadata;
    _moduleConfigurations = [moduleConfigurations copy];
    _recognizedModuleConfigurationCount =
        recognizedModuleConfigurationCount;
    _diagnostics = [diagnostics copy];
    return self;
}

@end

static NSString *_Nullable MTThemeMetadataNormalizeString(
    id value,
    BOOL mayBeEmpty,
    NSUInteger maximumUTF8Bytes) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [value
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *normalized = [trimmed precomposedStringWithCanonicalMapping];
    NSData *utf8 = [normalized dataUsingEncoding:NSUTF8StringEncoding
                            allowLossyConversion:NO];
    if (utf8 == nil || (!mayBeEmpty && utf8.length == 0) ||
        utf8.length > maximumUTF8Bytes) {
        return nil;
    }
    for (NSUInteger index = 0; index < normalized.length; index++) {
        unichar character = [normalized characterAtIndex:index];
        if (character == 0 || character < 0x20 || character == 0x7f) {
            return nil;
        }
    }
    return normalized;
}

static MTDiagnostic *MTThemeMetadataInvalidFieldDiagnostic(NSString *key) {
    return [[MTDiagnostic alloc]
        initWithSeverity:MTDiagnosticSeverityWarning
                    code:@"import.metadata.invalid-known-field"
                 summary:@"A recognized display-metadata field has an invalid value."
             resourceKey:nil
                 details:@{ @"key" : key }
                   error:NULL];
}

static MTDiagnostic *MTThemeMetadataInvalidCalendarDiagnostic(void) {
    return [[MTDiagnostic alloc]
        initWithSeverity:MTDiagnosticSeverityWarning
                    code:@"import.metadata.invalid-calendar-settings"
                 summary:@"Calendar day/date settings are incomplete or invalid and were ignored."
             resourceKey:nil
                 details:@{
                     @"profile" :
                         MTThemeInfoMetadataProfileSnowBoardCalendarV1
                 }
                   error:NULL];
}

static MTDiagnostic *MTThemeMetadataInvalidIconMaskDiagnostic(void) {
    return [[MTDiagnostic alloc]
        initWithSeverity:MTDiagnosticSeverityWarning
                    code:@"import.metadata.invalid-icon-mask-setting"
                 summary:@"IB-MaskIcons must be a property-list Boolean and was ignored."
             resourceKey:nil
                 details:@{
                     @"key" : @"IB-MaskIcons",
                     @"profile" :
                         MTThemeInfoMetadataProfileIconBundlesMaskV1,
                 }
                   error:NULL];
}

static MTDiagnostic *MTThemeMetadataInvalidStaticIconMatchingDiagnostic(void) {
    return [[MTDiagnostic alloc]
        initWithSeverity:MTDiagnosticSeverityWarning
                    code:@"import.metadata.invalid-bundle-matching"
                 summary:@"A fuzzy Bundle ID or explicit icon alias was invalid and was ignored."
             resourceKey:nil
                 details:@{
                     @"keys" : @"FuzzyBundleIdentifiers, BundleAliases, MarkThemeBundleAliases",
                 }
                   error:NULL];
}

static BOOL MTThemeCalendarReadMilliValue(id rawValue,
                                          NSInteger minimum,
                                          NSInteger maximum,
                                          NSInteger *output) {
    NSString *raw = nil;
    if ([rawValue isKindOfClass:NSString.class]) {
        raw = rawValue;
    } else if ([rawValue isKindOfClass:NSNumber.class] &&
               CFGetTypeID((__bridge CFTypeRef)rawValue) !=
                   CFBooleanGetTypeID()) {
        raw = [rawValue stringValue];
    }
    NSString *text = [raw
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0) return NO;

    NSUInteger index = 0;
    BOOL negative = NO;
    unichar first = [text characterAtIndex:0];
    if (first == '-' || first == '+') {
        negative = first == '-';
        index++;
    }
    if (index >= text.length) return NO;

    NSUInteger whole = 0;
    NSUInteger wholeDigits = 0;
    while (index < text.length) {
        unichar character = [text characterAtIndex:index];
        if (character < '0' || character > '9') break;
        if (whole > 1000000) return NO;
        whole = whole * 10 + (NSUInteger)(character - '0');
        wholeDigits++;
        index++;
    }
    if (wholeDigits == 0) return NO;

    NSUInteger fraction = 0;
    NSUInteger fractionDigits = 0;
    if (index < text.length && [text characterAtIndex:index] == '.') {
        index++;
        while (index < text.length && fractionDigits < 3) {
            unichar character = [text characterAtIndex:index];
            if (character < '0' || character > '9') break;
            fraction = fraction * 10 + (NSUInteger)(character - '0');
            fractionDigits++;
            index++;
        }
        if (fractionDigits == 0) return NO;
    }
    if (index != text.length) return NO;
    while (fractionDigits < 3) {
        fraction *= 10;
        fractionDigits++;
    }
    if (whole > (NSUInteger)NSIntegerMax / 1000) return NO;
    NSInteger milli = (NSInteger)(whole * 1000 + fraction);
    if (negative) milli = -milli;
    if (milli < minimum || milli > maximum) return NO;
    *output = milli;
    return YES;
}

static NSString *_Nullable MTThemeCalendarReadColor(id rawValue) {
    if (![rawValue isKindOfClass:NSString.class]) return nil;
    NSString *value = [[rawValue
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if ((value.length != 4 && value.length != 7) ||
        ![value hasPrefix:@"#"]) return nil;
    NSString *rgb = [value substringFromIndex:1];
    for (NSUInteger index = 0; index < rgb.length; index++) {
        unichar character = [rgb characterAtIndex:index];
        if (!((character >= '0' && character <= '9') ||
              (character >= 'a' && character <= 'f'))) {
            return nil;
        }
    }
    if (rgb.length == 3) {
        return [NSString stringWithFormat:@"%C%C%C%C%C%C",
            [rgb characterAtIndex:0], [rgb characterAtIndex:0],
            [rgb characterAtIndex:1], [rgb characterAtIndex:1],
            [rgb characterAtIndex:2], [rgb characterAtIndex:2]];
    }
    return rgb;
}

static MTCalendarIconTextStyle *_Nullable MTThemeCalendarReadTextStyle(
    NSDictionary<NSString *, id> *settings) {
    if (![settings isKindOfClass:NSDictionary.class]) return nil;
    NSString *fontName = settings[@"FontName"] == nil
        ? @"HelveticaNeue"
        : MTThemeMetadataNormalizeString(settings[@"FontName"], NO, 128);
    NSString *color = MTThemeCalendarReadColor(settings[@"TextColor"]);
    NSInteger fontSize = 0;
    NSInteger yOffset = 0;
    NSInteger alpha = 1000;
    if (fontName == nil || color == nil ||
        !MTThemeCalendarReadMilliValue(settings[@"FontSize"], 1000, 200000,
                                       &fontSize) ||
        !MTThemeCalendarReadMilliValue(settings[@"TextYoffset"], -200000,
                                       200000, &yOffset) ||
        (settings[@"FontAlpha"] != nil &&
         !MTThemeCalendarReadMilliValue(settings[@"FontAlpha"], 0, 1000,
                                        &alpha))) {
        return nil;
    }
    return [[MTCalendarIconTextStyle alloc]
        initWithFontName:fontName
        fontSizeMilliPoints:(NSUInteger)fontSize
        textColorRGB:color
        alphaPermille:(NSUInteger)alpha
        yOffsetMilliPoints:yOffset
        error:NULL];
}

static MTCalendarIconConfiguration *_Nullable
MTThemeCalendarReadConfiguration(NSDictionary<NSString *, id> *dictionary,
                                 BOOL *wasPresent) {
    id daySettings = dictionary[@"CalendarIconDaySettings"];
    id dateSettings = dictionary[@"CalendarIconDateSettings"];
    *wasPresent = daySettings != nil || dateSettings != nil;
    if (!*wasPresent) return nil;
    MTCalendarIconTextStyle *day = MTThemeCalendarReadTextStyle(daySettings);
    MTCalendarIconTextStyle *date = MTThemeCalendarReadTextStyle(dateSettings);
    return day == nil || date == nil ? nil :
        [[MTCalendarIconConfiguration alloc] initWithDayStyle:day
                                                   dateStyle:date
                                                       error:NULL];
}

static MTIconMaskConfiguration *_Nullable
MTThemeReadIconMaskConfiguration(
    NSDictionary<NSString *, id> *dictionary,
    BOOL *wasPresent,
    BOOL *wasValid) {
    id rawValue = dictionary[@"IB-MaskIcons"];
    *wasPresent = rawValue != nil;
    *wasValid = !*wasPresent ||
        ([rawValue isKindOfClass:NSNumber.class] &&
         CFGetTypeID((__bridge CFTypeRef)rawValue) == CFBooleanGetTypeID());
    if (!*wasPresent || !*wasValid || ![rawValue boolValue]) return nil;
    return MTIconMaskConfiguration.enabledConfiguration;
}

static MTStaticIconConfiguration *_Nullable
MTThemeReadStaticIconConfiguration(
    NSDictionary<NSString *, id> *dictionary,
    BOOL *wasPresent,
    BOOL *wasFullyValid) {
    id rawFuzzy = dictionary[@"FuzzyBundleIdentifiers"];
    id rawPreferredAliases = dictionary[@"MarkThemeBundleAliases"];
    id rawLegacyAliases = dictionary[@"BundleAliases"];
    *wasPresent = rawFuzzy != nil || rawPreferredAliases != nil ||
        rawLegacyAliases != nil;
    *wasFullyValid = YES;
    if (!*wasPresent) return nil;

    NSMutableArray<NSString *> *fuzzy = [NSMutableArray array];
    NSMutableSet<NSString *> *fuzzyFolded = [NSMutableSet set];
    if (rawFuzzy != nil) {
        if (![rawFuzzy isKindOfClass:NSArray.class]) {
            *wasFullyValid = NO;
        } else {
            for (id candidate in rawFuzzy) {
                if (!MTStaticIconBundleIdentifierIsValid(candidate)) {
                    *wasFullyValid = NO;
                    continue;
                }
                NSString *identifier = [candidate
                    precomposedStringWithCanonicalMapping];
                NSString *folded = identifier.lowercaseString;
                if ([fuzzyFolded containsObject:folded]) continue;
                if (fuzzy.count >=
                    MTStaticIconMaximumFuzzyBundleIdentifierCount) {
                    *wasFullyValid = NO;
                    continue;
                }
                [fuzzyFolded addObject:folded];
                [fuzzy addObject:identifier];
            }
        }
    }

    NSMutableDictionary<NSString *, NSString *> *aliases =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *aliasKeyByFoldedKey =
        [NSMutableDictionary dictionary];
    for (id rawAliases in @[rawPreferredAliases ?: NSNull.null,
                            rawLegacyAliases ?: NSNull.null]) {
        if (rawAliases == NSNull.null) continue;
        if (![rawAliases isKindOfClass:NSDictionary.class]) {
            *wasFullyValid = NO;
            continue;
        }
        NSMutableArray<NSDictionary<NSString *, NSString *> *> *validPairs =
            [NSMutableArray array];
        for (id rawAlias in rawAliases) {
            id rawTarget = rawAliases[rawAlias];
            if (!MTStaticIconBundleIdentifierIsValid(rawAlias) ||
                !MTStaticIconBundleIdentifierIsValid(rawTarget)) {
                *wasFullyValid = NO;
                continue;
            }
            [validPairs addObject:@{
                @"alias" : [rawAlias
                    precomposedStringWithCanonicalMapping],
                @"target" : [rawTarget
                    precomposedStringWithCanonicalMapping],
            }];
        }
        [validPairs sortUsingComparator:^NSComparisonResult(
                NSDictionary<NSString *, NSString *> *left,
                NSDictionary<NSString *, NSString *> *right) {
            return [left[@"alias"] compare:right[@"alias"]
                                      options:NSLiteralSearch];
        }];
        for (NSDictionary<NSString *, NSString *> *pair in validPairs) {
            NSString *alias = pair[@"alias"];
            NSString *target = pair[@"target"];
            NSString *folded = alias.lowercaseString;
            NSString *existingAlias = aliasKeyByFoldedKey[folded];
            if (existingAlias != nil) {
                if ([aliases[existingAlias]
                        caseInsensitiveCompare:target] != NSOrderedSame) {
                    *wasFullyValid = NO;
                }
                continue;
            }
            if (aliases.count >= MTStaticIconMaximumBundleAliasCount) {
                *wasFullyValid = NO;
                continue;
            }
            aliasKeyByFoldedKey[folded] = alias;
            aliases[alias] = target;
        }
    }
    MTStaticIconConfiguration *configuration = [MTStaticIconConfiguration
        configurationWithFuzzyBundleIdentifiers:fuzzy
        bundleAliases:aliases];
    if (configuration == nil && (fuzzy.count > 0 || aliases.count > 0)) {
        *wasFullyValid = NO;
    }
    return configuration;
}

static NSString *_Nullable MTThemeMetadataReadKnownString(
    NSDictionary<NSString *, id> *dictionary,
    NSString *key,
    NSUInteger maximumUTF8Bytes,
    NSMutableArray<MTDiagnostic *> *diagnostics,
    NSUInteger *recognizedFieldCount) {
    id rawValue = dictionary[key];
    if (rawValue == nil) return nil;
    NSString *value = MTThemeMetadataNormalizeString(
        rawValue, NO, maximumUTF8Bytes);
    if (value == nil) {
        [diagnostics addObject:MTThemeMetadataInvalidFieldDiagnostic(key)];
        return nil;
    }
    (*recognizedFieldCount)++;
    return value;
}

static NSString *MTThemeMetadataSourceFallback(NSString *sourceName) {
    NSString *candidate = [sourceName isKindOfClass:NSString.class]
        ? sourceName.lastPathComponent : @"";
    if ([candidate.lowercaseString hasSuffix:@".theme"] &&
        candidate.length > @".theme".length) {
        candidate = [candidate substringToIndex:
            candidate.length - @".theme".length];
    }
    NSString *normalized = MTThemeMetadataNormalizeString(
        candidate, NO, MTThemeManifestMaximumDisplayNameUTF8Bytes);
    return normalized ?: @"Imported Icon Theme";
}

static MTThemeImportMetadata *MTThemeMetadataFallback(
    NSString *sourceName,
    NSArray<MTDiagnostic *> *diagnostics) {
    MTThemeDisplayMetadata *display = [[MTThemeDisplayMetadata alloc]
        initWithDisplayName:MTThemeMetadataSourceFallback(sourceName)
                      author:@""
                themeVersion:@""
                   profileID:MTThemeInfoMetadataProfileCoreFoundationBundleV1
        displayNameSourceKey:@""
       themeVersionSourceKey:@""
       recognizedFieldCount:0
      usedSourceNameFallback:YES
                 diagnostics:diagnostics];
    return [[MTThemeImportMetadata alloc]
        initWithDisplayMetadata:display
        moduleConfigurations:@{}
        recognizedModuleConfigurationCount:0
        diagnostics:diagnostics];
}

@implementation MTThemeInfoMetadataMapper

- (MTThemeImportMetadata *)
    mapDocument:(MTSafePropertyListDocument *)document
      sourceName:(NSString *)sourceName
           error:(NSError **)error {
    if (![document isKindOfClass:MTSafePropertyListDocument.class]) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:MTThemeInfoMetadataMapperErrorDomain
                           code:1
                       userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Theme metadata requires a validated property-list document."
            }];
        }
        return nil;
    }

    NSDictionary<NSString *, id> *dictionary = document.rootDictionary;
    NSMutableArray<MTDiagnostic *> *diagnostics = [NSMutableArray array];
    NSUInteger recognized = 0;
    NSString *displayName = MTThemeMetadataReadKnownString(
        dictionary, @"CFBundleDisplayName",
        MTThemeManifestMaximumDisplayNameUTF8Bytes, diagnostics, &recognized);
    NSString *displayNameSourceKey = displayName == nil
        ? @"" : @"CFBundleDisplayName";
    NSString *fallbackName = MTThemeMetadataReadKnownString(
        dictionary, @"CFBundleName",
        MTThemeManifestMaximumDisplayNameUTF8Bytes, diagnostics, &recognized);
    if (displayName == nil && fallbackName != nil) {
        displayName = fallbackName;
        displayNameSourceKey = @"CFBundleName";
    }
    NSString *packageName = MTThemeMetadataReadKnownString(
        dictionary, @"PackageName",
        MTThemeManifestMaximumDisplayNameUTF8Bytes, diagnostics, &recognized);
    if (displayName == nil && packageName != nil) {
        displayName = packageName;
        displayNameSourceKey = @"PackageName";
    }

    NSString *themeVersion = MTThemeMetadataReadKnownString(
        dictionary, @"CFBundleShortVersionString",
        MTThemeManifestMaximumVersionUTF8Bytes, diagnostics, &recognized);
    NSString *themeVersionSourceKey = themeVersion == nil
        ? @"" : @"CFBundleShortVersionString";
    NSString *fallbackVersion = MTThemeMetadataReadKnownString(
        dictionary, @"CFBundleVersion",
        MTThemeManifestMaximumVersionUTF8Bytes, diagnostics, &recognized);
    if (themeVersion == nil && fallbackVersion != nil) {
        themeVersion = fallbackVersion;
        themeVersionSourceKey = @"CFBundleVersion";
    }

    BOOL usedSourceNameFallback = displayName == nil;
    if (displayName == nil) {
        displayName = MTThemeMetadataSourceFallback(sourceName);
    }
    if (themeVersion == nil) themeVersion = @"";
    MTThemeDisplayMetadata *display = [[MTThemeDisplayMetadata alloc]
        initWithDisplayName:displayName
                      author:@""
                themeVersion:themeVersion
                   profileID:MTThemeInfoMetadataProfileCoreFoundationBundleV1
        displayNameSourceKey:displayNameSourceKey
       themeVersionSourceKey:themeVersionSourceKey
       recognizedFieldCount:recognized
      usedSourceNameFallback:usedSourceNameFallback
                 diagnostics:diagnostics];

    BOOL calendarWasPresent = NO;
    MTCalendarIconConfiguration *calendar =
        MTThemeCalendarReadConfiguration(dictionary, &calendarWasPresent);
    BOOL iconMaskWasPresent = NO;
    BOOL iconMaskWasValid = NO;
    MTIconMaskConfiguration *iconMask = MTThemeReadIconMaskConfiguration(
        dictionary, &iconMaskWasPresent, &iconMaskWasValid);
    BOOL staticIconMatchingWasPresent = NO;
    BOOL staticIconMatchingWasFullyValid = NO;
    MTStaticIconConfiguration *staticIconConfiguration =
        MTThemeReadStaticIconConfiguration(dictionary,
            &staticIconMatchingWasPresent,
            &staticIconMatchingWasFullyValid);
    NSMutableDictionary *moduleConfigurations = [NSMutableDictionary dictionary];
    if (staticIconConfiguration != nil) {
        moduleConfigurations[@"icons.static"] =
            staticIconConfiguration.canonicalDictionary;
    }
    if (staticIconMatchingWasPresent &&
        !staticIconMatchingWasFullyValid) {
        [diagnostics addObject:
            MTThemeMetadataInvalidStaticIconMatchingDiagnostic()];
    }
    if (calendar != nil) {
        moduleConfigurations[MTCalendarIconsModuleID] =
            calendar.canonicalDictionary;
    } else if (calendarWasPresent) {
        [diagnostics addObject:MTThemeMetadataInvalidCalendarDiagnostic()];
    }
    if (iconMask != nil) {
        moduleConfigurations[MTIconMaskModuleID] =
            iconMask.canonicalDictionary;
    } else if (iconMaskWasPresent && !iconMaskWasValid) {
        [diagnostics addObject:MTThemeMetadataInvalidIconMaskDiagnostic()];
    }
    return [[MTThemeImportMetadata alloc]
        initWithDisplayMetadata:display
        moduleConfigurations:moduleConfigurations
        recognizedModuleConfigurationCount:
            (calendar == nil ? 0 : 1) + (iconMask == nil ? 0 : 1) +
            (staticIconConfiguration == nil ? 0 : 1)
        diagnostics:diagnostics];
}

@end

@implementation MTThemeInfoMetadataMapper (ImportComposition)

- (MTThemeImportMetadata *)
    fallbackMetadataForSourceName:(NSString *)sourceName
                       diagnostics:(NSArray<MTDiagnostic *> *)diagnostics {
    return MTThemeMetadataFallback(sourceName, diagnostics);
}

- (MTThemeImportMetadata *)metadataByMergingPrimaryMetadata:
    (MTThemeImportMetadata *)primaryMetadata
                                      componentMetadata:
    (NSArray<MTThemeImportMetadata *> *)componentMetadata {
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *configs =
        [primaryMetadata.moduleConfigurations mutableCopy];
    NSMutableArray<MTDiagnostic *> *diagnostics =
        [primaryMetadata.diagnostics mutableCopy];
    NSMutableArray<NSString *> *fuzzy = [NSMutableArray array];
    NSMutableSet<NSString *> *fuzzyFolded = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSString *> *aliases =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *aliasKeyByFoldedKey =
        [NSMutableDictionary dictionary];
    __block BOOL fuzzyTruncated = NO;
    __block BOOL aliasesTruncated = NO;
    __block BOOL aliasConflict = NO;

    void (^collectStaticConfiguration)(NSDictionary<NSString *, id> *) =
        ^(NSDictionary<NSString *, id> *dictionary) {
        if (dictionary == nil) return;
        MTStaticIconConfiguration *configuration =
            [[MTStaticIconConfiguration alloc]
                initWithDictionary:dictionary error:NULL];
        if (configuration == nil) return;
        for (NSString *identifier in
                configuration.fuzzyBundleIdentifiers) {
            NSString *folded = identifier.lowercaseString;
            if ([fuzzyFolded containsObject:folded]) continue;
            if (fuzzy.count >=
                    MTStaticIconMaximumFuzzyBundleIdentifierCount) {
                fuzzyTruncated = YES;
                continue;
            }
            [fuzzyFolded addObject:folded];
            [fuzzy addObject:identifier];
        }
        for (NSString *alias in [configuration.bundleAliases.allKeys
                sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *target = configuration.bundleAliases[alias];
            NSString *folded = alias.lowercaseString;
            NSString *existingAlias = aliasKeyByFoldedKey[folded];
            if (existingAlias != nil) {
                if ([aliases[existingAlias]
                        caseInsensitiveCompare:target] != NSOrderedSame) {
                    aliasConflict = YES;
                }
                continue;
            }
            if (aliases.count >= MTStaticIconMaximumBundleAliasCount) {
                aliasesTruncated = YES;
                continue;
            }
            aliasKeyByFoldedKey[folded] = alias;
            aliases[alias] = target;
        }
    };
    collectStaticConfiguration(configs[@"icons.static"]);

    for (MTThemeImportMetadata *component in componentMetadata) {
        [diagnostics addObjectsFromArray:component.diagnostics];
        collectStaticConfiguration(
            component.moduleConfigurations[@"icons.static"]);
        for (NSString *moduleID in [component.moduleConfigurations.allKeys
                sortedArrayUsingSelector:@selector(compare:)]) {
            if ([moduleID isEqualToString:@"icons.static"]) continue;
            NSDictionary *candidate =
                component.moduleConfigurations[moduleID];
            NSDictionary *existing = configs[moduleID];
            if (existing == nil) {
                configs[moduleID] = candidate;
            } else if (![existing isEqual:candidate]) {
                [diagnostics addObject:[[MTDiagnostic alloc]
                    initWithSeverity:MTDiagnosticSeverityWarning
                                code:@"import.metadata.component-configuration-shadowed"
                             summary:@"A component Info.plist configuration was superseded by the primary theme or an earlier component."
                         resourceKey:nil
                             details:@{ @"moduleID" : moduleID }
                               error:NULL]];
            }
        }
    }
    if (fuzzyTruncated) {
        [diagnostics addObject:[[MTDiagnostic alloc]
            initWithSeverity:MTDiagnosticSeverityWarning
                        code:@"import.metadata.fuzzy-bundle-identifiers-truncated"
                     summary:@"Additional component fuzzy Bundle IDs exceeded the merged theme limit and were ignored."
                 resourceKey:nil
                     details:@{ @"limit" : [NSString stringWithFormat:@"%lu",
                         (unsigned long)
                             MTStaticIconMaximumFuzzyBundleIdentifierCount] }
                       error:NULL]];
    }
    if (aliasesTruncated) {
        [diagnostics addObject:[[MTDiagnostic alloc]
            initWithSeverity:MTDiagnosticSeverityWarning
                        code:@"import.metadata.bundle-aliases-truncated"
                     summary:@"Additional component Bundle aliases exceeded the merged theme limit and were ignored."
                 resourceKey:nil
                     details:@{ @"limit" : [NSString stringWithFormat:@"%lu",
                         (unsigned long)MTStaticIconMaximumBundleAliasCount] }
                       error:NULL]];
    }
    if (aliasConflict) {
        [diagnostics addObject:[[MTDiagnostic alloc]
            initWithSeverity:MTDiagnosticSeverityWarning
                        code:@"import.metadata.bundle-alias-shadowed"
                     summary:@"A later component Bundle alias conflicted with the primary theme or an earlier component and was ignored."
                 resourceKey:nil
                     details:@{}
                       error:NULL]];
    }
    MTStaticIconConfiguration *staticConfiguration =
        [MTStaticIconConfiguration
            configurationWithFuzzyBundleIdentifiers:fuzzy
            bundleAliases:aliases];
    if (staticConfiguration != nil) {
        configs[@"icons.static"] =
            staticConfiguration.canonicalDictionary;
    } else {
        [configs removeObjectForKey:@"icons.static"];
    }
    return [[MTThemeImportMetadata alloc]
        initWithDisplayMetadata:primaryMetadata.displayMetadata
        moduleConfigurations:configs
        recognizedModuleConfigurationCount:configs.count
        diagnostics:diagnostics];
}

@end

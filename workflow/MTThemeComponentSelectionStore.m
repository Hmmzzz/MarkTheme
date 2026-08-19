#import "MTThemeComponentSelectionStore.h"

#import "MTThemeComponentCatalog.h"

NSString *const MTThemeComponentSelectionStoreErrorDomain =
    @"com.hmmzzz.marktheme.theme-component-selection-store";

static NSString *const MTDesiredSelectionsDefaultsKey =
    @"ThemeComponentSelections.v1";
static NSString *const MTAppliedSelectionsDefaultsKey =
    @"AppliedThemeComponentSelections.v1";
static const NSUInteger MTAppliedSelectionMaximumCount = 64;

static BOOL MTThemeSelectionStoreSetError(NSError **error,
                                          NSInteger code,
                                          NSString *description) {
    if (error != NULL) {
        *error = [NSError
            errorWithDomain:MTThemeComponentSelectionStoreErrorDomain
                       code:code
                   userInfo:@{NSLocalizedDescriptionKey : description}];
    }
    return NO;
}

@interface MTThemeComponentSelectionStore ()
@property(nonatomic, strong, readwrite) NSUserDefaults *userDefaults;
@end

@implementation MTThemeComponentSelectionStore

+ (instancetype)defaultStore {
    return [[self alloc] initWithUserDefaults:NSUserDefaults.standardUserDefaults];
}

- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults {
    NSParameterAssert(userDefaults != nil);
    self = [super init];
    if (self == nil) return nil;
    _userDefaults = userDefaults;
    return self;
}

- (NSDictionary<NSString *, id> *)dictionaryForKey:(NSString *)key {
    id value = [self.userDefaults objectForKey:key];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

- (MTThemeComponentSelection *)selectionForCatalog:
        (MTThemeComponentCatalog *)catalog {
    NSDictionary *selections = [self dictionaryForKey:
        MTDesiredSelectionsDefaultsKey];
    id stored = selections[catalog.themeIdentifier];
    return [MTThemeComponentSelection selectionByNormalizingDictionary:
        [stored isKindOfClass:NSDictionary.class] ? stored : nil
        catalog:catalog];
}

- (BOOL)saveSelection:(MTThemeComponentSelection *)selection
           forCatalog:(MTThemeComponentCatalog *)catalog
                error:(NSError **)error {
    if (![selection isKindOfClass:MTThemeComponentSelection.class] ||
        ![catalog isKindOfClass:MTThemeComponentCatalog.class] ||
        ![selection.manifestDigest isEqualToString:catalog.manifestDigest] ||
        [MTThemeComponentSelection selectionForCatalog:catalog
            canonicalDictionary:selection.canonicalDictionary
            error:NULL] == nil) {
        return MTThemeSelectionStoreSetError(error, 1,
            @"Only a valid selection for the current Theme revision can be saved.");
    }
    NSMutableDictionary *selections = [[self dictionaryForKey:
        MTDesiredSelectionsDefaultsKey] mutableCopy];
    selections[catalog.themeIdentifier] = selection.canonicalDictionary;
    [self.userDefaults setObject:selections forKey:MTDesiredSelectionsDefaultsKey];
    return YES;
}

- (BOOL)recordAppliedSelection:(MTThemeComponentSelection *)selection
               themeIdentifier:(NSString *)themeIdentifier
             revisionIdentifier:(NSString *)revisionIdentifier
           generationIdentifier:(NSString *)generationIdentifier
                          error:(NSError **)error {
    if (![selection isKindOfClass:MTThemeComponentSelection.class] ||
        themeIdentifier.length == 0 || revisionIdentifier.length == 0 ||
        generationIdentifier.length == 0) {
        return MTThemeSelectionStoreSetError(error, 2,
            @"Applied component selection identity is incomplete.");
    }
    NSMutableDictionary<NSString *, NSDictionary *> *applied =
        [[self dictionaryForKey:MTAppliedSelectionsDefaultsKey] mutableCopy];
    applied[generationIdentifier] = @{
        @"recordedAt" : @([NSDate date].timeIntervalSince1970),
        @"revisionIdentifier" : revisionIdentifier,
        @"selection" : selection.canonicalDictionary,
        @"themeIdentifier" : themeIdentifier,
    };
    if (applied.count > MTAppliedSelectionMaximumCount) {
        NSArray<NSString *> *ordered = [applied.allKeys
            sortedArrayUsingComparator:^NSComparisonResult(NSString *left,
                                                            NSString *right) {
            NSNumber *leftDate = applied[left][@"recordedAt"];
            NSNumber *rightDate = applied[right][@"recordedAt"];
            NSComparisonResult result = [leftDate compare:rightDate];
            return result != NSOrderedSame
                ? result : [left compare:right options:NSLiteralSearch];
        }];
        NSUInteger removeCount = applied.count - MTAppliedSelectionMaximumCount;
        for (NSUInteger index = 0; index < removeCount; index++) {
            [applied removeObjectForKey:ordered[index]];
        }
    }
    [self.userDefaults setObject:applied forKey:MTAppliedSelectionsDefaultsKey];
    return YES;
}

- (MTThemeComponentSelection *)appliedSelectionForGenerationIdentifier:
        (NSString *)generationIdentifier
                                                        themeIdentifier:
                                                            (NSString *)themeIdentifier
                                                     revisionIdentifier:
                                                         (NSString *)revisionIdentifier
                                                                catalog:
                                                                    (MTThemeComponentCatalog *)catalog {
    NSDictionary *applied = [self dictionaryForKey:
        MTAppliedSelectionsDefaultsKey];
    id value = applied[generationIdentifier];
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *entry = value;
    if (![entry[@"themeIdentifier"] isEqualToString:themeIdentifier] ||
        ![entry[@"revisionIdentifier"] isEqualToString:revisionIdentifier] ||
        ![entry[@"selection"] isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    return [MTThemeComponentSelection selectionForCatalog:catalog
        canonicalDictionary:entry[@"selection"] error:NULL];
}

@end

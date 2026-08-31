#import <Foundation/Foundation.h>

@class MTThemeComponentCatalog;
@class MTThemeComponentSelection;
@class MTThemeMixSelection;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTThemeComponentSelectionStoreErrorDomain;

// App-process preference store. It owns only user choices and the small map
// needed to relate a published Generation back to those choices; theme assets
// remain exclusively Library/Generation owned.
@interface MTThemeComponentSelectionStore : NSObject

@property(nonatomic, strong, readonly) NSUserDefaults *userDefaults;

+ (instancetype)defaultStore;
- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (MTThemeComponentSelection *)selectionForCatalog:
    (MTThemeComponentCatalog *)catalog;
- (BOOL)saveSelection:(MTThemeComponentSelection *)selection
           forCatalog:(MTThemeComponentCatalog *)catalog
                error:(NSError **)error;

- (BOOL)recordAppliedSelection:(MTThemeComponentSelection *)selection
               themeIdentifier:(NSString *)themeIdentifier
             revisionIdentifier:(NSString *)revisionIdentifier
           generationIdentifier:(NSString *)generationIdentifier
                          error:(NSError **)error;
- (nullable MTThemeComponentSelection *)appliedSelectionForGenerationIdentifier:
    (NSString *)generationIdentifier
                                                            themeIdentifier:
                                                                (NSString *)themeIdentifier
                                                         revisionIdentifier:
                                                             (NSString *)revisionIdentifier
                                                                    catalog:
                                                                        (MTThemeComponentCatalog *)catalog;

// Cross-theme preferences store only the user's feature switches, explicit
// source overrides, and ordered App-icon fallbacks. The returned immutable
// value is rebound to the supplied current Library revisions and per-theme
// component choices on every reload.
// If an explicit source theme or its selected feature becomes unavailable, the
// feature is persistently disabled while the source preference is remembered;
// availability returning never re-enables Runtime content without user action.
// An unavailable optional App-icon fallback is skipped without disabling the
// primary feature and its priority is likewise remembered for restoration.
// The availability map may contain the full Library or only themes whose
// component selections changed since the previous immutable projection.
- (nullable MTThemeMixSelection *)mixSelectionForBaseThemeIdentifier:
    (NSString *)baseThemeIdentifier
    revisionIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *, NSString *> *)revisionIdentifiersByThemeIdentifier
    componentSelectionsByThemeIdentifier:
        (NSDictionary<NSString *, MTThemeComponentSelection *> *)
            componentSelectionsByThemeIdentifier
    availableFeatureIdentifiersByThemeIdentifier:
        (NSDictionary<NSString *, NSSet<NSString *> *> *)
            availableFeatureIdentifiersByThemeIdentifier;
- (BOOL)saveMixSelection:(MTThemeMixSelection *)selection
                   error:(NSError **)error;
// Use this for a mutation that did not change the visible App-icon source
// chain. It retains any temporarily unavailable fallback identifiers stored as
// user intent while saving the selection's other switches and sources.
- (BOOL)saveMixSelection:(MTThemeMixSelection *)selection
    preservingStoredAppIconFallbacks:(BOOL)preserveStoredFallbacks
                   error:(NSError **)error;

- (BOOL)recordAppliedMixSelection:(MTThemeMixSelection *)selection
              generationIdentifier:(NSString *)generationIdentifier
                             error:(NSError **)error;
- (nullable MTThemeMixSelection *)appliedMixSelectionForGenerationIdentifier:
    (NSString *)generationIdentifier
                                                     baseThemeIdentifier:
                                                         (NSString *)baseThemeIdentifier
                                                  baseRevisionIdentifier:
                                                      (NSString *)baseRevisionIdentifier;

@end

NS_ASSUME_NONNULL_END

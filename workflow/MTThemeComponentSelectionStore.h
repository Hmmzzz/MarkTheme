#import <Foundation/Foundation.h>

@class MTThemeComponentCatalog;
@class MTThemeComponentSelection;

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

@end

NS_ASSUME_NONNULL_END

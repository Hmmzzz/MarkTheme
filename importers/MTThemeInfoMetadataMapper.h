#import <Foundation/Foundation.h>

@class MTDiagnostic;
@class MTSafePropertyListDocument;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTThemeInfoMetadataMapperErrorDomain;
FOUNDATION_EXPORT NSString *const
    MTThemeInfoMetadataProfileCoreFoundationBundleV1;
FOUNDATION_EXPORT NSString *const
    MTThemeInfoMetadataProfileSnowBoardCalendarV1;
FOUNDATION_EXPORT NSString *const
    MTThemeInfoMetadataProfileIconBundlesMaskV1;

// Display-only metadata. It never controls a path, module, capability,
// dependency, process, executable, or version ordering decision.
@interface MTThemeDisplayMetadata : NSObject

@property(nonatomic, copy, readonly) NSString *displayName;
@property(nonatomic, copy, readonly) NSString *author;
@property(nonatomic, copy, readonly) NSString *themeVersion;
@property(nonatomic, copy, readonly) NSString *profileID;
@property(nonatomic, copy, readonly) NSString *displayNameSourceKey;
@property(nonatomic, copy, readonly) NSString *themeVersionSourceKey;
// Number of present, valid fields in this profile, including valid fallback
// fields that lost precedence to a primary field.
@property(nonatomic, assign, readonly) NSUInteger recognizedFieldCount;
@property(nonatomic, assign, readonly) BOOL usedSourceNameFallback;
@property(nonatomic, copy, readonly) NSArray<MTDiagnostic *> *diagnostics;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// Validated root Info.plist projection. Display fields remain isolated from
// bounded, module-owned configuration dictionaries.
@interface MTThemeImportMetadata : NSObject

@property(nonatomic, strong, readonly)
    MTThemeDisplayMetadata *displayMetadata;
@property(nonatomic, copy, readonly)
    NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
        moduleConfigurations;
@property(nonatomic, assign, readonly)
    NSUInteger recognizedModuleConfigurationCount;
@property(nonatomic, copy, readonly) NSArray<MTDiagnostic *> *diagnostics;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface MTThemeInfoMetadataMapper : NSObject

// Display metadata recognizes Apple's documented Core Foundation bundle keys.
// Calendar settings and the IconBundles mask opt-in use separately versioned
// legacy-theme profiles and never control paths, executables, dependencies,
// or process selection.
- (nullable MTThemeImportMetadata *)
    mapDocument:(MTSafePropertyListDocument *)document
      sourceName:(NSString *)sourceName
           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

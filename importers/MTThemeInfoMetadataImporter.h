#import <Foundation/Foundation.h>

@class MTImportCancellationToken;
@class MTSafePropertyListReader;
@class MTThemeImportMetadata;
@class MTThemeInfoMetadataMapper;
@protocol MTAuditedSource;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const MTThemeInfoMetadataImporterErrorDomain;

// Container-neutral composition boundary for the primary Info.plist and every
// merged Components/<name>/Info.plist. Primary display metadata wins while
// component-owned module settings and Bundle-ID matching hints are merged.
@interface MTThemeInfoMetadataImporter : NSObject

@property(nonatomic, strong, readonly)
    MTSafePropertyListReader *propertyListReader;
@property(nonatomic, strong, readonly)
    MTThemeInfoMetadataMapper *metadataMapper;

- (instancetype)init;
- (instancetype)initWithPropertyListReader:
                    (MTSafePropertyListReader *)propertyListReader
                              metadataMapper:
                                  (MTThemeInfoMetadataMapper *)metadataMapper
    NS_DESIGNATED_INITIALIZER;

- (nullable MTThemeImportMetadata *)
    importMetadataFromSource:(id<MTAuditedSource>)source
                  sourceName:(NSString *)sourceName
           cancellationToken:
               (nullable MTImportCancellationToken *)cancellationToken
                       error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

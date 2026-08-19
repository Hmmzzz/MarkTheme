#import "MTThemeInfoMetadataImporter.h"

#import "MTDiagnostic.h"
#import "MTAuditedSource.h"
#import "MTImportSession.h"
#import "MTSafePropertyListReader.h"
#import "MTThemeComponentPath.h"
#import "MTThemeInfoMetadataMapper.h"
#import "MTThemeInfoMetadataMapperInternal.h"

NSString *const MTThemeInfoMetadataImporterErrorDomain =
    @"com.hmmzzz.marktheme.theme-info-metadata-importer";

static MTDiagnostic *MTThemeMetadataReadDiagnostic(NSString *code,
                                                    NSString *summary,
                                                    NSString *path) {
    return [[MTDiagnostic alloc]
        initWithSeverity:MTDiagnosticSeverityWarning
                    code:code
                 summary:summary
             resourceKey:nil
                 details:@{ @"path" : path }
                   error:NULL];
}

@implementation MTThemeInfoMetadataImporter

- (instancetype)init {
    MTSafePropertyListReader *reader = [[MTSafePropertyListReader alloc]
        initWithLimits:MTSafePropertyListLimits.defaultLimits];
    return [self initWithPropertyListReader:reader
                            metadataMapper:[[MTThemeInfoMetadataMapper alloc]
                                               init]];
}

- (instancetype)initWithPropertyListReader:
                    (MTSafePropertyListReader *)propertyListReader
                              metadataMapper:
                                  (MTThemeInfoMetadataMapper *)metadataMapper {
    NSParameterAssert(propertyListReader != nil);
    NSParameterAssert(metadataMapper != nil);
    self = [super init];
    if (self == nil) return nil;
    _propertyListReader = propertyListReader;
    _metadataMapper = metadataMapper;
    return self;
}

- (MTThemeImportMetadata *)
    importMetadataFromSource:(id<MTAuditedSource>)source
                  sourceName:(NSString *)sourceName
           cancellationToken:
               (MTImportCancellationToken *)cancellationToken
                       error:(NSError **)error {
    if (source == nil ||
        ![source conformsToProtocol:@protocol(MTAuditedSource)] ||
        ![source.inventory isKindOfClass:MTSourceInventory.class]) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:MTThemeInfoMetadataImporterErrorDomain
                           code:1
                       userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Theme metadata requires a valid audited source."
            }];
        }
        return nil;
    }
    if (cancellationToken.isCancelled) {
        if (error != NULL) {
            *error = [NSError
                errorWithDomain:MTThemeInfoMetadataImporterErrorDomain
                           code:2
                       userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Theme metadata import was cancelled."
            }];
        }
        return nil;
    }

    NSMutableArray<NSString *> *infoPaths = [NSMutableArray array];
    for (MTSourceFile *file in source.inventory.files) {
        MTThemeComponentPath *component = [MTThemeComponentPath
            pathWithLogicalRelativePath:file.relativePath];
        if ([component.relativePath caseInsensitiveCompare:@"Info.plist"] ==
                NSOrderedSame) {
            [infoPaths addObject:file.relativePath];
        }
    }
    [infoPaths sortUsingComparator:^NSComparisonResult(NSString *left,
                                                        NSString *right) {
        if ([left isEqualToString:@"Info.plist"]) return NSOrderedAscending;
        if ([right isEqualToString:@"Info.plist"]) return NSOrderedDescending;
        return [left compare:right options:NSLiteralSearch];
    }];

    MTThemeImportMetadata *primaryMetadata = nil;
    NSMutableArray<MTThemeImportMetadata *> *components =
        [NSMutableArray array];
    for (NSString *infoPath in infoPaths) {
        if (cancellationToken.isCancelled) {
            if (error != NULL) {
                *error = [NSError
                    errorWithDomain:MTThemeInfoMetadataImporterErrorDomain
                               code:2
                           userInfo:@{
                    NSLocalizedDescriptionKey :
                        @"Theme metadata import was cancelled."
                }];
            }
            return nil;
        }
        MTThemeComponentPath *component = [MTThemeComponentPath
            pathWithLogicalRelativePath:infoPath];
        BOOL primary = component.componentName == nil;
        NSString *componentSourceName = primary
            ? sourceName : component.componentName;
        MTSourceFile *infoFile = [source.inventory
            fileAtRelativePath:infoPath];
        MTThemeImportMetadata *metadata = nil;
        if (infoFile.byteCount >
            self.propertyListReader.limits.maximumInputBytes) {
            MTDiagnostic *diagnostic = MTThemeMetadataReadDiagnostic(
                @"import.metadata.info-plist-limit",
                @"An Info.plist exceeds the metadata byte limit and was ignored.",
                infoPath);
            metadata = [self.metadataMapper
                fallbackMetadataForSourceName:componentSourceName
                diagnostics:@[diagnostic]];
        } else {
            NSError *readError = nil;
            NSData *data = [source
                readFileDataAtRelativePath:infoPath
                maximumByteCount:
                    self.propertyListReader.limits.maximumInputBytes
                cancellationToken:cancellationToken
                error:&readError];
            if (data == nil) {
                if (error != NULL) *error = readError;
                return nil;
            }
            NSError *propertyListError = nil;
            MTSafePropertyListDocument *document = [self.propertyListReader
                readPropertyListData:data
                cancellationToken:cancellationToken
                error:&propertyListError];
            if (document == nil) {
                if ([propertyListError.domain
                        isEqualToString:MTSafePropertyListReaderErrorDomain] &&
                    propertyListError.code ==
                        MTSafePropertyListReaderErrorCancelled) {
                    if (error != NULL) *error = propertyListError;
                    return nil;
                }
                MTDiagnostic *diagnostic = MTThemeMetadataReadDiagnostic(
                    @"import.metadata.unreadable-info-plist",
                    @"An Info.plist is not a supported property list and was ignored.",
                    infoPath);
                metadata = [self.metadataMapper
                    fallbackMetadataForSourceName:componentSourceName
                    diagnostics:@[diagnostic]];
            } else {
                metadata = [self.metadataMapper mapDocument:document
                    sourceName:componentSourceName error:error];
                if (metadata == nil) return nil;
            }
        }
        if (primary) {
            primaryMetadata = metadata;
        } else {
            [components addObject:metadata];
        }
    }
    if (primaryMetadata == nil) {
        primaryMetadata = [self.metadataMapper
            fallbackMetadataForSourceName:sourceName diagnostics:@[]];
    }
    return [self.metadataMapper
        metadataByMergingPrimaryMetadata:primaryMetadata
        componentMetadata:components];
}

@end

#import "MTIconServiceCacheCoordinator.h"

#import <CommonCrypto/CommonDigest.h>

#import "MTCanonicalJSON.h"
#import "MTGenerationDescriptor.h"
#import "MTGenerationIndexCodec.h"
#import "MTGenerationReader.h"
#import "MTRuntimeSnapshot.h"

static void MTIconServiceHashFrame(CC_SHA256_CTX *hash, NSData *data) {
    uint64_t count = data.length;
    uint8_t length[8];
    for (NSUInteger index = 0; index < sizeof(length); index++) {
        length[sizeof(length) - index - 1] = (uint8_t)(count >> (index * 8));
    }
    CC_SHA256_Update(hash, length, (CC_LONG)sizeof(length));
    // Metadata and individual validated index records are bounded far below
    // CC_LONG_MAX, but chunk defensively so length conversion cannot truncate.
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining != 0) {
        CC_LONG chunk = (CC_LONG)MIN(remaining, (NSUInteger)UINT32_MAX);
        CC_SHA256_Update(hash, bytes, chunk);
        bytes += chunk;
        remaining -= chunk;
    }
}

NSString *MTIconServicePixelDependencyFingerprint(MTRuntimeSnapshot *snapshot,
                                                 NSError **error) {
    if (error != NULL) *error = nil;
    if (!snapshot.isReady) return @"stock";
    MTGeneration *generation = snapshot.generation;
    MTGenerationDescriptor *descriptor = generation.descriptor;
    MTGenerationIndex *index = generation.index;
    if (descriptor == nil || index == nil ||
        descriptor.contractVersions == nil) return nil;
    NSArray<NSString *> *dependencies = @[
        @"icons.static", @"icons.mask", @"icons.overlay",
        @"icons.calendar", @"icons.clock",
    ];
    NSMutableDictionary *modules = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *prefixes = [NSMutableArray array];
    for (NSString *moduleID in dependencies) {
        // The static resolver reads its indexed resources directly. Include
        // resources/configuration even if a producer omitted the module ID;
        // module presence separately controls mask/overlay and dynamic policy.
        modules[moduleID] = @{
            @"enabled" : @([descriptor.moduleIDs containsObject:moduleID]),
            @"configuration" : descriptor.moduleConfigurations[moduleID] ?: NSNull.null,
        };
        [prefixes addObject:[NSString stringWithFormat:@"mtk1|%lu:%@|",
            (unsigned long)[moduleID lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
            moduleID]];
    }
    // Index iteration is canonical. Include the complete version contracts and
    // a separate pixel algorithm version, not the whole Runtime build number:
    // a badge-only release must not masquerade as a changed icon dependency.
    NSData *data = MTCanonicalJSONData(@{
        @"pixelPipelineVersion" : @2,
        @"contracts" : descriptor.contractVersions,
        @"descriptorSchema" : @(descriptor.schemaVersion),
        @"indexFormat" : @(descriptor.indexFormatVersion),
        @"dynamicCategoryPolicy" : @"exclude-themed-calendar-and-clock",
        @"sourcePolicy" : @"iphone-exact-canvas-mask-before-overlay",
        @"modules" : modules,
    }, error);
    if (data == nil) return nil;
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    MTIconServiceHashFrame(&hash, data);
    // A Generation may contain 100,000 records. Hash length-framed canonical
    // records incrementally instead of retaining another full resource array
    // and JSON buffer in iconservicesagent.
    for (NSUInteger position = 0; position < index.recordCount; position++) {
        @autoreleasepool {
            MTGenerationIndexRecord *record = [index recordAtIndex:position];
            if (record == nil) return nil;
            for (NSString *prefix in prefixes) {
                if ([record.canonicalResourceKey hasPrefix:prefix]) {
                    NSData *recordData = MTCanonicalJSONData(@[
                        record.canonicalResourceKey, record.contentSHA256,
                        @(record.assetByteCount),
                    ], error);
                    if (recordData == nil) return nil;
                    MTIconServiceHashFrame(&hash, recordData);
                    break;
                }
            }
        }
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &hash);
    static const char digits[] = "0123456789abcdef";
    char output[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {0};
    for (NSUInteger position = 0; position < sizeof(digest); position++) {
        output[position * 2] = digits[digest[position] >> 4];
        output[position * 2 + 1] = digits[digest[position] & 15];
    }
    return @(output);
}

@interface MTIconServiceCacheRequest : NSObject
@property(nonatomic, copy) NSString *fingerprint;
@property(nonatomic, strong) NSMutableOrderedSet<NSNumber *> *sequences;
@end
@implementation MTIconServiceCacheRequest
@end

@interface MTIconServiceCacheCoordinator ()
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) MTIconServiceCacheInvalidation invalidation;
@property(nonatomic, copy) MTIconServiceCacheAcknowledgement acknowledgement;
@property(nonatomic, strong) NSMutableArray<MTIconServiceCacheRequest *> *pending;
@property(nonatomic, strong, nullable) MTIconServiceCacheRequest *inFlight;
@property(nonatomic, copy, nullable) NSString *completedFingerprint;
@end

@implementation MTIconServiceCacheCoordinator

- (instancetype)initWithInvalidation:(MTIconServiceCacheInvalidation)invalidation
                      acknowledgement:(MTIconServiceCacheAcknowledgement)acknowledgement {
    if (invalidation == nil || acknowledgement == nil) return nil;
    self = [super init];
    if (self == nil) return nil;
    _queue = dispatch_queue_create("com.hmmzzz.marktheme.icon-cache-transactions",
                                  DISPATCH_QUEUE_SERIAL);
    _invalidation = [invalidation copy];
    _acknowledgement = [acknowledgement copy];
    _pending = [NSMutableArray array];
    return self;
}

- (void)acknowledgeRequest:(MTIconServiceCacheRequest *)request
                  verified:(BOOL)verified skipped:(BOOL)skipped {
    NSArray<NSNumber *> *sequences = [request.sequences.array
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *sequence in sequences) {
        self.acknowledgement(sequence.unsignedLongLongValue, verified, skipped);
    }
}

- (void)drain {
    if (self.inFlight != nil) return;
    while (self.pending.count != 0) {
        MTIconServiceCacheRequest *request = self.pending.firstObject;
        [self.pending removeObjectAtIndex:0];
        if ([self.completedFingerprint isEqualToString:request.fingerprint]) {
            [self acknowledgeRequest:request verified:YES skipped:YES];
            continue;
        }
        // A different active snapshot may have generated pixels even before
        // its clear completes. Failure cannot leave an older fingerprint safe
        // to reuse (A succeeded -> B failed -> rollback A must clear again).
        self.completedFingerprint = nil;
        self.inFlight = request;
        __weak MTIconServiceCacheCoordinator *weakSelf = self;
        self.invalidation(^(BOOL verified) {
            MTIconServiceCacheCoordinator *owner = weakSelf;
            if (owner == nil) return;
            dispatch_async(owner.queue, ^{
                // Ignore an erroneous duplicate native completion.
                if (owner.inFlight != request) return;
                if (verified) owner.completedFingerprint = request.fingerprint;
                [owner acknowledgeRequest:request verified:verified skipped:NO];
                owner.inFlight = nil;
                [owner drain];
            });
        });
        return;
    }
}

- (void)acceptFingerprint:(NSString *)fingerprint sequence:(uint64_t)sequence {
    if (fingerprint.length == 0) return;
    NSString *acceptedFingerprint = [fingerprint copy];
    dispatch_async(self.queue, ^{
        // Coalesce only adjacent equal states: A -> B -> A must still perform
        // the final A clear even if the first A has already completed.
        MTIconServiceCacheRequest *tail = self.pending.lastObject ?: self.inFlight;
        if ([tail.fingerprint isEqualToString:acceptedFingerprint]) {
            [tail.sequences addObject:@(sequence)];
        } else {
            MTIconServiceCacheRequest *request = [[MTIconServiceCacheRequest alloc] init];
            request.fingerprint = acceptedFingerprint;
            request.sequences = [NSMutableOrderedSet orderedSetWithObject:@(sequence)];
            [self.pending addObject:request];
        }
        [self drain];
    });
}

@end

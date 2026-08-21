#import "MTSafePropertyListReader.h"

#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

#import "MTImportSession.h"

NSString *const MTSafePropertyListReaderErrorDomain =
    @"com.hmmzzz.marktheme64e.safe-property-list-reader";

@implementation MTSafePropertyListLimits

+ (instancetype)defaultLimits {
    return [[self alloc]
        initWithMaximumInputBytes:1024 * 1024
                     maximumDepth:32
                     maximumNodes:10000
         maximumCollectionEntries:4096
               maximumKeyUTF8Bytes:512
            maximumStringUTF8Bytes:64 * 1024
                    maximumDataBytes:256 * 1024
         maximumAggregateScalarBytes:2 * 1024 * 1024];
}

- (instancetype)initWithMaximumInputBytes:(NSUInteger)maximumInputBytes
                             maximumDepth:(NSUInteger)maximumDepth
                             maximumNodes:(NSUInteger)maximumNodes
                 maximumCollectionEntries:(NSUInteger)maximumCollectionEntries
                       maximumKeyUTF8Bytes:(NSUInteger)maximumKeyUTF8Bytes
                    maximumStringUTF8Bytes:(NSUInteger)maximumStringUTF8Bytes
                            maximumDataBytes:(NSUInteger)maximumDataBytes
                 maximumAggregateScalarBytes:
                     (NSUInteger)maximumAggregateScalarBytes {
    NSParameterAssert(maximumInputBytes > 0);
    NSParameterAssert(maximumDepth > 0);
    NSParameterAssert(maximumNodes > 0);
    NSParameterAssert(maximumCollectionEntries > 0);
    NSParameterAssert(maximumKeyUTF8Bytes > 0);
    NSParameterAssert(maximumStringUTF8Bytes >= maximumKeyUTF8Bytes);
    NSParameterAssert(maximumDataBytes > 0);
    NSParameterAssert(maximumAggregateScalarBytes >= maximumStringUTF8Bytes);
    NSParameterAssert(maximumAggregateScalarBytes >= maximumDataBytes);
    self = [super init];
    if (self == nil) return nil;
    _maximumInputBytes = maximumInputBytes;
    _maximumDepth = maximumDepth;
    _maximumNodes = maximumNodes;
    _maximumCollectionEntries = maximumCollectionEntries;
    _maximumKeyUTF8Bytes = maximumKeyUTF8Bytes;
    _maximumStringUTF8Bytes = maximumStringUTF8Bytes;
    _maximumDataBytes = maximumDataBytes;
    _maximumAggregateScalarBytes = maximumAggregateScalarBytes;
    return self;
}

@end

@interface MTSafePropertyListDocument ()
- (instancetype)initWithRootDictionary:(NSDictionary<NSString *, id> *)rootDictionary
                                  format:(NSPropertyListFormat)format
                               nodeCount:(NSUInteger)nodeCount
                    maximumObservedDepth:(NSUInteger)maximumObservedDepth
                   aggregateScalarBytes:(NSUInteger)aggregateScalarBytes;
@end

@implementation MTSafePropertyListDocument

- (instancetype)initWithRootDictionary:(NSDictionary<NSString *, id> *)rootDictionary
                                  format:(NSPropertyListFormat)format
                               nodeCount:(NSUInteger)nodeCount
                    maximumObservedDepth:(NSUInteger)maximumObservedDepth
                   aggregateScalarBytes:(NSUInteger)aggregateScalarBytes {
    self = [super init];
    if (self == nil) return nil;
    _rootDictionary = [rootDictionary copy];
    _format = format;
    _nodeCount = nodeCount;
    _maximumObservedDepth = maximumObservedDepth;
    _aggregateScalarBytes = aggregateScalarBytes;
    return self;
}

@end

@interface MTSafePropertyListWalkState : NSObject
@property(nonatomic, strong) MTSafePropertyListLimits *limits;
@property(nonatomic, strong, nullable) MTImportCancellationToken *cancellationToken;
@property(nonatomic, assign) NSUInteger nodeCount;
@property(nonatomic, assign) NSUInteger maximumObservedDepth;
@property(nonatomic, assign) NSUInteger aggregateScalarBytes;
@end

@implementation MTSafePropertyListWalkState
@end

static BOOL MTSafePropertyListSetError(
    NSError **error,
    MTSafePropertyListReaderErrorCode code,
    NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:MTSafePropertyListReaderErrorDomain
                                     code:code
                                 userInfo:@{
            NSLocalizedDescriptionKey : description
        }];
    }
    return NO;
}

static BOOL MTSafePropertyListReserveNode(MTSafePropertyListWalkState *state,
                                          NSUInteger depth,
                                          NSError **error) {
    if (state.cancellationToken.isCancelled) {
        return MTSafePropertyListSetError(error,
            MTSafePropertyListReaderErrorCancelled,
            @"Property-list validation was cancelled.");
    }
    if (depth == 0 || depth > state.limits.maximumDepth ||
        state.nodeCount >= state.limits.maximumNodes) {
        return MTSafePropertyListSetError(error,
            MTSafePropertyListReaderErrorLimitExceeded,
            @"Property list exceeds its configured depth or node limit.");
    }
    state.nodeCount++;
    state.maximumObservedDepth = MAX(state.maximumObservedDepth, depth);
    return YES;
}

static BOOL MTSafePropertyListReserveScalarBytes(
    MTSafePropertyListWalkState *state,
    NSUInteger byteCount,
    NSError **error) {
    if (state.aggregateScalarBytes >
            state.limits.maximumAggregateScalarBytes ||
        byteCount >
        state.limits.maximumAggregateScalarBytes -
            state.aggregateScalarBytes) {
        return MTSafePropertyListSetError(error,
            MTSafePropertyListReaderErrorLimitExceeded,
            @"Property list exceeds its aggregate scalar-byte limit.");
    }
    state.aggregateScalarBytes += byteCount;
    return YES;
}

static NSString *_Nullable MTSafePropertyListNormalizeString(
    NSString *string,
    BOOL dictionaryKey,
    MTSafePropertyListWalkState *state,
    NSError **error) {
    NSString *normalized = [string precomposedStringWithCanonicalMapping];
    NSData *utf8 = [normalized dataUsingEncoding:NSUTF8StringEncoding
                            allowLossyConversion:NO];
    NSUInteger maximumBytes = dictionaryKey
        ? state.limits.maximumKeyUTF8Bytes
        : state.limits.maximumStringUTF8Bytes;
    if (utf8 == nil || (dictionaryKey && normalized.length == 0) ||
        utf8.length > maximumBytes) {
        MTSafePropertyListSetError(error,
            MTSafePropertyListReaderErrorLimitExceeded,
            dictionaryKey
                ? @"Property-list key exceeds its configured Unicode or byte limit."
                : @"Property-list string exceeds its configured Unicode or byte limit.");
        return nil;
    }
    for (NSUInteger index = 0; index < normalized.length; index++) {
        unichar character = [normalized characterAtIndex:index];
        if (character == 0 ||
            (dictionaryKey && (character < 0x20 || character == 0x7f))) {
            MTSafePropertyListSetError(error,
                MTSafePropertyListReaderErrorUnsupportedObject,
                dictionaryKey
                    ? @"Property-list key contains an unsafe control character."
                    : @"Property-list string contains NUL.");
            return nil;
        }
    }
    if (!MTSafePropertyListReserveScalarBytes(state, utf8.length, error)) {
        return nil;
    }
    return [normalized copy];
}

static id _Nullable MTSafePropertyListNormalizeObject(
    id object,
    NSUInteger depth,
    MTSafePropertyListWalkState *state,
    NSError **error) {
    if (!MTSafePropertyListReserveNode(state, depth, error)) return nil;

    if ([object isKindOfClass:NSString.class]) {
        return MTSafePropertyListNormalizeString(object, NO, state, error);
    }

    if ([object isKindOfClass:NSData.class]) {
        NSData *data = object;
        if (data.length > state.limits.maximumDataBytes) {
            MTSafePropertyListSetError(error,
                MTSafePropertyListReaderErrorLimitExceeded,
                @"Property-list data exceeds its configured byte limit.");
            return nil;
        }
        if (!MTSafePropertyListReserveScalarBytes(state, data.length, error)) {
            return nil;
        }
        return [data copy];
    }

    if ([object isKindOfClass:NSNumber.class]) {
        NSNumber *number = object;
        CFTypeID typeID = CFGetTypeID((__bridge CFTypeRef)number);
        if (typeID != CFBooleanGetTypeID() &&
            typeID != CFNumberGetTypeID()) {
            MTSafePropertyListSetError(error,
                MTSafePropertyListReaderErrorUnsupportedObject,
                @"Property list contains an unsupported numeric object.");
            return nil;
        }
        if (typeID == CFNumberGetTypeID() &&
            CFNumberIsFloatType((__bridge CFNumberRef)number) &&
            !isfinite(number.doubleValue)) {
            MTSafePropertyListSetError(error,
                MTSafePropertyListReaderErrorUnsupportedObject,
                @"Property list contains a non-finite number.");
            return nil;
        }
        if (!MTSafePropertyListReserveScalarBytes(state, sizeof(uint64_t), error)) {
            return nil;
        }
        return [number copy];
    }

    if ([object isKindOfClass:NSDate.class]) {
        NSDate *date = object;
        if (!isfinite(date.timeIntervalSinceReferenceDate)) {
            MTSafePropertyListSetError(error,
                MTSafePropertyListReaderErrorUnsupportedObject,
                @"Property list contains a non-finite date.");
            return nil;
        }
        if (!MTSafePropertyListReserveScalarBytes(state, sizeof(double), error)) {
            return nil;
        }
        return [date copy];
    }

    if ([object isKindOfClass:NSArray.class]) {
        NSArray *array = object;
        if (array.count > state.limits.maximumCollectionEntries) {
            MTSafePropertyListSetError(error,
                MTSafePropertyListReaderErrorLimitExceeded,
                @"Property-list array exceeds its configured entry limit.");
            return nil;
        }
        NSMutableArray *normalized =
            [NSMutableArray arrayWithCapacity:array.count];
        for (id value in array) {
            id normalizedValue = MTSafePropertyListNormalizeObject(
                value, depth + 1, state, error);
            if (normalizedValue == nil) return nil;
            [normalized addObject:normalizedValue];
        }
        return [normalized copy];
    }

    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = object;
        if (dictionary.count > state.limits.maximumCollectionEntries) {
            MTSafePropertyListSetError(error,
                MTSafePropertyListReaderErrorLimitExceeded,
                @"Property-list dictionary exceeds its configured entry limit.");
            return nil;
        }
        NSMutableArray<NSString *> *rawKeys =
            [NSMutableArray arrayWithCapacity:dictionary.count];
        for (id key in dictionary) {
            if (![key isKindOfClass:NSString.class]) {
                MTSafePropertyListSetError(error,
                    MTSafePropertyListReaderErrorUnsupportedObject,
                    @"Property-list dictionary key is not a string.");
                return nil;
            }
            [rawKeys addObject:key];
        }
        [rawKeys sortUsingComparator:^NSComparisonResult(NSString *left,
                                                          NSString *right) {
            return [left compare:right options:NSLiteralSearch];
        }];
        NSMutableDictionary<NSString *, id> *normalized =
            [NSMutableDictionary dictionaryWithCapacity:dictionary.count];
        for (NSString *rawKey in rawKeys) {
            if (!MTSafePropertyListReserveNode(state, depth + 1, error)) {
                return nil;
            }
            NSString *key = MTSafePropertyListNormalizeString(
                rawKey, YES, state, error);
            if (key == nil) return nil;
            if (normalized[key] != nil) {
                MTSafePropertyListSetError(error,
                    MTSafePropertyListReaderErrorCanonicalCollision,
                    @"Property-list keys collide after NFC normalization.");
                return nil;
            }
            id value = MTSafePropertyListNormalizeObject(
                dictionary[rawKey], depth + 1, state, error);
            if (value == nil) return nil;
            normalized[key] = value;
        }
        return [normalized copy];
    }

    MTSafePropertyListSetError(error,
        MTSafePropertyListReaderErrorUnsupportedObject,
        @"Property list contains an unsupported object type.");
    return nil;
}

@implementation MTSafePropertyListReader

- (instancetype)initWithLimits:(MTSafePropertyListLimits *)limits {
    NSParameterAssert(limits != nil);
    self = [super init];
    if (self == nil) return nil;
    _limits = limits;
    return self;
}

- (MTSafePropertyListDocument *)
    readPropertyListData:(NSData *)data
       cancellationToken:(MTImportCancellationToken *)cancellationToken
                    error:(NSError **)error {
    if (![data isKindOfClass:NSData.class] || data.length == 0) {
        MTSafePropertyListSetError(error,
            MTSafePropertyListReaderErrorInvalidInput,
            @"Property-list input must be non-empty data.");
        return nil;
    }
    if (data.length > self.limits.maximumInputBytes) {
        MTSafePropertyListSetError(error,
            MTSafePropertyListReaderErrorLimitExceeded,
            @"Property-list input exceeds its configured byte limit.");
        return nil;
    }
    if (cancellationToken.isCancelled) {
        MTSafePropertyListSetError(error,
            MTSafePropertyListReaderErrorCancelled,
            @"Property-list validation was cancelled before parsing.");
        return nil;
    }

    NSData *snapshot = [data copy];
    if (snapshot.length == 0 ||
        snapshot.length > self.limits.maximumInputBytes) {
        MTSafePropertyListSetError(error,
            MTSafePropertyListReaderErrorLimitExceeded,
            @"Property-list input changed beyond its configured byte limit.");
        return nil;
    }

    NSPropertyListFormat format = NSPropertyListOpenStepFormat;
    NSError *parseError = nil;
    id object = nil;
    @try {
        object = [NSPropertyListSerialization
            propertyListWithData:snapshot
                         options:NSPropertyListImmutable
                          format:&format
                           error:&parseError];
    } @catch (__unused NSException *exception) {
        object = nil;
    }
    if (object == nil || parseError != nil) {
        MTSafePropertyListSetError(error,
            MTSafePropertyListReaderErrorMalformed,
            @"Property-list input is malformed.");
        return nil;
    }
    if (format != NSPropertyListXMLFormat_v1_0 &&
        format != NSPropertyListBinaryFormat_v1_0) {
        MTSafePropertyListSetError(error,
            MTSafePropertyListReaderErrorUnsupportedFormat,
            @"Only XML and binary property-list formats are accepted.");
        return nil;
    }
    if (![object isKindOfClass:NSDictionary.class]) {
        MTSafePropertyListSetError(error,
            MTSafePropertyListReaderErrorInvalidRoot,
            @"Property-list root must be a dictionary.");
        return nil;
    }
    if (cancellationToken.isCancelled) {
        MTSafePropertyListSetError(error,
            MTSafePropertyListReaderErrorCancelled,
            @"Property-list validation was cancelled after parsing.");
        return nil;
    }

    MTSafePropertyListWalkState *state =
        [[MTSafePropertyListWalkState alloc] init];
    state.limits = self.limits;
    state.cancellationToken = cancellationToken;
    id normalized = MTSafePropertyListNormalizeObject(
        object, 1, state, error);
    if (![normalized isKindOfClass:NSDictionary.class]) return nil;
    return [[MTSafePropertyListDocument alloc]
        initWithRootDictionary:normalized
                        format:format
                     nodeCount:state.nodeCount
          maximumObservedDepth:state.maximumObservedDepth
         aggregateScalarBytes:state.aggregateScalarBytes];
}

@end

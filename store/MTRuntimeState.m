#import "MTRuntimeState.h"

#import <CoreFoundation/CoreFoundation.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <TargetConditionals.h>
#import <unistd.h>

#import "MTCanonicalJSON.h"
#import "MTDigest.h"

NSString *const MTRuntimeStateErrorDomain =
    @"com.hmmzzz.marktheme64e.runtime-state";
NSUInteger const MTRuntimeStateSchemaVersion = 1;

static const uint64_t MTRuntimeStateMaximumByteCount = 4096;

static uid_t MTRuntimeStatePublishedUserID(void) {
#if defined(MT_HOST_TESTING) || TARGET_OS_SIMULATOR
    return geteuid();
#else
    return 0;
#endif
}

static gid_t MTRuntimeStatePublishedGroupID(void) {
#if defined(MT_HOST_TESTING) || TARGET_OS_SIMULATOR
    return getegid();
#else
    return 0;
#endif
}

static BOOL MTRuntimeStateSetError(NSError **error,
                                   MTRuntimeStateErrorCode code,
                                   NSString *description,
                                   NSError *underlying) {
    if (error != NULL) {
        NSMutableDictionary *userInfo = [NSMutableDictionary
            dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
        if (underlying != nil) userInfo[NSUnderlyingErrorKey] = underlying;
        *error = [NSError errorWithDomain:MTRuntimeStateErrorDomain
                                     code:code
                                 userInfo:userInfo];
    }
    return NO;
}

static BOOL MTRuntimeGenerationIdentifierIsCanonical(id value) {
    static NSString *const prefix = @"g1-";
    return [value isKindOfClass:NSString.class] &&
        [value hasPrefix:prefix] &&
        MTStringIsLowercaseSHA256Digest(
            [value substringFromIndex:prefix.length]);
}

static BOOL MTRuntimeStateUnsignedInteger(id value, uint64_t *output) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) {
        return NO;
    }
    NSNumber *number = value;
    const char *type = number.objCType;
    if (type == NULL || type[0] == 'f' || type[0] == 'd') return NO;
    NSString *string = number.stringValue;
    if (string.length == 0 || [string characterAtIndex:0] == '-') return NO;
    uint64_t result = 0;
    for (NSUInteger index = 0; index < string.length; index++) {
        unichar character = [string characterAtIndex:index];
        if (character < '0' || character > '9') return NO;
        uint64_t digit = (uint64_t)(character - '0');
        if (result > (UINT64_MAX - digit) / 10) return NO;
        result = result * 10 + digit;
    }
    *output = result;
    return YES;
}

static NSDictionary<NSString *, id> *MTRuntimeStateDictionary(
    uint64_t sequence,
    BOOL runtimeEnabled,
    NSString *activeIdentifier,
    NSString *previousIdentifier) {
    return @{
        @"activeGenerationIdentifier" : activeIdentifier ?: NSNull.null,
        @"previousGenerationIdentifier" : previousIdentifier ?: NSNull.null,
        @"runtimeEnabled" : @(runtimeEnabled),
        @"schemaVersion" : @(MTRuntimeStateSchemaVersion),
        @"sequence" : @(sequence),
    };
}

@interface MTRuntimeState ()

@property(nonatomic, assign, readwrite) NSUInteger schemaVersion;
@property(nonatomic, assign, readwrite) uint64_t sequence;
@property(nonatomic, assign, readwrite, getter=isRuntimeEnabled)
    BOOL runtimeEnabled;
@property(nonatomic, copy, readwrite, nullable)
    NSString *activeGenerationIdentifier;
@property(nonatomic, copy, readwrite, nullable)
    NSString *previousGenerationIdentifier;
@property(nonatomic, copy, readwrite) NSData *canonicalData;

@end

@implementation MTRuntimeState

+ (instancetype)initialState {
    MTRuntimeState *state = [[self alloc]
        initWithSequence:0
        runtimeEnabled:NO
        activeGenerationIdentifier:nil
        previousGenerationIdentifier:nil
        error:NULL];
    NSAssert(state != nil, @"The built-in Runtime state must be valid.");
    return state;
}

- (instancetype)initWithSequence:(uint64_t)sequence
                   runtimeEnabled:(BOOL)runtimeEnabled
       activeGenerationIdentifier:(NSString *)activeGenerationIdentifier
     previousGenerationIdentifier:(NSString *)previousGenerationIdentifier
                             error:(NSError **)error {
    BOOL activeValid = activeGenerationIdentifier == nil ||
        MTRuntimeGenerationIdentifierIsCanonical(activeGenerationIdentifier);
    BOOL previousValid = previousGenerationIdentifier == nil ||
        MTRuntimeGenerationIdentifierIsCanonical(previousGenerationIdentifier);
    if (!activeValid || !previousValid ||
        (runtimeEnabled && activeGenerationIdentifier == nil) ||
        (previousGenerationIdentifier != nil &&
         activeGenerationIdentifier == nil)) {
        MTRuntimeStateSetError(error, MTRuntimeStateErrorInvalidInput,
            @"Runtime state identifiers or activation flags are invalid.", nil);
        return nil;
    }
    NSDictionary *dictionary = MTRuntimeStateDictionary(
        sequence, runtimeEnabled, activeGenerationIdentifier,
        previousGenerationIdentifier);
    NSError *canonicalError = nil;
    NSData *canonicalData = MTCanonicalJSONData(dictionary, &canonicalError);
    if (canonicalData == nil) {
        MTRuntimeStateSetError(error, MTRuntimeStateErrorInvalidInput,
            @"Runtime state could not be encoded canonically.", canonicalError);
        return nil;
    }
    self = [super init];
    if (self == nil) return nil;
    _schemaVersion = MTRuntimeStateSchemaVersion;
    _sequence = sequence;
    _runtimeEnabled = runtimeEnabled;
    _activeGenerationIdentifier = [activeGenerationIdentifier copy];
    _previousGenerationIdentifier = [previousGenerationIdentifier copy];
    _canonicalData = [canonicalData copy];
    return self;
}

- (instancetype)initWithCanonicalData:(NSData *)canonicalData
                                  error:(NSError **)error {
    if (![canonicalData isKindOfClass:NSData.class] ||
        canonicalData.length == 0 ||
        canonicalData.length > MTRuntimeStateMaximumByteCount) {
        MTRuntimeStateSetError(error, MTRuntimeStateErrorMalformedData,
            @"Runtime state data is empty or too large.", nil);
        return nil;
    }
    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:canonicalData
                                                options:0
                                                  error:&jsonError];
    NSArray<NSString *> *keys = @[
        @"activeGenerationIdentifier",
        @"previousGenerationIdentifier",
        @"runtimeEnabled",
        @"schemaVersion",
        @"sequence",
    ];
    NSDictionary *dictionary = [object isKindOfClass:NSDictionary.class]
        ? object : nil;
    if (dictionary == nil) {
        MTRuntimeStateSetError(error, MTRuntimeStateErrorMalformedData,
            @"Runtime state root must be a dictionary.", jsonError);
        return nil;
    }
    BOOL exactKeys = dictionary.count == keys.count &&
        [[NSSet setWithArray:dictionary.allKeys]
            isEqualToSet:[NSSet setWithArray:keys]];
    uint64_t schemaVersion = 0;
    uint64_t sequence = 0;
    id activeValue = dictionary[@"activeGenerationIdentifier"];
    id previousValue = dictionary[@"previousGenerationIdentifier"];
    id enabledValue = dictionary[@"runtimeEnabled"];
    BOOL enabledIsBoolean = [enabledValue isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)enabledValue) == CFBooleanGetTypeID();
    BOOL activeValid = activeValue == NSNull.null ||
        MTRuntimeGenerationIdentifierIsCanonical(activeValue);
    BOOL previousValid = previousValue == NSNull.null ||
        MTRuntimeGenerationIdentifierIsCanonical(previousValue);
    if (!exactKeys ||
        !MTRuntimeStateUnsignedInteger(dictionary[@"schemaVersion"],
                                       &schemaVersion) ||
        !MTRuntimeStateUnsignedInteger(dictionary[@"sequence"], &sequence) ||
        !enabledIsBoolean || !activeValid || !previousValid) {
        MTRuntimeStateSetError(error, MTRuntimeStateErrorMalformedData,
            @"Runtime state does not match its canonical schema.", jsonError);
        return nil;
    }
    if (schemaVersion != MTRuntimeStateSchemaVersion) {
        MTRuntimeStateSetError(error, MTRuntimeStateErrorUnsupportedVersion,
            @"Runtime state schema version is not supported.", nil);
        return nil;
    }
    NSError *canonicalError = nil;
    NSData *reencoded = MTCanonicalJSONData(dictionary, &canonicalError);
    if (reencoded == nil || ![reencoded isEqualToData:canonicalData]) {
        MTRuntimeStateSetError(error, MTRuntimeStateErrorMalformedData,
            @"Runtime state is not canonically encoded.", canonicalError);
        return nil;
    }
    return [self initWithSequence:sequence
                   runtimeEnabled:[enabledValue boolValue]
       activeGenerationIdentifier:activeValue == NSNull.null ? nil : activeValue
     previousGenerationIdentifier:
        previousValue == NSNull.null ? nil : previousValue
                             error:error];
}

+ (instancetype)stateByReadingRuntimeRootURL:(NSURL *)runtimeRootURL
                            ownershipProfile:
                                (MTRuntimeStateOwnershipProfile)ownershipProfile
                                        error:(NSError **)error {
    if (![runtimeRootURL isKindOfClass:NSURL.class] ||
        !runtimeRootURL.isFileURL || runtimeRootURL.path.length == 0 ||
        (ownershipProfile != MTRuntimeStateOwnershipProfilePrivate &&
         ownershipProfile != MTRuntimeStateOwnershipProfilePublished)) {
        MTRuntimeStateSetError(error, MTRuntimeStateErrorInvalidInput,
            @"Runtime state requires a local store root.", nil);
        return nil;
    }
    NSURL *stateURL = [[runtimeRootURL
        URLByAppendingPathComponent:@"state" isDirectory:YES]
        URLByAppendingPathComponent:@"active.json" isDirectory:NO];
    int descriptor = open(stateURL.fileSystemRepresentation,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        if (errno == ENOENT) return self.initialState;
        MTRuntimeStateSetError(error, MTRuntimeStateErrorStorage,
            @"Unable to open Runtime state.",
            [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
        return nil;
    }
    struct stat status = {0};
    mode_t permissions = 0;
    BOOL privateState = NO;
    BOOL publishedState = NO;
    BOOL statValid = fstat(descriptor, &status) == 0;
    if (statValid) {
        permissions = status.st_mode & 0777;
        privateState = status.st_uid == geteuid() && permissions == 0600;
        publishedState = status.st_uid == MTRuntimeStatePublishedUserID() &&
            status.st_gid == MTRuntimeStatePublishedGroupID() &&
            permissions == 0644;
    }
    BOOL ownershipValid =
        ownershipProfile == MTRuntimeStateOwnershipProfilePrivate
            ? privateState : publishedState;
    BOOL metadataValid = statValid &&
        S_ISREG(status.st_mode) && status.st_nlink == 1 &&
        ownershipValid &&
        status.st_size > 0 &&
        (uint64_t)status.st_size <= MTRuntimeStateMaximumByteCount;
    if (!metadataValid) {
        close(descriptor);
        MTRuntimeStateSetError(error, MTRuntimeStateErrorStorage,
            @"Runtime state file metadata is invalid.", nil);
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)status.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = read(descriptor,
            (unsigned char *)data.mutableBytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        offset += (NSUInteger)count;
    }
    int closeResult = close(descriptor);
    if (offset != data.length || closeResult != 0) {
        MTRuntimeStateSetError(error, MTRuntimeStateErrorStorage,
            @"Unable to read the complete Runtime state.", nil);
        return nil;
    }
    return [[self alloc] initWithCanonicalData:data error:error];
}

@end

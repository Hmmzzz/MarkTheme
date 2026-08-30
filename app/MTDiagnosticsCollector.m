#import "MTDiagnosticsCollector.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <notify.h>
#import <sys/socket.h>
#import <time.h>
#import <unistd.h>

#import "MTBootstrapPaths.h"
#import "MTDiagnosticsReport.h"
#import "MTRuntimeDiagnosticsProtocol.h"

#if !defined(MARKTHEME_RUNTIME_BUILD_NUMBER)
#error "MARKTHEME_RUNTIME_BUILD_NUMBER must identify collected diagnostics"
#endif

static NSString *const MTDiagnosticsCollectorErrorDomain =
    @"com.hmmzzz.marktheme.diagnostics-collector";
static const NSTimeInterval MTDiagnosticsInitialCollectionDelay = 1.2;
static const uint32_t MTDiagnosticsCollectionSessionSeconds = 3 * 60;
static const NSUInteger MTDiagnosticsMaximumAcceptedDatagrams = 64;
static const NSUInteger MTDiagnosticsExpectedReportSchema = 3;
static const NSUInteger MTDiagnosticsExpectedObservationSchema = 7;

@interface MTDiagnosticsCollector ()
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, assign) int socketDescriptor;
@property(nonatomic, strong, nullable) dispatch_source_t readSource;
@property(nonatomic, assign) int requestToken;
@property(nonatomic, assign) uint32_t activeNonce;
@property(nonatomic, assign) uint64_t activeExpiration;
@property(nonatomic, strong) NSMutableSet<NSString *> *persistedProfiles;
@property(nonatomic, strong, nullable) NSError *lastPersistenceError;
@property(nonatomic, assign) NSUInteger acceptedDatagramCount;
- (instancetype)initPrivate;
- (void)closeSocketLocked;
- (void)drainSocketLocked;
@end

@implementation MTDiagnosticsCollector

+ (instancetype)sharedCollector {
    static MTDiagnosticsCollector *collector;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        collector = [[self alloc] initPrivate];
    });
    return collector;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self == nil) return nil;
    _queue = dispatch_queue_create(
        "com.hmmzzz.marktheme.diagnostics-collector",
        DISPATCH_QUEUE_SERIAL);
    _socketDescriptor = -1;
    _requestToken = NOTIFY_TOKEN_INVALID;
    _persistedProfiles = [NSMutableSet set];
    return self;
}

- (instancetype)init {
    return [MTDiagnosticsCollector sharedCollector];
}

- (NSError *)errorWithCode:(NSInteger)code description:(NSString *)description {
    return [NSError errorWithDomain:MTDiagnosticsCollectorErrorDomain
                               code:code
                           userInfo:@{
        NSLocalizedDescriptionKey : description,
    }];
}

- (BOOL)ensureSocketLockedWithPort:(uint16_t *)portOut
                              error:(NSError **)error {
    if (portOut != NULL) *portOut = 0;
    if (self.socketDescriptor >= 0 && self.readSource != nil) {
        struct sockaddr_in address = {0};
        socklen_t length = sizeof(address);
        if (getsockname(self.socketDescriptor,
                (struct sockaddr *)&address, &length) == 0 &&
            address.sin_family == AF_INET && address.sin_port != 0) {
            if (portOut != NULL) *portOut = ntohs(address.sin_port);
            return YES;
        }
        [self closeSocketLocked];
    }

    int descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (descriptor < 0) {
        if (error != NULL) {
            *error = [self errorWithCode:errno
                description:@"Unable to create the diagnostics loopback socket."];
        }
        return NO;
    }
    int receiveBufferBytes = 1024 * 1024;
    (void)setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF,
        &receiveBufferBytes, sizeof(receiveBufferBytes));
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0) {
        int savedError = errno;
        close(descriptor);
        if (error != NULL) {
            *error = [self errorWithCode:savedError
                description:@"Unable to configure the diagnostics socket."];
        }
        return NO;
    }
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = 0;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(descriptor, (const struct sockaddr *)&address,
             sizeof(address)) != 0) {
        int savedError = errno;
        close(descriptor);
        if (error != NULL) {
            *error = [self errorWithCode:savedError
                description:@"Unable to bind the diagnostics loopback socket."];
        }
        return NO;
    }
    socklen_t length = sizeof(address);
    if (getsockname(descriptor, (struct sockaddr *)&address, &length) != 0 ||
        address.sin_port == 0) {
        int savedError = errno;
        close(descriptor);
        if (error != NULL) {
            *error = [self errorWithCode:savedError
                description:@"Unable to resolve the diagnostics socket port."];
        }
        return NO;
    }

    self.socketDescriptor = descriptor;
    __weak typeof(self) weakSelf = self;
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)descriptor, 0, self.queue);
    dispatch_source_set_event_handler(source, ^{
        [weakSelf drainSocketLocked];
    });
    dispatch_source_set_cancel_handler(source, ^{
        close(descriptor);
    });
    self.readSource = source;
    dispatch_resume(source);
    if (portOut != NULL) *portOut = ntohs(address.sin_port);
    return YES;
}

- (void)closeSocketLocked {
    if (self.readSource != nil) {
        dispatch_source_cancel(self.readSource);
        self.readSource = nil;
    } else if (self.socketDescriptor >= 0) {
        close(self.socketDescriptor);
    }
    self.socketDescriptor = -1;
}

- (BOOL)ensureRequestTokenLockedWithError:(NSError **)error {
    if (self.requestToken != NOTIFY_TOKEN_INVALID) return YES;
    int token = NOTIFY_TOKEN_INVALID;
    int result = notify_register_check(
        MTRuntimeDiagnosticsCollectionRequestNotificationName.UTF8String,
        &token);
    if (result != NOTIFY_STATUS_OK) {
        if (error != NULL) {
            *error = [self errorWithCode:result
                description:@"Unable to register the diagnostics request state."];
        }
        return NO;
    }
    self.requestToken = token;
    return YES;
}

- (BOOL)reportIsCurrent:(NSDictionary<NSString *, id> *)report {
    return [report[@"schemaVersion"] unsignedIntegerValue] ==
            MTDiagnosticsExpectedReportSchema &&
        [report[@"runtimeBuild"] unsignedIntegerValue] ==
            MARKTHEME_RUNTIME_BUILD_NUMBER &&
        [report[@"observationSchema"] unsignedIntegerValue] ==
            MTDiagnosticsExpectedObservationSchema;
}

- (void)persistDatagram:(NSData *)data
             fromAddress:(const struct sockaddr_in *)sourceAddress {
    if (sourceAddress == NULL || sourceAddress->sin_family != AF_INET ||
        ntohl(sourceAddress->sin_addr.s_addr) != INADDR_LOOPBACK ||
        data.length == 0 ||
        data.length > MTRuntimeDiagnosticsMaximumDatagramByteCount) {
        return;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data
                                                 options:0
                                                   error:NULL];
    if (![object isKindOfClass:NSDictionary.class]) return;
    NSDictionary<NSString *, id> *report = object;
    NSDictionary<NSString *, id> *transport =
        [report[@"transport"] isKindOfClass:NSDictionary.class]
            ? report[@"transport"] : nil;
    if ([transport[@"schemaVersion"] unsignedIntegerValue] != 1 ||
        ![transport[@"method"] isEqualToString:@"loopback-udp"] ||
        [transport[@"nonce"] unsignedIntValue] != self.activeNonce ||
        ![self reportIsCurrent:report]) {
        return;
    }
    NSString *profile = [report[@"profile"] isKindOfClass:NSString.class]
        ? report[@"profile"] : nil;
    if (profile.length == 0 ||
        ![MTDiagnosticsExpectedProfileIdentifiers()
            containsObject:profile]) {
        return;
    }
    NSURL *directory = [MTDefaultManagerDataRootURL()
        URLByAppendingPathComponent:@"Diagnostics" isDirectory:YES];
    NSError *error = nil;
    BOOL directoryReady = [NSFileManager.defaultManager
        createDirectoryAtURL:directory
 withIntermediateDirectories:YES
                  attributes:nil
                       error:&error];
    NSURL *fileURL = [directory URLByAppendingPathComponent:
        [profile stringByAppendingPathExtension:@"json"]];
    if (!directoryReady || ![data writeToURL:fileURL
                                  options:NSDataWritingAtomic
                                    error:&error]) {
        self.lastPersistenceError = error ?: [self errorWithCode:5
            description:@"Unable to persist a collected Runtime report."];
        return;
    }
    [self.persistedProfiles addObject:profile];
}

- (void)drainSocketLocked {
    if (self.socketDescriptor < 0) return;
    while (self.acceptedDatagramCount <
            MTDiagnosticsMaximumAcceptedDatagrams) {
        uint8_t buffer[60 * 1024 + 1];
        struct sockaddr_in sourceAddress = {0};
        socklen_t sourceLength = sizeof(sourceAddress);
        ssize_t received = recvfrom(self.socketDescriptor, buffer,
            sizeof(buffer), 0, (struct sockaddr *)&sourceAddress,
            &sourceLength);
        if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (received <= 0) break;
        self.acceptedDatagramCount += 1;
        if ((NSUInteger)received >
            MTRuntimeDiagnosticsMaximumDatagramByteCount) {
            continue;
        }
        NSData *data = [NSData dataWithBytes:buffer
                                      length:(NSUInteger)received];
        [self persistDatagram:data fromAddress:&sourceAddress];
    }
}

- (void)refreshWithCompletion:
        (MTDiagnosticsCollectionCompletion)completion {
    MTDiagnosticsCollectionCompletion callback = [completion copy];
    dispatch_async(self.queue, ^{
        [self drainSocketLocked];
        NSError *error = nil;
        uint16_t port = 0;
        if (![self ensureSocketLockedWithPort:&port error:&error] ||
            ![self ensureRequestTokenLockedWithError:&error]) {
            [self closeSocketLocked];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (callback != nil) callback(0, error);
            });
            return;
        }
        self.persistedProfiles = [NSMutableSet set];
        self.lastPersistenceError = nil;
        self.acceptedDatagramCount = 0;
        uint32_t nonce = 0;
        do {
            nonce = arc4random_uniform(UINT32_C(0xffffff));
        } while (nonce == 0);
        uint64_t now = (uint64_t)time(NULL);
        uint64_t expiration = now + MTDiagnosticsCollectionSessionSeconds;
        uint64_t word = MTRuntimeDiagnosticsCollectionRequestWord(
            port, nonce, expiration);
        if (word == 0 ||
            notify_set_state(self.requestToken, word) != NOTIFY_STATUS_OK ||
            notify_post(
                MTRuntimeDiagnosticsCollectionRequestNotificationName.UTF8String)
                != NOTIFY_STATUS_OK) {
            error = [self errorWithCode:6
                description:@"Unable to publish the diagnostics request."];
            (void)notify_set_state(self.requestToken, 0);
            (void)notify_post(
                MTRuntimeDiagnosticsCollectionRequestNotificationName.UTF8String);
            self.activeNonce = 0;
            self.activeExpiration = 0;
            [self closeSocketLocked];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (callback != nil) callback(0, error);
            });
            return;
        }
        self.activeNonce = nonce;
        self.activeExpiration = expiration;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(MTDiagnosticsInitialCollectionDelay * NSEC_PER_SEC)),
            self.queue, ^{
            [self drainSocketLocked];
            NSUInteger count = self.persistedProfiles.count;
            NSError *collectionError = self.lastPersistenceError;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (callback != nil) callback(count, collectionError);
            });
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(MTDiagnosticsCollectionSessionSeconds * NSEC_PER_SEC)),
            self.queue, ^{
            if (self.activeNonce != nonce ||
                self.activeExpiration != expiration) {
                return;
            }
            [self drainSocketLocked];
            (void)notify_set_state(self.requestToken, 0);
            (void)notify_post(
                MTRuntimeDiagnosticsCollectionRequestNotificationName.UTF8String);
            self.activeNonce = 0;
            self.activeExpiration = 0;
            [self closeSocketLocked];
        });
    });
}

@end

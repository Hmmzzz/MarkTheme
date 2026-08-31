#import "MTRuntimeHelperClient.h"

#import <errno.h>
#import <fcntl.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

#import "MTBootstrapPaths.h"
#import "MTCanonicalJSON.h"
#import "MTDigest.h"
#import "MTRuntimeState.h"

extern char **environ;

NSString *const MTRuntimeHelperClientErrorDomain =
    @"com.hmmzzz.marktheme.runtime-helper-client";

static NSError *MTRuntimeHelperClientError(NSInteger code,
                                           NSString *description) {
    return [NSError errorWithDomain:MTRuntimeHelperClientErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

static NSString *MTRuntimeHelperOutputDiagnostic(NSData *output) {
    if (output.length == 0) return @"no helper output";
    NSString *text = [[NSString alloc] initWithData:output
                                           encoding:NSUTF8StringEncoding];
    if (text == nil) return @"non-UTF-8 helper output";
    NSArray<NSString *> *lines = [text
        componentsSeparatedByCharactersInSet:
            NSCharacterSet.newlineCharacterSet];
    NSString *singleLine = [[lines componentsJoinedByString:@" "]
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (singleLine.length > 512) {
        singleLine = [[singleLine substringToIndex:512]
            stringByAppendingString:@"…"];
    }
    return singleLine.length > 0 ? singleLine : @"empty helper output";
}

@interface MTRuntimeApplyResult ()
@property(nonatomic, copy, readwrite) NSString *generationIdentifier;
@property(nonatomic, assign, readwrite) BOOL reusedExistingGeneration;
@property(nonatomic, strong, readwrite) MTRuntimeState *state;
@property(nonatomic, assign, readwrite) BOOL iconServiceAcknowledged;
- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                     reusedExistingGeneration:(BOOL)reused
                                        state:(MTRuntimeState *)state
                      iconServiceAcknowledged:(BOOL)iconServiceAcknowledged;
@end

@implementation MTRuntimeApplyResult

- (instancetype)initWithGenerationIdentifier:(NSString *)generationIdentifier
                     reusedExistingGeneration:(BOOL)reused
                                        state:(MTRuntimeState *)state
                      iconServiceAcknowledged:(BOOL)iconServiceAcknowledged {
    self = [super init];
    if (self == nil) return nil;
    _generationIdentifier = [generationIdentifier copy];
    _reusedExistingGeneration = reused;
    _state = state;
    _iconServiceAcknowledged = iconServiceAcknowledged;
    return self;
}

@end

@interface MTRuntimeHelperClient ()
@property(nonatomic, copy, readwrite) NSURL *helperURL;
@end

@implementation MTRuntimeHelperClient

+ (instancetype)defaultClientWithError:(NSError **)error {
    NSURL *helperURL = MTDefaultRuntimeHelperURL(error);
    return helperURL == nil ? nil
        : [[self alloc] initWithHelperURL:helperURL];
}

- (instancetype)initWithHelperURL:(NSURL *)helperURL {
    NSParameterAssert(helperURL.isFileURL);
    self = [super init];
    if (self == nil) return nil;
    _helperURL = [helperURL copy];
    return self;
}

- (NSDictionary<NSString *, id> *)runArguments:(NSArray<NSString *> *)arguments
                                           error:(NSError **)error {
    if (![NSFileManager.defaultManager
            isExecutableFileAtPath:self.helperURL.path]) {
        if (error != NULL) {
            *error = MTRuntimeHelperClientError(1,
                @"The MarkTheme Runtime Helper is unavailable.");
        }
        return nil;
    }
    int outputPipe[2] = {-1, -1};
    if (pipe(outputPipe) != 0) {
        if (error != NULL) {
            *error = MTRuntimeHelperClientError(2,
                @"Unable to create the Runtime Helper output pipe.");
        }
        return nil;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
    // Helper failures are deliberately path-free and bounded. Capture stderr
    // with stdout so the Manager can report the real child exit reason rather
    // than collapsing every failure into a storage suggestion.
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
    posix_spawn_file_actions_addclose(&actions, outputPipe[1]);

    NSUInteger count = arguments.count + 2;
    char **spawnArguments = calloc(count, sizeof(char *));
    if (spawnArguments == NULL) {
        posix_spawn_file_actions_destroy(&actions);
        close(outputPipe[0]);
        close(outputPipe[1]);
        if (error != NULL) {
            *error = MTRuntimeHelperClientError(2,
                @"Unable to prepare Runtime Helper arguments.");
        }
        return nil;
    }
    const char *executable = self.helperURL.fileSystemRepresentation;
    spawnArguments[0] = executable == NULL ? NULL : strdup(executable);
    for (NSUInteger index = 0;
         spawnArguments[0] != NULL && index < arguments.count; index++) {
        const char *value = arguments[index].UTF8String;
        spawnArguments[index + 1] = value == NULL ? NULL : strdup(value);
        if (spawnArguments[index + 1] == NULL) break;
    }
    BOOL argumentsReady = spawnArguments[0] != NULL;
    for (NSUInteger index = 0; argumentsReady && index < arguments.count;
         index++) {
        argumentsReady = spawnArguments[index + 1] != NULL;
    }
    if (!argumentsReady) {
        for (NSUInteger index = 0; index < count; index++) {
            free(spawnArguments[index]);
        }
        free(spawnArguments);
        posix_spawn_file_actions_destroy(&actions);
        close(outputPipe[0]);
        close(outputPipe[1]);
        if (error != NULL) {
            *error = MTRuntimeHelperClientError(2,
                @"Unable to copy Runtime Helper arguments.");
        }
        return nil;
    }
    pid_t child = 0;
    // The Manager runs in the RootHide-mapped LaunchServices environment.
    // Preserve that environment across the fixed trusted Helper boundary;
    // passing an empty environment loses the process mapping context that the
    // already-audited MarkFont client also retains.
    int spawnResult = posix_spawn(&child,
        spawnArguments[0], &actions, NULL,
        spawnArguments, environ);
    for (NSUInteger index = 0; index < count; index++) {
        free(spawnArguments[index]);
    }
    free(spawnArguments);
    posix_spawn_file_actions_destroy(&actions);
    close(outputPipe[1]);
    if (spawnResult != 0) {
        close(outputPipe[0]);
        if (error != NULL) {
            *error = MTRuntimeHelperClientError(3,
                [NSString stringWithFormat:
                    @"Unable to launch the Runtime Helper (%d: %s).",
                    spawnResult, strerror(spawnResult)]);
        }
        return nil;
    }

    NSMutableData *output = [NSMutableData data];
    unsigned char buffer[4096];
    BOOL outputTooLarge = NO;
    BOOL readFailed = NO;
    int readErrorValue = 0;
    while (YES) {
        ssize_t amount = read(outputPipe[0], buffer, sizeof(buffer));
        if (amount < 0 && errno == EINTR) continue;
        if (amount < 0) {
            readFailed = YES;
            readErrorValue = errno;
            break;
        }
        if (amount == 0) break;
        if (output.length + (NSUInteger)amount > 64 * 1024) {
            outputTooLarge = YES;
            break;
        }
        [output appendBytes:buffer length:(NSUInteger)amount];
    }
    close(outputPipe[0]);
    int childStatus = 0;
    pid_t waited = -1;
    do {
        waited = waitpid(child, &childStatus, 0);
    } while (waited < 0 && errno == EINTR);
    int waitErrorValue = waited < 0 ? errno : 0;
    if (outputTooLarge || readFailed || waited < 0 ||
        !WIFEXITED(childStatus) || WEXITSTATUS(childStatus) != 0) {
        if (error != NULL) {
            NSString *description = nil;
            if (outputTooLarge) {
                description = @"The Runtime Helper output exceeded 64 KiB.";
            } else if (readFailed) {
                description = [NSString stringWithFormat:
                    @"Unable to read Runtime Helper output (%d: %s).",
                    readErrorValue, strerror(readErrorValue)];
            } else if (waited < 0) {
                description = [NSString stringWithFormat:
                    @"Unable to wait for the Runtime Helper (%d: %s).",
                    waitErrorValue, strerror(waitErrorValue)];
            } else if (WIFSIGNALED(childStatus)) {
                description = [NSString stringWithFormat:
                    @"The Runtime Helper was terminated by signal %d (%@).",
                    WTERMSIG(childStatus),
                    MTRuntimeHelperOutputDiagnostic(output)];
            } else {
                description = [NSString stringWithFormat:
                    @"The Runtime Helper exited with status %d (%@).",
                    WEXITSTATUS(childStatus),
                    MTRuntimeHelperOutputDiagnostic(output)];
            }
            *error = MTRuntimeHelperClientError(4,
                description);
        }
        return nil;
    }
    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:output
                                                options:0
                                                  error:&jsonError];
    if (![object isKindOfClass:NSDictionary.class]) {
        if (error != NULL) {
            *error = MTRuntimeHelperClientError(5,
                [NSString stringWithFormat:
                    @"The Runtime Helper returned an invalid response (%@).",
                    MTRuntimeHelperOutputDiagnostic(output)]);
        }
        return nil;
    }
    return object;
}

- (MTRuntimeState *)stateFromResponse:(NSDictionary<NSString *, id> *)response
                     expectedOperation:(NSString *)expectedOperation
                        expectedStatus:(NSString *)expectedStatus
                                 error:(NSError **)error {
    NSDictionary *stateDictionary =
        [response[@"state"] isKindOfClass:NSDictionary.class]
            ? response[@"state"] : nil;
    if (![response[@"schemaVersion"] isEqual:@1] ||
        ![response[@"operation"] isEqual:expectedOperation] ||
        ![response[@"status"] isEqual:expectedStatus] ||
        stateDictionary == nil) {
        if (error != NULL) {
            *error = MTRuntimeHelperClientError(5,
                @"The Runtime Helper response does not match its operation.");
        }
        return nil;
    }
    NSData *canonicalData = MTCanonicalJSONData(stateDictionary, error);
    return canonicalData == nil ? nil
        : [[MTRuntimeState alloc] initWithCanonicalData:canonicalData error:error];
}

- (MTRuntimeApplyResult *)applyGenerationWithIdentifier:
    (NSString *)generationIdentifier
                                                          error:(NSError **)error {
    if (![generationIdentifier hasPrefix:@"g1-"] ||
        !MTStringIsLowercaseSHA256Digest(
            [generationIdentifier substringFromIndex:3])) {
        if (error != NULL) {
            *error = MTRuntimeHelperClientError(6,
                @"Apply requires a canonical Generation identifier.");
        }
        return nil;
    }
    NSDictionary *response = [self runArguments:
        @[@"apply", generationIdentifier, @"--json"] error:error];
    MTRuntimeState *state = response == nil ? nil
        : [self stateFromResponse:response
                expectedOperation:@"apply"
                   expectedStatus:@"applied"
                            error:error];
    id reused = response[@"reusedExistingGeneration"];
    NSString *iconServiceDelivery =
        [response[@"iconServiceDelivery"] isKindOfClass:NSString.class]
            ? response[@"iconServiceDelivery"] : nil;
    BOOL iconServiceAcknowledged =
        [iconServiceDelivery isEqualToString:@"acknowledged"];
    BOOL iconServiceDeliveryValid = iconServiceAcknowledged ||
        [iconServiceDelivery isEqualToString:@"unavailable"];
    if (state == nil || ![response[@"generationIdentifier"]
            isEqual:generationIdentifier] ||
        ![reused isKindOfClass:NSNumber.class]) {
        if (state != nil && error != NULL) {
            *error = MTRuntimeHelperClientError(5,
                @"The Runtime Helper Apply response is invalid.");
        }
        return nil;
    }
    if (!iconServiceDeliveryValid) {
        if (error != NULL) {
            *error = MTRuntimeHelperClientError(5,
                @"The Runtime Helper omitted IconServices delivery.");
        }
        return nil;
    }
    return [[MTRuntimeApplyResult alloc]
        initWithGenerationIdentifier:generationIdentifier
        reusedExistingGeneration:[reused boolValue]
        state:state
        iconServiceAcknowledged:iconServiceAcknowledged];
}

- (MTRuntimeState *)committedMutationStateFromResponse:
    (NSDictionary<NSString *, id> *)response
                               expectedOperation:(NSString *)expectedOperation
                                  expectedStatus:(NSString *)expectedStatus
                                           error:(NSError **)error {
    MTRuntimeState *state = [self stateFromResponse:response
                                 expectedOperation:expectedOperation
                                    expectedStatus:expectedStatus
                                             error:error];
    if (state == nil) return nil;
    BOOL iconServiceAcknowledged =
        [response[@"iconServiceDelivery"]
            isEqualToString:@"acknowledged"];
    if (!iconServiceAcknowledged) {
        if (error != NULL) {
            *error = MTRuntimeHelperClientError(7,
                @"The IconServices source did not confirm the committed state.");
        }
        return nil;
    }
    return state;
}

- (MTRuntimeState *)activateGenerationWithIdentifier:
    (NSString *)generationIdentifier
                                                        error:(NSError **)error {
    NSDictionary *response = [self runArguments:
        @[@"activate", generationIdentifier, @"--json"] error:error];
    return response == nil ? nil
        : [self committedMutationStateFromResponse:response
                expectedOperation:@"activate"
                   expectedStatus:@"activated"
                            error:error];
}

- (MTRuntimeState *)disableWithError:(NSError **)error {
    NSDictionary *response = [self runArguments:@[@"disable", @"--json"]
                                          error:error];
    return response == nil ? nil
        : [self committedMutationStateFromResponse:response
                expectedOperation:@"disable"
                   expectedStatus:@"disabled"
                            error:error];
}

- (BOOL)requestRespringWithError:(NSError **)error {
    NSDictionary *response = [self runArguments:
        @[@"reload-desktop", @"--json"] error:error];
    if (response == nil) return NO;
    if (![response[@"schemaVersion"] isEqual:@1] ||
        ![response[@"operation"] isEqual:@"reload-desktop"] ||
        ![response[@"status"] isEqual:@"requested"]) {
        if (error != NULL) {
            *error = MTRuntimeHelperClientError(5,
                @"The Runtime Helper Respring response is invalid.");
        }
        return NO;
    }
    return YES;
}

@end

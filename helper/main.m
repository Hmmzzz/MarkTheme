#import <Foundation/Foundation.h>

#import <errno.h>
#import <fcntl.h>
#import <spawn.h>
#import <stdio.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

#import "MTBootstrapPaths.h"
#import "MTGenerationReader.h"
#import "MTRuntimeInvalidation.h"
#import "MTRuntimeState.h"
#import "MTRuntimeStoreController.h"

extern char **environ;

static int MTPrintHelperJSON(NSDictionary<NSString *, id> *document) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:document
                                                   options:NSJSONWritingSortedKeys
                                                     error:&error];
    if (data == nil || fwrite(data.bytes, 1, data.length, stdout) != data.length ||
        fputc('\n', stdout) == EOF || fflush(stdout) != 0) {
        fprintf(stderr, "marktheme-helper output failure.\n");
        return 74;
    }
    return 0;
}

static NSDictionary<NSString *, id> *MTStateDictionary(MTRuntimeState *state) {
    id object = [NSJSONSerialization JSONObjectWithData:state.canonicalData
                                                options:0
                                                  error:NULL];
    return [object isKindOfClass:NSDictionary.class] ? object : @{};
}

static NSString *MTBoundedHelperErrorChain(NSError *error) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSError *current = error;
    for (NSUInteger depth = 0; current != nil && depth < 6; depth++) {
        NSString *domain = current.domain ?: @"unknown";
        NSString *detail = nil;
        if ([domain hasPrefix:@"com.hmmzzz.marktheme."]) {
            detail = current.localizedDescription;
        } else if ([domain isEqualToString:NSPOSIXErrorDomain]) {
            detail = [NSString stringWithUTF8String:strerror((int)current.code)];
        }
        if (detail.length > 0) {
            detail = [[detail
                componentsSeparatedByCharactersInSet:
                    NSCharacterSet.newlineCharacterSet]
                componentsJoinedByString:@" "];
            if (detail.length > 192) {
                detail = [[detail substringToIndex:192]
                    stringByAppendingString:@"…"];
            }
        }
        [parts addObject:detail.length > 0
            ? [NSString stringWithFormat:@"%@/%ld: %@", domain,
                (long)current.code, detail]
            : [NSString stringWithFormat:@"%@/%ld", domain,
                (long)current.code]];
        id underlying = current.userInfo[NSUnderlyingErrorKey];
        current = [underlying isKindOfClass:NSError.class]
            ? underlying : nil;
    }
    NSString *chain = [parts componentsJoinedByString:@" <- "];
    if (chain.length > 640) {
        chain = [[chain substringToIndex:640] stringByAppendingString:@"…"];
    }
    return chain.length > 0 ? chain : @"unknown error";
}

static int MTPrintHelperFailure(NSString *operation, NSError *error) {
    fprintf(stderr, "marktheme-helper %s failed (%s).\n",
            operation.UTF8String,
            MTBoundedHelperErrorChain(error).UTF8String);
    return 70;
}

static MTGeneration *MTReadInboxGeneration(NSString *identifier,
                                            NSError **error) {
    NSError *pathError = nil;
    NSURL *inboxURL = MTDefaultGenerationInboxURL(&pathError);
    if (inboxURL == nil) {
        if (error != NULL) *error = pathError;
        return nil;
    }

    uid_t originalEffectiveUserID = geteuid();
    uid_t realUserID = getuid();
    if (realUserID != originalEffectiveUserID && seteuid(realUserID) != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:nil];
        }
        return nil;
    }

    MTGenerationReaderConfiguration *configuration =
        [[MTGenerationReaderConfiguration alloc]
            initWithRootURL:inboxURL
            maximumAssetCount:20000
            maximumGenerationByteCount:1024ULL * 1024ULL * 1024ULL
            ownershipProfile:MTGenerationReaderOwnershipProfilePrivate];
    MTGeneration *generation = [[[MTGenerationReader alloc]
        initWithConfiguration:configuration]
        readGenerationWithIdentifier:identifier
        cancellationToken:nil
        error:error];

    if (geteuid() != originalEffectiveUserID &&
        seteuid(originalEffectiveUserID) != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:errno
                                     userInfo:nil];
        }
        return nil;
    }
    return generation;
}

static BOOL MTIdentifierCommandArgumentsAreValid(int argc,
                                                  const char *argv[]) {
    return argc == 4 && argv[2][0] != '\0' &&
        strcmp(argv[3], "--json") == 0;
}

static BOOL MTRequestDesktopReload(NSError **error) {
    NSString *resolvedExecutable = [MTBootstrapPathResolver.currentResolver
        resolvedPathForLogicalPath:MTDesktopReloadExecutableLogicalPath
                               error:error];
    if (resolvedExecutable == nil) return NO;
    const char *executable = resolvedExecutable.fileSystemRepresentation;
    posix_spawn_file_actions_t actions;
    int actionResult = posix_spawn_file_actions_init(&actions);
    if (actionResult != 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:actionResult
                                     userInfo:nil];
        }
        return NO;
    }
    if (actionResult == 0) {
        actionResult = posix_spawn_file_actions_addopen(
            &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    }
    if (actionResult == 0) {
        actionResult = posix_spawn_file_actions_addopen(
            &actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    }
    if (actionResult == 0) {
        actionResult = posix_spawn_file_actions_addopen(
            &actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    }
    if (actionResult != 0) {
        posix_spawn_file_actions_destroy(&actions);
        if (error != NULL) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:actionResult
                                     userInfo:nil];
        }
        return NO;
    }
    char *arguments[] = {(char *)executable, NULL};
    pid_t child = 0;
    int spawnResult = posix_spawn(&child, executable, &actions, NULL,
                                  arguments, environ);
    (void)child;
    posix_spawn_file_actions_destroy(&actions);
    if (spawnResult != 0 && error != NULL) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                     code:spawnResult
                                 userInfo:nil];
    }
    return spawnResult == 0;
}

static int MTPrintInvalidArguments(int argc, const char *argv[]) {
    const char *operation = argc > 1 && argv[1] != NULL ? argv[1] : NULL;
    BOOL knownOperation = operation != NULL &&
        (strcmp(operation, "status") == 0 ||
         strcmp(operation, "publish") == 0 ||
         strcmp(operation, "activate") == 0 ||
         strcmp(operation, "apply") == 0 ||
         strcmp(operation, "rollback") == 0 ||
         strcmp(operation, "disable") == 0 ||
         strcmp(operation, "reload-desktop") == 0);
    size_t identifierLength = argc > 2 && argv[2] != NULL
        ? strnlen(argv[2], 256) : 0;
    int jsonIndex = -1;
    for (int index = 1; index < argc && index < 8; index++) {
        if (argv[index] != NULL && strcmp(argv[index], "--json") == 0) {
            jsonIndex = index;
            break;
        }
    }
    fprintf(stderr,
        "marktheme-helper invalid request (argc=%d, operation=%s, "
        "identifierLength=%zu, jsonIndex=%d).\n",
        argc, knownOperation ? operation : "unknown",
        identifierLength, jsonIndex);
    return 64;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        umask(022);
        if (argc == 2 && strcmp(argv[1], "--version") == 0) {
            fprintf(stdout, "marktheme-helper 1.0\n");
            return 0;
        }
        if (geteuid() != 0 || (getuid() != 0 && getuid() != 501)) {
            fprintf(stderr, "marktheme-helper requires its installed root transition.\n");
            return 77;
        }
        if (setegid(0) != 0) {
            fprintf(stderr, "marktheme-helper could not select the wheel group.\n");
            return 77;
        }

        BOOL statusCommand = argc >= 2 && strcmp(argv[1], "status") == 0;
        BOOL publishCommand = argc >= 2 && strcmp(argv[1], "publish") == 0;
        BOOL activateCommand = argc >= 2 && strcmp(argv[1], "activate") == 0;
        BOOL applyCommand = argc >= 2 && strcmp(argv[1], "apply") == 0;
        BOOL rollbackCommand = argc >= 2 && strcmp(argv[1], "rollback") == 0;
        BOOL disableCommand = argc >= 2 && strcmp(argv[1], "disable") == 0;
        BOOL reloadDesktopCommand =
            argc >= 2 && strcmp(argv[1], "reload-desktop") == 0;
        BOOL noIdentifierArgumentsValid =
            (statusCommand || rollbackCommand || disableCommand ||
             reloadDesktopCommand) &&
            argc == 3 && strcmp(argv[2], "--json") == 0;
        BOOL identifierArgumentsValid =
            (publishCommand || activateCommand || applyCommand) &&
            MTIdentifierCommandArgumentsAreValid(argc, argv);
        if (!noIdentifierArgumentsValid && !identifierArgumentsValid) {
            return MTPrintInvalidArguments(argc, argv);
        }

        NSError *error = nil;
        if (reloadDesktopCommand) {
            if (!MTRequestDesktopReload(&error)) {
                return MTPrintHelperFailure(@"reload-desktop", error);
            }
            return MTPrintHelperJSON(@{
                @"operation" : @"reload-desktop",
                @"schemaVersion" : @1,
                @"status" : @"requested",
            });
        }
        MTRuntimeStoreController *controller =
            [MTRuntimeStoreController defaultControllerWithError:&error];
        if (controller == nil) return MTPrintHelperFailure(@"open", error);

        if (statusCommand) {
            MTRuntimeState *state = [controller currentStateWithError:&error];
            if (state == nil) return MTPrintHelperFailure(@"status", error);
            return MTPrintHelperJSON(@{
                @"operation" : @"status",
                @"schemaVersion" : @1,
                @"state" : MTStateDictionary(state),
                @"status" : @"ready",
            });
        }

        NSString *identifier = identifierArgumentsValid
            ? [NSString stringWithUTF8String:argv[2]] : nil;
        if (identifierArgumentsValid && identifier == nil) {
            fprintf(stderr, "marktheme-helper received a non-UTF-8 generation identifier.\n");
            return 64;
        }
        MTRuntimePublishResult *publishResult = nil;
        if (publishCommand || applyCommand) {
            if (identifier == nil) return 64;
            MTGeneration *generation = MTReadInboxGeneration(identifier, &error);
            if (generation == nil) return MTPrintHelperFailure(@"read-inbox", error);
            publishResult = [controller publishGeneration:generation
                                        cancellationToken:nil
                                                     error:&error];
            if (publishResult == nil) {
                return MTPrintHelperFailure(@"publish", error);
            }
            if (publishCommand) {
                return MTPrintHelperJSON(@{
                    @"generationIdentifier" : publishResult.generationIdentifier,
                    @"operation" : @"publish",
                    @"reusedExistingGeneration" :
                        @(publishResult.reusedExistingGeneration),
                    @"schemaVersion" : @1,
                    @"status" : publishResult.reusedExistingGeneration
                        ? @"reused" : @"published",
                });
            }
        }

        MTRuntimeState *state = nil;
        NSString *operation = nil;
        NSString *status = nil;
        if (activateCommand || applyCommand) {
            if (identifier == nil) return 64;
            state = [controller activateGenerationWithIdentifier:identifier
                                                            error:&error];
            operation = applyCommand ? @"apply" : @"activate";
            status = applyCommand ? @"applied" : @"activated";
        } else if (rollbackCommand) {
            state = [controller rollbackWithError:&error];
            operation = @"rollback";
            status = @"rolledBack";
        } else if (disableCommand) {
            state = [controller disableWithError:&error];
            operation = @"disable";
            status = @"disabled";
        }
        if (state == nil) return MTPrintHelperFailure(operation, error);
        BOOL runtimeAcknowledged = applyCommand
            ? MTRuntimePostInvalidationAndWaitForAcknowledgement(
                state.sequence)
            : MTRuntimePostInvalidation();

        NSMutableDictionary<NSString *, id> *response = [@{
            @"operation" : operation,
            @"schemaVersion" : @1,
            @"state" : MTStateDictionary(state),
            @"status" : status,
        } mutableCopy];
        if (identifier != nil) response[@"generationIdentifier"] = identifier;
        if (publishResult != nil) {
            response[@"reusedExistingGeneration"] =
                @(publishResult.reusedExistingGeneration);
        }
        if (applyCommand) {
            response[@"runtimeDelivery"] = runtimeAcknowledged
                ? @"acknowledged" : @"reloadRequired";
        }
        return MTPrintHelperJSON(response);
    }
}

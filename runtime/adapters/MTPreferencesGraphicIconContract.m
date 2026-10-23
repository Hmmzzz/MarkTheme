#import "MTPreferencesGraphicIconContract.h"

#import <objc/runtime.h>

#include <string.h>

BOOL MTPreferencesGraphicIconTypeIsSupported(NSString *type) {
    static NSString *const prefix = @"com.apple.graphic-icon.";
    if (![type isKindOfClass:NSString.class] ||
        ![type hasPrefix:prefix] || type.length <= prefix.length ||
        type.length > 192) {
        return NO;
    }
    for (NSUInteger index = prefix.length; index < type.length; index++) {
        unichar character = [type characterAtIndex:index];
        if (!((character >= 'a' && character <= 'z') ||
              (character >= '0' && character <= '9') ||
              character == '-' || character == '.')) {
            return NO;
        }
    }
    return YES;
}

// Apple Blocks ABI (Clang's Block Implementation Specification). We inspect
// only genuine compiler-created blocks and never invoke a raw function pointer.
typedef struct MTPreferencesBlockLiteral {
    const void *isa;
    int flags;
    int reserved;
    const void *invoke;
    const void *descriptor;
} MTPreferencesBlockLiteral;

static BOOL MTPreferencesObjectIsBlock(id object) {
    static Class blockRoot;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class candidate = object_getClass(^{ });
        while (candidate != Nil) {
            Class parent = class_getSuperclass(candidate);
            if (parent == NSObject.class) {
                blockRoot = candidate;
                break;
            }
            candidate = parent;
        }
    });
    if (object == nil || blockRoot == Nil) return NO;
    // Use runtime ancestry rather than an overridable isKindOfClass: result.
    for (Class candidate = object_getClass(object); candidate != Nil;
         candidate = class_getSuperclass(candidate)) {
        if (candidate == blockRoot) return YES;
    }
    return NO;
}

static BOOL MTPreferencesEncodingIsObject(const char *encoding) {
    return encoding != NULL && encoding[0] == '@' &&
        (encoding[1] == '\0' || encoding[1] == '"');
}

MTPreferencesGraphicCompletionShape
MTPreferencesGraphicIconCompletionShape(id completion) {
    if (!MTPreferencesObjectIsBlock(completion)) {
        return MTPreferencesGraphicCompletionUnsupported;
    }
    const MTPreferencesBlockLiteral *literal =
        (__bridge const void *)completion;
    const int hasCopyDispose = 1 << 25;
    const int hasStret = 1 << 29;
    const int hasSignature = 1 << 30;
    if ((literal->flags & hasSignature) == 0 ||
        (literal->flags & hasStret) != 0 || literal->descriptor == NULL) {
        return MTPreferencesGraphicCompletionUnsupported;
    }
    const unsigned char *cursor = literal->descriptor;
    cursor += 2 * sizeof(unsigned long);
    if ((literal->flags & hasCopyDispose) != 0) {
        cursor += 2 * sizeof(void *);
    }
    const char *encoding = NULL;
    memcpy(&encoding, cursor, sizeof(encoding));
    if (encoding == NULL || strnlen(encoding, 256) == 256) {
        return MTPreferencesGraphicCompletionUnsupported;
    }
    @try {
        NSMethodSignature *signature =
            [NSMethodSignature signatureWithObjCTypes:encoding];
        NSUInteger argumentCount = signature.numberOfArguments;
        if (signature == nil ||
            strcmp(signature.methodReturnType, @encode(void)) != 0 ||
            (argumentCount != 2 && argumentCount != 3) ||
            strcmp([signature getArgumentTypeAtIndex:0], "@?") != 0 ||
            !MTPreferencesEncodingIsObject(
                [signature getArgumentTypeAtIndex:1]) ||
            (argumentCount == 3 && !MTPreferencesEncodingIsObject(
                [signature getArgumentTypeAtIndex:2]))) {
            return MTPreferencesGraphicCompletionUnsupported;
        }
        return argumentCount == 2
            ? MTPreferencesGraphicCompletionImage
            : MTPreferencesGraphicCompletionImageAndError;
    } @catch (__unused NSException *exception) {
        return MTPreferencesGraphicCompletionUnsupported;
    }
}

id MTPreferencesGraphicIconWrapCompletion(
    id completion,
    MTPreferencesGraphicImageTransform transform) {
    MTPreferencesGraphicCompletionShape shape =
        MTPreferencesGraphicIconCompletionShape(completion);
    if (shape == MTPreferencesGraphicCompletionImage) {
        void (^callback)(id) = [completion copy];
        return [^(id image) {
            id result = image == nil ? nil : (transform(image) ?: image);
            callback(result);
        } copy];
    }
    if (shape == MTPreferencesGraphicCompletionImageAndError) {
        void (^callback)(id, id) = [completion copy];
        return [^(id image, id error) {
            id result = image == nil || error != nil
                ? image : (transform(image) ?: image);
            callback(result, error);
        } copy];
    }
    return completion;
}

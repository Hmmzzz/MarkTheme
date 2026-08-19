#import "MTIdentifier.h"

NSString *const MTIdentifierErrorDomain = @"com.hmmzzz.marktheme.identifier";

static BOOL MTIdentifierCharacterIsAlphanumeric(unichar character) {
    return (character >= 'a' && character <= 'z') ||
           (character >= '0' && character <= '9');
}

BOOL MTIdentifierIsValid(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class]) return NO;

    NSData *utf8 = [identifier dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8.length == 0 || utf8.length > 128 || identifier.length == 0) {
        return NO;
    }

    unichar first = [identifier characterAtIndex:0];
    unichar last = [identifier characterAtIndex:identifier.length - 1];
    if (!MTIdentifierCharacterIsAlphanumeric(first) ||
        !MTIdentifierCharacterIsAlphanumeric(last)) {
        return NO;
    }

    BOOL previousWasSeparator = NO;
    for (NSUInteger index = 0; index < identifier.length; index++) {
        unichar character = [identifier characterAtIndex:index];
        if (MTIdentifierCharacterIsAlphanumeric(character)) {
            previousWasSeparator = NO;
            continue;
        }
        BOOL isSeparator =
            character == '.' || character == '-' || character == '_';
        if (!isSeparator || previousWasSeparator) return NO;
        previousWasSeparator = YES;
    }
    return YES;
}

NSString *MTNormalizeIdentifier(NSString *identifier, NSError **error) {
    if (![identifier isKindOfClass:NSString.class]) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTIdentifierErrorDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey : @"Identifier must be a string."
            }];
        }
        return nil;
    }

    NSString *normalized = [[identifier precomposedStringWithCanonicalMapping]
        lowercaseStringWithLocale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    if (!MTIdentifierIsValid(normalized)) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:MTIdentifierErrorDomain
                                         code:2
                                     userInfo:@{
                NSLocalizedDescriptionKey :
                    @"Identifier is not stable lowercase ASCII."
            }];
        }
        return nil;
    }
    return normalized;
}

#import "MTCanonicalJSON.h"

#import <CoreFoundation/CoreFoundation.h>

NSString *const MTCanonicalJSONErrorDomain =
    @"com.hmmzzz.marktheme64e.canonical-json";

static BOOL MTCanonicalJSONSetError(NSError **error,
                                    NSInteger code,
                                    NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:MTCanonicalJSONErrorDomain
                                     code:code
                                 userInfo:@{
            NSLocalizedDescriptionKey : description
        }];
    }
    return NO;
}

static BOOL MTAppendUTF8(NSMutableData *output,
                         NSString *string,
                         NSError **error) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding
                        allowLossyConversion:NO];
    if (data == nil) {
        return MTCanonicalJSONSetError(error, 2,
            @"Canonical JSON contains an invalid Unicode string.");
    }
    [output appendData:data];
    return YES;
}

static BOOL MTAppendJSONString(NSMutableData *output,
                               NSString *string,
                               NSError **error) {
    NSString *normalized = [string precomposedStringWithCanonicalMapping];
    NSMutableString *escaped = [NSMutableString stringWithString:@"\""];
    for (NSUInteger index = 0; index < normalized.length; index++) {
        unichar character = [normalized characterAtIndex:index];
        switch (character) {
            case '"':
                [escaped appendString:@"\\\""];
                break;
            case '\\':
                [escaped appendString:@"\\\\"];
                break;
            case '\b':
                [escaped appendString:@"\\b"];
                break;
            case '\f':
                [escaped appendString:@"\\f"];
                break;
            case '\n':
                [escaped appendString:@"\\n"];
                break;
            case '\r':
                [escaped appendString:@"\\r"];
                break;
            case '\t':
                [escaped appendString:@"\\t"];
                break;
            default:
                if (character < 0x20) {
                    [escaped appendFormat:@"\\u%04x", character];
                } else if (CFStringIsSurrogateHighCharacter(character)) {
                    if (index + 1 >= normalized.length) {
                        return MTCanonicalJSONSetError(error, 2,
                            @"Canonical JSON contains an unpaired surrogate.");
                    }
                    unichar low = [normalized characterAtIndex:index + 1];
                    if (!CFStringIsSurrogateLowCharacter(low)) {
                        return MTCanonicalJSONSetError(error, 2,
                            @"Canonical JSON contains an unpaired surrogate.");
                    }
                    unichar pair[] = { character, low };
                    [escaped appendString:[NSString stringWithCharacters:pair
                                                                   length:2]];
                    index++;
                } else if (CFStringIsSurrogateLowCharacter(character)) {
                    return MTCanonicalJSONSetError(error, 2,
                        @"Canonical JSON contains an unpaired surrogate.");
                } else {
                    [escaped appendString:[NSString stringWithCharacters:&character
                                                                   length:1]];
                }
                break;
        }
    }
    [escaped appendString:@"\""];
    return MTAppendUTF8(output, escaped, error);
}

static BOOL MTIntegerStringIsCanonical(NSString *value) {
    if (value.length == 0) return NO;
    NSUInteger index = 0;
    if ([value characterAtIndex:0] == '-') {
        if (value.length == 1) return NO;
        index = 1;
    }
    if ([value characterAtIndex:index] == '0' && index + 1 < value.length) {
        return NO;
    }
    for (; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        if (character < '0' || character > '9') return NO;
    }
    return ![value isEqualToString:@"-0"];
}

static BOOL MTAppendCanonicalObject(NSMutableData *output,
                                    id object,
                                    NSUInteger depth,
                                    NSUInteger *nodeCount,
                                    NSError **error) {
    if (depth > 64 || ++(*nodeCount) > 100000) {
        return MTCanonicalJSONSetError(error, 3,
            @"Canonical JSON exceeds its depth or node limit.");
    }

    if ([object isKindOfClass:NSString.class]) {
        return MTAppendJSONString(output, object, error);
    }

    if ([object isKindOfClass:NSNumber.class]) {
        NSNumber *number = object;
        if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) {
            return MTAppendUTF8(output, number.boolValue ? @"true" : @"false",
                                error);
        }
        const char *type = number.objCType;
        if (type == NULL || type[0] == 'f' || type[0] == 'd') {
            return MTCanonicalJSONSetError(error, 4,
                @"Canonical JSON does not accept floating-point values.");
        }
        NSString *value = number.stringValue;
        if (!MTIntegerStringIsCanonical(value)) {
            return MTCanonicalJSONSetError(error, 4,
                @"Canonical JSON contains a non-canonical integer.");
        }
        return MTAppendUTF8(output, value, error);
    }

    if (object == NSNull.null) {
        return MTAppendUTF8(output, @"null", error);
    }

    if ([object isKindOfClass:NSArray.class]) {
        [output appendBytes:"[" length:1];
        NSArray *array = object;
        for (NSUInteger index = 0; index < array.count; index++) {
            if (index > 0) [output appendBytes:"," length:1];
            if (!MTAppendCanonicalObject(output, array[index], depth + 1,
                                         nodeCount, error)) {
                return NO;
            }
        }
        [output appendBytes:"]" length:1];
        return YES;
    }

    if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = object;
        NSMutableDictionary<NSString *, id> *valuesByCanonicalKey =
            [NSMutableDictionary dictionaryWithCapacity:dictionary.count];
        for (id key in dictionary) {
            if (![key isKindOfClass:NSString.class]) {
                return MTCanonicalJSONSetError(error, 5,
                    @"Canonical JSON dictionary keys must be strings.");
            }
            NSString *canonicalKey =
                [key precomposedStringWithCanonicalMapping];
            if (valuesByCanonicalKey[canonicalKey] != nil) {
                return MTCanonicalJSONSetError(error, 5,
                    @"Canonical JSON dictionary keys collide after NFC normalization.");
            }
            valuesByCanonicalKey[canonicalKey] = dictionary[key];
        }
        NSArray<NSString *> *keys = [valuesByCanonicalKey.allKeys
            sortedArrayUsingComparator:^NSComparisonResult(NSString *left,
                                                            NSString *right) {
                return [left compare:right options:NSLiteralSearch];
            }];
        [output appendBytes:"{" length:1];
        for (NSUInteger index = 0; index < keys.count; index++) {
            if (index > 0) [output appendBytes:"," length:1];
            NSString *key = keys[index];
            if (!MTAppendJSONString(output, key, error)) return NO;
            [output appendBytes:":" length:1];
            if (!MTAppendCanonicalObject(output, valuesByCanonicalKey[key],
                                         depth + 1, nodeCount, error)) {
                return NO;
            }
        }
        [output appendBytes:"}" length:1];
        return YES;
    }

    return MTCanonicalJSONSetError(error, 6,
        @"Canonical JSON contains an unsupported object type.");
}

NSData *MTCanonicalJSONData(id object, NSError **error) {
    if (object == nil) {
        MTCanonicalJSONSetError(error, 1,
            @"Canonical JSON root cannot be nil.");
        return nil;
    }
    NSMutableData *output = [NSMutableData data];
    NSUInteger nodeCount = 0;
    if (!MTAppendCanonicalObject(output, object, 0, &nodeCount, error)) {
        return nil;
    }
    return [output copy];
}

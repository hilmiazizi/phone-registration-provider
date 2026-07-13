// Minimal `gestalt` CLI: prints MGCopyAnswer() for each key argument.
// Because this binary is named "gestalt" (and "gestalt" is in MGSpoof's
// injection filter), MGSpoof injects into it - so the values printed here are
// exactly what the IDS/APNs daemons see. With no /var/mobile/.mgspoof.plist it
// prints the REAL values; with one present it prints the ROTATED values.

#import <Foundation/Foundation.h>

extern CFPropertyListRef MGCopyAnswer(CFStringRef question);

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: gestalt <Key> [<Key> ...]\n");
            return 2;
        }
        for (int i = 1; i < argc; i++) {
            CFStringRef key = CFStringCreateWithCString(NULL, argv[i], kCFStringEncodingUTF8);
            CFPropertyListRef val = MGCopyAnswer(key);
            id obj = (__bridge id)val;
            NSString *desc = obj ? [obj description] : @"(null)";
            printf("%s: %s\n", argv[i], [desc UTF8String]);
            if (val) CFRelease(val);
            CFRelease(key);
        }
    }
    return 0;
}

// idextract — dump the IDS identity from INSIDE identityservicesd.
//
// keychain_dumper failed because it ran as a standalone binary without the
// `com.apple.identities` keychain-access-group and couldn't read the
// ThisDeviceOnly-protected items. Loaded into identityservicesd via ellekit,
// this tweak inherits the daemon's entitlements + access groups, so
// SecItemCopyMatching returns the *decrypted* key/cert/token bytes.
//
// Output: /var/mobile/idextract.json  (array of keychain items, data base64'd)
// Trigger: `killall identityservicesd` (launchd respawns it) with the device
//          UNLOCKED. Dump runs ~8s after launch.

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <sys/stat.h>

static NSString *const kOutPath = @"/var/mobile/idextract.json";

static id sanitize(id v) {
    if ([v isKindOfClass:[NSData class]]) {
        return @{ @"__b64__": [(NSData *)v base64EncodedStringWithOptions:0] };
    }
    if ([v isKindOfClass:[NSDate class]]) {
        return [(NSDate *)v description];
    }
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) {
        return v;
    }
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id e in (NSArray *)v) [out addObject:sanitize(e)];
        return out;
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        [(NSDictionary *)v enumerateKeysAndObjectsUsingBlock:^(id k, id val, BOOL *s) {
            out[[k description]] = sanitize(val);
        }];
        return out;
    }
    return [v description];
}

static void dumpClass(NSString *clsName, CFTypeRef secClass, NSMutableArray *acc) {
    NSDictionary *q = @{
        (__bridge id)kSecClass:            (__bridge id)secClass,
        (__bridge id)kSecMatchLimit:       (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnData:       @YES,
    };
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (st != errSecSuccess || result == NULL) {
        NSLog(@"[idextract] class %@ -> status %d", clsName, (int)st);
        return;
    }
    NSArray *items = (__bridge_transfer NSArray *)result;
    for (NSDictionary *it in items) {
        NSMutableDictionary *row = [sanitize(it) mutableCopy];
        row[@"__class__"] = clsName;
        [acc addObject:row];
    }
    NSLog(@"[idextract] class %@ -> %lu items", clsName, (unsigned long)items.count);
}

static void runDump(void) {
    @autoreleasepool {
        NSMutableArray *acc = [NSMutableArray array];
        dumpClass(@"genp", kSecClassGenericPassword,  acc);
        dumpClass(@"inet", kSecClassInternetPassword, acc);
        dumpClass(@"cert", kSecClassCertificate,      acc);
        dumpClass(@"keys", kSecClassKey,              acc);
        dumpClass(@"idnt", kSecClassIdentity,         acc);

        NSError *err = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:acc
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&err];
        if (!json) { NSLog(@"[idextract] json error: %@", err); return; }
        if ([json writeToFile:kOutPath atomically:YES]) {
            chmod(kOutPath.fileSystemRepresentation, 0666);
            NSLog(@"[idextract] wrote %lu items to %@", (unsigned long)acc.count, kOutPath);
        } else {
            NSLog(@"[idextract] FAILED to write %@", kOutPath);
        }
    }
}

%ctor {
    // Only act inside identityservicesd (the filter plist already restricts this,
    // but double-check the executable to be safe).
    NSString *exe = [[NSProcessInfo processInfo] processName];
    if (![exe isEqualToString:@"identityservicesd"]) return;

    NSLog(@"[idextract] loaded into %@, scheduling dump in 8s", exe);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        runDump();
    });
}

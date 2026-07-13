#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// DeviceIdentityIssueClientCertificateWithCompletion ABI (IDS @ 0x1001e7d80):
//   x0 = dispatch_queue_t
//   x1 = CFDictionaryRef options
//   x2 = void (^)(SecKeyRef, NSArray *, NSError *)   // also try NSDictionary form

static void bw_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void bw_log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[baawipe] %@", msg);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSString *path = @"/var/mobile/baawipe.log";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static NSString *bw_proc(void) {
    return [[NSProcessInfo processInfo] processName];
}

static BOOL bw_armed_for_me(void) {
    NSString *proc = bw_proc();
    NSString *specific = [NSString stringWithFormat:@"/var/mobile/.baawipe_%@", proc];
    if ([[NSFileManager defaultManager] fileExistsAtPath:specific]) {
        [[NSFileManager defaultManager] removeItemAtPath:specific error:nil];
        return YES;
    }
    // generic arm: only first process wins; prefer per-proc flags
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/.baawipe"]) {
        [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/.baawipe" error:nil];
        return YES;
    }
    return NO;
}

static CFStringRef bw_cfstr(void *handle, const char *sym) {
    CFStringRef *p = (CFStringRef *)dlsym(handle, sym);
    if (!p || !*p) return NULL;
    return *p;
}

static void bw_dump_arg(NSString *name, id obj) {
    if (!obj) { bw_log(@"%@ = nil", name); return; }
    bw_log(@"%@ class=%@ desc=%@", name, NSStringFromClass([obj class]), obj);
}

%ctor {
    if (!bw_armed_for_me()) {
        bw_log(@"%@ loaded unarmed", bw_proc());
        return;
    }
    bw_log(@"%@ ARMED", bw_proc());

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        void *ma = dlopen(
            "/System/Library/PrivateFrameworks/MobileActivation.framework/MobileActivation",
            RTLD_NOW);
        void *di = dlopen(
            "/System/Library/PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity",
            RTLD_NOW);
        if (!di) { bw_log(@"DeviceIdentity dlopen fail: %s", dlerror()); return; }

        // Resolve real option key strings from MobileActivation exports
        NSMutableDictionary *opts = [NSMutableDictionary dictionary];
        if (ma) {
            struct { const char *sym; id value; } pairs[] = {
                { "kMAOptionsBAAValidity", @((unsigned)525600) },
                { "kMAOptionsBAADeleteExistingKeysAndCerts", @YES },
                { "kMAOptionsBAAOIDUCRTDeviceIdentifiers", @YES },
                { NULL, nil }
            };
            for (int i = 0; pairs[i].sym; i++) {
                CFStringRef key = bw_cfstr(ma, pairs[i].sym);
                if (key) {
                    opts[(__bridge NSString *)key] = pairs[i].value;
                    bw_log(@"resolved %s -> %@", pairs[i].sym, (__bridge NSString *)key);
                } else {
                    bw_log(@"missing export %s", pairs[i].sym);
                }
            }
            CFStringRef labelKey = bw_cfstr(ma, "kMAOptionsBAAKeychainLabel");
            if (labelKey) {
                NSString *label = nil;
                NSString *proc = bw_proc();
                if ([proc isEqualToString:@"locationd"])
                    label = @"com.apple.locationd.BAA";
                else
                    label = @"com.apple.identityservicesd"; // try agrp we still have
                opts[(__bridge NSString *)labelKey] = label;
                bw_log(@"labelKey=%@ label=%@", (__bridge NSString *)labelKey, label);
            }
            // OIDUCRT / OIDDeviceOSInformation are option KEYs (booleans), not OID values.
            CFStringRef oidOS = bw_cfstr(ma, "kMAOptionsBAAOIDDeviceOSInformation");
            if (oidOS) {
                opts[(__bridge NSString *)oidOS] = @YES;
                bw_log(@"set OIDDeviceOSInformation");
            }
        } else {
            bw_log(@"MobileActivation dlopen fail, using raw string keys");
            opts[@"Validity"] = @((unsigned)525600);
            opts[@"DeleteExistingKeysAndCerts"] = @YES;
            opts[@"KeychainLabel"] = [bw_proc() isEqualToString:@"locationd"]
                ? @"com.apple.locationd.BAA"
                : @"com.apple.identityservicesd";
        }

        bw_log(@"opts=%@", opts);

        typedef void (*DIFunc)(dispatch_queue_t, CFDictionaryRef, id);
        DIFunc fn = (DIFunc)dlsym(di, "DeviceIdentityIssueClientCertificateWithCompletion");
        if (!fn) { bw_log(@"dlsym fail"); return; }

        // Use a raw 3-id block so we can see actual arg types regardless of typedef
        id cb = [^(id a, id b, id c) {
            bw_log(@"completion fired");
            bw_dump_arg(@"arg0", a);
            bw_dump_arg(@"arg1", b);
            bw_dump_arg(@"arg2", c);
            NSString *path = @"/private/var/containers/Data/System/"
                @"1598C2CD-DBDB-410C-8455-8BA776C14C49/Library/dcrt/dcrt.der";
            NSData *der = [NSData dataWithContentsOfFile:path];
            bw_log(@"dcrt present=%d len=%lu", der != nil, (unsigned long)der.length);
            if (der) [der writeToFile:@"/var/mobile/dcrt_after_baawipe.der" atomically:YES];
        } copy];

        dispatch_queue_t q =
            dispatch_queue_create("com.zeroday.baawipe", DISPATCH_QUEUE_SERIAL);
        bw_log(@"calling DeviceIdentity...");
        fn(q, (__bridge CFDictionaryRef)opts, cb);
        bw_log(@"call returned (async)");
    });
}

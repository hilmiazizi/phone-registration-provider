// idsbaa — force the iMessage validation down the software Absinthe (baa:false)
// path inside identityservicesd, instead of the SEP-backed BAA (baa:true) path
// that locks the registration to the real serial.
//
// Static RE of identityservicesd (iOS 15.8.5) showed class IDSValidationQueue
// drives the decision with two independent senders:
//   -_sendBAAValidationRequestIfNeededForSubsystem:       (SEP BAA cert -> baa:true)
//   -_sendAbsintheValidationCertRequestIfNeededForSubsystem: (software cert)
// gated under  -buildValidationCredentialsIfNeededForSubsystem:.
//
// This tweak runs in two modes (controlled by flag files, no rebuild needed):
//   * LOG-ONLY (default): logs every call + the subsystem, calls %orig. Use this
//     to confirm the live ordering during a real registration.
//   * KILL-BAA  (touch /var/mobile/.idsbaa_kill): the BAA sender becomes a no-op
//     so only the software Absinthe cert is fetched -> validation should emit
//     absinthe-baa:false carrying the (spoofed) gestalt serial.
//
// Logs to /var/mobile/idsbaa.log (NSLog capture over SSH is unreliable; a file
// is authoritative) AND NSLog for the unified-log pipeline.

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <sys/stat.h>

static NSString *const kLogPath   = @"/var/mobile/idsbaa.log";
static NSString *const kKillFlag  = @"/var/mobile/.idsbaa_kill";       // force baa:false (no BAA cert)
static NSString *const kSpoofFlag = @"/var/mobile/.idsbaa_spoofserial"; // override absinthe serial/udid/imei from .mgspoof.plist
static NSString *const kInvFlag   = @"/var/mobile/.idsbaa_invalidate"; // evict cached validation/registration once
static NSString *const kLogoutFlag = @"/var/mobile/.idsbaa_logout";    // full IDS keychain logout once
static NSString *const kDumpFlag  = @"/var/mobile/.idsbaa_dump";       // enumerate reachable keychain items (decrypted attrs)
static NSString *const kPurgeFlag = @"/var/mobile/.idsbaa_purgeacct";  // delete every reachable item whose svce/acct/label holds the Apple ID

static NSString *spoofVal(NSString *key) {
    static NSDictionary *m = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ m = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/.mgspoof.plist"] ?: @{}; });
    return m[key];
}

static dispatch_queue_t logq(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("idsbaa.log", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static void logln(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[idsbaa] %@", msg);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [NSDate date], msg];
    dispatch_async(logq(), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:kLogPath]) {
            [line writeToFile:kLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
            chmod(kLogPath.fileSystemRepresentation, 0666);
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    });
}

static BOOL flag(NSString *p) {
    return [[NSFileManager defaultManager] fileExistsAtPath:p];
}

// Delete the cached validation/registration material so the daemon is FORCED to
// rebuild validation on next registration (which fires the hooks below). Runs
// from inside identityservicesd, so it has the access groups to do it.
// Leaves the Apple ID AuthToken + lockdown activation identity intact (no re-login).
static int delItem(CFTypeRef cls, NSString *agrp, NSString *svce, NSString *acct) {
    NSMutableDictionary *q = [@{ (__bridge id)kSecClass: (__bridge id)cls,
        // match BOTH local and iCloud-Keychain-synced copies (default = local only)
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny } mutableCopy];
    if (agrp) q[(__bridge id)kSecAttrAccessGroup] = agrp;
    if (svce) q[(__bridge id)kSecAttrService]     = svce;
    if (acct) q[(__bridge id)kSecAttrAccount]     = acct;
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef)q);
    logln(@"  delItem agrp=%@ svce=%@ acct=%@ -> %d", agrp, svce, acct, (int)st);
    return (int)st;
}

static void invalidateValidationState(void) {
    logln(@"INVALIDATE: dropping cached BAA + registration material");
    // BAA validation blob + anti-replay state (all *-ucrt under mobileactivationd)
    delItem(kSecClassGenericPassword, @"com.apple.identityservicesd", @"com.apple.mobileactivationd", nil);
    // iMessage registration record (carries private-device-data / serial)
    delItem(kSecClassGenericPassword, @"apple", @"com.apple.facetime", @"registrationV2");
    // IDS registration control
    delItem(kSecClassGenericPassword, @"apple", @"com.apple.ids", @"RegistrationControl-0");
}

// FULL iMessage/IDS logout: delete the account identity + auth tokens + protection
// keys from the keychain (the part nuke_accounts.sh can't touch). After this the
// device is genuinely signed out of iMessage and must re-auth from scratch.
// Leaves apsd push identity + lockdown activation identity intact.
static void fullLogout(void) {
    logln(@"LOGOUT: wiping IDS/iMessage keychain identity + tokens");
    // IDS identity RSA keys + signatures, registration control, auth tokens
    delItem(kSecClassGenericPassword, @"apple", @"ids", nil);              // identity-rsa-*
    delItem(kSecClassGenericPassword, @"apple", @"com.apple.ids", nil);    // RegistrationControl, localdevice-AuthToken
    delItem(kSecClassGenericPassword, @"apple", @"IDS", nil);              // <email>-AuthToken (all accounts)
    delItem(kSecClassGenericPassword, @"apple", @"com.apple.facetime", nil); // registrationV2
    // per-message protection keys (ichat group)
    delItem(kSecClassGenericPassword, @"ichat", nil, nil);
    // DO NOT delete mobileactivationd / identityservicesd BAA-ucrt keys here —
    // that breaks Absinthe issueClientCertificate / validation minting.
}

// Enumerate every keychain item this process (identityservicesd) can reach, with
// decrypted attributes, so we can see the real svce/acct that on-disk encryption
// hides. Logs agrp/svce/acct/label for genp + keys + cert classes.
static void dumpKeychain(void) {
    logln(@"DUMP: enumerating reachable keychain items");
    CFTypeRef classes[] = { kSecClassGenericPassword, kSecClassInternetPassword,
                            kSecClassKey, kSecClassCertificate };
    const char *names[] = { "genp", "inet", "keys", "cert" };
    for (int i = 0; i < 4; i++) {
        NSDictionary *q = @{ (__bridge id)kSecClass: (__bridge id)classes[i],
                             (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
                             (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
                             (__bridge id)kSecReturnAttributes: @YES };
        CFTypeRef res = NULL;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &res);
        if (st != errSecSuccess) { logln(@"  [%s] copy -> %d", names[i], (int)st); continue; }
        NSArray *items = (__bridge_transfer NSArray *)res;
        logln(@"  [%s] %lu items", names[i], (unsigned long)items.count);
        for (NSDictionary *it in items) {
            id agrp = it[(__bridge id)kSecAttrAccessGroup];
            id svce = it[(__bridge id)kSecAttrService];
            id acct = it[(__bridge id)kSecAttrAccount];
            id labl = it[(__bridge id)kSecAttrLabel];
            id sync = it[(__bridge id)kSecAttrSynchronizable];
            logln(@"    %s agrp=%@ svce=%@ acct=%@ lbl=%@ sync=%@", names[i], agrp, svce, acct, labl, sync);
        }
    }
    logln(@"DUMP: done");
}

// Delete every reachable item whose service/account/label string contains an
// Apple-ID / IDS marker. This reaches the credential that keeps resurrecting the
// account row, which fixed-svce deletes missed. Scoped to identityservicesd's
// access groups so it can't touch Wi-Fi / unrelated system creds.
static void purgeAppleIDItems(void) {
    logln(@"PURGE: removing reachable Apple-ID / IDS keychain items by content");
    NSArray *needles = @[ @"hilmiazizi", @"@icloud", @"@gmail", @"appleid", @"apple-id",
                          @"grandslam", @"gs.appleid", @"authkit", @"idms", @"AuthToken",
                          @"identity-rsa", @"facetime", @"madrid",
                          @"message-protection", @"profile", @"RegistrationControl",
                          @"registrationV2" ];
    // NOTE: deliberately NOT matching "ids"/"IDS"/"ucrt"/mobileactivationd —
    // those wipe Absinthe device-identity certs and break validation minting.
    CFTypeRef classes[] = { kSecClassGenericPassword, kSecClassKey, kSecClassCertificate };
    for (int i = 0; i < 3; i++) {
        NSDictionary *q = @{ (__bridge id)kSecClass: (__bridge id)classes[i],
                             (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
                             (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
                             (__bridge id)kSecReturnAttributes: @YES };
        CFTypeRef res = NULL;
        if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &res) != errSecSuccess) continue;
        NSArray *items = (__bridge_transfer NSArray *)res;
        for (NSDictionary *it in items) {
            NSString *agrp = it[(__bridge id)kSecAttrAccessGroup];
            NSString *svce = [it[(__bridge id)kSecAttrService] description] ?: @"";
            NSString *acct = [it[(__bridge id)kSecAttrAccount] description] ?: @"";
            NSString *labl = [it[(__bridge id)kSecAttrLabel] description] ?: @"";
            id      sync   = it[(__bridge id)kSecAttrSynchronizable];
            NSString *hay  = [[NSString stringWithFormat:@"%@ %@ %@", svce, acct, labl] lowercaseString];
            BOOL hit = NO;
            for (NSString *n in needles) { if ([hay containsString:[n lowercaseString]]) { hit = YES; break; } }
            // never touch Wi-Fi / push transport creds (would drop our SSH link)
            if ([agrp isEqualToString:@"com.apple.apsd"]) hit = NO;
            if ([hay containsString:@"airport"] || [hay containsString:@"wifi"]) hit = NO;
            if (!hit) continue;
            NSMutableDictionary *d = [@{ (__bridge id)kSecClass: (__bridge id)classes[i],
                // delete the matching variant (local or synced) explicitly
                (__bridge id)kSecAttrSynchronizable: (sync ?: (__bridge id)kSecAttrSynchronizableAny) } mutableCopy];
            if (agrp) d[(__bridge id)kSecAttrAccessGroup] = agrp;
            if (it[(__bridge id)kSecAttrService]) d[(__bridge id)kSecAttrService] = it[(__bridge id)kSecAttrService];
            if (it[(__bridge id)kSecAttrAccount]) d[(__bridge id)kSecAttrAccount] = it[(__bridge id)kSecAttrAccount];
            OSStatus st = SecItemDelete((__bridge CFDictionaryRef)d);
            logln(@"  PURGE del agrp=%@ svce=%@ acct=%@ sync=%@ -> %d", agrp, svce, acct, sync, (int)st);
        }
    }
    logln(@"PURGE: done");
}

// NOTE: the "subsystem" argument is a primitive (NSInteger enum), NOT an object.
// Declaring it as id makes ARC retain it -> crash (objc_retain on 0x1). Use a
// scalar type so ARC never touches it, and never %@-format it.
%hook IDSValidationQueue

- (void)buildValidationCredentialsIfNeededForSubsystem:(NSInteger)subsystem {
    logln(@"buildValidationCredentialsIfNeeded subsystem=%ld", (long)subsystem);
    %orig;
}

- (void)_sendBAAValidationRequestIfNeededForSubsystem:(NSInteger)subsystem {
    BOOL kill = flag(kKillFlag);
    logln(@"_sendBAAValidationRequestIfNeeded subsystem=%ld  kill=%d", (long)subsystem, kill);
    if (kill) {
        logln(@"  -> BAA sender SUPPRESSED (no SEP cert request); absinthe-only path");
        return;             // do NOT call %orig: never fetch the SEP BAA cert
    }
    %orig;
}

- (void)_sendAbsintheValidationCertRequestIfNeededForSubsystem:(NSInteger)subsystem {
    logln(@"_sendAbsintheValidationCertRequestIfNeeded subsystem=%ld", (long)subsystem);
    %orig;
}

%end

// Capture the EXACT device identity dict sent to Apple at registration time.
// This dict carries the serial / UniqueID / hardware-version. Comparing it to the
// spoofed gestalt tells us definitively whether the spoof propagates to Apple.
%hook IDSRegistrationMessage

- (id)privateDeviceData {
    id d = %orig;
    logln(@"privateDeviceData = %@", d);
    return d;
}

%end

// THE decisive layer. IDSValidationSession decides baa:true/false and supplies the
// hardware identity folded into the Absinthe validation-data.
//   - LOG-ONLY by default: records the live baa decision + the absinthe serial source.
//   - kKillFlag  -> force baa:false (BAA cert option / BAA-only / isUsingBAA = NO)
//   - kSpoofFlag -> override the absinthe serial/UDID/IMEI with .mgspoof.plist values
%hook IDSValidationSession

- (BOOL)isUsingBAA {
    BOOL r = %orig;
    if (flag(kKillFlag)) { logln(@"isUsingBAA orig=%d -> FORCED 0", r); return NO; }
    logln(@"isUsingBAA -> %d", r); return r;
}
- (BOOL)_shouldUseBAACertOption {
    BOOL r = %orig;
    if (flag(kKillFlag)) { logln(@"_shouldUseBAACertOption orig=%d -> FORCED 0", r); return NO; }
    logln(@"_shouldUseBAACertOption -> %d", r); return r;
}
- (BOOL)_shouldUseBAAOnly {
    BOOL r = %orig;
    if (flag(kKillFlag)) { logln(@"_shouldUseBAAOnly orig=%d -> FORCED 0", r); return NO; }
    logln(@"_shouldUseBAAOnly -> %d", r); return r;
}
- (id)_deviceAbsintheSerialNumber {
    id r = %orig;
    NSString *s = spoofVal(@"SerialNumber");
    if (flag(kSpoofFlag) && s) { logln(@"_deviceAbsintheSerialNumber orig=%@ -> SPOOF %@", r, s); return s; }
    logln(@"_deviceAbsintheSerialNumber -> %@", r); return r;
}
- (id)_deviceAbsintheUDID {
    id r = %orig;
    NSString *s = spoofVal(@"UniqueDeviceID");
    if (flag(kSpoofFlag) && s) { logln(@"_deviceAbsintheUDID orig=%@ -> SPOOF %@", r, s); return s; }
    logln(@"_deviceAbsintheUDID -> %@", r); return r;
}
- (id)_deviceAbsintheIMEI {
    id r = %orig;
    NSString *s = spoofVal(@"InternationalMobileEquipmentIdentity");
    if (flag(kSpoofFlag) && s) { logln(@"_deviceAbsintheIMEI orig=%@ -> SPOOF %@", r, s); return s; }
    logln(@"_deviceAbsintheIMEI -> %@", r); return r;
}
- (id)serialNumber {
    id r = %orig;
    logln(@"serialNumber -> %@", r); return r;
}

%end

%ctor {
    NSString *exe = [[NSProcessInfo processInfo] processName];
    BOOL isIDS = [exe isEqualToString:@"identityservicesd"];
    // akd/accountsd/apsd are loaded ONLY to enumerate/purge their keychain access
    // groups (GrandSlam / AppleAccount creds invisible to identityservicesd).
    if (!isIDS) {
        logln(@"loaded into %@ (aux keychain agent)", exe);
        if (flag(kDumpFlag))  { dumpKeychain(); }
        if (flag(kPurgeFlag)) { purgeAppleIDItems(); }
        // NOTE: do not clear the flags here; identityservicesd clears them so every
        // injected agent gets a chance to run against its own access groups.
        return;
    }
    Class c = objc_getClass("IDSValidationQueue");
    BOOL hasBuild = c && [c instancesRespondToSelector:@selector(buildValidationCredentialsIfNeededForSubsystem:)];
    BOOL hasBAA   = c && [c instancesRespondToSelector:@selector(_sendBAAValidationRequestIfNeededForSubsystem:)];
    BOOL hasAbs   = c && [c instancesRespondToSelector:@selector(_sendAbsintheValidationCertRequestIfNeededForSubsystem:)];
    logln(@"loaded into %@ (kill=%d) | IDSValidationQueue=%d build=%d baa=%d abs=%d",
          exe, flag(kKillFlag), (c != nil), hasBuild, hasBAA, hasAbs);
    // dump/purge flags are NOT cleared here: akd/accountsd/apsd agents also act on
    // them against their own access groups. The driving script removes the flags.
    if (flag(kDumpFlag))  dumpKeychain();
    if (flag(kPurgeFlag)) purgeAppleIDItems();
    if (flag(kLogoutFlag)) {
        fullLogout();
        [[NSFileManager defaultManager] removeItemAtPath:kLogoutFlag error:nil];
        logln(@"LOGOUT done; flag cleared. iMessage is now signed out.");
    }
    if (flag(kInvFlag)) {
        invalidateValidationState();
        // fire exactly once: clear the flag so subsequent respawns don't re-evict
        [[NSFileManager defaultManager] removeItemAtPath:kInvFlag error:nil];
        logln(@"INVALIDATE done; flag cleared. Daemon should now rebuild validation.");
    }
}

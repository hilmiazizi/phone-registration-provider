// Self-contained device-identity spoof for beepserv, injected into identityservicesd.
// This folds the two former research tweaks (idsbaa + MGSpoof) into beepserv itself:
//
//   * MGCopyAnswer hook  -> the NAC / validation routine reads the SPOOFED
//                           SerialNumber / UniqueDeviceID / IMEI instead of the real
//                           fused-in gestalt values.
//   * baa:false forcing  -> drives validation onto the software Absinthe path so the
//                           (spoofable) gestalt serial is folded into the blob rather
//                           than the SEP-attested real one (which can't be spoofed).
//
// Source of truth is /var/mobile/.beepserv_spoof.plist, written by the Controller
// (BPDeviceIdentifiers). Keys: SerialNumber, UniqueDeviceID,
// InternationalMobileEquipmentIdentity, Enabled (optional bool, default YES). When the
// file is absent or Enabled=NO, every hook is a transparent passthrough (stock).
//
// Scope: this dylib is only injected into identityservicesd (see the .plist filter),
// so the MGCopyAnswer override never leaks to the rest of the system.

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "./Logging.h"
#import "./bp_spoof.h"

CFPropertyListRef MGCopyAnswer(CFStringRef question);

static NSString *const kInvalidateFlag = @"/var/mobile/.beepserv_invalidate";
static NSString *const kLegacyInvalidateFlag = @"/var/mobile/.idsbaa_invalidate";
static NSString *const kKillFlag = @"/var/mobile/.beepserv_kill";
static NSString *const kLegacyKillFlag = @"/var/mobile/.idsbaa_kill";

static int bp_del_keychain_item(CFTypeRef cls, NSString *agrp, NSString *svce, NSString *acct) {
    NSMutableDictionary *q = [@{
        (__bridge id)kSecClass: (__bridge id)cls,
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
    } mutableCopy];
    if (agrp) q[(__bridge id)kSecAttrAccessGroup] = agrp;
    if (svce) q[(__bridge id)kSecAttrService]     = svce;
    if (acct) q[(__bridge id)kSecAttrAccount]     = acct;
    OSStatus st = SecItemDelete((__bridge CFDictionaryRef)q);
    LOG(@"[spoof] delItem agrp=%@ svce=%@ acct=%@ -> %d", agrp, svce, acct, (int)st);
    return (int)st;
}

// Evict cached registration material so the next mint re-drives NAC signing.
// NEVER delete mobileactivationd *-ucrt or IDS-rk-ucrt — that breaks Absinthe
// issueClientCertificate / leaves IfNeeded stuck before nac_key_establishment.
// Serial spoofing does not need ucrt wipe: NAC reads gestalt via MGCopyAnswer hooks.
static void bp_invalidate_validation_state(void) {
    LOG(@"[spoof] invalidating cached registration material (preserving Absinthe ucrt)");
    bp_del_keychain_item(kSecClassGenericPassword, @"apple", @"com.apple.facetime", @"registrationV2");
    bp_del_keychain_item(kSecClassGenericPassword, @"apple", @"com.apple.ids", @"RegistrationControl-0");
}

void bp_invalidate_validation_state_now(void) {
    bp_invalidate_validation_state();
}

static void bp_consume_invalidate_flag(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kInvalidateFlag] || [fm fileExistsAtPath:kLegacyInvalidateFlag]) {
        bp_invalidate_validation_state();
        [fm removeItemAtPath:kInvalidateFlag error:nil];
        [fm removeItemAtPath:kLegacyInvalidateFlag error:nil];
        LOG(@"[spoof] invalidate flag consumed");
    }
}

%ctor {
    bp_consume_invalidate_flag();
}

// Re-read every call. beepservd writes a new plist on each validation request
// without restarting identityservicesd.
static NSDictionary* bp_spoof_map(void) {
    return [NSDictionary dictionaryWithContentsOfFile: @"/var/mobile/.beepserv_spoof.plist"] ?: @{};
}

static BOOL bp_spoof_enabled(void) {
    NSDictionary* m = bp_spoof_map();
    if (!m.count) return NO;
    id en = m[@"Enabled"];
    return (en == nil) || [en boolValue];
}

// Force baa:false independently of serial spoof (matches idsbaa .idsbaa_kill).
// Armed when spoof is enabled OR an explicit kill flag is present.
static BOOL bp_baa_kill_enabled(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kKillFlag] || [fm fileExistsAtPath:kLegacyKillFlag]) {
        return YES;
    }
    return bp_spoof_enabled();
}

BOOL bp_spoof_enabled_export(void) {
    return bp_spoof_enabled();
}

%hookf(CFPropertyListRef, MGCopyAnswer, CFStringRef question) {
    if (question && bp_spoof_enabled()) {
        NSString* key = (__bridge NSString*) question;
        id value = bp_spoof_map()[key];
        if ([value isKindOfClass: NSString.class]) {
            // caller owns the returned ref; CFBridgingRetain matches the +1 contract
            return (CFPropertyListRef) CFBridgingRetain(value);
        }
    }
    return %orig;
}

// IDSValidationQueue drives the BAA-vs-Absinthe decision. NOTE: the `subsystem`
// argument is a scalar enum (long long), NOT an object — never declare it `id`
// (ARC would retain the scalar and crash).
@interface IDSValidationQueue: NSObject
@end

@interface IDSValidationSession: NSObject
@end

static NSString* bp_spoof_value(NSString* key) {
    if (!bp_spoof_enabled()) return nil;
    id value = bp_spoof_map()[key];
    return [value isKindOfClass: NSString.class] ? value : nil;
}

%hook IDSValidationQueue
- (BOOL)shouldUseAbsinthe {
    if (bp_baa_kill_enabled()) {
        LOG(@"[spoof] forcing shouldUseAbsinthe=YES");
        return YES;
    }
    return %orig;
}

- (void)buildValidationCredentialsIfNeededForSubsystem:(long long)subsystem {
    if (bp_baa_kill_enabled() || bp_spoof_enabled()) {
        LOG(@"[spoof] buildValidationCredentials subsystem=%lld", subsystem);
    }
    %orig;
}

- (void)_sendBAAValidationRequestIfNeededForSubsystem:(long long)subsystem {
    if (bp_baa_kill_enabled()) {
        LOG(@"[spoof] suppressing BAA cert request (forcing baa:false), subsystem=%lld", subsystem);
        return;
    }
    %orig;
}

- (void)_sendAbsintheValidationCertRequestIfNeededForSubsystem:(long long)subsystem {
    if (bp_baa_kill_enabled() || bp_spoof_enabled()) {
        LOG(@"[spoof] _sendAbsintheValidationCertRequestIfNeeded subsystem=%lld", subsystem);
    }
    %orig;
}
%end

%hook IDSValidationSession
- (BOOL)isUsingBAA            { return bp_baa_kill_enabled() ? NO : %orig; }
- (BOOL)_shouldUseBAACertOption { return bp_baa_kill_enabled() ? NO : %orig; }
- (BOOL)_shouldUseBAAOnly     { return bp_baa_kill_enabled() ? NO : %orig; }

- (id)_deviceAbsintheSerialNumber {
    NSString *s = bp_spoof_value(@"SerialNumber");
    if (s) { LOG(@"[spoof] _deviceAbsintheSerialNumber -> %@", s); return s; }
    return %orig;
}
- (id)_deviceAbsintheUDID {
    NSString *s = bp_spoof_value(@"UniqueDeviceID");
    if (s) { LOG(@"[spoof] _deviceAbsintheUDID -> %@", s); return s; }
    return %orig;
}
- (id)_deviceAbsintheIMEI {
    NSString *s = bp_spoof_value(@"InternationalMobileEquipmentIdentity");
    if (s) { LOG(@"[spoof] _deviceAbsintheIMEI -> %@", s); return s; }
    return %orig;
}
%end

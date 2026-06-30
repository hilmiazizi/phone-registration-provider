#import "BPDeviceIdentifiers.h"
#import <sys/utsname.h>
#import <sys/sysctl.h>
#import <sys/stat.h>

CFPropertyListRef MGCopyAnswer(CFStringRef property);

static NSDictionary* cachedIdentifiers;

static NSString* const kBPSpoofPlistPath = @"/var/mobile/.beepserv_spoof.plist";
static NSString* const kBPRotateFlagPath = @"/var/mobile/.beepserv_rotate";

// ---------------------------------------------------------------------------
// On-phone identity generation (ported from mgspoof/genfp.py).
// INTERNAL CONSISTENCY rule: per-UNIT ids (serial date+unit, UDID, IMEI body)
// rotate; per-MODEL parts are kept from the REAL device (serial plant 1-3 +
// config 9-12, IMEI TAC) so the tuple stays a plausible iPhone9,3.
// ---------------------------------------------------------------------------
static NSString* bp_random_from(NSString* charset, NSUInteger n) {
    NSMutableString* s = [NSMutableString stringWithCapacity: n];
    uint32_t len = (uint32_t) charset.length;
    for (NSUInteger i = 0; i < n; i++) {
        [s appendFormat: @"%C", [charset characterAtIndex: arc4random_uniform(len)]];
    }
    return s;
}

static NSString* bp_luhn(NSString* body14) {
    NSInteger total = 0;
    for (NSUInteger i = 0; i < body14.length; i++) {
        NSInteger d = [body14 characterAtIndex: i] - '0';
        if (i % 2 == 1) { d *= 2; if (d > 9) d -= 9; }
        total += d;
    }
    return [NSString stringWithFormat: @"%ld", (long) ((10 - (total % 10)) % 10)];
}

// PPP Y W SSS CCCC: keep plant(1-3)+config(9-12) from the real serial; valid
// half-year letter + week code; randomize the 3-char unit id.
static NSString* bp_gen_serial(NSString* templ) {
    NSString* const serialChars = @"0123456789CDFGHJKLMNPQRTVWXY"; // no vowels/confusables
    NSString* const yearCodes   = @"STVWXYZ";                       // 2016 H2 .. 2019 H2
    NSString* const weekOrder    = @"123456789CDFGHJKLMNPQRTVWXY";   // week 1..27
    if (templ.length != 12) templ = @"F4JSDXCEHG7K";
    templ = templ.uppercaseString;
    return [NSString stringWithFormat: @"%@%@%@%@%@",
        [templ substringToIndex: 3],
        bp_random_from(yearCodes, 1),
        bp_random_from(weekOrder, 1),
        bp_random_from(serialChars, 3),
        [templ substringWithRange: NSMakeRange(8, 4)]];
}

static NSString* bp_gen_imei(NSString* tac) {
    if (tac.length != 8) tac = @"35920507"; // a real iPhone 7 TAC
    NSString* body = [tac stringByAppendingString: bp_random_from(@"0123456789", 6)]; // 14 digits
    return [body stringByAppendingString: bp_luhn(body)];
}

static NSString* bp_gen_udid(void) { return bp_random_from(@"0123456789abcdef", 40); }

static NSString* bp_real_gestalt(CFStringRef key, NSString* fallback) {
    NSString* v = (__bridge_transfer NSString*) MGCopyAnswer(key);
    return v.length ? v : fallback;
}

@implementation BPDeviceIdentifiers
    + (NSString*) spoofValueForKey: (NSString*) key {
        NSDictionary* m = [NSDictionary dictionaryWithContentsOfFile: kBPSpoofPlistPath];
        if (!m.count) return nil;
        id en = m[@"Enabled"];
        if (en != nil && ![en boolValue]) return nil;
        id v = m[key];
        return [v isKindOfClass: NSString.class] ? v : nil;
    }

    + (void) ensureSpoofIdentity {
        NSFileManager* fm = NSFileManager.defaultManager;
        BOOL rotate = [fm fileExistsAtPath: kBPRotateFlagPath];
        if ([fm fileExistsAtPath: kBPSpoofPlistPath] && !rotate) {
            return; // keep the current identity
        }

        NSString* realSerial = bp_real_gestalt(CFSTR("SerialNumber"), @"F4JSDXCEHG7K");
        NSString* realImei = bp_real_gestalt(CFSTR("InternationalMobileEquipmentIdentity"), @"359205070000000");
        NSString* tac = realImei.length >= 8 ? [realImei substringToIndex: 8] : @"35920507";

        NSDictionary* identity = @{
            @"Enabled": @YES,
            @"SerialNumber": bp_gen_serial(realSerial),
            @"UniqueDeviceID": bp_gen_udid(),
            @"InternationalMobileEquipmentIdentity": bp_gen_imei(tac)
        };

        if ([identity writeToFile: kBPSpoofPlistPath atomically: YES]) {
            chmod(kBPSpoofPlistPath.fileSystemRepresentation, 0644);
        }
        if (rotate) {
            [fm removeItemAtPath: kBPRotateFlagPath error: nil];
        }
    }

    + (NSDictionary*) get {
        if (!cachedIdentifiers) {
            [self cache];
        }
        
        return cachedIdentifiers;
    }
    
    + (void) cache {
        struct utsname systemInfo;
        uname(&systemInfo);
        
        NSString* model = [NSString stringWithCString: systemInfo.machine encoding: NSUTF8StringEncoding];
        
        size_t malloc_size = 10;
        char* buildNumberBuf = malloc(malloc_size);
        sysctlbyname("kern.osversion\0", (void*) buildNumberBuf, &malloc_size, NULL, 0);
        
        // we don't need to free `buildNumberBuf` if we pass it into this method
        NSString* buildNumber = [NSString stringWithCString: buildNumberBuf encoding: NSUTF8StringEncoding];
        
        // SPOOF: report the spoofed serial/UDID so version-info matches the minted blob.
        NSString* udid = [self spoofValueForKey: @"UniqueDeviceID"]
            ?: (__bridge_transfer NSString*) MGCopyAnswer(CFSTR("UniqueDeviceID"));
        NSString* serial = [self spoofValueForKey: @"SerialNumber"]
            ?: (__bridge_transfer NSString*) MGCopyAnswer(CFSTR("SerialNumber"));
        
        cachedIdentifiers = @{
            @"hardware_version": model,
            @"software_name": @"iPhone OS",
            @"software_version": UIDevice.currentDevice.systemVersion,
            @"software_build_id": buildNumber,
            @"unique_device_id": udid,
            @"serial_number": serial
        };
    }
@end
#import <UIKit/UIKit.h>

@interface BPDeviceIdentifiers: NSObject
    // Caches the identifiers if needed and then returns the cached identifiers
    + (NSDictionary*) get;
    // Generates the dictionary with the identifiers and caches it for later use
    + (void) cache;
    // Generate a fresh format-valid spoof identity if none exists, or if the rotate
    // flag (/var/mobile/.beepserv_rotate) is set. Persists to .beepserv_spoof.plist.
    + (void) ensureSpoofIdentity;
    // Always write a new serial/UDID/IMEI. Called on every validation-data request.
    + (void) rotateSpoofIdentity;
@end
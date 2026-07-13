# beepserv spoof fork — design + full background

This is a fork of `beeper/phone-registration-provider` (beepserv). Goal: make beepserv
**self-contained** for off-device iMessage "bbox manufacturing" with a **spoofable, valid
device identity**, so we no longer need the two separate research tweaks (`idsbaa` +
`MGSpoof`). Everything below is what we learned proving this works end-to-end on an
iPhone 7 (iPhone9,3), iOS 15.8.5, palera1n rootful.

---

## 0. The big picture (what beepserv is for)

`rustpush` registers Apple IDs into iMessage identities **off-device** (on Linux). To do
that, Apple requires **validation data**: a short, signed blob that proves the request
comes from a genuine Apple device. rustpush cannot mint it (the crypto lives in Apple
frameworks + the Secure Enclave), so it asks a **provider** for it. beepserv is that
provider: a jailbreak tweak on a real iPhone that mints genuine validation data and serves
it to rustpush over Beeper's relay.

```
  Linux (rustpush)                Beeper relay                 iPhone (beepserv)
  ----------------                ------------                 -----------------
  --register / --relay-test  --> registration-relay.beeper --> beepservd websocket
     get-version-info         <--      (routes by code)    <--   getIdentifiers()
     get-validation-data      -->                          --> mint via identityservicesd
        <-- base64 blob       <--                          <--   (NAC/Absinthe sign)
  GSA login + Albert + IDS register  (all on Linux, using that blob)
```

Each Apple ID rustpush registers this way is **not** subject to the phone's own per-device
account cap, because the registration happens off-device. The phone only lends its
device-identity + crypto to mint the blob.

---

## 1. What is "validation data"?

- It is the value Apple calls `validation-data` (a.k.a. `X-Apple-I-MD` style data) that is
  sent in the IDS `id-register` request (and in the GSA/`X-Mme-Nas-Qualify` step).
- On this device it is a **~261-byte binary token** (leading byte `0x02`). It is **NOT**
  the big SEP certificate chain — it is a short, freshly-signed token produced by Apple's
  **NAC / Absinthe** routine. It embeds (cryptographically, not in plaintext) the device's
  hardware identity + a timestamp/nonce, and is signed so Apple's servers can verify it
  came from a real Apple device.
- It is **single-use-ish / time-bound**: beepserv caches one for **10 minutes**
  (`validationDataExpiry` in `Tweak.x`). Within that window every request returns the same
  bytes; after expiry (or a beepservd restart) the next request mints a fresh one.
- rustpush treats it as opaque base64. See `src/relay.rs` `generate_validation_data()` and
  `src/ids/user.rs` (the `("validation-data", Value::Data(...))` field of `id-register`).

### How rustpush uses it (the off-device pipeline)
1. `get-version-info` → `Versions` { `hardware_version`=iPhone9,3, `software_version`,
   `software_build_id`, `unique_device_id` (IDFV, **not** the real UDID), `serial_number` }.
   rustpush fans these into headers, Albert activation, and IDS register-meta.
2. `get-validation-data` → the 261-byte blob.
3. **Albert activation** (`APSConnectionResource`): gets an APNs push certificate. NOTE:
   this is always done as **DeviceClass=MacOS / iMac13,1** (the bundled FairPlay keys are
   generic Mac keys; Albert only mints a push cert for Mac class). iPhone-ness lives in the
   validation-data + register-meta, not the push cert. Forcing iPhone class here causes
   `Failed to parse Albert Cert`.
4. **GSA login** (`gsa.apple.com`): Apple-ID auth → adsid/PET/token set. Requires a
   **unique anisette machine** (`remote-anisette-v3`), not a shared public one, or IDS
   provisioning returns `UNAUTHORIZED`.
5. **IDS register** (`id-register` to `*.ess.apple.com`): sends register-meta +
   `private-device-data` + the **validation-data**. Apple returns per-service certs with
   `status 0` on success.
6. Lookups (`id-query` to `query.ess.apple.com`) resolve handles using the issued identity.

---

## 2. What is BAA, and the two validation paths

Inside `identityservicesd`, class `IDSValidationQueue` builds validation credentials via
`-buildValidationCredentialsIfNeededForSubsystem:`, which can take **two independent
paths**:

- **BAA path** — `-_sendBAAValidationRequestIfNeededForSubsystem:`
  - **BAA = Basic Attestation Authority**: a **Secure-Enclave-backed device attestation**.
    The SEP signs an attestation certificate that cryptographically binds the registration
    to the device's **real, fused-in serial/identity**. This is `absinthe-baa:true`.
  - Source of the attestation: `DeviceIdentityIssueClientCertificateWithCompletion`
    (DeviceIdentity.framework) → talks to the SEP.
  - Because the SEP holds the real identity, **you cannot spoof the serial on this path** —
    MobileGestalt spoofing is ignored; the SEP attests the true serial.

- **Absinthe path** — `-_sendAbsintheValidationCertRequestIfNeededForSubsystem:`
  - A **software** validation cert. The hardware identity it folds in comes from
    `IDSValidationSession` getters `_deviceAbsintheSerialNumber` / `_deviceAbsintheUDID` /
    `_deviceAbsintheIMEI`, which read **MobileGestalt** (`MGCopyAnswer("SerialNumber")`
    etc.) — i.e. plaintext, userland-reachable, **spoofable**. This is `absinthe-baa:false`.

`IDSValidationSession` decides which path with `isUsingBAA`, `_shouldUseBAACertOption`,
`_shouldUseBAAOnly`. A modern iPhone **defaults to baa:true** (SEP present), so by default
the real serial is welded into every registration.

---

## 3. Why we disable BAA (force baa:false)

To **spoof the device serial**, the validation-data must take the **Absinthe** path, where
the serial is sourced from MobileGestalt (spoofable) instead of the SEP (not spoofable).
So we force `baa:false`:
- Suppress `-_sendBAAValidationRequestIfNeededForSubsystem:` (never fetch the SEP cert).
- Force `isUsingBAA = NO`, `_shouldUseBAACertOption = NO`, `_shouldUseBAAOnly = NO`.

Then only the software Absinthe cert is built, and the serial it carries is whatever
MobileGestalt / the `_deviceAbsinthe*` getters return — which we control.

### Proven results (Jun 30, this device)
- **baa:false accepted off-device**: forced baa:false with the REAL serial → rustpush
  `--register` returned `status 0` on madrid/ess/facetime/multiplex1 and `--test-lookup`
  resolves. Re-confirmed with a **fresh full-login account** (no prior baa:true history on
  this serial) → rules out grandfathering. **Apple does not require the SEP BAA cert on the
  off-device relay path.**
- **Spoofed serial accepted**: a fabricated-but-valid serial `F4JY73X9HG7K` (real is
  `F4JSDXCEHG7K`), carried consistently through version-info + blob, registered + resolves.
- **Important caveat**: forcing baa:false for the **device's own on-device** registration
  fails (`ErrorCode 26 / InternalErrorCode 38`, retry-loops). That failure is specific to
  the device registering itself; it does **not** apply to the off-device relay path, where
  beepserv only captures the blob (via `-setValidationData:`) before it is sent and rustpush
  does the actual registration. The off-device path is the one that matters and it works.

---

## 4. The serial format (so spoofs look genuine, like `gensmbios` for Mac)

Apple 12-char serials (2010–2020) = `PPP Y W SSS CCCC`:
- `PPP` (1-3): manufacturing plant. Keep real (e.g. `F4J`).
- `Y` (4): year + half. **Letter**, looping per decade. iPhone 7 era valid set =
  `S`(2016 H2) `T`(2017 H1) `V`(2017 H2) `W`(2018 H1) `X`(2018 H2) `Y`(2019 H1) `Z`(2019 H2).
- `W` (5): week of half. Digit `1-9` = weeks 1-9; letters `C..Y` minus vowels and `S` =
  weeks 10-27. (Second half adds 26.)
- `SSS` (6-8): unique unit id (alphanumeric, no vowels/confusables).
- `CCCC` (9-12): model/config code → ties to ProductType+color+capacity. **Keep real**
  (`HG7K` for this iPhone9,3) so the tuple is internally consistent.

A random string fails this; `mgspoof/genfp.py` (rewritten) emits valid serials, e.g.
`F4JY73X9HG7K` → plant F4J, 2019 H1, week 7, config HG7K. IMEI uses a **real iPhone 7 TAC**
(`35920507`) + Luhn check digit; UDID is 40-hex; MACs use real Apple OUIs.

---

## 5. THE FORK: fold idsbaa + MGSpoof into beepserv

beepserv's dylib already loads into `identityservicesd` (see `beepserv.plist` filter +
`%ctor` bundle check). So all the hooks can live in `Tweak.x`. Plan:

### 5a. Spoof config source
Read a spoof tuple once at mint time from `ROOT_PATH_NS(@"/var/mobile/.beepserv_spoof.plist")`
(keys: `SerialNumber`, `UniqueDeviceID`, `InternationalMobileEquipmentIdentity`; optional
`Enabled`). Helper `bpsSpoof(key)` with `dispatch_once` cache. If file/key absent → real
value (passthrough), so the tweak is safe when not spoofing.

### 5b. version-info serial (replaces MGSpoof-on-beepservd)
In `getIdentifiers()`, change:
```objc
@"serial_number": (__bridge NSString *)MGCopyAnswer(CFSTR("SerialNumber"))
```
to prefer `bpsSpoof(@"SerialNumber")` and fall back to MGCopyAnswer. This makes the serial
rustpush *reports* match the blob without needing MGSpoof injected into beepservd.

### 5c. blob serial + force baa:false (replaces idsbaa)
Add to `Tweak.x` (these classes are already in-process):
```objc
%hook IDSValidationQueue
- (void)_sendBAAValidationRequestIfNeededForSubsystem:(NSInteger)s {
    if (bpsSpoofEnabled()) return;   // force baa:false: never fetch SEP cert
    %orig;
}
%end

%hook IDSValidationSession
- (BOOL)isUsingBAA            { return bpsSpoofEnabled() ? NO : %orig; }
- (BOOL)_shouldUseBAACertOption { return bpsSpoofEnabled() ? NO : %orig; }
- (BOOL)_shouldUseBAAOnly     { return bpsSpoofEnabled() ? NO : %orig; }
- (id)_deviceAbsintheSerialNumber { id s=bpsSpoof(@"SerialNumber"); return s?:%orig; }
- (id)_deviceAbsintheUDID         { id s=bpsSpoof(@"UniqueDeviceID"); return s?:%orig; }
- (id)_deviceAbsintheIMEI         { id s=bpsSpoof(@"InternationalMobileEquipmentIdentity"); return s?:%orig; }
%end
```
NOTE on ARC: the `subsystem:` arg is a scalar `NSInteger` enum — declare it `NSInteger`,
never `id` (ARC would retain `0x1` → crash). (Same gotcha as idsbaa.)

### 5d. cache invalidation when the serial changes
`Tweak.x` caches the blob for 10 min (`validationDataExpiry`). When the spoof serial
changes, the cached blob is stale (wrong serial). Fix: key the cache on the current spoof
serial; if it changed, ignore the cache and re-mint. Also, the daemon may have a cached
Absinthe/registration cert — to force a clean re-mint on serial change, evict
`registrationV2` / mobileactivationd `*-ucrt` (the idsbaa `.idsbaa_invalidate` set) before
minting. (Port `invalidateValidationState()` from idsbaa as a helper.)

### 5e. Standalone on-phone identity generation + rotation (IMPLEMENTED)
**rustpush is never touched** — it only holds the relay code and pulls version-info +
the blob. beepserv generates its **own** format-valid identity on-device (the `genfp.py`
logic ported to Objective-C in `Tweak.x`: `bpsGenSerial`/`bpsGenIMEI`/`bpsGenUDID`),
persists it to `.beepserv_spoof.plist`, and serves the **same** identity to both
version-info and the blob — so they always agree (this is the consistency rustpush relies
on, since it caches the version-info serial in `hwconfig.plist` and reuses it for
register-meta / GSA / Albert).

Why on-phone and not per-request over the relay: rustpush fetches version-info **once**
and caches it (`resolve_relay_config` → `hwconfig.plist`); the serial Apple sees in
register-meta/GSA comes from that cache, while the blob is fetched fresh. If only the blob
rotated, it would mismatch the cached serial. Owning the identity on the phone keeps the
pair consistent without any rustpush logic.

Rotation policy (decided entirely on the phone):
- plist missing → generate a fresh identity (first run);
- `/var/mobile/.beepserv_rotate` present → generate a NEW identity, clear the flag;
- otherwise → keep the current identity.

Per-model parts (serial plant 1-3 + config 9-12, IMEI TAC) are seeded from the **real**
device gestalt (`MGCopyAnswer`) so the spoof stays a plausible iPhone9,3; only per-unit
ids (serial date+unit, UDID, IMEI body) rotate.

**To roll a new device** (one phone-side action, then re-pull on rustpush):
```
# on the phone
touch /var/mobile/.beepserv_rotate && killall -9 beepservd identityservicesd
# on Linux: force a fresh version-info pull so the new serial lands in hwconfig.plist
rm -f hwconfig.plist   # (or use the --force-relay-fetch path), then --register
```
The restart also flushes identityservicesd's cached Absinthe cert, so the next mint
genuinely rebuilds with the new serial (no stale-cert problem).

Note: version-info `unique_device_id` is still the IDFV (as upstream), not the spoofed
UDID — this matches the proven-working setup where blob-UDID (gestalt) and version-info
UDID (IDFV) differed and Apple still accepted + resolved. Rotating the version-info UDID
too is a possible future hardening, but kept as-is to not regress the known-good path.

### 5f. build / install
- theos rootful: `THEOS=/home/zeroday/theos`, `unset THEOS_PACKAGE_SCHEME`, `make package`.
- `Makefile` already `killall identityservicesd` after install. After installing the fork,
  also `killall beepservd` if split, or it's all one dylib now.
- The on-device stock beepserv is the **split** 0.2.0 (`beepservd` + injected dylib). Our
  fork is the **monolithic** repo build; installing it replaces the dylib that loads into
  identityservicesd. Decide whether to keep `beepservd` or run monolithic (the repo's
  websocket runs inside identityservicesd directly — simpler, one process).
- Keep `genfp.py` for generating the valid serial tuples that feed `.beepserv_spoof.plist`
  (or the per-request field).

---

## 6. Operational recipe (standalone)
Per new identity:
1. **(phone)** `touch /var/mobile/.beepserv_rotate && killall -9 beepservd identityservicesd`
   → beepserv generates a fresh format-valid identity into `.beepserv_spoof.plist`.
2. **(Linux)** `rm -f hwconfig.plist` (force a fresh version-info pull), then
   `--register <account>` → status 0 + lookups resolve with the new spoofed serial.

No genfp.py copy step, no spoof-plist push: the phone produces the identity itself.
`genfp.py` remains as the reference the Objective-C generator was ported from.

---

## 7. Files in this fork
- `Tweak.x` — websocket provider + IDSRegistrationMessage capture + (NEW) baa:false + serial hooks.
- `Tweak.h` — IDS private interfaces (add `IDSValidationQueue`/`IDSValidationSession` decls).
- `getIdentifiers()` — version-info (NEW: spoof serial).
- `beepserv.plist` — inject filter (identityservicesd + Preferences).
- `Makefile`, `Constants.h`, `State.x/.h`, `SocketRocket/` — unchanged build scaffolding.
- `../mgspoof/genfp.py` — valid-serial generator (shared).

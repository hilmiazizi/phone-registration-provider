# MGSpoof — MobileGestalt rotation test harness

Goal of this harness: answer the one make-or-break question for the iPhone-farm
model — **can a single physical iPhone register multiple, independent iMessage
identities by rotating its device fingerprint, without tripping Apple's
per-device cap?** Everything else (login automation, renewal) is mechanical and
only worth building if rotation works.

This is a *minimal* test rig, scoped to the IDS-relevant daemons, not a global
spoof.

## What gets rotated vs kept fixed

`MGCopyAnswer` is the single chokepoint every Apple daemon uses to read device
identity. We override it **only inside** `identityservicesd`, `apsd`, `imagent`,
`IMDPersistenceAgent`, `akd` (see `MGSpoof.plist`).

| Field (MobileGestalt key)                 | Cycle    | Why |
|-------------------------------------------|----------|-----|
| `SerialNumber`                            | ROTATE   | primary id Apple links accounts by |
| `UniqueDeviceID` (UDID, 40-hex)           | ROTATE   | per-unit |
| `UniqueChipID` (ECID)                     | ROTATE   | per-SoC |
| `DieID`                                   | ROTATE   | per-SoC |
| `InternationalMobileEquipmentIdentity`    | ROTATE   | per-unit (valid Luhn) |
| `WifiAddress` / `BluetoothAddress` / `EthernetMacAddress` | ROTATE | per-unit |
| `ProductType` (`iPhone9,3`)               | **FIXED**| must stay a real model |
| `HardwareModel` (`D101AP`)                | **FIXED**| must match ProductType |
| `ChipID`, `BoardId`                       | **FIXED / real** | model-tied; inconsistency = flag |

The whole game is **internal consistency**: rotate the per-unit ids, never the
per-model ids.

## The single most important confirmation

You explicitly de-prioritized renewal (easy) and asked: login vs device identity?
**Device identity change is the one to confirm.** If rotation works, the farm
scales; login is just plumbing. If rotation does NOT work (Apple still caps the
physical device), no amount of login automation saves the model.

So this harness tests rotation in isolation: you can do the logins by hand for
the 2–3 cycles.

## Build

On a box with Theos:

```bash
cd research/mgspoof
make package          # produces a .deb
# install the .deb on the rootful-JB iPhone (Filza / dpkg -i / Sileo)
```

## Test procedure (2–3 cycles)

Use a DIFFERENT Apple ID per cycle (a capped device rejects the 2nd id; a
successfully-rotated "new device" should accept each fresh id cleanly).

For each cycle N:

1. `python3 genfp.py --serial-template <REAL_iPhone7_serial> --imei-tac <REAL_TAC> -o cycleN.plist`
   - Seed the template from one of your real iPhone 7s:
     `gestalt SerialNumber InternationalMobileEquipmentIdentity HardwareModel ProductType`
2. `scp cycleN.plist root@<iphone>:/var/mobile/.mgspoof.plist`
3. On device: Settings → Messages OFF, then **sign out** the current Apple ID.
4. On device: `sh reset_cycle.sh`
5. Verify the spoof took:
   `gestalt SerialNumber UniqueDeviceID InternationalMobileEquipmentIdentity`
   (must show the rotated values, not the real ones).
6. Sign in Apple ID #N, enable iMessage, send/receive one test message.
7. Record: did activation succeed? was the number/email usable? any
   "waiting for activation" / cap error?

## Pass / fail criteria

- **PASS (rotation works):** each cycle activates a fresh Apple ID and iMessage
  works, even though it's the same physical phone. The cap is keyed to the
  spoofed fingerprint, so each rotation looks like a new device.
- **FAIL (still capped):** 2nd/3rd activation hangs on "waiting for activation"
  or is rejected, despite the spoofed gestalt values reading correctly in step 5.
  That means Apple is linking via a signal we did NOT rotate (e.g. the keychain
  push token survived, or an unspoofed key). First mitigation: confirm the old
  push token was cleared (sign-out should do it; if not, delete the
  `push.apple.com` keychain item with your keychain tooling) and re-test.

## If a real id still leaks (step 5 shows the real value)

Some callers ask MobileGestalt by an *obfuscated/hashed* key rather than the
readable string. If `gestalt <Key>` shows rotated but a daemon still leaks the
real one, add the hashed-key alias to `mgspoof.plist` (same value) — capture the
hashed key by logging `question` in `Tweak.x`.

# Method A - checkm8 + patched DeviceTree re-activation (GATED follow-up)

Reached because Method B (userland gestalt rotation) is insufficient: the
iMessage validation identity is the SEP-backed BAA attestation cert + the
Apple-signed activation cert, neither forgeable in userland (see FINDINGS.md).

## Host gate (you said "unsure" - here is the hard requirement)
- **Linux or macOS with REAL USB** + the phone enterable into DFU.
- **WSL is NOT usable**: checkm8 needs precise USB timing in DFU; usbipd
  passthrough under WSL is unreliable and the exploit will fail/brick the cycle.
  Use a native Linux laptop, a mac mini, or a dual-boot. (Cheap Linux box is fine.)
- Device is A10 / `iPhone9,3` -> checkm8-class, no caveats.

## Tools
- `gaster` (standalone checkm8 pwn) or `palera1n` (wraps checkm8).
- A custom boot chain for the target iOS: `iBSS`/`iBEC`, **DeviceTree**,
  kernelcache, (optional) ramdisk - decrypted/patched for this build.
- `img4tool` / `img4` to repack the patched DeviceTree as an IMG4.
- `irecovery` (libirecovery) to stage images over USB in DFU/recovery.

## What gets patched
The DeviceTree blob carries the AP-side hardware identity that the XNU kernel
publishes into IORegistry and that lockdownd/mobileactivationd read:
- `serial-number`, `unique-chip-id` (ECID), `mlb-serial-number`,
  `region-info`, `model-number`, MAC addresses.
Patch these to the spoofed tuple (use `genfp.py` values - keep model/board real),
repack IMG4, and checkm8-boot the chain so the kernel comes up believing the
spoofed identity is real **before** mobileactivationd builds the activation
request. Then re-activate -> Apple issues a fresh activation cert for the
spoofed serial.

## Procedure (per rotation cycle)
1. Enter DFU. `gaster pwn` (+ `gaster reset`).
2. Patch DeviceTree (`serial-number` etc.) -> repack IMG4.
3. `irecovery` stage iBSS/iBEC, send patched DeviceTree + kernelcache, `bootx`.
4. After boot: verify with kernel source `ioreg IOPlatformSerialNumber` (NOT
   gestalt) shows the spoofed serial -> confirms the patch reached the kernel.
5. Wipe IDS/account state (`reset_cycle.sh`), sign in the next Apple ID,
   activate iMessage.
6. Extract (`idextract` + `assemble_bbox.py`), verify, recycle.

## THE MAKE-OR-BREAK CAVEAT (validate before trusting Method A)
checkm8 compromises the Application Processor, **not the SEP** (separate
SecureROM; confirmed by axi0mX and multiple analyses). So a DeviceTree patch
changes the AP-side serial/UDID/ECID, but the **SEP attestation key is fused and
unchanged** - the BAA cert key hash (our `CN=17a5ac62...`) would stay constant
across rotations.

The open question that decides whether Method A actually beats the cap:
- **If Apple keys the per-device cap on the AP-side serial/activation data**
  (DeviceTree-patchable) -> Method A works, each patched boot is a "new device".
- **If Apple keys it on the fused SEP attestation key** -> Method A also fails,
  because no AP-side exploit can change the SEP key.

**You MUST validate with the same test:** after a patched-DeviceTree boot,
register account #2/#3 and check whether `ICLOUD_UNSUPPORTED_DEVICE` clears.
Do NOT assume Method A works until this passes.

## Likely-better alternative: the software validation-data path (no hardware rotation)
Strong counter-signal: rustpush / pypush / Beeper register iMessage using
**software-generated validation data** on machines with **no SEP at all**. That
means the IDS registration does not strictly require a genuine SEP attestation -
validation data can be produced in software from an arbitrary `device_info`.

Implication for the farm model: instead of physically rotating one phone's
hardware identity (checkm8 per cycle, slow, SEP-gated), generate validation data
off-device with rotated `device_info`, the way the bbox/`p-radar` pipeline
already consumes it. The phone may only be needed as ONE validation-data
provider (or not at all). This sidesteps the SEP wall entirely and is the path
worth prototyping BEFORE investing in the checkm8 rig.

=> Recommendation: prototype the software validation-data route first; treat
checkm8 Method A as the fallback, and only after the per-device-cap-on-serial
question is empirically confirmed.

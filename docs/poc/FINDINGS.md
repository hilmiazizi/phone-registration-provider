# Identity Rotation PoC - Findings

> **HISTORICAL.** This document records early PoC phases that used separate
> `idsbaa` + `MGSpoof` tweaks. The **current product** integrates spoof +
> `baa:false` + mint inside `com.beeper.beepserv` alone.
>
> For operators / fresh phones, use:
> - [INSTALL.md](../../INSTALL.md)
> - [FARM.md](../../FARM.md)
> - [ARCHITECTURE.md](../../ARCHITECTURE.md)
> - [`research/README.md`](../../research/README.md) (archive — do not install on farm phones)

Device: iPhone 7 (iPhone9,3), iOS 15.x (Darwin 21.6.0), checkm8-class A10.
Driver: `_ssh.py` (mobile@192.168.18.153). Backups: `poc/backup_*/`.

## Phase 0 - Backup (DONE)
- File-restorable state captured to `device_state.tar` (573 KB): MGSpoof.*,
  IdentityServices/, akd Application Support + Caches, lockdown data_ark.plist.
- KEY FACT: ADI/anisette has **no portable file** on iOS. `akd` only owns
  `authorization.db`; the ADI provisioning lives in the keychain as
  `com.apple.iAdIDRecords` (14 items) - SEP-wrapped. -> ADI cannot be
  file-backed-up or hand-rotated. Restore path = re-login (see RESTORE.md).

## Phase 1 - Baseline instrumentation (DONE)
- Log capture: `oslog -p identityservicesd` / `oslog -p akd` works on-device.
- Real identity (kernel/ioreg, unhookable): serial `F4JSDXCEHG7K`,
  IOPlatformUUID `B2350563-9D43-550F-A549-D10DA3239FCB`.

### DECISIVE: what serial reaches Apple in the registration
Decoded the keychain blobs from `idextract_baseline.json` (174 items):
- The iMessage registration body lives in `genp svce=com.apple.facetime
  acct=registrationV2`, and its `private-device-data` contains:
  - `hardware-version` = `iPhone9,3`
  - serial = **`F4JSDXCEHG7K`** (the REAL serial, matches kernel ioreg)
- `mobileactivationd` `com.apple.IDS-combined-ucrt` also carries the real serial.
- The IDS identity certs are keyed by `UID=D:<dsid>` (Apple ID directory id),
  not the serial - so the serial enters Apple's view via `private-device-data`,
  not the cert subject.
- Historical leftovers in the dump: prior accounts with `UID=D:` dsids and
  country codes US/AR (a previous Argentina account) - confirms multiple past
  registrations on this hardware.

CONCLUSION (baseline): with MGSpoof in **passthrough** (current state), the
iMessage registration folds the **REAL** serial `F4JSDXCEHG7K` + real model into
`private-device-data`. So today Apple sees the genuine device. For Method B to
work, an *active* MGSpoof rotation must (a) change the serial AND (b) propagate
into a freshly-built `registrationV2/private-device-data`. Phase 2 tests this.

## Phase 2.1 - Activate the gestalt rotation (DONE)
- Mechanism: MGSpoof (`mgspoof/Tweak.xm`) overrides `MGCopyAnswer` and reads
  `/var/mobile/.mgspoof.plist` once per process start; only listed keys override,
  rest fall through. It was passthrough because that plist was absent.
- Generated cycle-1 fingerprint with `genfp.py` (seeded from real serial so
  factory `F4J` + config `HG7K` stay valid): rotated tuple
  - SerialNumber `F4J8JN4YHG7K`, UDID `bf55c153cc38c928438c463168c00866b2b1089b`,
    IMEI `354042077696106`, WiFi `f0:18:98:e8:2f:ee`, model fixed `iPhone9,3`.
- Pushed to `/var/mobile/.mgspoof.plist`. Verification:
  - `gestalt SerialNumber` (HOOKED) -> `F4J8JN4YHG7K` (rotated) [PASS]
  - `ioreg IOPlatformSerialNumber` (kernel, UNHOOKED) -> `F4JSDXCEHG7K` (real,
    unchanged) -> confirms userland hook cannot touch the kernel identity.
- Restarted identityservicesd/imagent/IMDPersistenceAgent (same MGSpoof hook, no
  per-process logic) -> they respawn reading the rotated tuple. (oslog capture of
  the inject NSLog was unreliable over non-TTY SSH; propagation is verified
  authoritatively in Phase 3 via the fresh registrationV2 serial.)

## Phase 2.2-2.3 - Clear state + ADI/attestation rotation attempt (DONE)

### The real identity surfaces (from keychain access-group analysis)
Correction: `com.apple.iAdIDRecords` is the *advertising* ID (iAd), irrelevant.
The identity-critical keychain groups are:
- `agrp=lockdown-identities`: device **activation identity** cert
  `CN=46FCC175-2014-4A01-8FA3-F6E5905FF6C2`, issued by **Apple iPhone Device CA**
  (Apple-signed at activation) + its private keys/identities.
- `agrp=com.apple.identityservicesd`, `com.apple.mobileactivationd/
  com.apple.IDS-combined-ucrt`: the iMessage **validation identity** = a
  **BAA (Basic Attestation Authority) cert** `CN=17a5ac62c4dcd6...` issued by
  **Basic Attestation User Sub CA1** (SEP-backed device key, Apple-signed).
- `agrp=ichat`: per-message IDS protection keys.
- "ADI/anisette" has NO portable file; the machine-id is SEP-derived on demand.

### Decisive autonomous experiment (rotate -> force re-dump -> compare)
With the spoofed gestalt active (`F4J8JN4YHG7K`) I killed identityservicesd to
force a fresh in-daemon keychain dump, then compared baseline vs post-rotation:

| Surface | Baseline (real gestalt) | After rotate (spoofed gestalt) |
|---|---|---|
| serials in keychain/registration | `F4JSDXCEHG7K` | `F4JSDXCEHG7K` (UNCHANGED) |
| spoofed serial `F4J8JN4YHG7K` present? | n/a | **NO - absent everywhere** |
| BAA attestation cert CN | `17a5ac62...` | `17a5ac62...` (UNCHANGED) |
| kernel ioreg serial | `F4JSDXCEHG7K` | `F4JSDXCEHG7K` (UNCHANGED) |

So even though `MGCopyAnswer` returns the spoofed serial to callers, the
**persisted registration and the SEP-backed BAA attestation remain bound to the
REAL hardware identity**, and a daemon restart does not re-mint them under the
new gestalt. ADI/attestation cannot be rotated in userland:
- `akd` is (correctly) excluded from the MGSpoof filter, so it reads the REAL
  identity -> anisette/GSA stays genuine (this is why login works).
- Adding `akd` to the filter does NOT help: the BAA attestation is SEP-signed,
  not gestalt-derived; spoofing gestalt for akd just creates an inconsistency
  that broke login in earlier testing (the SEP can't attest a fake serial).

## GATE CONCLUSION (SOP Q1): Method B is INSUFFICIENT
The identity Apple validates at iMessage registration is the BAA attestation
cert (SEP-backed, Apple-signed) + the activation cert (Apple iPhone Device CA),
neither of which a userland MobileGestalt hook can forge or regenerate. A fresh
sign-in of account #2 would still authenticate via the REAL attestation, so
Apple links it to the real device and the per-device cap
(`ICLOUD_UNSUPPORTED_DEVICE`) is NOT reset. This is now established
cryptographically, not just empirically.

> Optional live re-confirmation (needs a 2nd Apple ID + device UI, which the SSH
> harness can't drive): with the spoof active, sign out acct #1, run
> `reset_cycle.sh`, sign in acct #2, enable iMessage. Predicted: activation
> fails / `ICLOUD_UNSUPPORTED_DEVICE` recurs because the BAA attestation is real.
> This only re-confirms the crypto above; not required to answer Q1.

=> Robust rotation requires **Method A: checkm8 + patched DeviceTree
re-activation**, so the spoofed serial is the device's reality *before* SEP /
mobileactivationd mint the attestation, making Apple issue a fresh BAA +
activation cert for the spoofed identity. See METHOD_A.md.

---

## Phase 5 - BINARY RE OF identityservicesd (iOS 15.8.5) -> Method C found

The Phase-2/Gate verdict ("must use BAA, so spoofing needs checkm8") assumed the
registration ALWAYS embeds the SEP BAA attestation. Static analysis of the
on-device `identityservicesd` (11 MB arm64 Mach-O, pulled to `re/`) disproves
that assumption: **the BAA attestation and the software Absinthe (NAC) blob are
SEPARABLE, toggle-controlled components.**

### Evidence (strings + symbols in identityservicesd)
- Software NAC (Absinthe) algorithm is present & used: `Calling NACInit with: %@`,
  ivar `^{NACContextOpaque_=} _validationContext`. The NAC* functions are exported
  by the linked **`MobileActivation.framework`** (the same primitives
  `open-absinthe` reimplements). => the iPhone has a genuine, callable NAC oracle.
- BAA (SEP) cert path is a DISTINCT mechanism via **`DeviceIdentity.framework`**:
  `DeviceIdentityIssueClientCertificateWithCompletion` + `kMAOptionsBAA*`
  (`...DeleteExistingKeysAndCerts`, `...KeychainLabel`, `...OIDUCRTDeviceIdentifiers`,
  `...Validity`).
- Explicit toggles separating the two:
  - `_shouldUseAbsinthe`, `_shouldUseAbsintheV3`, `_shouldUseAbsintheV4`,
    setter `setShouldUseAbsinthe:`
  - `DisableBAACertOption`, `EnableAbsintheV4Option`
- Graceful no-BAA / fallback code paths exist:
  - `Absinthe is disabled, ignoring it: %@`
  - `Absinthe failed, just disabling`
  - `Using BAA-only validation`  (=> a non-BAA mode is also reachable)
  - `*** Lockdown state is expired, not doing absinthe validation`
  - `Successfully signed baa data in validation session` /
    `Failed signing baa data in validation session`

### Interpretation
Baseline capture showed `absinthe-baa:true` because the device, being BAA-capable,
OFFERS the SEP attestation and folds it into the validation blob (overriding the
gestalt-derived hardware in NAC -> why Phase 2 gestalt spoof was ignored). If the
BAA component is disabled (`DisableBAACertOption` / skip
`DeviceIdentityIssueClientCertificate`) while `shouldUseAbsinthe` stays on, the
daemon emits an **absinthe-only, `baa:false`** validation blob whose hardware
identity comes from what NACInit reads (gestalt / IOReg path) -> SPOOFABLE without
checkm8. This is exactly the path the friend's old-iOS caches used (they are
`baa:false` by default); we can FORCE the same path on this iOS 15.8.5 device.

### Method C (hook, no checkm8) - proposed
1. ellekit tweak in `identityservicesd`:
   - force `shouldUseAbsinthe = YES`, and short-circuit the BAA branch
     (hook `DeviceIdentityIssueClientCertificateWithCompletion` to return
     nil/failure, or force `DisableBAACertOption`) so the validation session
     builds absinthe-only.
   - feed spoofed hardware into the NAC input (gestalt already hookable via
     MGSpoof; verify NACInit's input source — gestalt vs IOReg).
2. Register account, capture: confirm blob shows `absinthe-baa:false` and the
   SPOOFED serial inside the absinthe hardware data.
3. OPEN RISK (server-side, untestable statically): Apple's scoring may flag a
   `baa:false` blob coming from BAA-capable iPhone-class hardware as anomalous and
   reject/limit it. The friend's caches prove `baa:false` spoofed identities are
   accepted in general; whether they pass for *this device class* is the only
   remaining unknown and must be settled empirically with a live registration.

### Bonus: NAC-oracle path (scalable)
`MobileActivation.framework`'s NAC* are directly callable on-device. A small
helper that calls `NACInit/NACKeyEstablishment/NACSign` with an arbitrary
`HardwareConfig` turns this single iPhone 7 into the `get-validation-data`
provider that `rustpush`/`open-absinthe` need (the role the failed macOS VM was
meant to play) — enabling many identities from one device.

---

## Phase 6 - SETTLED: absinthe hardware source is MobileGestalt (MGSpoof-reachable)

Resolves the Phase-5 open TODO ("verify NACInit's input source — gestalt vs
IOReg"). Disassembled the four `IDSValidationSession` hardware getters in
`re/identityservicesd` (the values that get folded into the absinthe
validation-data). They are trivial `MGCopyAnswer` wrappers over **plaintext**
MobileGestalt keys:

| getter (IMP) | reads |
|---|---|
| `_deviceAbsintheSerialNumber` @ `0x1001e8888` | `MGCopyAnswer("SerialNumber")` |
| `_deviceAbsintheIMEI` @ `0x1001e88c0` | `MGCopyAnswer("InternationalMobileEquipmentIdentity")` |
| `_deviceAbsintheMEID` @ `0x1001e88f8` | `MGCopyAnswer("MobileEquipmentIdentifier")` |
| `_deviceAbsintheUDID` @ `0x1001e8854` | obj selector returning `UniqueDeviceID` |

```
0x1001e889c  adrp x0, 0x1009e3000
0x1001e88a0  add  x0, x0, 0xd30        ; cstr "SerialNumber"
0x1001e88a4  mov  x1, 0
0x1001e88a8  bl   MGCopyAnswer          ; <- gestalt, NOT ioreg/SEP
```

=> The serial/IMEI/MEID/UDID that `identityservicesd` injects into the absinthe
blob come straight from MobileGestalt, which `MGSpoof` (a `MGCopyAnswer` hook)
already controls. **No checkm8 needed for the IDS-level identity on the
absinthe/`baa:false` path.** This is why Phase-2 still saw the REAL serial: that
was the `baa:true` path (SEP BAA cert + persisted `registrationV2` dominate) AND
MGSpoof was off in the capture; it does not contradict this.

CAVEAT (still open): the DEEPER NAC fields (board-id, ROM, MLB, and the
obfuscated `Gq3489ugfi`/`Fyp98tpgj`/… encrypted gestalt blobs in
`open-absinthe::HardwareConfig`) are NOT read in `identityservicesd` — they're
harvested inside `MobileActivation.framework`'s NAC routine, which we don't have
pulled yet. Those obfuscated key names ARE MobileGestalt keys, so a global
`MGCopyAnswer` hook should also catch them — but only if `.mgspoof.plist`
supplies those keys with values consistent with the spoofed plaintext serial
(this is what `genfp.py` exists to produce). To fully confirm, pull
`MobileActivation.framework` and disassemble its NAC hardware-gather, OR just run
the live combo never-yet-tested: `.idsbaa_kill` (force absinthe) + MGSpoof ON,
then inspect whether the spoofed serial appears in the emitted blob.

Net: input-source problem is SOLVED (gestalt). The two remaining gates are
unchanged and are NOT about where the serial comes from:
1. emit an internally-consistent `baa:false` blob (naive flag-force gave err26/
   internal38 — see KNOWLEDGE.md FORCE PASS);
2. server-side acceptance/scoring of `baa:false` from BAA-capable iPhone hardware.

---

## Phase 7 - SETTLED: the RELAY blob is minted inside identityservicesd (MGSpoof-reachable)

The relay path was the real question ("we use the iPhone as a relay — what does
it hand over and can we spoof it"). Disassembled `re/beepservd` (pulled from
device) + checked on-device tweak filters. The beepserv mint pipeline:

```
rustpush --(Beeper relay)--> beepservd (pid 77, daemon)
   beepservd:
     - links libMobileGestalt; BPDeviceIdentifiers.cache reads
       MGCopyAnswer("SerialNumber") + MGCopyAnswer("UniqueDeviceID")  => the
       get-version-info {serial, udid} it reports to the relay.
     - does NOT link IDS/MobileActivation and does NOT mint the blob itself.
     - BPValidationDataManager broadcasts NSDistributedNotification
       "com.beeper.beepserv/requestValidationData" and waits.
   BeepservIdentityServices.dylib (injected into identityservicesd) catches the
     notification, mints validation-data using identityservicesd's own NAC /
     IDSValidationSession, posts it back. (Error string proves it:
     "...failed because identityservicesd did not respond with validation data.
      Try reinstalling the tweak...")
```

Tweaks currently loaded in `identityservicesd`: `BeepservIdentityServices`
(minter), `MGSpoof` (gestalt hook), `idsbaa` (force baa:false). They coexist.

CONSEQUENCE — the spoof needs NO new code and NO checkm8:
- The blob's hw identity = identityservicesd's `_deviceAbsinthe*` = MGCopyAnswer
  (Phase 6). MGSpoof ALREADY injects into identityservicesd, so the spoofed
  gestalt feeds the minter — **on the absinthe path**. On baa:true the SEP cert
  still overrides with the real serial, so `idsbaa .idsbaa_kill` is required.
- BUT `beepservd` is NOT in the MGSpoof filter (`mgspoof/MGSpoof.plist` lists
  identityservicesd/apsd/imagent/IMDPersistenceAgent/akd/gestalt only). So the
  version-info serial/udid beepservd reports stays REAL → would MISMATCH the
  spoofed blob. FIX: add `beepservd` to the MGSpoof Executables filter.

### Full spoof recipe (relay path)
1. Add `beepservd` to `mgspoof/MGSpoof.plist` Executables (so reported
   version-info {serial,udid} are spoofed too). Verify injection actually takes
   in beepservd (some daemons resisted ellekit injection before).
2. Write a consistent fake tuple via `genfp.py` to `/var/mobile/.mgspoof.plist`
   (SerialNumber, UniqueDeviceID, IMEI/MEID, ECID/DieID; keep ProductType/
   HardwareModel/BoardId real).
3. Arm `idsbaa`: `.idsbaa_kill` + `.idsbaa_invalidate` (force absinthe-only so the
   gestalt identity lands in the blob instead of the SEP real serial).
4. Restart `identityservicesd` + `beepservd`; mint via `rustpush --relay-test`.
5. Verify: `hwconfig.plist` shows the SPOOFED serial/udid AND the minted blob /
   subsequent `registrationV2 private-device-data` carry the spoofed serial.

### Still-open gates (unchanged, NOT input-source)
- naive `.idsbaa_kill` alone previously gave register err26/internal38 — the
  forced baa:false blob must be internally consistent (deeper NAC fields:
  board/ROM/MLB + obfuscated enc keys, harvested inside MobileActivation.framework,
  possibly also via MGCopyAnswer → may need those keys in `.mgspoof.plist`).
- server-side acceptance/scoring of baa:false from BAA-capable iPhone hardware.

### EXACT mint mechanism (from beeper/phone-registration-provider source)
beepserv does NOT call NAC itself. Inside `identityservicesd` it:
1. `IDSDAccountController.sharedInstance.accounts` → finds an account with a valid
   `.registration` (forces `_checkRegistration` if needed). **=> the device must
   be signed into iMessage for a mint to work; the blob is built in the context of
   that existing registration.**
2. `[[IDSRegistrationCenter sharedInstance] _sendAuthenticateRegistration:reg]` —
   runs identityservicesd's NORMAL authenticate flow (the same
   `buildValidationCredentialsIfNeededForSubsystem:` path we disassembled).
3. Captures the blob with `%hook IDSRegistrationMessage -setValidationData:` (stores
   the global `validationData`, signals a semaphore, 60s timeout).
So the relay blob == exactly what identityservicesd would send Apple during a real
registration == the `IDSValidationSession` / `_deviceAbsinthe*` (MGCopyAnswer) path.
Confirms: MGSpoof (already in identityservicesd) controls the blob's identity on the
absinthe path; baa:true default still needs `.idsbaa_kill`.

version-info (`getIdentifiers()` / `BPDeviceIdentifiers`):
- `serial_number` = `MGCopyAnswer("SerialNumber")`  → MGSpoof-reachable.
- `hardware_version` = `uname().machine` (NOT gestalt; uname hook would be needed —
  but model is kept real anyway, so fine).
- `software_version` = UIDevice.systemVersion; `software_build_id` = sysctl
  kern.osversion; `software_name` = hardcoded "iPhone OS".
- `unique_device_id` = `UIDevice.identifierForVendor` (IDFV) — a per-vendor UUID,
  NOT the real UDID and NOT gestalt. So the relay never reports the true UDID here.
NOTE on versions: the GitHub repo is the MONOLITHIC build (websocket + mint hook all
inside identityservicesd, so its `getIdentifiers` serial read is already MGSpoof-
covered). The DEVICE runs split 0.2.0 (`beepservd` daemon + `BeepservIdentityServices
.dylib`); there `BPDeviceIdentifiers.cache` runs in `beepservd` → beepservd MUST be
added to the MGSpoof filter for the reported serial to be spoofed. Mint hook still
runs in identityservicesd (already covered).

---

## Phase 8 - PLAN: baa:false is the unlock; test it OFF-DEVICE (not on-device)

Re-scoping after re-reading idsbaa/Tweak.xm + beepserv source. Key correction to the
FORCE PASS: that err26/internal38 was the **device's OWN on-device registration**
failing with forced baa:false. The farm does NOT need the device to register — it
needs the relay-captured blob to be ACCEPTED when rustpush registers an account
OFF-device. beepserv's `%hook IDSRegistrationMessage -setValidationData:` captures
the blob BEFORE it is sent to Apple, so we can capture a forced-baa:false blob even
if the device's own registration then fails. => off-device acceptance of baa:false
is UNTESTED and is the real question.

Tools already in place (no new code needed to test):
- idsbaa `.idsbaa_kill` = force baa:false (suppress BAA sender + isUsingBAA/
  _shouldUseBAACertOption/_shouldUseBAAOnly = NO).
- idsbaa `.idsbaa_spoofserial` = directly override `_deviceAbsintheSerialNumber/
  _UDID/_IMEI` from `.mgspoof.plist` (more direct than MGSpoof for the BLOB).
- idsbaa `.idsbaa_invalidate` = evict cached validation so the build re-runs.
- rustpush `--relay-test` (capture blob to hwconfig) and `--register` (off-device).

Ordered experiment (isolate one variable at a time):
1. BASELINE: idsbaa OFF, mgspoof OFF → `--relay-test`; save the baa:true blob.
2. baa:false REAL serial: arm `.idsbaa_kill` + `.idsbaa_invalidate`, restart idsd,
   `--relay-test`; save blob. Diff vs baseline (length/structure). Then
   `--register` a REAL/known-good Apple ID off-device → does Apple ACCEPT (status 0,
   lookups resolve)?  ← THE decisive gate. Isolates baa:false-acceptance from spoof.
   - if ACCEPTED → baa:false works off-device; go to step 3.
   - if REJECTED → the baa:false blob itself is the problem; decode/diff to find the
     missing/incomplete NAC component (deeper than just flipping booleans).
3. baa:false SPOOFED serial: also arm `.idsbaa_spoofserial` + consistent genfp tuple
   in `.mgspoof.plist` + add `beepservd` to MGSpoof filter (version-info serial).
   `--register` → confirm spoofed serial in registrationV2/private-device-data AND
   Apple accepts AND lookups resolve. = full device spoof proven.

err26/internal38 are IDS registration error codes (mapped by
`identityservicesd -_errorCodeForRegistrationError:`); exact enum value is less
important than the empirical off-device accept/reject in step 2.

### Phase 8 RESULT (Jun 30) — STEP 2 PASSED: baa:false accepted off-device
- Gotcha first: beepservd caches the minted blob IN MEMORY; a relay request returns the
  cache and does NOT re-drive idsd (hooks don't fire). Must `killall -9 beepservd` to
  force a fresh mint. Without this the baa:false flag had no effect on the returned blob.
- After beepservd restart + `.idsbaa_kill`: relay minted a genuine forced-baa:false blob
  (idsbaa.log: BAA sender suppressed, isUsingBAA/_shouldUseBAACertOption/_shouldUseBAAOnly
  forced 0; only absinthe cert fired; real serial F4JSDXCEHG7K). Blob differs from the
  baa:true baseline (both 261B, differ from byte 2) = same token format, different signing.
- `--register hilmiazizi19@icloud.com` (cached login) consumed that baa:false blob:
  register response top-level status 0; madrid/multiplex1/facetime.multi/ess all status 0.
- `--test-lookup mailto:rikaazizi31@gmail.com` => LOOKUP OK, valid:[handle]. Identity
  resolves => not the issued-but-disabled empty result. baa:false works END-TO-END.
- => The old FORCE PASS err26/38 was ONLY the phone's own on-device registration. The
  off-device relay model accepts absinthe-only (baa:false) validation-data. SEP BAA cert
  is NOT required off-device. Step 3 (spoofed serial via .idsbaa_spoofserial) is unblocked.

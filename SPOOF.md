# beepserv-rewrite spoof fork

Fork of `thatmarcel/beepserv-rewrite` that makes beepserv a **standalone** spoofing
provider: it generates its own format-valid iPhone identity on the phone, forces the
validation-data onto the `baa:false` (software Absinthe) path, and folds the spoofed
serial into both the reported version-info and the minted blob. This replaces the two
external research tweaks (`idsbaa` + `MGSpoof`). rustpush is unchanged — it only holds
the relay code.

See `../beepserv-fork/SPOOF_FORK.md` for the full background (what BAA is, why we force
`baa:false`, how rustpush uses validation-data).

## What was added
- **`IdentityServices/bp_spoof.x`** (new, injected into `identityservicesd`):
  - `MGCopyAnswer` hook → the NAC/`nac_sign` routine reads the spoofed
    SerialNumber/UniqueDeviceID/IMEI (this is what MGSpoof did, now scoped to idsd).
  - `IDSValidationQueue._sendBAAValidationRequestIfNeededForSubsystem:` suppressed and
    `IDSValidationSession.isUsingBAA/_shouldUseBAACertOption/_shouldUseBAAOnly` → NO
    (force `baa:false`; this is what idsbaa did).
- **`Controller/BPDeviceIdentifiers.{h,m}`**:
  - On-phone identity generator ported from `../mgspoof/genfp.py` (valid Apple serial
    `PPP Y W SSS CCCC`, Luhn IMEI, 40-hex UDID; plant/config/TAC seeded from the real
    device so the tuple stays a plausible iPhone9,3).
  - `+ensureSpoofIdentity` — generate-if-missing / rotate-on-flag, persisted to
    `/var/mobile/.beepserv_spoof.plist`.
  - version-info `serial_number` + `unique_device_id` now read the spoof (so the
    reported identity matches the minted blob).
- **`Controller/main.m`**: calls `+ensureSpoofIdentity` at daemon startup.
- **Makefiles**: rootful branch retargeted to the local theos toolchain
  (`iphone:clang:latest:14.0`, `arm64`) instead of a macOS Xcode path; `chown 0:0`.

Source of truth: `/var/mobile/.beepserv_spoof.plist` (`SerialNumber`, `UniqueDeviceID`,
`InternationalMobileEquipmentIdentity`, `Enabled`). Absent/`Enabled=NO` ⇒ stock behavior.

## Build
```
git submodule update --init --recursive
make package          # rootful; .deb in ./packages/
```

## Rotate to a new device identity
```
# phone
touch /var/mobile/.beepserv_rotate && killall -9 beepservd identityservicesd
# linux (rustpush): force a fresh version-info pull, then register
rm -f hwconfig.plist
./target/release/rustpush-test --register --relay-code=XXXX-XXXX-XXXX-XXXX
```

## Verified on-device (iPhone9,3, iOS 15.8.5, rootful)
- daemon auto-generated `F4JYLQ9NHG7K`; relay pairing preserved across the dpkg upgrade.
- `--relay-test` → version-info serial `F4JYLQ9NHG7K`, 261-byte blob minted.
- `--register` → "Registration complete. serial=F4JYLQ9NHG7K" (Apple accepted).
- `--test-lookup mailto:rikaazizi31@gmail.com` → LOOKUP OK (identity live).
- rotate flag → new serial `F4JW3RPYHG7K`; flag consumed.

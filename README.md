# beepserv (spoofing fork)

A tweak for jailbroken iPhones that provides iMessage **registration data** (validation
data) to an off-device client over Beeper's relay.

This fork makes beepserv a **standalone device-identity spoofing provider**: it generates
its own *format-valid* iPhone identity on the phone, forces validation onto the software
Absinthe (`baa:false`) path, and folds the spoofed serial into both the reported
version-info and the minted validation-data blob. This replaces the two external research
tweaks it grew out of (`idsbaa` for `baa:false`, `MGSpoof` for the gestalt serial) — now
everything happens inside beepserv. The off-device client (e.g. rustpush) is unchanged and
only needs the relay code.

> Fork of [thatmarcel/beepserv-rewrite](https://github.com/thatmarcel/beepserv-rewrite),
> itself a rewrite of the original [beepserv](https://github.com/beeper/phone-registration-provider).
> See `SPOOF.md` for integration notes and `iphone/beepserv-fork/SPOOF_FORK.md` (in the
> rustpush workspace) for the full background on BAA, why `baa:false` is required, and how
> validation-data is used.

## What this fork adds
- **`IdentityServices/bp_spoof.x`** (injected into `identityservicesd`):
  - hooks `MGCopyAnswer` so the NAC / `nac_sign` routine reads the spoofed
    `SerialNumber` / `UniqueDeviceID` / `IMEI` instead of the real fused-in values;
  - forces `baa:false` (`IDSValidationQueue._sendBAAValidationRequestIfNeededForSubsystem:`
    suppressed; `IDSValidationSession.isUsingBAA/_shouldUseBAACertOption/_shouldUseBAAOnly`
    → `NO`) so the spoofable gestalt serial is folded into the blob, not the SEP-attested one.
- **`Controller/BPDeviceIdentifiers`**: an on-phone generator (valid Apple serial
  `PPP Y W SSS CCCC`, Luhn IMEI, 40-hex UDID; plant + config + IMEI TAC seeded from the
  **real** device so the tuple stays a plausible model) and `+ensureSpoofIdentity`
  (generate-if-missing / rotate-on-flag). version-info `serial_number` + `unique_device_id`
  now read the spoof so they match the minted blob.
- **`Controller/main.m`**: generates/rotates the identity at daemon startup.

### Spoof configuration
Source of truth is `/var/mobile/.beepserv_spoof.plist` (rootless:
`/var/jb/var/mobile/.beepserv_spoof.plist`), written by the Controller:

| key | meaning |
| --- | --- |
| `SerialNumber` | spoofed 12-char serial |
| `UniqueDeviceID` | spoofed 40-hex UDID |
| `InternationalMobileEquipmentIdentity` | spoofed IMEI |
| `Enabled` | optional bool, default `YES` when the file exists |

If the file is absent or `Enabled=NO`, every hook is a transparent passthrough and beepserv
behaves like stock (real identity, `baa:true`).

## The 4 components
- **Application**: app showing the registration code, logs, and notification toggle
- **Controller**: launch daemon managing the relay connection (+ identity generation here)
- **NotificationHelper**: hooks `SpringBoard` to send local notifications
- **IdentityServices**: hooks `identityservicesd`, generates validation data (+ the spoof)

## Building
Requires [Theos](https://theos.dev/docs/installation) (`$THEOS/bin/update-theos` to update).

```sh
git submodule update --init --recursive
make clean package FINALPACKAGE=1            # rootful  -> ./packages/*.deb
# or
make clean package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

This fork's Makefiles build against the Theos-managed SDK/toolchain
(`iphone:clang:latest:14.0`, `arm64`) — no local Xcode is required. (Upstream hardcoded a
macOS `Xcode_11.7` path for arm64e/iOS 12-13.7 compatibility; if you need that, restore the
original `PREFIX`/`SYSROOT` block and add `arm64e` back to `ARCHS`.)

## Usage
The tweak runs in the background, connected to the relay, ready to provide validation data.

Open the beepserv app to read the registration code (or SSH in and run
`cat /var/mobile/.beepserv_state`, rootless `cat /var/jb/var/mobile/.beepserv_state`).
Give that code to your off-device client.

### Rotate to a new device identity
```sh
# on the phone
touch /var/mobile/.beepserv_rotate && killall -9 beepservd identityservicesd
```
On the next start the Controller generates a fresh valid identity, persists it, and clears
the flag (the restart also flushes identityservicesd's cached Absinthe cert). Then re-pull
version-info on the client (e.g. rustpush: `rm -f hwconfig.plist` before `--register`) so
the new serial propagates. The relay pairing in `.beepserv_state` is preserved across this.

### Using a self-hosted relay
Replace the URL with your own [registration relay](https://github.com/beeper/registration-relay):

**Rootful**
```sh
launchctl unload /Library/LaunchDaemons/com.beeper.beepservd.plist
echo "https://registration-relay.beeper.com/api/v1/provider" > /var/mobile/.beepserv_relay_url
rm -f /var/mobile/.beepserv_state
launchctl load /Library/LaunchDaemons/com.beeper.beepservd.plist
```

**Rootless**
```sh
launchctl unload /var/jb/Library/LaunchDaemons/com.beeper.beepservd.plist
echo "https://registration-relay.beeper.com/api/v1/provider" > /var/jb/var/mobile/.beepserv_relay_url
rm -f /var/jb/var/mobile/.beepserv_state
launchctl load /var/jb/Library/LaunchDaemons/com.beeper.beepservd.plist
```

## Credits
Original [beepserv](https://github.com/beeper/phone-registration-provider) by Beeper
(James Gill, June Welker); rewrite by [thatmarcel](https://github.com/thatmarcel/beepserv-rewrite).

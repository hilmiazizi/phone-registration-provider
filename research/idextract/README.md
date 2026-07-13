# idextract — clone the iPhone's signed-in iMessage identity into a bbox

## Why a tweak (and not keychain_dumper)

The bbox only needs three secrets for an HTTP `id-query` lookup:

| bbox tag | field        | where it lives on the phone                          |
|----------|--------------|------------------------------------------------------|
| `0x21`   | push token   | identityservicesd / apsd                             |
| `0x31`   | id_cert      | keychain (`com.apple.identities`) — the IDS cert     |
| `0x32`   | id_priv_der  | keychain (`com.apple.identities`) — RSA-2048 key     |

`keychain_dumper` returned **0 bytes** for the key/cert because it ran as a
standalone binary: it had neither the `com.apple.identities` access group nor
the entitlements to read `...ThisDeviceOnly` items. Running the *same*
`SecItemCopyMatching` from **inside identityservicesd** (via ellekit) inherits
the daemon's access groups, so the bytes come back decrypted.

## Build (Theos + ellekit)

```bash
export THEOS=/opt/theos
cd research/idextract
make package        # produces ./packages/com.zeroday.idextract_0.1.0_iphoneos-arm64.deb
```

Install the `.deb` on the phone (`dpkg -i` over SSH, or AppSync/Filza), then
respring / reload.

## Run

1. **Unlock the phone** (items are `WhenUnlocked` / `ThisDeviceOnly`).
2. Trigger a fresh load of the daemon so the `%ctor` fires:
   ```bash
   ssh root@localhost -p 2222 'killall identityservicesd'   # launchd respawns it
   ```
3. Wait ~10s, then pull the dump:
   ```bash
   scp -P 2222 root@localhost:/var/mobile/idextract.json .
   ```
   Check the device console / `idevicesyslog | grep idextract` for the line
   `wrote N items to /var/mobile/idextract.json`.

## Assemble the bbox (off-device)

```bash
pip install cryptography
python3 ../assemble_bbox.py idextract.json \
    --handle mailto:hilmiazizi19@icloud.com \
    --serial <device-serial> \
    -o caches.json
```

The script auto-pairs the RSA key with its certificate (modulus match) and
lists push-token candidates. If it picks the wrong token, re-run with
`--push-token <base64>`.

The resulting `caches.json` is the exact array-of-base64 format rustpush's
`Bbox::parse_b64` consumes — no registration, anisette, or APNs connection
needed for lookups.

## Notes / things to verify on the first real run

- **Push token**: the IDS push token may not appear as a clean 32-byte keychain
  blob. If `assemble_bbox.py` can't find it, read it from the decoded
  registration (`com.apple.madrid.plist` / the `services` blob in `ids.tar`) or
  from apsd, and pass `--push-token`.
- **RSA key format**: the script tries PKCS#8 and PKCS#1. If the key is stored
  wrapped (length-prefixed), inspect the raw `v_Data` and strip the wrapper
  before re-running.
- This clones **one** identity (the one signed in). To mint many, this is the
  per-cycle extraction step in the manufacturing SOP — rotate the device
  fingerprint and re-register between extractions.

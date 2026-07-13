# Fresh install — iPhone 7 spoofing provider

This phone exists for one job: mint **spoofed** validation-data for Beeper / rustpush.
**Spoof + `baa:false` is the only supported mode** — never leave the provider on the
real fused serial for farm use.

Pinned product build: **`com.beeper.beepserv` 0.2.0-22**

Production kit (no on-phone build) — see [`releases/`](releases/):

| Artifact | Path | Required? |
|----------|------|-----------|
| beepserv | [`releases/com.beeper.beepserv_0.2.0-22_iphoneos-arm.deb`](releases/com.beeper.beepserv_0.2.0-22_iphoneos-arm.deb) | **Yes** |
| Rotate CLI | [`ops/relayrotate`](ops/relayrotate) → `/var/root/relayrotate` | **Yes** |
| baawipe | [`releases/com.zeroday.baawipe_0.1.0_iphoneos-arm.deb`](releases/com.zeroday.baawipe_0.1.0_iphoneos-arm.deb) | Repair only |
| dcrtforce | [`releases/com.zeroday.dcrtforce_0.1.0_iphoneos-arm.deb`](releases/com.zeroday.dcrtforce_0.1.0_iphoneos-arm.deb) | Repair only |

Also: [ARCHITECTURE.md](ARCHITECTURE.md) · [FARM.md](FARM.md) · [REPAIR.md](REPAIR.md)

## Prerequisites

- iPhone 7 (`iPhone9,3`), iOS **15.8.5**
- **palera1n rootful** + ElleKit / MobileSubstrate
- OpenSSH; phone **unlocked** during mint
- Wi‑Fi that allows Apple services (APNs)
- **Do not sign into Apple ID / iMessage** on this phone

## Install (once per phone)

```bash
scp releases/com.beeper.beepserv_0.2.0-22_iphoneos-arm.deb \
    ops/relayrotate \
    mobile@PHONE:/var/mobile/

ssh mobile@PHONE 'echo SUDO_PASS | sudo -S bash -lc "
  dpkg -i /var/mobile/com.beeper.beepserv_0.2.0-22_iphoneos-arm.deb
  install -m 755 /var/mobile/relayrotate /var/root/relayrotate
  dpkg -r com.zeroday.idsbaa com.local.mgspoof com.zeroday.idextract 2>/dev/null || true
  killall -9 identityservicesd beepservd 2>/dev/null || true
  launchctl kickstart -k system/com.beeper.beepservd
"'
```

Spoof lives **inside** beepserv (`bp_spoof.x`). Do not install `idsbaa` / `MGSpoof`.

## First bring-up = first spoof rotate (required)

After install, **always** run `relayrotate` once before handing a code to rustpush.
That is what turns spoof on (`Enabled=true`), arms `baa:false`, and prints a farm identity.

```bash
# phone unlocked, as root
/var/root/relayrotate
```

It will:

1. Force `.beepserv_spoof.plist` → `Enabled=true`
2. Arm `.beepserv_kill` → Absinthe `baa:false` (blob carries spoofed serial, not SEP)
3. Generate serial / UDID / IMEI
4. Issue a new relay code
5. Restart daemons and soft-invalidate mint cache

Confirm before continuing:

```bash
python3 - <<'PY'
import plistlib
d = plistlib.load(open("/var/mobile/.beepserv_spoof.plist", "rb"))
assert d.get("Enabled") is not False, "spoof must be Enabled"
print("Enabled", d.get("Enabled", True))
print("serial ", d["SerialNumber"])
print("udid   ", d["UniqueDeviceID"])
print("imei   ", d["InternationalMobileEquipmentIdentity"])
# Real fused serial on this fleet is F4JSDXCEHG7K — farm serial must differ
assert d["SerialNumber"] != "F4JSDXCEHG7K", "still on real serial — rotate failed"
print("OK spoof identity ready")
PY
grep -A1 com.beepserv.code /var/mobile/.beepserv_state
```

## Smoke test (spoof-aware)

```bash
CODE=$(python3 -c "import plistlib; print(plistlib.load(open('/var/mobile/.beepserv_state','rb'))['com.beepserv.code'])")

curl -sS --max-time 30 -X POST \
  "https://registration-relay.beeper.com/api/v1/bridge/get-version-info" \
  -H "Authorization: Bearer $CODE" \
  -H "X-Beeper-Access-Token: 5c175851953ecaf5209185d897591badb6c3e712" \
  -H "Content-Length: 0"
```

**Pass:** `serial_number` equals `.beepserv_spoof.plist` `SerialNumber` (spoofed), **not** the
real `F4JSDXCEHG7K`.

```bash
curl -sS --max-time 90 -X POST \
  "https://registration-relay.beeper.com/api/v1/bridge/get-validation-data" \
  -H "Authorization: Bearer $CODE" \
  -H "X-Beeper-Access-Token: 5c175851953ecaf5209185d897591badb6c3e712" \
  -H "Content-Length: 0"
```

**Pass:** HTTP **200**, base64 decoding to **~261 bytes**.

**Fail:** version-info still shows real serial → spoof off / daemons not restarted; fix with
`/var/root/relayrotate` again.

## Build from source (maintainers)

```bash
git submodule update --init --recursive
make clean package FINALPACKAGE=1
# Copy intended deb into releases/ and bump this file’s version pin
```

## Repair kit (break-glass only)

Prebuilt debs are in [`releases/`](releases/). When Absinthe/DeviceIdentity/DCRT is dead,
see **[REPAIR.md](REPAIR.md)** (`baawipe` + `dcrtforce`).

Never hard-nuke Accounts3 / IdentityServices / `*-ucrt` as part of rotate.  
Never set `Enabled=false` on a farm phone except deliberate real-HW debug (not Beeper farm).  
Never install `idsbaa` / `MGSpoof` — spoof is inside beepserv.

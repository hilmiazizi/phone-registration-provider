# releases/ — production install kit (no build required on the phone)

Copy these onto a jailbroken iPhone 7. Spoof + mint live in **beepserv**;
baawipe / dcrtforce are **repair-only**.

## Always install (farm)

| File | Package | Role |
|------|---------|------|
| `com.beeper.beepserv_0.2.0-23_iphoneos-arm.deb` | `com.beeper.beepserv` | Spoof + `baa:false` + Absinthe mint + relay + `/usr/bin/relayrotate` |

## Repair kit (install only when mint breaks)

| File | Package | When |
|------|---------|------|
| `com.zeroday.baawipe_0.1.0_iphoneos-arm.deb` | `com.zeroday.baawipe` | DeviceIdentity certs dead / Absinthe stuck |
| `com.zeroday.dcrtforce_0.1.0_iphoneos-arm.deb` | `com.zeroday.dcrtforce` | DCRT expired / won't renew |

See [REPAIR.md](../REPAIR.md).

## Not in this folder (do not install on farm phones)

- `idsbaa` / `MGSpoof` / `idextract` — superseded by beepserv spoof; sources under `research/`

## One-liner install

```bash
scp releases/com.beeper.beepserv_0.2.0-23_iphoneos-arm.deb mobile@PHONE:/var/mobile/

ssh mobile@PHONE 'echo SUDO_PASS | sudo -S bash -lc "
  dpkg -i /var/mobile/com.beeper.beepserv_0.2.0-23_iphoneos-arm.deb
  dpkg -r com.zeroday.idsbaa com.local.mgspoof com.zeroday.idextract 2>/dev/null || true
  relayrotate
"'
```

After `make package`, copy the intended beepserv deb here and bump versions in
[INSTALL.md](../INSTALL.md). Rebuild repair tweaks from `tools/baawipe` /
`tools/dcrtforce` the same way.

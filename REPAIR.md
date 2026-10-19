# Production repair kit — baawipe + dcrtforce

Use only when **spoof mint fails** after beepserv + `relayrotate` are healthy
(relay connected, hooks load, but no `setValidationData` / HTTP 500 forever).

Normal farm phones need **only** beepserv + `relayrotate`. These packages are
optional insurance.

## Symptoms → tool

| Symptom | Tool | Arm |
|---------|------|-----|
| DeviceIdentity never returns certs; Absinthe hello missing | **baawipe** | touch `/var/mobile/.baawipe_locationd` and/or `.baawipe_identityservicesd`, restart those daemons |
| DCRT expired / `issueDCRT` never runs | **dcrtforce** | touch `/var/mobile/.dcrt_force`, restart `mobileactivationd` |

Debs: [`releases/`](releases/).

```bash
dpkg -i com.zeroday.baawipe_0.1.0_iphoneos-arm.deb
dpkg -i com.zeroday.dcrtforce_0.1.0_iphoneos-arm.deb
```

Source: [`tools/baawipe`](tools/baawipe), [`tools/dcrtforce`](tools/dcrtforce).

## Do not

- Do not hard-nuke Accounts3 / IdentityServices / Absinthe `*-ucrt` as “repair”
- Do not install **idsbaa** for repair — spoof/`baa:false` is inside beepserv
- Do not leave baawipe/dcrtforce flags armed after success (one-shot)

## After repair

```bash
relayrotate
# smoke: get-version-info shows spoofed serial; get-validation-data → 200 / ~261B
```

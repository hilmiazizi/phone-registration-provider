# Farm loop — spoof rotate → Beeper / rustpush register

**Every validation-data request generates a new spoof identity and mints against it.** You do not run `relayrotate` between Apple IDs. `relayrotate` only issues a new relay code.

rustpush calls `get-version-info` first, then `get-validation-data`. The phone rotates on the validation call, and rustpush re-reads version-info immediately after so the serial it registers matches the blob.

Setup: [INSTALL.md](INSTALL.md). Architecture: [ARCHITECTURE.md](ARCHITECTURE.md).

## Per Apple ID

Phone **unlocked**. No manual rotate.

```bash
cd ~/imessage/rustpush
rm -f hwconfig.plist
RUST_LOG=info ./target/release/rustpush-test \
  --register --relay-code=RELAY-CODE
```

The validation request on the phone writes a new serial, UDID, and IMEI, then mints the blob for that identity. rustpush reads version-info again after the mint and registers with that serial.

`relayrotate` is only when you want a **new relay code**. It is not part of each registration.

```bash
cargo build --release --bin rustpush-test \
  --features 'macos-validation-data,remote-anisette-v3'
```

### 3) Export BBOX (optional)

```bash
./target/release/rustpush-test --export-bbox …
```

### Next account

Run `--register` again. The phone rotates on that validation request.

## Guardrails

| Do | Don't |
|----|-------|
| Let each validation request rotate | Run `relayrotate` between accounts |
| Keep `Enabled=true` + `.beepserv_kill` | Set `Enabled=false` on farm phones |
| Soft rotate only | Nuke Accounts3 / IdentityServices / `*-ucrt` |
| Unlock during mint | Mint while locked |
| Flush `beepservd` after rotate (script does) | Reuse cached blob from prior identity |

## Two identities (both rotate per account)

| Identity | Where | How |
|----------|-------|-----|
| Phone spoof (serial/UDID/IMEI in blob) | iPhone | automatic, on each `get-validation-data` |
| Anisette `X-Apple-I-MD-M` | rustpush host | per-account `anisette_test/<email>.plist` |

## Smoke after rotate

```bash
# version-info serial == spoof plist serial
# get-validation-data → HTTP 200, ~261 bytes
```

See curl examples in [INSTALL.md](INSTALL.md).

## Sticky spoof (debug only — still spoofed)

Same spoofed identity, re-mint only (not the multi-account default):

```bash
touch /var/mobile/.beepserv_kill /var/mobile/.beepserv_invalidate
killall -9 beepservd identityservicesd
launchctl kickstart -k system/com.beeper.beepservd
```

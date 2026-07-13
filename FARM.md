# Farm loop — spoof rotate → Beeper / rustpush register

**Every Beeper registration uses a spoofed iPhone identity.** There is no “real serial”
farm path. Before each Apple ID:

1. Phone: `/var/root/relayrotate` (new spoof + `baa:false` + new relay code)
2. Linux: `rustpush-test --register --relay-code=…`

Setup: [INSTALL.md](INSTALL.md). Architecture: [ARCHITECTURE.md](ARCHITECTURE.md).

## Per Apple ID

Phone **unlocked**.

### 1) Spoof rotate (required)

```bash
ssh mobile@PHONE 'echo SUDO_PASS | sudo -S /var/root/relayrotate'
```

`relayrotate` always:

| Step | Effect |
|------|--------|
| `Enabled=true` | Spoof on (refuses farm passthrough) |
| `.beepserv_kill` | Force Absinthe `baa:false` so blob uses spoofed serial |
| `.beepserv_rotate` | New serial / UDID / IMEI |
| Clear `.beepserv_state` | New relay code |
| Soft invalidate + restart | Fresh mint; Absinthe ucrt kept |

Copy the printed **serial** and **relay code**. Serial must not be the fused real one.

### 2) Register on Linux (rustpush)

```bash
cd ~/imessage/rustpush
rm -f hwconfig.plist
RUST_LOG=info ./target/release/rustpush-test \
  --register --relay-code=NEW-CODE-HERE
```

```bash
cargo build --release --bin rustpush-test \
  --features 'macos-validation-data,remote-anisette-v3'
```

### 3) Export BBOX (optional)

```bash
./target/release/rustpush-test --export-bbox …
```

### 4) Next account

Run `relayrotate` again → new spoof → new `--register`.

## Guardrails

| Do | Don't |
|----|-------|
| Spoof every cycle via `relayrotate` | Ship version-info / blob with real serial |
| Keep `Enabled=true` + `.beepserv_kill` | Set `Enabled=false` on farm phones |
| Soft rotate only | Nuke Accounts3 / IdentityServices / `*-ucrt` |
| Unlock during mint | Mint while locked |
| Flush `beepservd` after rotate (script does) | Reuse cached blob from prior identity |

## Two identities (both rotate per account)

| Identity | Where | How |
|----------|-------|-----|
| Spoofed serial / UDID / IMEI (in validation-data) | iPhone | `relayrotate` |
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

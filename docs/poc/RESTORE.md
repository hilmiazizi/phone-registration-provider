# Restore procedure (PoC rollback)

The PoC may sign out / wipe the working account. Use this to get back to a
working logged-in state.

## What IS file-restorable (in `device_state.tar`)
- `MGSpoof.plist` / `.plist.bak` / `.dylib`
- `/var/mobile/Library/IdentityServices/` (IDS dbs, PDS cache)
- `/var/mobile/Library/Application Support/com.apple.akd/` (authorization.db)
- `/var/mobile/Library/Caches/com.apple.akd/`
- `/var/root/Library/Lockdown/data_ark.plist`

## What is NOT file-restorable (important)
The IDS identity keys (`com.apple.identities` keychain access group) and the
ADI / anisette provisioning are **SEP-wrapped keychain items**, not files. They
cannot be tar-backed-up or hand-restored. The only way to restore a working
identity is to **re-login the Apple ID** (Settings -> Messages -> Send & Receive,
or full Apple ID sign-in), which re-provisions these from Apple. This is itself a
PoC finding (it is the Method B wall).

## Restore steps
1. Restore MGSpoof to the known-good (currently passthrough) config:
   ```bash
   python3 _ssh.py --sudo 'cp /Library/MobileSubstrate/DynamicLibraries/MGSpoof.plist.bak /Library/MobileSubstrate/DynamicLibraries/MGSpoof.plist'
   ```
2. (Optional) Restore the file state from the tar if dbs got corrupted:
   ```bash
   B=$(cat poc/LATEST_BACKUP.txt)        # or the specific backup_* dir
   # push device_state.tar to /tmp on the phone, then on-device:
   #   cd / && tar xf /tmp/device_state.tar
   # (do this with daemons stopped: killall -9 identityservicesd imagent akd apsd)
   ```
3. Reboot the phone (`python3 _ssh.py --sudo reboot`) so daemons re-read state.
4. Re-login the Apple ID on the device UI (this restores the keychain/ADI items
   that files cannot). Confirm iMessage activates.

## Known-good reference state (from manifest.txt at backup time)
- Real serial (kernel/ioreg): `F4JSDXCEHG7K`
- IOPlatformUUID: `B2350563-9D43-550F-A549-D10DA3239FCB`
- MGSpoof filter: identityservicesd, imagent, IMDPersistenceAgent, gestalt
  (akd/apsd intentionally excluded so login works on real anisette)

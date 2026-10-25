# June Local installer v0.8 release notes

Released: 2026-10-24

Build: `20261024-1602-b5ca5293`

ISO: `june-local-live.iso`

SHA-256: `19378a2b9d75339d82655c8cf032b2d5caead5da71968563a5d94f7a45f824f3`

Size: `1,413,529,600` bytes

## Highlights

### Factory reset is no longer fatal

The oven now ships a per-oven identity seed, and June Local re-creates the
June account row on the next boot when a factory reset wiped it. A reset no
longer leaves the oven permanently "disconnected"; re-pair the phone or Home
Assistant afterwards and the oven is back. The status page also reports the
identity state directly, so this failure mode is visible instead of mysterious.

This fix exists because of a detailed community report: a correctly installed
v0.7 oven still showed `oven.connection=disconnected` after a factory reset,
and the reporter patiently captured the symptoms, tested the workaround, and
re-tested the fix. Thank you, Brooks—your report turned a day-long mystery
into a design we could actually ship.

### Two clear install modes

- **Connect by IP** (recommended): a per-home certificate authority and a
  certificate that includes the oven's LAN IP. No hostname or DNS setup.
- **Connect by name (june.local)**: the project CA goes into the oven's trust
  store, and the new **JuneDns** helper advertises `june.local`,
  `june2.local`, or `june3.local` over mDNS. If multicast is blocked on the
  network, add a local DNS entry or use Connect by IP.

### Every paired device stays paired

The oven now serves the complete paired-companion roster, so pairing a second
phone no longer hides Home Assistant or earlier phones after a reboot.

### Status page tells the truth

The `/local` status page now shows the oven identity, certificate trust state,
and clear red/yellow problems with concrete fix instructions—including the
exact factory-reset recovery path.

## Known notes

- mDNS is multicast: some networks (guest/isolated VLANs, aggressive IGMP
  snooping) block it. **Connect by IP** always works.
- In both modes the phone must trust the CA: download it from
  `http://<oven-ip>/local/ca.crt` after the install.
- Keep the project CA private key offline. A basic install makes it the trust
  anchor for every oven that uses it; Connect by IP uses a unique per-home CA
  instead.
- Make a full backup from the installer before changing anything; the
  installer can restore it.

Thanks to everyone who reported and reproduced the beta issues. This release
is yours as much as ours.

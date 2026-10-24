# June Local DNS (`com.july.dns`)

A tiny system app whose only job is to start Android's mDNS responder and
advertise the oven as `<name>.local`. It is deliberately separate from the
June Light Bridge (`com.july.oven`): the camera/light helper stays focused and
this one can be installed/disabled on its own.

The installer writes the chosen oven name to `/system/etc/june_hostname`, and
`june_bootclear.sh` starts this service after `boot_completed`:

```sh
am startservice --user 0 -n com.july.dns/.MdnsService
```

## What the service does

`MdnsService` (`smali/com/july/dns/MdnsService.smali`):

- `onCreate`: acquires a `WifiManager.MulticastLock` (so multicast queries are
  not filtered while the Wi-Fi stack is idle), reads the oven name from
  `/system/etc/june_hostname` (falling back to `net.hostname`, then `june`),
  and registers a DNS-SD service with `NsdManager`:
  `NsdServiceInfo("June Local", "_http._tcp", port 80, host "<name>.local")`.
- `onStartCommand`: returns `START_STICKY` and never stops itself, so the
  registration (and `mdnsd`) survive. `june_bootclear.sh` only has to start it
  once per boot; a sticky restart re-registers in `onCreate`.
- `onDestroy`: unregisters the service and releases the multicast lock.
- If registration fails (e.g. Wi-Fi is still coming up during boot), the
  registration listener retries up to 20 times, 15 s apart.

Manifest: `minSdkVersion 21`, `targetSdkVersion 21` (the oven is Android
5.0.1), `INTERNET`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, one
exported service, `versionCode 1` / `versionName 1.0`.

## The host-name caveat (read this before debugging)

`NsdServiceInfo.setHost()` is **best effort only on this platform**. On Android
5.0.1 the framework's `NsdService.registerService()` forwards only the service
name, type, port and TXT records to `netd`/`mdnsd`; it never sends the host
field. The A record clients resolve for `<name>.local` is the device's own mDNS
host name.

That is why the name is also set outside this app:

- `june_reaper.sh` (June Local boot script) runs `setprop net.hostname "$HN"`
  from `/system/etc/june_hostname` before Android starts.
- `june_bootclear.sh` re-asserts `net.hostname` and also sets the kernel host
  name before it starts `MdnsService`, because `mdnsd` derives its host name
  from the device host name on some builds.

If `<name>.local` resolves to `android.local` (or nothing), check
`adb shell getprop net.hostname` and `adb shell hostname` first, then check the
service's log (tag `JuneLocalDns`). The IP path (`http://<oven-ip>/local`) is
always available as a fallback.

## Build (Arch-side; apktool + project APK key)

Run from this directory on a machine with Java, `apktool` and the project APK
keystore (`June/tools/certs/june_apk_sign.p12`, alias `june`, password `june`):

```sh
cd installer/onoven/june-dns
KS=/path/to/June/tools/certs/june_apk_sign.p12 ./build.sh
```

`build.sh` runs:

```sh
apktool b . -o JuneDns_unsigned.apk
jarsigner -keystore "$KS" -storetype PKCS12 -storepass june \
  -sigalg SHA256withRSA -digestalg SHA-256 JuneDns_unsigned.apk june
cp -f JuneDns_unsigned.apk JuneDns_signed.apk
```

Output: `JuneDns_signed.apk` plus its sha256. On Android 5.0.1 the v1 JAR
signature is sufficient (same as the other June Local helper APKs).

The installer payload wiring lives outside this directory (owned by the
identity-installer): `prepare_assets.sh` copies `JuneDns_signed.apk` into the
payload (from `DNS_SRC` if set, else one of `<payload>/onoven/june-dns/`,
`<repo>/installer/onoven/june-dns/`, `<LR>/onoven/june-dns/`), and
`deploy_onoven.sh` stages it at `/system/app/JuneDns/JuneDns.apk` on both the
APP and SAP system partitions, like the other helper APKs. Rebuild the APK here
and leave the signed output where `prepare_assets.sh` looks for it; this
directory does not edit `prepare_assets.sh`, `assets/` or `deploy_onoven.sh`
itself.

## Install / start on an existing oven (test path, no USB installer)

```sh
# over the oven's root adb
adb push JuneDns_signed.apk /data/local/tmp/JuneDns_signed.apk
adb shell pm install -r /data/local/tmp/JuneDns_signed.apk

# start it now (no reboot needed for a first check)
adb shell am startservice --user 0 -n com.july.dns/.MdnsService

# what to look at
adb shell getprop net.hostname
adb shell cat /proc/sys/kernel/hostname
adb shell dumpsys activity services com.july.dns
adb logcat -d -s JuneLocalDns
```

With the June Local boot image, `/system/bin/june_bootclear.sh` starts it
automatically after the next boot; no manual `am startservice` is needed after
the installer has staged the APK.

## Test plan

From a Mac/iPhone on the same LAN/VLAN as the oven:

```sh
# 1. Browse the advertised service
dns-sd -B _http._tcp                     # expect "June Local"
dns-sd -L "June Local" _http._tcp        # resolves to <name>.local

# 2. Resolve the host name
ping -c 3 june.local                     # basic install default
ping -c 3 june2.local                    # second oven
ping -c 3 <custom-name>.local            # custom install hostname
curl -s http://june.local/local/status | head -c 200
open http://june.local/local             # iOS/Android: the status page

# 3. DNS-SD discovery of the address
dns-sd -R ... / dns-sd -G v4 <name>.local
```

Expected: the service is listed as **June Local** and the host name matches
`/system/etc/june_hostname`. Basic installs use `june`, `june2`, `june3` (the
standard certificate covers those names); a custom install can use any name
(the per-home certificate carries it as a SAN). If two ovens pick the same
name, mDNS conflict resolution renames one service to `June Local (2)`, so give
each oven its own name.

If mDNS does not work (guest/isolated VLAN, multicast filtering, IGMP snooping),
use `http://<oven-ip>/local`; the custom certificate always includes the oven's
IP as a SAN.

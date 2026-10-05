# Camera, live view, and interior light (2026-10-05)

This is the summary of the on-oven camera work that ships with the installer.
The detailed reverse-engineering notes live in the development tree at
`june-arch/docs/camera-local-live-plan.md` and
`june-arch/docs/camera-settings-findings.md`.
The Go source for both `june-local` and `june-camerad` is mirrored into this
repository under `golocal/`; build it with `make -C golocal oven camerad`.

## The rule: stock `cameracapturerd` owns `/dev/video0`

The stock camera is not idle during a cook. These services use it:

| Consumer | When | Cadence / format |
| --- | --- | --- |
| `FoodRecognizer.CookMonitorService` | toast/bread-slice cooks | 4000 ms, rectified BGR (4) |
| `FoodRecognizer.RecognitionService` | door open | 400 ms, original BGR (1) |
| `MediaCapturer.VideoCaptureService` | every cook | 1000 ms, rectified JPEG (6) |
| `Chef.CleanCameraActivity` | cleaning | 200 ms, rectified RGBA (5) |

`CookMonitorService` is the important one: it runs the toast monitor, broadcasts
`TIMELESS_COOK_STATUS`, and `CookManager.DonenessPhaseRunner` uses that value to
finish the doneness phase. A local daemon that holds `/dev/video0` breaks toast
doneness and door-open food recognition. The installer therefore never lets
`june-camerad` open the V4L2 device on a stock oven.

## Live view

- `june-camerad --source auto` checks for `/system/bin/cameracapturerd`. If it
  exists (the normal case) the daemon becomes a client of
  `/juneOS2/cameracapturerd-capture.sock`, requests format 6 (rectified JPEG),
  and posts frames to june-local through `/internal/video`.
- The bridge is viewer-gated. It connects only when
  `GET /internal/camera-bridge-enabled` returns `1`: a viewer is active and no
  cook is running. It disconnects as soon as either changes.
- Home Assistant opens the gate with `POST /internal/camera/on` while its
  camera entity is displayed and closes it with `/internal/camera/off`.
- Phone/browser live view: `GET /media/view` is a phone-friendly page that
  embeds `GET /media/stream.mjpg`. Watching the stream opens the same gate for
  the duration and closes it about 15 seconds after the client disconnects.
  Duplicate JPEGs are suppressed; the stream carries the stock 1 fps cadence.
- Cook-time frames come from MediaCapturer instead of the bridge. june-local
  implements `POST /1/videos/{sessionId}/start_image`, stores the uploaded
  multipart `photo` as `/media/prod/images/latest.jpg`, and pushes a `10011`
  VideoFrame to the companion/HA. This adds no extra camera client during a
  cook.
- Safety fallback: if a cook is active but no `start_image` frame has arrived
  for 8 seconds (older install or failed patch), the bridge re-enables at 1 fps
  so live view still works. The stock daemon still owns the device.
- `--source v4l2` remains for systems without the stock daemon.

## Interior light

`com.july.oven/LightBridgeService` is a tiny exported helper APK
(`onoven/oven-light/`). june-local starts it with `am startservice`; it binds
CookManager's exported
`com.junelife.device.cookmanager.service.AxonService` and performs
`enableLightingScene` / `disableLightingScene` (transactions 12/13, priority
100, 100% left/right). Door-open and cooking scenes therefore always win.

The scene follows the camera gate: the viewer endpoints and the bridge-enabled
poll keep it in lockstep, and june-local clears a scene left by a previous
process at startup. The installer stages the helper at
`/system/app/JuneLight/JuneLight.apk`.

## Certificate patches

`MediaCapturer` and `Analytics` embed the same June certificate pin as
JCM/Remotes:

- **Custom/per-home CA installs** stage the no-pin `MediaCapturer` and
  `Analytics` APKs (recipes in `windows-work/mediacapturer-pinning/` and
  `windows-work/analytics-pinning/`), so cook-time stills and analytics reach
  june-local.
- **Basic/prepackaged installs** keep the factory apps and the GoDaddy chain,
  which the factory pins accept. The camera fallback still produces live view
  if a particular factory pin rejects the chain.

## Toast level mapping

The on-screen primitive Toast uses nine plans (`i = 0..8`, UI 1-9) with
`Plan.intensity = i` and `base_duration = exit_duration =
(i * 30000) + 150000` ms (2.5-6.5 minutes). A remote `11002` has no level
field; it uses the oven's saved/default plan. The `bread_slices` preset uses a
`dimension` map (`intensity: light|medium|dark`, `quantity: 1..8`). Camera
doneness is a separate 0-100 scale (Light 25, Medium 50, Dark 75, Burnt 100),
so a UI level must be converted before it is sent as a doneness target.

## Build/release state

- Installer repo `main` commits:
  - `1524bba` camera: keep stock cameracapturerd and bridge cook-time frames safely
  - `d08a4b4` installer: keep june.local as the default oven name
  - `6eef2f9` camera: phone MJPEG view and interior-light bridge
  - `36f2df9` installer: include the source-built light bridge APK
- Latest stick image: build `20261005-0119-9130bb89`, ISO sha256
  `1221ff236835ca316eb279a29165e22801dac6594f68a12e5acb8b0e90bfa56a`.
- Not yet exercised on physical hardware (oven offline at build time). A
  reinstall is required to deploy the new `june-camerad`, `june-local`, boot
  image, and `JuneLight` helper.

# June Light Bridge

`com.july.oven` is a tiny helper APK for the on-oven june-local camera wake.
The oven's interior light is controlled by CookManager's exported
`com.junelife.device.cookmanager.service.AxonService` binder; a Go process
cannot speak Android binder, so `june-local` starts this service with `am
startservice` and it performs the `enableLightingScene` / `disableLightingScene`
transactions.

The service is exported, has no special UID or permissions, and uses a
priority-100 scene so door-open and cooking scenes always win. The installer
stages it at `/system/app/JuneLight/JuneLight.apk`.

Build (apktool + the project APK key):

    bash build.sh

The signed output is `OvenLight_signed.apk`.

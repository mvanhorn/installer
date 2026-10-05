# Chef cook-modes patch (`plan_index`)

The stock oven Chef app refuses every remote `11002` primitive start except
bake, roast, airfry, pizzaiolo, sous_vide and grill
(`CookParamValidator.isValidFoodToStartRemotely`), and it has no way to pick a
plan for multi-plan primitives. Remote toast therefore either fails today or,
after only widening the whitelist, would always start plan 0 (level 1).

`patch.py` changes three things in a decoded Chef APK:

1. `CookParamValidator.isValidFoodToStartRemotely` allows every primitive in
   `CookPrograms.PRIMITIVE_PROGRAM_MAP`, except `blow_dry` (cleaning cycle).
2. `StartCookCommandData` gains an optional Jackson field `plan_index`
   (`@JsonProperty("plan_index")`, default `-1`).
3. `RemoteFoodLoadListener` selects `food.selectPlan(plan_index)` before the
   stock run-state and recipe checks; an out-of-range index is answered
   not-allowed instead of starting the wrong plan.

The old six primitives and every client that omits `plan_index` behave exactly
as before (`plan_index < 0` keeps the first plan).

## Wire contract

```
11002 {"primitive_type":"toast","temperature_cavity":260000,"plan_index":4}
```

Toast level N maps to `plan_index = N-1` (0..8), `temperature_cavity = 260000`,
fixed durations 150000 + index*30000 ms. Other multi-plan modes:

| primitive | plan_index | temperature_cavity |
|---|---|---|
| grill | 0 high, 1 medium, 2 low | 232222 / 204444 / 135000 |
| reheat | 0 timed, 1 probe | 176667 |
| slow_cook | 0 high, 1 low | 160000 / 140000 |

Single-plan modes: bake 176667 (user value allowed), roast 204444, airfry
204444, pizzaiolo 260000, sous_vide 60000, proof 29444, warm 76667, dehydrate
57222, broil 260000. Broil intensity is a separate `11010 SetBroilIntensity`
command and needs the running plan id from `10014`.

## Build

```
./build_patched.sh [stock-Chef.apk] [output.apk]
```

The default stock APK is the healthy-build extraction at
`local-resources/june-rcm/healthy-build/decompiled/priv-app-apks/Chef.apk`.
The script decodes with resources kept raw (`apktool d -r`), patches, rebuilds
and signs with `tools/certs/june_apk_sign.p12`.

The signed APK is intentionally not committed: it contains June's original
assets and is ~246 MB. Keep the built APK next to this recipe (or in the
installer working tree) for ISO builds; the public installer ships the recipe
and builds the APK from the user's own extracted stock Chef APK.

Current build:

```
Chef_cookmodes_signed.apk
sha256 64edf1e4e967489e2eeb195f8a66ea95b6b06caad57043e43da1b93e0e01a137
```

## Deploy

Chef is a priv-app, so it cannot be `pm install -r`'d over the June build.
Stage the APK and let `june_reaper.sh` swap it into the collector volume:

* persistent (survives factory reset): `/system/etc/june/chef_cookmodes.apk`
* one-shot: `/data/june/chef_cookmodes.apk` (removed after it is applied)

The live target inside the collector volume is
`/system/priv-app/Chef/Chef.apk`. The installer integration adds the staging
copy plus the `apply_staged_apk` block in `june_reaper.sh.junelocal`; this
recipe only builds the APK.

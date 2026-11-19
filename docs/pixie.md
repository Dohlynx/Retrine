# Optional Pixie native downloads

Pixie is an **optional, opt-in** build overlay that adds a native download manager to Vitrine.
Default builds never include it, on any Spotify version. Read the whole page before using it:
**9.2.0 packages are not yet functional-download releases** (see [Supported targets](#supported-targets)).

## Building

```sh
make release PIXIE=1                                # primary Spotify 9.2.0
make release PIXIE=1 IPA=ipa/Spotify-9.1.90.ipa     # compatibility lane
```

These produce `out/vitrine-<version>-pixie.ipa` and
`out/vitrine-<version>-pixie-spotify-9.1.90.ipa`, separately from the input and ordinary
Vitrine output. An explicit `IPA=` overrides the Pixie primary target.
`make build PIXIE=1` and `make install PIXIE=1` use the same overlay
(the latter also signs and installs). Direct pipeline usage accepts `--pixie`
(`--require-pixie` is an alias). Default builds never include Pixie on any version;
`make quick` does not build the overlay.

## Supported targets

Packaging accepts the exact decrypted Spotify **9.2.0** (`920002054`) and
**9.1.90** (`919002269`) profiles. Main and SpotifyShared UUIDs are recorded in
`NativeDownloads/targets/spotify-9.2.0.json` and `spotify-9.1.90.json`.
Version, build, both UUIDs, instruction windows, import bindings and unused executable
padding are checked before the base build; requested Pixie mismatches fail closed.

**9.2.0 packages are not yet functional-download releases.** Packaging admission
does not override the companion's unverified native-layout/counter gates:
its runtime remains inactive on 9.2.0. Separately, the host must feed the nebula
account-attributes response through `SAPRewriteOfflineAccountAttributes`; without
that integration, Eevee's 9.2 port observed `NOT_ALLOWED (23)` for downloads.
Neither condition is established by a successful build. Jailbreak packaging is
9.1.90-only; 9.2.0 DEBs are refused before output mutation.

Default builds still work without Pixie. All builds reject existing Pixie
payloads, partial overlays, malformed inputs and encrypted executables.
The finished Vitrine IPA is checked again and overlaid after App Intents merging, before
any installation. The companion build needs Xcode's iPhoneOS SDK and `ldid`; application
entitlements are preserved and the complete ZIP is verified before atomic publication.

## In the app

Settings → Vitrine reuses Pixie's existing runtime attachment for **Pixie Download Manager**
and **Send log**. Downloads stay in Spotify's offline storage; Pixie 1.4 also offers
separate, explicit audio-export actions.

Music-track context menus gain **Download**, bound to the selected track rather than
the currently playing one. The manager's **Add single-track downloads to Liked Songs**
switch defaults off and applies to subsequent individual downloads, including the
current-track action. When enabled, an accepted or already-present download also
requests an add to Liked Songs; album downloads do not. Canceling or removing a
download never removes a like. Library-add errors are reported separately from
download status. Menu routing and library changes still need real-device acceptance;
the host regressions check captured track identity and the verified 9.1.90 API.

## Diagnostics and privacy

Release builds enforce `SAP_ENABLE_WAV_CAPTURE=0`. Diagnostics default off; enabling them
persists across launches. Action recording also respects this switch. Reports can contain
track URIs, device identifiers and listening/download history: **inspect before sharing.**
Unstructured Eevee debug logs are excluded because their credential safety is unknown.
Existing About diagnostics remain available and are included through `SGWriteDiagnosticsFile`.

Pixie's `SAPL` uses Vitrine's localization keys and Korean/English resources, following the
app's language with the same checked English fallback. `scripts/check-strings.py` also checks
Pixie's keys and placeholders. Long-term offline licence renewal remains unverified.

## Provenance and credits

`NativeDownloads/` imports the sources, tests, patch tools and assets from
[Glongq/Vitrine-Pixie](https://github.com/Glongq/Vitrine-Pixie) at exact commit
[`2632bdf9081665b9fd78e71cea2878edc6aae73c`](https://github.com/Glongq/Vitrine-Pixie/tree/2632bdf9081665b9fd78e71cea2878edc6aae73c/NativeDownloads),
under GPL-3.0 with existing notices retained. Upstream credits Pixie development/integration
to OpenAI Codex under Glongq's direction, and device testing/feedback to Glongq; earlier
work comes from Glongq/EeveeSpotifyReincarnated. Selected companion fixes are pinned to
Eevee [`0d9feaa9008e53b06382c61fffcb5cfcfceb2981`](https://github.com/Glongq/EeveeSpotifyReincarnated/tree/0d9feaa9008e53b06382c61fffcb5cfcfceb2981).
Its Vitrine host overlay patch was **not** applied.

Local adaptations add preflight/atomic build integration, entitlement preservation,
init-family ownership safety, nonblocking diagnostic notifications and diagnostics privacy guards.
Jailbreak packaging supports only the exact 9.1.90 profile (rootful and rootless);
9.2.0 DEBs are rejected. Both Pixie package formats include the root GPL license
and `NativeDownloads/vendor/M4A-NOTICES.md`. Jailbroken-device execution remains unverified.

## Checks

Focused checks on an Apple Silicon Mac (no installation):

```sh
python3 -B NativeDownloads/tests/build_guard.py ipa/Spotify-9.1.90.ipa
python3 -B NativeDownloads/tests/track_api_binary.py
python3 -B NativeDownloads/tools/test_single_track.py
python3 -B NativeDownloads/tools/test.py
SPOTIFY_TEST_IPA="$PWD/ipa/Spotify-9.1.90.ipa" python3 -B NativeDownloads/tools/test_native_restrictions.py
```

`tools/test.py` and `tools/test14.py` share one current runner, including the
exact-target admission and frozen-golden checks. These use the clean target IPAs.

The optional UI fixtures need an already booted iPhone simulator:
`python3 NativeDownloads/tools/test_settings_ui.py` (iOS 26 or newer) and
`python3 NativeDownloads/tools/test_vitrine_init.py` (Vitrine root rows and init ownership).
`python3 NativeDownloads/tools/test_trace_platform.py` exercises the production notification
observers for nonblocking background posts and disabled/stale-generation delivery.
After simulator checks, run `xcrun simctl shutdown all` and
`osascript -e 'tell application "Simulator" to quit'`.

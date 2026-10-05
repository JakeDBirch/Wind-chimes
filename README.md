# Pocket Chimes

A wind chime simulator. It plays the sound of wind chimes, and if you hang your phone up outside, it becomes a real wind chime that moves with the wind. Under the hood it's a top-down 2D pendulum simulation driven by wind, sound and the phone's motion sensors.

Pocket Chimes is an iOS app built with [Capacitor](https://capacitorjs.com). The chime itself (physics, motion input and sound) runs natively in Swift so it keeps playing in the background and with the screen locked. The controls and the top-down view are a web page (`index.html`) shown inside the app. It no longer runs in a desktop or mobile browser.

## Controls

| Control | What it does |
| --- | --- |
| *(hidden)* Phone mode | Simulated wind drives the chimes. Hang the phone upside down (top edge toward the ground) for a second and its own motion takes over; turn it upright again to go back to wind |
| **Strength** | How hard the wind blows |
| **Consistency** | Low: gusty and shifting, long lulls, half of them truly still, big wander within each gust. High: long steady holds, short lulls that stay a breeze, little wander. Strength scales all of it |
| **Wind sound** | The sound of the wind itself, following the same gusts that move the chimes. On or off; silent in phone mode |
| *(tuning branch)* Wind tightness | How closely the wind sound tracks the force on the chimes: 0 is a smooth, lagging impression; 1 follows every gust and jiggle almost directly, for judging the physics by ear. Fixed at 0.6 in the main build |
| **Chimes** | Number of tubes, 3–12 |
| **Register** | Pitch, ±2 octaves |
| **Scale** | Dropdown of tunings (default Pentatonic). *Chord Seq* cycles through a chord progression; *Custom* shows an octave of keys to pick notes from |
| **Sound** | *Metal* is the synthesized tube. *Recorded* uses a sound you record with the mic. Each chime plays it at its own pitch, shaped with the same decay and filter sweep as a struck tube, so even a sustained note rings and dies away |
| **Record** | Opens the mic in standby with a level meter. Set **Trigger** just below your sound's level, tap **Arm**, and recording starts the moment the level crosses it (with 150 ms of pre-roll). Tap **Stop** when done; it caps at 10 s |
| **Save / bank** | After a take, name it and tap **Save** to keep it. Saved sounds are listed under the recorder: **Use** switches to one, ✕ deletes it. The last take is kept between launches even if unsaved |
| **Gust** | A two-second push of wind |

Every setting (sliders, wind sound, scale and custom keys, sound mode, the sample in use, physics on or off) is saved as you change it and restored the next time the app opens.

## Project layout

| Path | What it is |
| --- | --- |
| `index.html` | Controls and visualization. Sends settings to the native engine and draws its state. |
| `ios/App/App/ChimePhysics.swift` | Pendulum physics, wind model, gusts, scales and phone-motion input |
| `ios/App/App/ChimeVoices.swift` | Turns each strike into synth voices: inharmonic metal partials, or the recorded sample at the tube's pitch |
| `ios/App/App/UserSample.swift` | Prepares a mic recording for playback (trim, normalize, seamless loop, pitch estimate) and the on-disk sample bank |
| `ios/App/App/ChimeSynth.swift` | Real-time synthesizer: envelopes, filters and mixing on the audio thread |
| `ios/App/App/ChimeEngine.swift` | Runs it all: physics clock, CoreMotion, audio session and AVAudioEngine, interruption recovery |
| `ios/App/App/ChimeEnginePlugin.swift` | Capacitor plugin the page calls (`setParams`, `setPhysics`, `setSound`, `startStandby`, `setTriggerLevel`, `arm`, `disarm`, `stopRecording`, `cancelRecording`, `listSamples`, `saveSample`, `selectSample`, `deleteSample`, `gust`, `getState`) |
| `ios/App/App/MainViewController.swift` | Registers the plugin with Capacitor |
| `ios/App/App/Info.plist` | Background audio mode, microphone and motion usage strings, portrait-only on iPhone, light status bar, no-encryption declaration |
| `ios/App/App/Assets.xcassets` | App icon (1024×1024, placeholder) and launch screen |
| `capacitor.config.json` | App name, bundle ID (`com.jakedbirch.windchimes`) and web directory |
| `.github/workflows/ios-build.yml` | Compiles the app on every push, so build errors show up early |
| `.github/workflows/testflight.yml` | Builds, signs and uploads a build to TestFlight |

`www/` is a build output (a copy of `index.html`) and is not committed.

## Shipping a TestFlight build

### One-time setup

1. **Join the Apple Developer Program** ($99/year) at <https://developer.apple.com/programs/>.
2. **Register the bundle ID.** In Certificates, Identifiers & Profiles → Identifiers, add an App ID with the bundle ID `com.jakedbirch.windchimes`. To use a different one, change `appId` in `capacitor.config.json` and `PRODUCT_BUNDLE_IDENTIFIER` in `ios/App/App.xcodeproj/project.pbxproj`.
3. **Create the app in App Store Connect.** My Apps → + → New App, pick that bundle ID. The name has to be unique on the App Store.
4. **Create an API key.** App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → +. Give it the **Admin** role, which lets the workflow create signing certificates and profiles for you. Download the `.p8` file; Apple only lets you download it once.
5. **Add four repository secrets** (GitHub → Settings → Secrets and variables → Actions):

   | Secret | Value |
   | --- | --- |
   | `APP_STORE_CONNECT_API_KEY_ID` | The key's ID, e.g. `ABC123DEFG` |
   | `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID shown above the keys list |
   | `APP_STORE_CONNECT_API_KEY` | The full text of the `.p8` file, including the `BEGIN`/`END` lines |
   | `APPLE_TEAM_ID` | Your 10-character Team ID from <https://developer.apple.com/account> → Membership details |

Each run makes Xcode create an Apple Development certificate for its CI machine, and the workflow deletes it again afterwards (`scripts/asc-certs.mjs`). If a run still fails with **"Your account has reached the maximum number of certificates"**, older runs left some behind: in Certificates, Identifiers & Profiles → Certificates, revoke the Development ones you don't use.

### Each build

1. GitHub → Actions → **TestFlight** → **Run workflow**.
2. The build number is the workflow run number, so every run uploads a new build. Bump `MARKETING_VERSION` in `project.pbxproj` for a new version (1.0 → 1.1).
3. After Apple finishes processing (usually 5–30 minutes), the build appears under the app's TestFlight tab.
4. **Internal testers** (up to 100 App Store Connect users): add them to an internal group and they get the build right away.
   **External testers** (anyone with an email or public link): the first build of each version goes through Beta App Review, usually within a day.

## Local development

```sh
npm install
npm run sync      # copy index.html into the iOS project
npm run open:ios  # open in Xcode (macOS only), then Run on a simulator or device
```

Run `npm run sync` after every change to `index.html` before building in Xcode.

# Pocket Chimes

A wind chime simulator. It plays the sound of wind chimes, and if you hang your phone up outside, it becomes a real wind chime that moves with the wind. Under the hood it's a top-down 2D pendulum simulation driven by wind, sound and the phone's motion sensors.

Pocket Chimes is an iOS app built with [Capacitor](https://capacitorjs.com). The chime itself (physics, motion input and sound) runs natively in Swift so it keeps playing in the background and with the screen locked. The controls and the top-down view are a web page (`index.html`) shown inside the app. It no longer runs in a desktop or mobile browser.

## Controls (gesture branch)

Nothing on screen but the chimes, with a scatter of dust that drifts with the wind so you can see it blow. Physics is always on; everything is a gesture. Light mode (a tinted cream) is the default, dark mode the option; both take the current scale's colour and fall away into shade at the edges.

| Gesture | What it does |
| --- | --- |
| **Swipe in from the left or right edge** | Next or previous scale (a straight horizontal stroke anywhere works too): Pentatonic, Major Pent, Minor, Lydian, Whole Tone, Hirajoshi, Slendro, Pelog (both Javanese gamelan tunings, off the piano's grid), Chord Seq, Custom. Each has its own colour, so the screen takes on the scale's mood. Custom brings up an octave of keys along the bottom to pick the notes |
| **Circle a finger around the outside** | Register, one octave per turn, clockwise up, ±2 octaves |
| **Circle a finger over the chimes** | Add a chime per sixth of a turn clockwise, remove one anticlockwise, 3–12 |
| **Press and hold** | A two-second gust |
| **Double-tap the clapper** | Opens the sound sheet: Metal or Recorded, the recorder (standby, trigger, arm, stop, 10 s cap) and the sample bank |
| **? icon** (top left) | A guide to these gestures |
| **Sun / moon icon** (top right) | Light mode (the default) or dark mode |
| **Wind icon** (top right) | Opens the wind drawer: wind sound on or off, **Strength** and **Consistency** sliders |
| *(hidden)* Phone mode | Hang the phone upside down for a second and its own motion drives the chimes; upright again returns to wind |

Pocket Chimes takes the audio for itself: it pauses whatever else was playing, and another app starting playback (or a call) stops the chimes. After a call they come back on their own; after music, tap the screen.

Every setting is saved as it changes and restored the next time the app opens.

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

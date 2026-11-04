# Shrava

**Every Conversation, Captured.**

Local-first voice dictation and meeting capture for **macOS** and **iPhone**. Hold a key (or tap Record), speak naturally, and get clean on-device transcripts — with optional Meeting Brief insights when you ask for them.

## Download

| Platform | Download |
|---|---|
| **macOS** (Apple silicon, macOS 14+) | [**Download Shrava.dmg**](https://github.com/nitinkanish/shrava-ai/raw/main/dist/Shrava.dmg) |
| **iPhone** (iOS 26+) | Not on the App Store. Install from source with Xcode and a free Apple ID; see [iPhone (free Apple ID)](#iphone-free-apple-id). |

> The Mac app is ad-hoc signed. On first open, right-click Shrava.app > **Open**, or run `xattr -dr com.apple.quarantine ~/Applications/Shrava.app`.

## Highlights

| Desktop (macOS 14+) | Mobile (iOS 18+) |
| --- | --- |
| Hold **Right Option** (default) to dictate into any app | Liquid Glass UI |
| Double-tap the hotkey for **hands-free**; tap again to stop | Long **background** meeting recording |
| Local Whisper via **whisper-cli** (`large-v3-turbo` q5); **Auto (English/Hindi)**; History playback | On-device Whisper (**turbo**/small/base picker); History **play/scrub/share**; **Auto (English/Hindi)** |
| Draggable creative recording indicator + menu-bar logo | Compact **Dynamic Island** / Live Activity with **Stop** |
| **Meeting Brief** via Ollama + **Send to Slack** | Action Button / Siri / Control Center start **without opening the app** |
| History, dictionary, settings tabs | Keyboard extension, history, dictionary, meeting brief |
| Ad-hoc **DMG** for local install | Copy / Share transcript as `.md` |

Audio never leaves your device for transcription. Meeting Brief text is sent to Ollama **only when you tap Analyze**.

---

## Desktop

Menu-bar app: hold your hotkey, speak, release — polished text is typed into the focused field.


| Welcome | Hotkey settings |
|:---:|:---:|
| <img src="docs/screenshots/mac-welcome.png" width="420" alt="Mac welcome"> | <img src="docs/screenshots/mac-hotkey.png" width="420" alt="Mac hotkey settings"> |

### Features

- **Hold-to-talk dictation** on **Right Option** by default (Fn, Right Command or Control+Option selectable in Settings → Hotkey) with a floating, **draggable** recording indicator and custom Shrava menu-bar logo
- **Hands-free mode**: double-tap the hotkey to start, tap again to stop
- **Local Whisper** through Homebrew `whisper-cli` / whisper.cpp — prefers `ggml-large-v3-turbo` in Application Support; default **Auto (English/Hindi)** detects language on the first ~30s, keeps the full recording WAV, and transcribes the whole file in one pass (chunked Whisper remains fallback). Filters `(Speaking in foreign language)` hallucinations and retries the other language / a larger model when needed
- **Meeting Brief**: send a transcript to **Ollama** (`gpt-oss:120b-cloud`, with non-cloud fallback) for insights and action items — API key stored in **Keychain**
- **Slack**: post briefs to a channel you pick (Block Kit), optional transcript thread — bot token in **Keychain**
- Searchable **history** with **audio playback** (play/pause, scrubber, share), personal **dictionary**, and Settings tabs (Enhance transcript when Ollama key is set) (General, Hotkey, Model, Permissions, Meeting Brief, …)
- Distribute as a local **DMG** (`dist/Shrava.dmg`) for ad-hoc install into `~/Applications`

### Install (Mac)

1. Open `dist/Shrava.dmg` (or build from source below) and drag **Shrava** to Applications (or `~/Applications`).
2. First launch: grant **Microphone** and **Accessibility** (needed for the hotkey and typing into other apps). After every reinstall/update macOS resets this: remove Shrava with **−** and re-add it with **+** in Accessibility.
3. Install Whisper runtime if needed: `brew install whisper-cpp` (provides `whisper-cli`).
4. Place a ggml model (e.g. `ggml-large-v3-turbo-q5_0.bin`) in  
   `~/Library/Application Support/Shrava/models/`  
   (Settings → Model shows the folder and readiness).
5. Optional Meeting Brief: open Settings → **Meeting Brief**, choose Ollama endpoint mode, and save your Ollama API key (Keychain).

**Usage:** hold **Right Option** to talk; release to insert text. Double-tap for hands-free. Open History / Dictionary / Settings from the menu bar (Settings button or ⌘,). Fn can conflict with macOS (emoji/dictation) or other apps, so Right Option is the default.

---

## Mobile

iPhone app with Liquid Glass chrome, long-form meeting capture, and Shortcuts that record in the background.

| Record | History |
|:---:|:---:|
| ![Record](docs/screenshots/ios-record.png) | ![History](docs/screenshots/ios-history.png) |

| Dictionary | Settings |
|:---:|:---:|
| ![Dictionary](docs/screenshots/ios-dictionary.png) | ![Settings](docs/screenshots/ios-settings.png) |

### Features

- **Liquid Glass** UI (iOS 26 design language)
- **Long background recording** (switch apps / lock screen) with AAC capture; **auto-resumes after phone calls** (CXCallObserver + AVAudioSession interruption / route / media-reset)
- **Dynamic Island** + Lock Screen **Live Activity** — compact mic + narrow timer; **Stop** ends recording without opening the app
- **App Intents** (`AudioRecordingIntent` + `LiveActivityIntent`, `openAppWhenRun = false`):
  - *Start Shrava Recording* / *Stop* / *Toggle* for **Action Button**, **Back Tap**, **Shortcuts**, and **Siri**
  - **Control Center** control (`Shrava Recording`) toggles recording without launching UI
- On-device **Whisper** via whisper.cpp (XCFramework) — Settings model picker: **large-v3-turbo q5 (~547MB)**, small, or base (download on first use); beam search + Silero VAD + Hinglish prompt; optional **Enhance transcript** via Ollama; History **play/pause/scrub/share** of saved audio under Documents/Recordings
- **Meeting Brief** (Ollama) with insights / action items; **Send to Slack**, **Copy**, and **Share as `.md`**
- **Shrava Keyboard** for quick capture from other apps (Full Access recommended when App Groups are available)

### Action Button (start without opening the app)

1. **Settings → Action Button → Shortcut**
2. Under **Shrava**, choose **Start Recording** / **Start Shrava Recording**
3. Press the Action Button — recording + Live Activity start; the app stays in the background

### Control Center

1. Open Control Center → **+** / Edit Controls  
2. Add **Shrava Recording**  
3. Tap to start/stop without opening Shrava  

> **Note (free Apple ID):** personal-team builds expire about every **7 days** and must be reinstalled from Xcode. App Groups / iCloud may be unavailable on free signing, so keyboard ↔ app sharing can be limited.

---


---

## Slack integration

Send a **Meeting Brief** to any Slack channel from Mac or iPhone.

### 1. Create the Slack app

1. Open [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From an app manifest**.
2. Paste the contents of [`docs/slack-app-manifest.yml`](docs/slack-app-manifest.yml) (bot scopes: `chat:write`, `channels:read`, `groups:read`, `channels:join`, optional `chat:write.public`).
3. **Install to Workspace** and copy the **Bot User OAuth Token** (`xoxb-…`).
4. For **private** channels, invite the bot in Slack: `/invite @Shrava`.

### 2. Connect in Shrava

| Platform | Where |
|---|---|
| **Mac** | Settings → **Slack** — paste token → **Connect / Test** → pick default channel |
| **iPhone** | Settings → **Slack** — same flow |

Toggles:

- **Auto-send brief after Analyze** (off by default) — posts to the default channel when analysis finishes
- **Include transcript** — posts the full transcript as a threaded reply (chunked)

### 3. Send a brief

Open a Meeting Brief → **Send to Slack** → searchable channel picker (defaults to your saved channel) → success link **Open in Slack**.

Tokens are stored in the **Keychain** (`com.shrava` / `slack_bot_token`) — never commit them.


## Privacy

- **Transcription audio stays on device** (Mac: whisper-cli; iPhone: embedded whisper.cpp).
- **Meeting Brief** sends transcript **text** to Ollama only when you tap **Analyze** (not while recording).
- Ollama API keys (if used) are stored in the **Keychain** — never commit keys to git or the README.
- No OpenAI account is required for dictation.

---

## Build from source

### Prerequisites

- macOS with **Xcode 16+** (iOS 18 / 26 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Mac dictation: `brew install whisper-cpp` + a ggml model under Application Support (see above)
- iOS Whisper binary framework:

```bash
./scripts/fetch-whisper-xcframework.sh
```

### Generate & open

```bash
cd Shrava
xcodegen generate
open Shrava.xcodeproj
```

### macOS (ad-hoc / local)

1. Scheme **ShravaMac**
2. Signing: your Personal Team or ad-hoc; empty entitlements override is fine for local use
3. Build & run (or archive → DMG for `~/Applications`)

### iPhone (free Apple ID)

1. Connect your iPhone; scheme **ShravaIOS**
2. Signing & Capabilities: select your **Personal Team** (free Apple ID)
3. Run to device  
4. Re-sign / reinstall about every **7 days** when the free provisioning profile expires  
5. First launch: allow Microphone; download the Whisper base model in Settings; enable Live Activities for Shrava if prompted  

For background shortcut recording, grant mic once in-app, then use Action Button / Control Center / Siri as above.

### Project layout

```
Shrava/
├── project.yml                 # XcodeGen
├── scripts/fetch-whisper-xcframework.sh
├── ShravaCore/                 # Shared models, history, dictionary, Ollama client, Keychain
├── ShravaMac/                  # Menu bar app, hotkeys, LocalWhisper, Meeting Brief UI
├── ShravaIOS/                  # Host app, recorder, intents bridge, Liquid Glass UI
├── ShravaKeyboard/             # Keyboard extension
├── ShravaLiveActivity/         # Live Activity + Control Center widget
├── Shared/                     # Recording intents, activity attributes, constants
├── docs/screenshots/           # README screenshots (committed)
├── docs/slack-app-manifest.yml # Slack app manifest for Meeting Brief posts
└── dist/                       # Local DMG / preview dumps (not all committed)
```

---

## Troubleshooting

| Issue | What to try |
| --- | --- |
| Hotkey does nothing (Mac) | Accessibility was reset (happens after each reinstall). Remove Shrava with **−** and re-add it under **System Settings → Privacy & Security → Accessibility**; it re-arms within 2 s |
| Settings won't open (Mac) | Update to the latest build; use the menu-bar **Settings** button or ⌘, |
| `whisper-cli not installed` | `brew install whisper-cpp`; confirm Settings → Model |
| Model not ready (Mac) | Drop `ggml-large-v3-turbo*.bin` into Application Support → Shrava → models |
| Model not ready (iPhone) | Settings → download Whisper base; keep the app open until finished |
| Shortcut opens the app | Use the **Start Shrava Recording** App Shortcut (not an Open App / URL action) |
| Live Activity missing | Settings → Shrava → Live Activities; AudioRecordingIntent requires an active Live Activity |
| Free-team install expired | Rebuild/run from Xcode (≈7-day personal provisioning) |

---

## License & credit

© 2026 Shrava. Developed by Nitin Kanish, [Debugged Pro](https://debuggedpro.com).

Clean-room implementation. No third-party dictation app code, assets, or prompts.

## Testing

ShravaCore ships with an XCTest suite (SPM) covering:

- Transcript chunking / merge helpers
- Ollama client request/response parsing (mocked `URLProtocol`)
- Slack Block Kit formatter limits and Slack client auth parsing (mocked)
- Keychain save/load/delete
- History + BriefStore persistence (atomic writes) and `TranscriptionState` migration
- Recording state machine transitions (start/pause/resume/stop/interrupt)
- Transcript chunk scheduling math
- `shrava://` URL / intent routing

### Run tests locally

```bash
# ShravaCore (macOS host)
cd ShravaCore && swift test

# Or via xcodebuild (iOS Simulator — use a booted sim UUID if preferred)
xcodebuild test -project Shrava.xcodeproj -scheme ShravaCore -destination 'platform=macOS'
```

CI (`.github/workflows/ci.yml`) runs ShravaCore tests plus unsigned iOS Simulator and macOS Debug builds on `macos-15`.

### Production / Release notes

- `shrava://debug/*` URL schemes are compiled out of Release builds.
- On-device file log (`Documents/shrava-debug.log`) rotates at ~512 KB and redacts Slack/API tokens.
- Orphaned recordings are recovered as **pending** (ready to transcribe), not failed.
- Transcription never marks **failed** if any chunk produced text — it saves **partial** and offers Retry.

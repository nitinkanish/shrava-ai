# Murmur

A clean-room AI voice dictation app for macOS 14+ and iOS 18+. Speak naturally and get clean, polished text with AI-powered transcription and cleanup.

## Features

- **AI-Powered Transcription**: Uses OpenAI's gpt-4o-transcribe (with whisper-1 fallback) for accurate speech-to-text
- **Intelligent Cleanup**: Removes filler words, applies spoken self-corrections, adds punctuation, and formats lists/paragraphs
- **Personal Dictionary**: Custom word replacements for names, technical terms, and corrections
- **Dictation History**: Searchable history of all your transcriptions
- **Cross-Platform Sync**: iCloud sync for dictionary and history across Mac and iOS
- **macOS Menu Bar App**: Hold-to-talk with global hotkey (Fn or Ctrl+Option)
- **iOS Keyboard Extension**: Dictate directly from any app

## Requirements

- macOS 14.0+ (Sonoma or later)
- iOS 18.0+
- OpenAI API key
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Project Structure

```
Murmur/
├── project.yml              # XcodeGen project configuration
├── MurmurCore/              # Shared Swift Package
│   ├── Package.swift
│   ├── Sources/MurmurCore/
│   │   ├── OpenAI/          # API client, transcription service
│   │   ├── Prompts/         # Cleanup prompt builder
│   │   ├── Dictionary/      # Personal dictionary
│   │   ├── History/         # Dictation history
│   │   ├── Snippets/        # Snippets model (UI pending)
│   │   ├── Keychain/        # Secure API key storage
│   │   ├── Settings/        # App settings
│   │   └── Sync/            # iCloud sync manager
│   └── Tests/MurmurCoreTests/
├── MurmurMac/               # macOS menu bar app
├── MurmurIOS/               # iOS host app
├── MurmurKeyboard/          # iOS keyboard extension
└── Shared/                  # Shared constants
```

## Building

### Prerequisites

1. Install XcodeGen:
   ```bash
   brew install xcodegen
   ```

2. Get an OpenAI API key from [platform.openai.com/api-keys](https://platform.openai.com/api-keys)

### Generate Xcode Project

```bash
cd Murmur
xcodegen generate
```

This creates `Murmur.xcodeproj` from `project.yml`.

### Configure Signing

1. Open `Murmur.xcodeproj` in Xcode
2. Select each target and configure:
   - **Team**: Select your development team
   - **Bundle Identifier**: Update if needed (default: `com.murmurapp.*`)

### App Group Setup (iOS)

The iOS app and keyboard extension share data via an App Group:

1. In Xcode, select the **MurmurIOS** target
2. Go to **Signing & Capabilities**
3. Verify **App Groups** capability with `group.com.murmurapp`
4. Repeat for **MurmurKeyboard** target

If using a different App Group identifier, update:
- `project.yml` entitlements
- `MurmurCore/Sources/MurmurCore/MurmurCore.swift` (`appGroupIdentifier`)
- `Shared/SharedConstants.swift`

### iCloud Setup (Optional)

For cross-device sync:

1. Enable **iCloud** capability on both iOS and macOS targets
2. Enable **Key-value storage**
3. The container identifier is `iCloud.com.murmurapp`

### Build and Run

**macOS:**
```bash
# Select MurmurMac scheme
# Build: Cmd+B
# Run: Cmd+R
```

**iOS:**
```bash
# Select MurmurIOS scheme
# Select your iPhone or simulator
# Build: Cmd+B
# Run: Cmd+R
```

## Running on Devices

### macOS

1. Build and run the **MurmurMac** scheme
2. The app appears in the menu bar (waveform icon)
3. Complete onboarding:
   - Enter your OpenAI API key
   - Grant microphone permission
   - Grant accessibility permission (for text insertion and global hotkey)

**Usage:**
- Hold **Fn** (or **Ctrl+Option**) to record
- Release to transcribe and insert text
- Access settings, history, and dictionary from the menu bar

### iOS

1. Build and run the **MurmurIOS** scheme on your iPhone
2. Complete onboarding:
   - Enter your OpenAI API key
   - Grant microphone permission
3. Install the keyboard extension:
   - Go to **Settings > General > Keyboard > Keyboards**
   - Tap **Add New Keyboard...**
   - Select **Murmur Keyboard**
   - Tap **Murmur Keyboard** and enable **Allow Full Access**

**Usage (Host App):**
- Tap and hold the record button to dictate
- Release to transcribe
- Copy the result or view history

**Usage (Keyboard):**
- In any app, switch to **Murmur Keyboard**
- Tap the **microphone button** to open Murmur for recording
- After recording, return to your app
- The transcribed text is automatically inserted

## Permissions

### macOS

| Permission | Purpose |
|------------|---------|
| Microphone | Record audio for transcription |
| Accessibility | Insert text into focused fields, register global hotkey |
| Network | Send audio to OpenAI API |

### iOS

| Permission | Purpose |
|------------|---------|
| Microphone | Record audio for transcription |
| Full Access (Keyboard) | Communicate with host app via App Group |

## Configuration

### Global Hotkey (macOS)

Default: **Fn** key (hold to talk)

To change:
1. Open Settings from menu bar
2. Go to **Hotkey** tab
3. Click **Change** and press your preferred key combination
4. Or use **Control+Option** preset

### Language

Supports 28 languages including English, Spanish, French, German, Japanese, Chinese, and more. Set in app settings.

### Personal Dictionary

Add custom word corrections:
- **Spoken**: How you say it (e.g., "john doe")
- **Written**: How to write it (e.g., "John Doe")

The AI cleanup pass respects dictionary entries.

## API Usage & Costs

Murmur uses the OpenAI API. Estimated costs per minute of audio:

| Model | Cost |
|-------|------|
| gpt-4o-transcribe | ~$0.006/min |
| gpt-4o-mini (cleanup) | ~$0.0001/request |

Total: approximately **$0.01 per minute** of dictation.

## Testing

### Unit Tests

```bash
cd MurmurCore
swift test
```

Tests cover:
- Cleanup prompt building
- Dictionary corrections
- History management
- Settings serialization
- Mock API client

Note: Full tests require macOS with Swift toolchain. Core package tests can also run on Linux.

## Troubleshooting

### "Microphone permission not granted"
- macOS: System Preferences > Privacy & Security > Microphone
- iOS: Settings > Murmur > Microphone

### "Invalid API key"
- Verify your OpenAI API key at platform.openai.com
- Re-enter the key in Settings

### Text not inserting (macOS)
- Grant Accessibility permission in System Preferences
- If still failing, the app falls back to clipboard paste (Cmd+V)

### Keyboard not showing transcription (iOS)
- Ensure **Allow Full Access** is enabled for the keyboard
- Tap the mic button to open the host app
- After recording, manually switch back to the original app

## Architecture

### MurmurCore (Swift Package)

Platform-agnostic core logic:
- `OpenAIClient`: Handles transcription and chat completion API calls
- `TranscriptionService`: Orchestrates transcription + cleanup workflow
- `CleanupPromptBuilder`: Generates system prompts with filler word removal, punctuation, and dictionary
- `PersonalDictionary`: Word replacement management
- `HistoryManager`: Transcription history storage
- `KeychainManager`: Secure API key storage
- `CloudSyncManager`: iCloud key-value sync

### macOS App

- Menu bar app (LSUIElement)
- Global hotkey via CGEvent tap
- Text insertion via Accessibility API with clipboard fallback
- Floating recording indicator

### iOS App

- SwiftUI host app with tab navigation
- URL scheme handler for keyboard integration
- App Group for sharing transcriptions

### iOS Keyboard Extension

- Basic QWERTY fallback layout
- Globe key for keyboard switching
- Mic button opens host app via URL scheme
- Reads transcription from App Group

## Known Gaps

- **Snippets UI**: Model exists but UI is not implemented
- **Tone per app**: Not implemented
- **Hands-free mode**: Not implemented
- **Voice commands**: Not implemented
- **Meeting notes**: Not implemented

## License

Copyright © 2024 Murmur. All rights reserved.

This is a clean-room implementation. No code, assets, prompts, or branding from other voice dictation apps.

# WakeTag

An iOS alarm clock you can't talk your way out of. Pick **any song on Apple Music** as your wake-up sound — and the only way to stop it (or change the volume) is to physically scan the **NFC tag** you registered. Stick the tag in the bathroom; the walk is the point.

## How it works

1. **Register** — create your account, grant Alarms + Apple Music access, and scan an NFC tag to bind it to the app.
2. **Set an alarm** — time, repeat days, and a song searched straight from the Apple Music catalog.
3. **It rings no matter what** — alarms are scheduled with **AlarmKit** (iOS 26), so they fire system-side even if the app is force-quit, in Silent mode, or behind a Focus.
4. **The trap** — both buttons on the system alarm ("Stop" *and* "Scan Tag") open WakeTag, which immediately starts your chosen song on repeat at full volume. Lowering the volume just snaps it back.
5. **The only way out** — scan the registered tag. The app matches the tag's factory UID; the wrong tag keeps the session polling with a "wrong tag" message.

### Playback ladder

| Situation | What plays |
|---|---|
| Apple Music subscriber | Full song via `ApplicationMusicPlayer`, repeat-one |
| No subscription | The song's 30-second preview, looped via `AVPlayer` |
| Offline / no preview | A synthesized backup tone, looped |

## Requirements

- **iOS 26+** (AlarmKit). iOS 26.1+ recommended.
- iPhone with NFC (any iPhone that runs iOS 26).
- An NFC tag from the **NTAG21x family** (NTAG213/215/216 stickers — the common cheap ones). MIFARE Classic tags are *not* readable by iPhones.
- Apple Music subscription for full-song alarms (previews work without).

## Building

```sh
xcodebuild build -project WakeTag.xcodeproj -scheme WakeTag \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates
```

One-time manual steps in the [Apple Developer portal](https://developer.apple.com/account):

1. **Agree to the latest Program License Agreement** if prompted — automatic signing can't create the App ID until you do.
2. **Enable the MusicKit app service** for `com.adinsegall.waketag`: Certificates, Identifiers & Profiles → Identifiers → the App ID → **App Services** tab → check **MusicKit**. Without this, catalog search fails with a developer-token error. (NFC Tag Reading is added automatically by Xcode from the entitlements file; there is deliberately no AlarmKit entitlement — none exists.)

Install to a connected/paired device:

```sh
xcrun devicectl list devices
xcrun devicectl device install app --device <UDID> <path>/WakeTag.app
xcrun devicectl device process launch --device <UDID> com.adinsegall.waketag
```

## Architecture notes

- `Services/AlarmScheduler.swift` — AlarmKit wrapper. Alarms are scheduled under the model's UUID; both alert buttons carry `AlarmRingIntent`, a `LiveActivityIntent` with `supportedModes: .foreground(.immediate)` that silences the system ring, foregrounds the app, and starts music.
- `Services/NFCService.swift` — `NFCTagReaderSession` (`.iso14443` + `.iso15693`) reading the tag's immutable factory UID; match-mode keeps polling on a wrong tag. Simulator builds return a stubbed UID so flows stay testable.
- `Services/MusicService.swift` — MusicKit search + the playback ladder above. `repeatMode` is set *after* `play()` (it's ignored before playback starts).
- `Services/VolumeGuard.swift` — KVO on `outputVolume`; snaps system media volume back via the hidden-`MPVolumeView`-slider technique while ringing.
- Registration is local-only: profile in `UserDefaults`, salted SHA-256 password digest in the Keychain. There is no server.

### Honest limitations

- iOS offers no way to block the hardware volume buttons or the Control Center slider — WakeTag *reacts* by snapping volume back rather than preventing the change.
- If the user kills WakeTag *after* it starts playing (rather than scanning), music stops — but the AlarmKit alarm has already done its job of waking them.
- Full-song playback can't start while the phone stays locked; the one tap on the alarm alert is required (Core NFC also requires an unlocked, foregrounded app to scan).

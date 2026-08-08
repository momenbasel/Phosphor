<p align="center">
  <img src="Resources/banner.png" alt="Phosphor Banner" width="100%">
</p>

<p align="center">
  <img src="Resources/AppIcon.svg" alt="Phosphor Icon" width="128" height="128">
</p>

<h1 align="center">Phosphor</h1>

<p align="center">
  <strong>Free and open-source iOS device manager for macOS.</strong><br>
  <a href="https://github.com/momenbasel/Phosphor/releases/latest">Download</a> -
  <a href="https://momenbasel.github.io/Phosphor/">Website</a> -
  <a href="#features">Features</a> -
  <a href="#installation">Install</a>
</p>

<p align="center">
  <a href="https://github.com/momenbasel/Phosphor/releases/latest"><img src="https://img.shields.io/github/v/release/momenbasel/Phosphor?style=flat-square&color=5856D6" alt="Release"></a>
  <a href="https://github.com/momenbasel/Phosphor/blob/main/LICENSE"><img src="https://img.shields.io/github/license/momenbasel/Phosphor?style=flat-square&color=34C759" alt="License"></a>
  <a href="https://github.com/momenbasel/Phosphor/actions"><img src="https://img.shields.io/github/actions/workflow/status/momenbasel/Phosphor/build.yml?style=flat-square" alt="Build"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.9-orange?style=flat-square" alt="Swift">
</p>

---

Phosphor gives you complete control over your iPhone, iPad, and iPod touch without proprietary software, iCloud lock-in, or subscriptions. Built natively with SwiftUI and powered by [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) with [libimobiledevice](https://libimobiledevice.org/) as fallback. Supports iOS 17-26+.

## Recent highlights

The current release includes several recent improvements from merged pull requests:

- **PDF message exports** that preserve the conversational layout, inline replies, and iMessage context ([#42](https://github.com/momenbasel/Phosphor/pull/42)).
- **Finder Wi-Fi sync controls** from the device view, so a paired USB device can be prepared for wireless use without leaving Phosphor ([#43](https://github.com/momenbasel/Phosphor/pull/43)).
- **A Readiness Center** that explains missing dependencies and backup recovery steps instead of leaving users with opaque failures ([#34](https://github.com/momenbasel/Phosphor/pull/34)).
- **Native encrypted-backup browsing**, including a password prompt, macOS Keychain option, and AES/PBKDF2-based decryption without a Python decryptor.
- **Safer, faster device operations**: lower-overhead polling, correct restore source/target handling, preserved timeout failures, and contained app-data extraction ([#47](https://github.com/momenbasel/Phosphor/pull/47), [#48](https://github.com/momenbasel/Phosphor/pull/48), [#49](https://github.com/momenbasel/Phosphor/pull/49), [#50](https://github.com/momenbasel/Phosphor/pull/50)).

> **Note:** The [active development PRs](#active-development) section below is intentionally separate from the shipped feature list. Open pull requests are not release promises and may overlap or change during review.

---

## Why Phosphor?

Apple's Finder integration is all-or-nothing. Proprietary tools like iMazing cost $50/year. Phosphor fills the gap:

| Feature | Finder | iMazing | Phosphor |
|---------|--------|---------|----------|
| Full device backup | Yes | Yes | Yes |
| Incremental backup | No | Yes | Yes |
| Browse backup contents | No | Yes | Yes |
| Selective file restore | No | Yes | Yes |
| Export iMessages to CSV/HTML/PDF | No | Yes | Yes |
| Export WhatsApp messages | No | Yes | Yes |
| Photo extraction (no iCloud) | No | Yes | Yes |
| App data extraction | No | Yes | Yes |
| Install/remove IPAs | No | Yes | Yes |
| Battery health diagnostics | No | Yes | Yes |
| Real-time device console | No | Yes | Yes |
| Device file system browser | No | Yes | Yes |
| Drag-and-drop file transfer | No | Yes | Yes |
| Scheduled Wi-Fi backups | No | Yes | Yes |
| Time Machine backup restore | No | No | **Yes** |
| Contacts export (vCard/CSV) | No | Yes | Yes |
| Calendar export (ICS/CSV) | No | Yes | Yes |
| Apple Watch data browsing | No | Yes | Yes |
| Backup archive format | No | .imazing | **.phosphor** |
| Localization (7 languages) | No | Yes | Yes |
| Crash report viewer | No | Yes | Yes |
| Process monitor | No | Yes | Yes |
| Ringtone creator | No | Yes | Yes |
| HEIC to JPG conversion | No | Yes | Yes |
| iOS 26 support | N/A | Paid | **Yes** |
| Price | Free | $49.99/yr | Free |
| Open source | No | No | **MIT** |

## Features

### Device Management
- Automatic detection of connected iOS devices via USB
- Device info: model, iOS version, serial, UDID, IMEI, Wi-Fi/Bluetooth MAC
- Pair/unpair devices
- Enable Finder Wi-Fi sync for a trusted USB-connected device
- Restart, shutdown, sleep commands
- Take device screenshots

### Backups
- Create full and incremental local backups (no iCloud required)
- Browse backup contents through parsed `Manifest.db`
- Navigate by domain (Camera Roll, Apps, Home, System, Keychain, etc.)
- Search files across the entire backup
- Extract individual files or entire domains
- Open password-protected backups. Phosphor prompts for the backup password and decrypts natively (PBKDF2, RFC 3394 key unwrap, AES-256-CBC) with no Python or external tools. Works on backups made by Finder, iMazing, libimobiledevice and pymobiledevice3, not only ones Phosphor created. The password stays in memory for the session unless you tick "Remember this password", which stores it in the macOS Keychain.
- Manage backup encryption
- Delete old backups

### Messages
- Browse all iMessage and SMS conversations from backups
- View messages in a native chat-bubble interface
- Search across all messages
- Export conversations to **CSV**, **HTML**, **Plain Text**, **JSON**, or **PDF**
- Export all conversations at once
- HTML export styled like native iMessage (blue/gray bubbles)
- PDF exports keep a readable conversation layout, reactions, and inline-reply context

### Photos & Videos
- Browse Camera Roll from backup without restoring
- Filter by type: Photos, Videos, Screenshots
- Grid and list view modes
- Batch extract to any folder
- Preserves original filenames and structure

### Applications
- List all installed apps on connected devices
- Browse apps stored in backups with data sizes
- Install `.ipa` files directly to device
- Remove apps from device
- Extract an app's container out of a backup - pick a backup in the Apps header, then use Extract Data on any app row. Extraction reads from a local backup, not from the connected device.

### File System
- Browse device filesystem via AFC (Apple File Conduit) - no FUSE/ifuse required on macOS Sonoma+
- Navigate directories, view file metadata
- Copy files to/from device via pymobiledevice3 AFC push/pull
- Browse specific app containers (Documents, Library, tmp)
- Delete files on device
- Drag-and-drop file transfer

### Contacts
- Browse all contacts from backup AddressBook database
- View phone numbers, emails, organization details
- Search across all contacts
- Export as **vCard (.vcf)** or **CSV**

### Calendar
- Browse calendars and events from backup
- View event details, duration, all-day status
- Export as **ICS (iCalendar)** or **CSV**

### Apple Watch
- View paired Apple Watch info from iPhone backup
- Browse WatchKit extension apps with data sizes
- Activity ring history (Move, Exercise, Stand)
- Extract all Watch-related data from backup

### Diagnostics
- Readiness Center for dependency checks, backup recovery guidance, and redacted diagnostics
- Battery: current charge, charging status, health percentage, design vs. actual capacity (mAh), cycle count, temperature
- Storage: total capacity, usage breakdown (Apps, Photos, Media, Other), available space
- Visual storage bar similar to macOS About This Mac
- Real-time device system log (syslog) streaming with proper process termination
- Filter and search logs
- Export logs to file
- Color-coded log levels (Error/Warning/Debug)
- **Crash report viewer** - Pull and browse device crash reports
- **Process monitor** - Live process list from device

### Backup Management
- **Time Machine mode**: 3D animated backup browser for visual restore
- **Scheduled backups**: automatic hourly/daily/weekly/monthly via USB or Wi-Fi
- **.phosphor archives**: portable backup export/import format
- Backup encryption management (enable/disable/verify)
- Drag-and-drop file transfer in file browser

## Installation

### Homebrew (recommended)

```bash
brew tap momenbasel/phosphor
brew install --cask phosphor
```

### Manual

1. Download the latest `.dmg` from [Releases](https://github.com/momenbasel/Phosphor/releases)
2. Drag `Phosphor.app` to Applications
3. Install pipx if needed: `brew install pipx`
4. Install pymobiledevice3: `pipx install pymobiledevice3`
5. Optional fallback: `brew install libimobiledevice ideviceinstaller`

### Build from Source

```bash
# Install pipx and pymobiledevice3 (primary)
brew install pipx
pipx install pymobiledevice3

# Optional fallback tools
brew install libimobiledevice ideviceinstaller

# Clone and build
git clone https://github.com/momenbasel/Phosphor.git
cd Phosphor
swift build -c release

# Create app bundle
bash Scripts/build.sh

# Launch
open .build/Phosphor.app
```

## Requirements

- **macOS 14.0** (Sonoma) or later
- **pymobiledevice3** (primary backend, supports iOS 17-26+): `brew install pipx && pipx install pymobiledevice3`
- **libimobiledevice** (optional fallback): `brew install libimobiledevice`
- **ideviceinstaller** (optional fallback for app management)
- **ifuse** (legacy file mounting, not needed with pymobiledevice3)

Phosphor checks for available tools on launch and uses the best available backend automatically.

## Architecture

```
Sources/Phosphor/
  App/           SwiftUI app entry point
  Models/        DeviceInfo, BackupInfo, Message, MediaItem, AppBundle
  Services/      DeviceManager, BackupManager, MessageExporter,
                 PhotoExtractor, AppManager, FileTransferManager,
                 DiagnosticsManager
  ViewModels/    MVVM state management layer
  Views/         SwiftUI views organized by feature
  Utilities/     Shell (process runner), SQLiteReader, BackupManifest,
                 PlistParser
```

**Key design decisions:**

- **pymobiledevice3 primary, libimobiledevice fallback** - Every operation tries pymobiledevice3 first (JSON-based, supports latest iOS), falls back to libimobiledevice CLI if unavailable.
- **No C bindings** - Wraps CLI tools via subprocess. Simpler dependency chain, easier to maintain.
- **Direct SQLite** - Parses iOS backup databases (`Manifest.db`, `sms.db`) using system `sqlite3`. Zero external Swift dependencies.
- **MVVM** - Services handle business logic, ViewModels manage UI state, Views are declarative and composable.
- **Zero external dependencies** - Only system frameworks (SwiftUI, Foundation, sqlite3, UniformTypeIdentifiers).

## iOS Backup Format

Phosphor directly parses Apple's backup format:

```
~/Library/Application Support/MobileSync/Backup/<UDID>/
  Info.plist           Device metadata
  Manifest.plist       Encryption status, app list
  Manifest.db          SQLite database mapping files to SHA-1 hashes
  Status.plist         Backup state
  <xx>/<sha1-hash>     Actual files, organized in 2-char prefix dirs
```

The `Manifest.db` contains a `Files` table with columns:
- `fileID` - SHA-1 hash (also the filename on disk)
- `domain` - e.g., `CameraRollDomain`, `AppDomain-com.example.app`
- `relativePath` - Original path within the domain
- `flags` - 1=file, 2=directory, 4=symlink

Phosphor parses this to provide file-system-like browsing without modifying the backup.

## Active development

The following pull requests are open at the time this README was updated. They describe work under review rather than functionality guaranteed in the latest release. Some changes intentionally overlap; each PR should be reviewed and merged on its own merits.

| Area | Pull request | What it proposes |
|---|---|---|
| Updates | [#53](https://github.com/momenbasel/Phosphor/pull/53) | A secure built-in update checker. |
| Operation safety | [#54](https://github.com/momenbasel/Phosphor/pull/54) | Prevent overlapping backup and restore operations. |
| Backup browsing | [#55](https://github.com/momenbasel/Phosphor/pull/55) | Home-screen snapshot view, asynchronous backup browsing, and file previews. |
| Localization | [#56](https://github.com/momenbasel/Phosphor/pull/56) | Package and load Simplified Chinese localization strings. |
| Backup visibility / platform support | [#57](https://github.com/momenbasel/Phosphor/pull/57) | App-wide backup status and iOS 27 support. |
| Message exports | [#58](https://github.com/momenbasel/Phosphor/pull/58) | Improved message exports and attachment preservation. |
| Background reliability | [#59](https://github.com/momenbasel/Phosphor/pull/59) | More reliable background backup behavior. |
| Multiple devices | [#60](https://github.com/momenbasel/Phosphor/pull/60) | Safe concurrent multi-device backups. |
| Backup locations | [#61](https://github.com/momenbasel/Phosphor/pull/61) | Network-aware backup locations. |
| Wi-Fi discovery | [#62](https://github.com/momenbasel/Phosphor/pull/62) | Stabilized Wi-Fi device discovery. |
| Reliability hardening | [#63](https://github.com/momenbasel/Phosphor/pull/63) | Safer destructive operations and process cleanup. |
| Export / responsiveness | [#65](https://github.com/momenbasel/Phosphor/pull/65) | Atomic message export publication, persistent export and extraction controls, cancellable background work, and streamed MBOX attachments. |

## Roadmap

- [x] WhatsApp message parsing (ChatStorage.sqlite)
- [x] Apple Notes extraction (NoteStore.sqlite)
- [x] Call log browsing and export
- [x] Safari bookmarks and history
- [x] Health data extraction (samples, workouts, all data types)
- [x] Music and ringtone transfer (extract from backup, install to device via AFC)
- [x] Batch operations (multi-select extract in Photos, Music)
- [x] Wi-Fi device connection (libimobiledevice network mode)
- [x] Encrypted backup browsing (native, no Python or external tools)
- [x] Drag-and-drop file transfer
- [x] Localization (English, Arabic, Spanish, French, German, Japanese, Chinese)
- [x] Apple Watch data through paired iPhone
- [x] Time Machine-style backup restore with 3D animation
- [x] Scheduled automatic backups (hourly/daily/weekly/monthly, Wi-Fi support)
- [x] .phosphor backup archive format (portable backup export/import)
- [x] Contacts browsing and export (vCard, CSV)
- [x] Calendar events browsing and export (ICS, CSV)
- [x] Device-to-device transfer (clone) - backup source, restore to destination
- [x] Full pymobiledevice3 migration (72 Shell calls, 13 services)
- [x] Crash report viewer
- [x] Process monitor
- [x] Ringtone creator (afconvert)
- [x] HEIC to JPG conversion (sips)
- [x] Backup progress bar with percentage
- [x] Syslog proper process termination
- [x] Backup cancel support
- [x] Backup encryption management (enable/disable/change password)
- [ ] Voicemail browsing

## Troubleshooting

### Where Phosphor stores backups

Starting with v1.0.4, Phosphor's default backup directory is `~/Documents/Phosphor Backups`. This is a user-owned location, so Phosphor needs no special permission grant; it also keeps Phosphor's backups separate from Finder's, which eliminates any risk of a Phosphor run corrupting Finder-managed backups.

If you are upgrading from v1.0.3 or earlier and were using the system MobileSync directory, Phosphor will detect existing backups there on first launch and pin it as your override - nothing changes. You can switch to the new default any time from **Phosphor -> Settings -> Backup Directory -> Reset**.

### "Both backup methods failed"

Phosphor now surfaces the underlying `pymobiledevice3` and `idevicebackup2` stderr in the failure message. Common causes:

0. **Directory "is not readable" / permission denied** - you pointed Phosphor at `~/Library/Application Support/MobileSync/Backup` but did not grant Full Disk Access. Prefer switching the backup directory back to the default `~/Documents/Phosphor Backups` in **Settings**; only grant Full Disk Access if you specifically need Phosphor to read Apple's shared backups.
1. **Trust prompt missed** - Unlock the device, tap **Trust This Computer**, enter your passcode, then retry the backup.
2. **Stale pymobiledevice3** - iOS 17/18/26 require a recent release. Upgrade with:
   ```bash
   pipx upgrade pymobiledevice3
   ```
3. **Binary not on PATH** - GUI apps do not inherit your shell PATH. Phosphor probes `pipx`, Homebrew, and `~/Library/Python/3.{10..14}/bin` automatically; if you installed pymobiledevice3 elsewhere, symlink it into one of those directories.
4. **Missing Python dependencies** - `ModuleNotFoundError` in the failure details means a partial install. Reinstall with `pipx reinstall pymobiledevice3`.
5. **Pairing record mismatch** - From Terminal, run `pymobiledevice3 lockdown pair` once, accept the Trust prompt, then retry.

For encrypted backup issues, verify the device has a passcode set and that `pymobiledevice3 backup2 encryption` reports the expected state.

## Star History

<a href="https://star-history.com/#momenbasel/Phosphor&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=momenbasel/Phosphor&type=Date&theme=dark">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=momenbasel/Phosphor&type=Date">
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=momenbasel/Phosphor&type=Date" width="600">
  </picture>
</a>

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## Credits

- [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) - Pure Python implementation of Apple's mobile device protocols (primary backend)
- [libimobiledevice](https://libimobiledevice.org/) - Cross-platform protocol library for iOS devices (fallback)
- [ifuse](https://github.com/libimobiledevice/ifuse) - FUSE filesystem for iOS devices (legacy)
- Apple's SF Symbols for iconography

## License

[MIT](LICENSE) - Use it, fork it, ship it.

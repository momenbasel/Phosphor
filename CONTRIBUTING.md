# Contributing to Phosphor

Thanks for your interest in contributing. Phosphor is built to give iOS users full control over their devices without proprietary lock-in.

## Getting Started

### Prerequisites

- macOS 14.0 (Sonoma) or later
- Swift 5.9+
- Xcode Command Line Tools (`xcode-select --install`)
- libimobiledevice (`brew install libimobiledevice ideviceinstaller ifuse`)

### Building

```bash
git clone https://github.com/momenbasel/Phosphor.git
cd Phosphor
swift build
```

To create the .app bundle:

```bash
bash Scripts/build.sh
open .build/Phosphor.app
```

### Windows Edition

The Windows edition lives in `windows/` and needs Python 3.12 x64 and Node.js 22+ on Windows 10 or 11:

```powershell
cd windows
./scripts/build.ps1
```

For day-to-day work, run `npm run dev` and `npm start -- --dev`, and `npm test` for the engine regression suite. Format Python with `black backend tests scripts` and the interface with `npm run format`; CI checks both. See [windows/README.md](windows/README.md) for details. When you add or rename a macOS sidebar section, keep the Windows `navigation` list in `windows/src/navigation.ts` in step with it.

### Project Structure

```
Sources/Phosphor/
  App/           - App entry point
  Models/        - Data models (DeviceInfo, BackupInfo, Message, etc.)
  Services/      - Business logic (DeviceManager, BackupManager, etc.)
  ViewModels/    - SwiftUI state management
  Views/         - All SwiftUI views, organized by feature
  Utilities/     - Shell runner, SQLite wrapper, plist parser
```

## How to Contribute

### Reporting Bugs

Open an issue with:
- macOS version
- Device model and iOS version (if relevant)
- Steps to reproduce
- Expected vs. actual behavior
- Console output if applicable

### Submitting Changes

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Test with a real device if possible
5. Run `Scripts/regression/run.py` and `swift build` to verify regressions and compilation
6. Commit with clear messages
7. Open a PR against `main`

### Code Style

- Follow existing patterns in the codebase
- Use Swift concurrency (async/await) for async operations
- Keep views small and composable
- Services wrap CLI tools; views never call shell commands directly
- Use SF Symbols for icons

### Areas Where Help is Needed

- **WhatsApp parser**: Parse ChatStorage.sqlite for WhatsApp message export
- **Notes extraction**: Parse NoteStore.sqlite from backups
- **Call log extraction**: Parse call_history.db
- **Music transfer**: Implement music/ringtone sync via AFC
- **Localization**: Add support for non-English languages
- **Accessibility**: VoiceOver and keyboard navigation improvements
- **Testing**: Unit tests for services and integration tests

## Code of Conduct

Be respectful, constructive, and patient. We're all here to build something useful.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

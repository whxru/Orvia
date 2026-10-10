# Development and release guide

[English README](../README.en.md) · [中文首页](../README.md)

## Build

Use a Mac with the macOS 26 SDK or newer, supplied by Xcode 26+ or matching Command Line Tools. `xcrun --sdk macosx --show-sdk-version` shows the selected SDK. When several Xcode installations are available, use `DEVELOPER_DIR` to select one for the build.

```bash
bash Source/build.sh
bash Source/test.sh
bash Source/package.sh
```

`build.sh` accepts an optional output directory. `package.sh` accepts an optional release directory. Both work when called from outside the repository and with paths containing spaces. Packages contain an ad-hoc signed app and include the MIT license in its resources; the SHA-256 checksum is a separate file beside the ZIP.

Builds use the host architecture and an explicit deployment target read from `Source/Info.plist`. That file also owns the app version and build number. There is no universal binary build or third-party dependency resolver. The deployment target is macOS 13.0; actual validation has been on Apple Silicon and macOS 26, not the full advertised deployment range.

## Source map

| Path | Responsibility |
| --- | --- |
| `Source/main.swift` | App lifecycle, controller, settings UI, native integration checks |
| `Source/GestureCore.swift` | Touch lifecycle, gesture recognition, directional selection |
| `Source/Multitouch.c`, `Multitouch.h` | Runtime-loaded MultitouchSupport bridge |
| `Source/Model.swift` | Wheels, actions, trigger rules, scenes, persisted preferences |
| `Source/KeyRecording.swift`, `InputActions.swift`, `Shortcuts.swift` | Keyboard bindings, text actions, Apple Shortcuts |
| `Source/RuntimeKeyboard.swift`, `QuickTextEditor.swift` | Floating keyboard and phrase editor |
| `Source/SettingsPickers.swift`, `SystemSymbols.swift` | App/key pickers and system icon search |
| `Source/SettingsTransfer.swift`, `SettingsTransferUI.swift` | Validated settings import/export and backup UI |
| `Source/WheelRendering.swift`, `WheelCursor.swift` | Themes, feedback, and cursor lifecycle |
| `Source/Localization.swift` | Chinese and English interface strings |
| `Source/Resources/`, `Icon.swift` | App artwork, symbol-name catalog, icon generation |
| `Source/Tests/main.swift` | Automated core and settings checks |
| `docs/` | User guide, settings contract, development notes |

Keep `Source/Resources/`: these are build inputs. The symbol catalog supplies names, keywords, and aliases; AppKit renders the system icons at runtime. `outputs/` holds generated apps and archives and stays outside Git.

## Validation

`Source/test.sh` uses isolated preferences and exercises gesture transitions, wheel geometry, trigger behavior, keyboard encoding, scene matching, settings persistence/migration/import, and icon search. It also reads `docs/settings-example.json` through the actual importer. These checks do not establish physical trackpad compatibility or validate all behavior in other apps.

Before shipping a release, test on real hardware:

- A stationary two-finger hold opens the wheel; scrolling and physical clicks before activation do not.
- Entry, release, and held-key actions behave correctly, including returning to the center and changing the input target. All held keys and the cursor are restored on exit.
- Global, app-specific, and text-input scenes match correctly and survive a restart.
- Unicode phrases, multiline text, optional Enter, and a known Apple Shortcut work in the intended target apps.
- Import previews changes, makes a recoverable backup, and preserves a round trip.
- Light/dark appearance, both themes, reduced motion/transparency, permission recovery, and launch at login work as expected.

The executable has optional native review modes:

```bash
outputs/Orvia.app/Contents/MacOS/Orvia --settings-review
outputs/Orvia.app/Contents/MacOS/Orvia --glass-review
outputs/Orvia.app/Contents/MacOS/Orvia --glass-review --dark
```

`--settings-review` copies the current preferences into an isolated review domain; edits do not change normal saved settings. It still opens a real application with real runtime capabilities. Glass review shows the system-composited material; `--render-feedback` only renders foreground artwork and is not a glass-compositing check.

Native integration flags in `main.swift` can send real keystrokes, open voice input, or change login-item registration. Read the relevant mode before running it, quit the normal instance, and use a controlled local session. CI runs only `Source/test.sh`, builds, and packages; it does not run these interactive modes.

## Prepare a GitHub Release

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Source/Info.plist` for a new version.
2. Run the core checks and the relevant manual checks. Record the macOS version and hardware actually tested.
3. Run `bash Source/package.sh`. For version 0.21.1 on Apple Silicon, this produces `outputs/release/Orvia-0.21.1-macos-arm64.zip` and its `.sha256` file.
4. Verify the checksum from the release directory with `shasum -a 256 -c Orvia-0.21.1-macos-arm64.zip.sha256`.
5. Attach the archive and checksum to the intended GitHub Release. State the architecture, tested system versions, Accessibility requirement, private-API dependency, and signing/notarization status in the release notes.

The included scripts use **ad-hoc signing**, not Developer ID signing or Apple notarization. They do not provide a frictionless Gatekeeper-approved download. If distributing a Developer ID signed build, sign and notarize the completed app, staple the ticket, and then create its final ZIP and checksum; the existing `package.sh` rebuilds and ad-hoc signs, so do not run it over that prepared bundle.

The [GitHub Actions runner catalog](https://github.com/actions/runner-images#available-images) lists `macos-26` as an Apple Silicon runner. The workflow in `.github/workflows/build.yml` runs on pushes, pull requests, and manual dispatch, and uploads build artifacts. It has read-only repository permissions and does not create releases, tags, or commits.

## Compatibility and data

Orvia was renamed from Magic Wheel. Preserve these identifiers unless implementing an explicit migration:

- Bundle identifier and standard preference domain: `local.magicwheel.app`.
- Export format identifier: `magic-wheel-settings`.
- Backup location: `~/Library/Application Support/MagicWheel/Backups/`.

Settings exports are versioned separately from the app: current exports are v3; v1 and v2 remain importable. The [format description](settings-format.zh-CN.md), [schema](settings-format.schema.json), [example](settings-example.json), and importer should stay consistent. The example includes deliberately fictitious app/shortcut references; it is a format fixture, not a ready-to-use profile.

Global touch access relies on the private MultitouchSupport ABI, and background cursor hiding uses optional WindowServer symbols. Older systems use a material fallback for Liquid Glass. These compatibility paths need testing after macOS updates; this is not a public-API-only Mac App Store implementation.

Keep generated builds, local preferences, exported personal phrases, logs, signing keys, and experimental artwork out of commits. When reporting a bug, include a minimal reproduction and remove personal content from any settings export.

## License

Orvia is distributed under the [MIT License](../LICENSE).

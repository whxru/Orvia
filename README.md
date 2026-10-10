

https://github.com/user-attachments/assets/e4998c96-6128-473e-bc98-07fbc3015a09


<p align="center">
  <img src="Source/Resources/OrviaLogo.png" width="112" alt="Orvia icon">
</p>

<h1 align="center">Orvia</h1>
<p align="center"><strong>Everyday actions, right on your Magic Trackpad.</strong></p>
<p align="center">English · <a href="README.zh-CN.md">简体中文</a></p>

Orvia is a customizable action wheel for macOS. Vibe Coding with your voice, hands off the keyboard. Rest two fingers on your trackpad to bring it up beside your pointer, slide toward an action, and lift to close. Copy, paste, voice input, and your favorite shortcuts are a gesture away.

## Features

- **Quick voice input.** Bring your favorite hold-to-talk input method into the wheel. Bind its voice-input key to a slice, slide in to speak, and lift to finish.
- **Automatic scene switching.** Give each app its own wheel, or create a wheel for typing in text fields. Combine app and text-focus conditions, and share a scene across multiple apps.
- **Customizable wheels.** Add or remove slices, drag to reorder, rotate the wheel, and choose labels and icons. Actions can run on entry or release; keys can also stay held while you remain inside a slice.
- **Shortcuts, text, and workflows.** Record key combinations, insert saved phrases, run Apple Shortcuts, or open a floating keyboard. Saved text supports line breaks, emoji, and an optional Enter afterward.
- **Appearance and settings.** Minimal and Liquid Glass themes follow light and dark mode. Includes Chinese and English interfaces, settings import/export, and launch at login.

## Examples

| Context | Example wheel |
| --- | --- |
| Coding with AI | Dictate a request, with paste, Return, and editor shortcuts nearby |
| Messaging | Voice input, saved replies, and line breaks; optionally press Enter after a specific phrase |
| Editing documents | Copy, paste, undo, and cursor movement when a text field has focus |
| Everyday workflows | Launch your Apple Shortcuts directly from the wheel |

For example, if your input method uses Right Option for hold-to-talk, bind Right Option to a slice and choose “hold on entry, release on exit.” Rest two fingers to open the wheel, slide into that slice to speak, and lift to finish.

## Build and use

Requires **Xcode 26+ or Command Line Tools with the macOS 26 SDK**. Download or clone the repository, then run from its root:

```bash
bash Source/build.sh
open outputs/Orvia.app
```

On first launch, allow Orvia in **System Settings → Privacy & Security → Accessibility**. Click a slice to configure an action, switch to your target app, and rest two fingers for about **0.45 seconds** to open the wheel. Closing settings leaves Orvia running in the menu bar.

Tested on **Apple Silicon with macOS 26**, including native Liquid Glass.

See the [usage guide (Chinese)](docs/user-guide.zh-CN.md) for detailed controls, the [development guide](docs/development.md) for testing, packaging, and signing, and the [settings format (Chinese)](docs/settings-format.zh-CN.md) for configuration details.

## License

[MIT](LICENSE)

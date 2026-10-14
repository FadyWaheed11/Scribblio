<p align="center"><img src="Resources/icon_1024.png" width="140" alt="Scribblio icon"></p>

<h1 align="center">Scribblio</h1>

<p align="center">A magic quill that writes your notes on your Mac desktop.</p>

Scribblio puts a sheet of old, burnt-edged paper on your desktop with a glowing green quill hovering over it. Start typing and the quill writes every letter for you in cursive, in ink that glows green and then dries dark. The paper moves like a real sheet: lift a corner, curl it, fold it or flip it.

- Write in **English or Arabic** (right to left)
- Keep **many notes** on the desktop and **save** them to open later
- Undo, select all, copy and paste, resize notes from the corners
- No permissions needed, no internet connection

**Requires** macOS 14 Sonoma or later, on Apple silicon or Intel.

## Install

### Option 1: Use the ready-made installer (easiest)

Download one of these from the [`dist`](dist) folder or the [latest release](https://github.com/FadyWaheed11/Scribblio/releases/latest):

- **[Scribblio.dmg](https://github.com/FadyWaheed11/Scribblio/raw/main/dist/Scribblio.dmg)**: double-click it and drag **Scribblio** onto **Applications**.
- **[Scribblio.pkg](https://github.com/FadyWaheed11/Scribblio/raw/main/dist/Scribblio.pkg)**: double-click it, click **Continue**, then **Install**, and enter your Mac password.

**First launch:** Scribblio is not notarized by Apple, so macOS may say it can't verify it. Click **Done**, open **System Settings > Privacy & Security**, click **Open Anyway** and confirm. You only do this once.

### Option 2: Install the downloaded file from Terminal

If the file is in your Downloads folder:

```bash
# from the .pkg
sudo installer -pkg ~/Downloads/Scribblio.pkg -target /

# or from the .dmg
hdiutil attach ~/Downloads/Scribblio.dmg -nobrowse -mountpoint /tmp/scribblio
cp -R /tmp/scribblio/Scribblio.app /Applications/
hdiutil detach /tmp/scribblio
xattr -dr com.apple.quarantine /Applications/Scribblio.app
```

### Option 3: Build it from source

You only need Apple's free Command Line Tools (`xcode-select --install`), no Xcode project.

```bash
git clone https://github.com/FadyWaheed11/Scribblio.git
cd Scribblio
zsh build.sh
cp -R build/Scribblio.app /Applications/
xattr -cr /Applications/Scribblio.app
open /Applications/Scribblio.app
```

## Use

Open Scribblio, click the paper and start typing.

| Action | How |
| --- | --- |
| Move the quill | Arrow keys, or click a letter |
| New note / Open / Save | ⌘N / ⌘O / ⌘S |
| Undo / Redo | ⌘Z / ⌘⇧Z |
| Select all, copy, paste | ⌘A, ⌘C, ⌘V |
| Close note / Quit | ⌘W / ⌘Q |
| Move, curl or fold the paper | Drag any edge |
| Resize a note | Drag a corner |
| Rotate a note | Scroll over it |
| More commands | Right-click the paper |

To write in Arabic, switch your keyboard to Arabic and type. The app's menus follow your Mac's language (English or Arabic).

## Uninstall

Quit Scribblio, open **Finder > Applications**, drag **Scribblio** to the **Trash** and empty it. (Launchpad and the Dock can't remove it.) Your saved notes stay where you saved them.

## Build the installers

```bash
zsh package.sh
```

This makes `dist/Scribblio.dmg` and `dist/Scribblio.pkg` for Apple silicon and Intel. To sign and notarize them with an Apple Developer ID, see the comments at the top of [`package.sh`](package.sh).

## License

MIT, see [LICENSE](LICENSE).

# ClipboardArchiv

ClipboardArchiv is a native macOS clipboard history app. It saves copied text, images, and rich clipboard data locally, then lets you reopen your archive by holding `Command+C`.

It is built for everyday work in Confluence, Jira, browsers, documents, and similar tools where clipboard data can contain links, formatted text, mentions, due dates, action items, or images.

## Features

- Automatically archives new clipboard entries.
- Stores text, images, and rich pasteboard payloads.
- Preserves rich clipboard formats where macOS provides them, including HTML, RTF, and app-specific pasteboard data.
- Restores rich entries to the clipboard instead of flattening everything to plain text.
- Opens the archive window by holding `Command+C`.
- Does not open on `Command+Shift+V`.
- Shows `Alle` and `Favoriten` tabs.
- Lets you mark entries as favorites.
- Lets you assign favorite shortcuts from `Command+1` to `Command+9`.
- Pastes a favorite into the active app with its shortcut.
- Copies any entry by clicking its row.
- Lets you drag image entries out of the archive window.
- Starts at the top of the list whenever the archive window opens.
- Stores entries by date and time inside a local `ClipboardArchiv` folder.

## Rich Clipboard

ClipboardArchiv saves more than plain text when the source app places rich data on the macOS pasteboard. This is useful for Confluence and Jira content such as links, formatted snippets, mentions, action items, and due dates.

Some apps do not place the full original data on the pasteboard. For example, a Confluence image copy may contain rich HTML or Atlassian metadata, but not always the actual image pixels. In that case ClipboardArchiv can preserve and restore the rich payload it received, but it cannot recreate an image that was never provided by macOS. If real image data is present, the app stores a preview and supports dragging the image out of the archive.

## Security

ClipboardArchiv stores archive data locally and encrypts it at rest:

- Archive files are encrypted with AES-GCM.
- The encryption key is stored in the macOS Keychain.
- Text files, image files, rich pasteboard sidecars, previews, and the JSON index are encrypted.
- Existing plain archive files are migrated to encrypted storage on app start.
- The archive window is protected by macOS authentication.
- The archive auto-locks after 10 minutes.
- A manual lock action is available from the app menu.

ClipboardArchiv is not a password manager. It protects stored archive files, but anything currently on the system clipboard can still be read by apps that macOS allows to access the clipboard.

Temporary decrypted files are created only when dragging an image out of the app. They are cleaned up on app start and scheduled for deletion after a few minutes.

## Requirements

- macOS
- Swift command line tools
- Optional but recommended: an Apple Development signing identity

Check Swift:

```bash
swift --version
```

## Build

```bash
cd ~/Desktop/ClipboardArchiv
./build.sh
```

The app is created here:

```text
~/Desktop/ClipboardArchiv/build/ClipboardArchiv.app
```

The build script signs the app with the first available `Apple Development:` identity. If none is available, it falls back to ad-hoc signing.

## Start

```bash
open ~/Desktop/ClipboardArchiv/build/ClipboardArchiv.app
```

Restart after rebuilding:

```bash
pkill -f '/ClipboardArchiv.app/Contents/MacOS/ClipboardArchiv'
open ~/Desktop/ClipboardArchiv/build/ClipboardArchiv.app
```

## Permissions

ClipboardArchiv needs macOS permissions for the global keyboard behavior:

- `Bedienungshilfen` for opening the window with `Command+C`, pasting favorites with shortcuts, and bringing the panel forward.
- `Eingabeüberwachung` for reliable keyboard detection.

Open the app menu or menu bar icon, then use:

- `Bedienungshilfen öffnen`
- `Eingabeüberwachung öffnen`

Enable `ClipboardArchiv` in both macOS settings, then restart the app.

If permissions stop working after a rebuild, make sure the built app is signed consistently and that you are launching the same `.app` path each time.

## Configure Archive Folder

By default, ClipboardArchiv stores data in:

```text
~/Documents/ClipboardArchiv
```

Choose another parent folder:

```bash
cd ~/Desktop/ClipboardArchiv
./configure-archive-folder.sh "/path/to/parent-folder"
```

ClipboardArchiv will then create or use:

```text
/path/to/parent-folder/ClipboardArchiv
```

Example for iCloud Drive:

```bash
./configure-archive-folder.sh "$HOME/Library/Mobile Documents/com~apple~CloudDocs"
```

Reset to the default location:

```bash
./reset-archive-folder.sh
```

Restart ClipboardArchiv after changing the folder.

The setting is stored via macOS defaults:

```bash
defaults write local.clipboardarchiv.app ArchiveParentPath "/path/to/parent-folder"
defaults delete local.clipboardarchiv.app ArchiveParentPath
```

## Archive Files

Archive structure:

```text
ClipboardArchiv/
  clipboard_history.json
  diagnose.log
  YYYY-MM-DD/
    HH-mm-ss_text_xxxxxxxx.txt
    HH-mm-ss_bild_xxxxxxxx.png
    HH-mm-ss_rich-preview_xxxxxxxx.png
    HH-mm-ss_pasteboard_xxxxxxxx.pasteboard/
      manifest.json
      item_0_type_0_public.html.data
```

The files are encrypted after the first secure app start.

## Development

Useful commands:

```bash
./build.sh
open build/ClipboardArchiv.app
pkill -f '/ClipboardArchiv.app/Contents/MacOS/ClipboardArchiv'
```

Check the app signature:

```bash
codesign -dv build/ClipboardArchiv.app 2>&1 | sed -n '1,20p'
```

Inspect configured archive location:

```bash
defaults read local.clipboardarchiv.app ArchiveParentPath
```

## GitHub Notes

- Do not commit `build/`.
- Do not commit local archive data from `~/Documents/ClipboardArchiv`.
- Keep signing identity optional for contributors.
- Include screenshots only if they do not reveal clipboard contents.

The repository includes `.gitignore` for build output and local app artifacts.

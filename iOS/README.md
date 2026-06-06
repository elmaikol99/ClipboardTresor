# iOS Plan

This folder contains the first iOS implementation slice for ClipboardTresor.

## Targets to create in Xcode

Create an iOS project with these targets:

- `ClipboardTresor` iOS app
- `ClipboardKeyboard` Custom Keyboard extension
- `ClipboardShareExtension` Share extension

Add `../Shared/ClipboardCore` as a local Swift package dependency and link it to all three targets.

## App Groups

Use one App Group for the app and both extensions:

```text
group.local.clipboardtresor
```

The Keyboard extension needs `RequestsOpenAccess = YES` in its `Info.plist` if it should read the shared App Group archive.

## MVP Behavior

- The iOS app shows the encrypted archive, supports search and favorites, and imports changed clipboard content when the app opens or returns to the foreground.
- The Share extension stores text, URLs, and image data from other apps.
- The Keyboard extension shows a compact horizontal favorites bar and inserts text favorites directly.
- Image favorites from the Keyboard are copied to `UIPasteboard.general`; the user then pastes manually.

## Enable Keyboard on iPhone

After installing the app on a device:

```text
Settings > General > Keyboard > Keyboards > Add New Keyboard > ClipboardTresor
```

Then open the `ClipboardTresor` keyboard settings and enable:

```text
Allow Full Access
```

Full Access is required so the Keyboard extension can read the shared encrypted archive from the App Group.

## Important iOS limits

- iOS does not allow macOS-style global background clipboard monitoring.
- iOS does not allow a third-party app to add a bar above Apple's standard keyboard. The ClipboardTresor keyboard is therefore a compact custom keyboard made only of the favorites bar.
- ClipboardTresor can import copied content when the iOS app becomes active, but it cannot observe every copy while it is fully in the background.
- Custom keyboards cannot type into secure text fields.
- Some apps can block custom keyboards.
- Custom keyboards are best for frequently reused text snippets, not full rich-content insertion.

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

- The iOS app shows the encrypted archive, supports search and favorites, and can import the current clipboard on user action.
- The Share extension stores text, URLs, and image data from other apps.
- The Keyboard extension shows favorites and inserts text directly.
- Image favorites from the Keyboard are copied to `UIPasteboard.general`; the user then pastes manually.

## Important iOS limits

- iOS does not allow macOS-style global background clipboard monitoring.
- Custom keyboards cannot type into secure text fields.
- Some apps can block custom keyboards.
- Custom keyboards are best for frequently reused text snippets, not full rich-content insertion.

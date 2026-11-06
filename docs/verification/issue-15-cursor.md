# Text box cursor following

Steven's follow-up to PR #42 requires the open text box to move with the cursor after double-tapping Control. Previously, `TextBoxPanel.show` positioned it once.

`TextBoxPanel` now samples the pointer at 60 Hz on the main run loop while the box is open. It moves the existing panel without replacing its content or taking focus again. The existing display selection, screen margins, and flip above the pointer near the bottom edge apply to every position. Hiding or replacing the panel invalidates its timer; releasing the adapter does too. There is no tracking timer while closed.

## Native verification

A temporary AppKit fixture compiled the production `TextBoxPanel.swift` and `DesignSystem.swift`. Within that fixture process only, Objective-C method replacement supplied known pointer positions and suppressed `makeKeyAndOrderFront`. Its panel stayed hidden, and the owner's frontmost app was unchanged. It posted no keyboard or pointer events and made no screen capture.

The fixture with `TextBoxPanel.swift` from `69834511b33e8471eec7719eafbecf8d52f7ae63` failed the movement check. With the updated production source it passed:

- Pointer displacement moves the open window by the same amount.
- The content view, typed question, and field's first responder survive movement.
- Following continues in the event-tracking run-loop mode.
- The right and left edges stay inside the visible screen; the box flips above the pointer at the bottom edge and stays below the top edge.
- Hiding, replacing, and releasing the adapter invalidate the previous timer. Hidden windows stop moving, and the timer does not retain the adapter.
- Movement invokes neither submission nor dismissal.

One physical display, the built-in Retina display, was attached. Actual display crossing remains unverified. The fixture exercises the native panel and its actual timer, but suppresses showing and key-window acquisition, so it does not establish foreground keyboard behavior or a complete submitted turn. The unchanged text-box view was rendered directly from its native content view and inspected.

Temporary source, before/after logs, and the content render are in `/tmp/buddy-issue15-cursor-verify/` on the implementation Mac. They are local verification artifacts, not a persistent automated test suite.

## Build checks

```sh
swift test --package-path BuddyCore
# 102 tests passed.

xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-issue15-dock-ci \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test
# Three app tests passed; TEST SUCCEEDED.

xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-build-15 build
# Signed Debug build succeeded.

codesign --verify --deep --strict /tmp/buddy-build-15/Build/Products/Debug/Buddy.app
# Succeeded.
```

No Swift compiler warnings appeared. Xcode printed its existing AppIntents metadata warning and test-host system-service connection messages; all tests passed.

## Owner check

Double-tap Control, start typing, then move the pointer. The text box should follow with the question intact. Move near the screen edges, continue typing, and press Esc to close. The original question/Return/spoken-answer/pointing and click-away checks in [issue-15.md](issue-15.md#owner-checks) remain open.

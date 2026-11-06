# Text box keyboard focus

Steven reported that the text box opened after double-Control but did not accept typing without a click. This follow-up to issue 15 builds on the Dock, cursor-following, and CLIProxy changes.

## Cause and fix

`NSHostingView` had not laid out its text field when `makeKeyAndOrderFront` ran. The panel became key while its first responder was still the window. SwiftUI installed the field editor later, so an immediate keystroke was lost.

`TextBoxPanel.show` now lays out the content before making the panel key. This preserves the non-activating panel and its cursor tracking, without a timed focus retry.

## Verification

- The new app test calls the existing `TextBoxPanel.show` interface, checks that the field editor has focus immediately, sends `x` and Return only to the test process, and verifies the submitted question. It repeats after hiding and reopening. The baseline failed because the window was its own first responder. With the fix, the test passes.
- A separate native fixture began with its host inactive and the owner's app frontmost. On both first open and reopen, the baseline dropped an immediate `x` and submitted only the later `y`. The fixed production panel submitted `xy`, retained its editor during cursor tracking, hid successfully, and left the foreground application's identity unchanged.
- All 103 BuddyCore tests and all four app tests pass. The app tests require no privacy grant and send no global keyboard or pointer events.

Commands:

```sh
swift test --package-path BuddyCore
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-issue15-dock-ci \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test
```

Temporary native fixture sources and before/after logs are in `/tmp/buddy-focus-verify/` on the implementation Mac. The app regression remains in `BuddyTests/TextBoxPanelTests.swift`.

## Owner check

With another app in front, double-tap Control and type immediately without clicking. Confirm that every letter enters the box, Esc closes it, and reopening accepts typing again. The full screen question, spoken answer, and point remain separate owner checks.

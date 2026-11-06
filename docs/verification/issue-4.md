# Turn engine verification

Scope is issue 4, against the project spec.

## Acceptance mapping

| Acceptance criterion | Implementation and evidence |
| --- | --- |
| BuddyCore builds in Swift 6 strict concurrency with no AppKit, and the app links it | `BuddyCore/Package.swift` keeps `swiftLanguageModes: [.v6]`. BuddyCore imports Foundation only. `swift test` builds it with no warnings, and the app's clean `xcodebuild build` links it. |
| The engine accepts the spec's events and emits its effects; the app implements the ears, mouth, brain, screen, overlay and store ports | `BuddyEngine` adds the turn phases `held → transcribing → capturing → thinking → speaking`. Its new events are `transcriptFinished`, `screensCaptured`, `provider(ProviderEvent)`, `speechFinished`, `listeningFailed` and `captureFailed`. Its new effects are `startListening`, `stopListening`, `captureScreens`, `sendTurn`, `cancelReply`, `speak`, `stopSpeaking`, `showBuddy`, `point` and `recordTurn`. `Buddy/Ports.swift` declares the six ports. `AppleSpeechEars`, `AppleVoiceMouth`, `DisplayCapture`, `OverlayWindowManager` and `InMemoryStore` implement five of them. The brain port has no implementation yet (see Limits). |
| POINT parsing and mapping exist only in BuddyCore, and upstream's duplicate is gone | `PointTag.swift` holds upstream's regex. `ScreenCapture.displayPoint(pixelX:pixelY:)` is the one mapping function. Neither the screenshot-to-display mapping nor the POINT parser exists in `Buddy/`. Upstream's two copies, in the talk turn and the onboarding demo, were already removed with their callers in #3. |
| Tests cover POINT parsing, single and multi-display mapping with literal points, and turn transitions including interruption | `TurnTests` covers parsing in 6 cases: valid, no label, none, absent, malformed, and tag not at the end. It covers single-display mapping and clamping in 4 cases and screen numbers on two displays in 9 cases. Transition tests cover deltas split anywhere, silent turns, tag-only replies, out-of-order events, a press during thinking, speaking or waiting, Esc in each phase and while a notice shows, provider, capture and listening failures, and a late failure from an earlier turn. |
| A fake brain runs a full scripted turn with ordered effects | `fakeBrainRunsAFullScriptedTurn` asserts all ten effects in order, from `showPushToTalk` to the final `clearOverlay`. |
| Manual check: push-to-talk, the waveform and the no-provider notice behave as before | Passed against the baseline app (below). The baseline has no waveform, because #3 removed listening without a provider. The push-to-talk bubble is the only indicator, and it is unchanged. |
| Added logic is covered by Swift Testing tests through the engine's public interface | All 17 new tests drive `handle` only. The parser and the mapping function are internal. A mutation sweep broke the y-flip, clamping, screen lookup, cursor fallback, tag anchor, interrupt effects (including Esc while transcribing and while a notice shows), delta accumulation and both failure guards. Each of those 12 mutants failed at least one test. |

Commands run on macOS 26.6.2 with Xcode 26.6 and Swift 6.3.3:

```sh
swift test --package-path BuddyCore
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-build-pr clean build test
```

`swift test` passed 34 tests (17 kept and 17 new). `xcodebuild test` passed the three upstream tests.

## Native runtime checks

- **Before and after.** The signed baseline app from #3 ran from `~/Applications/Buddy.app`. A posted Control+Option press showed the buddy with "Release to finish". Release showed "No provider connected.", and the notice cleared after 4 seconds. This branch's signed build gave the same bubble, position, copy and 4-second expiry. All five permissions read Granted. No audio device was opened, and screen capture did not run.
- **Every adapter, end to end.** A throwaway local build set the brain to a scripted fake that replies `[POINT:640,413:middle]`. That build was never committed. The real ears heard speech played with `say` and returned "Where is the Wi-Fi menu?" within 46 ms of release. The real screen port captured the 2056 × 1329 display at 1280 × 827. The engine mapped the tag to (1028, 665.3), and the overlay flew the buddy there with a "middle" label. The Apple voice spoke the reply. A second press during speech emitted `stopSpeaking, showPushToTalk, startListening`, and no stale speech-finished event followed. A silent turn ended with `clearOverlay`.

## Limits

- The brain port has no implementation. A provider arrives in #5, so the app keeps its no-provider behavior.
- The engine covers the turn's events and effects. The ears report only the final transcript. Transcript updates, usage and limit events, clock ticks, speech progress and owner answers arrive with the tickets that use them. So do the effects for annotations, typing, dictation, agent runs and owner questions.
- Upstream labeled each screenshot for the provider. A label said which screen the image showed, whether the cursor was on it, and the image's pixel size. Those labels had no consumer here, so they were removed. #5 must label the captures in their `TurnRequest` order, flag the cursor's display, and give each image's pixel size. That keeps a tag's `screenN` and pixels pointing where the engine maps them.
- The overlay holds a point until speech ends. Its bubble shows the tag's label. Returning to the cursor is #6.
- A reply that is only a tag ends the turn without pointing, because nothing is spoken.
- The first real screen capture made macOS 26 ask whether Buddy may bypass the private window picker. The capture still succeeded. The prompt was left for the owner. #5 will meet it on the first real turn.
- Clean `xcodebuild build test` runs on this branch printed two "Failed to parse executable" warnings for `XCTestCore` and `Testing`. They come from `CopySwiftLibs` scanning `Buddy.app/Contents/Frameworks` while the test-host copy of those frameworks is in progress. The partial sizes it read changed between runs. One clean run on `main` did not print them. Incremental runs did not print them. There were no Swift warnings.

## Merge and rollback

This is a two-way door. No provider is connected, so the owner-visible behavior is the baseline's. Reverting the commit restores the previous engine and app.

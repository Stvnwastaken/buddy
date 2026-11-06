# Issue 61 verification

Past conversations extend the accepted notch at
`b12cc1678e167501d1038de79f161d838a981ba0`.

## Owner acceptance

Steven installed the earlier signed artifact for
`baa5fcdd353d54ac64ace407aea73add1b6c77cf`. He reported that reopening and deletion
worked, but Buddy quit completely when he clicked the reopened text box, before
typing. The contextual follow-up **did not pass**. Owner61 remains **pending and
not waived**. The replacement artifact below has not been installed or launched.
Issue21's owner voice gate remains separate; issue22 stays blocked.

## Automated live qualification, 2026-11-04

The remaining owner acceptance item stays pending. This batch verifies a real
Claude answer through the engine and through the signed native notch harness;
it does not claim an owner action or normal app startup. No product defect was
found. Only opt-in tests and evidence changed.

### Real-provider engine check

```sh
BUDDY_LIVE_CLAUDE=1 swift test --package-path BuddyCore --filter liveClaudeReopensItsOwnContextAndDeletesAnotherConversation
```

Passed one test in one suite in 7.137 seconds. Three talk turns and two utility
summary turns used the owner's direct Claude sign-in. A established Copper
Finch; B established the conflicting Azure Heron. Reopening A reset the provider,
primed A's summary and returned **“You named it Copper Finch.”** B had a real
summary before deletion. Deleting B saved a private temporary JSON history;
reloading it found only A, with neither B's turns nor summary text. The next
request after reload carried A's summary/recent turn and no B context. That
last request was inspected without spending another provider turn.

The first trial got the right answer and deleted B, but failed four fixture
assertions that mistakenly expected an already-active reloaded conversation in
`earlierSummaries` rather than `summary`/`recentTurns`. Corrected expectations
passed; this was not a product failure. The final
[engine receipt](issue-61/live-engine-result.txt) records the passing run.

### Signed native check

```sh
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-build build
BUDDY_NOTCH_EVIDENCE=/tmp/issue61-live-native-final TEST_RUNNER_BUDDY_NOTCH_EVIDENCE=/tmp/issue61-live-native-final BUDDY_NOTCH_LIVE_CLAUDE=1 TEST_RUNNER_BUDDY_NOTCH_LIVE_CLAUDE=1 xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-build '-only-testing:BuddyTests/NotchPanelTests/ownedHistoryControlsRenderScrollContinueDeleteAndClear()' test
codesign --verify --deep --strict /tmp/buddy-build/Build/Products/Debug/Buddy.app
```

The build and signed test passed. The selector needs the trailing `()`; an
initial selector without it selected zero tests and is not accepted as evidence.
The final run selected and passed one Swift Testing test. The signed app ran as
an XCTest host, using the same `dev.steven.buddy` Apple Development identity.
XCTest suppresses normal manager startup. The harness owns its window, engine
and `HistoryStore`, and sends native history/open/delete control presses. It
inserts the follow-up into the native field editor and sends native Return.
The submitted request's summary and recent turns reach a fresh real Claude
process, which answered [“Gold.”](issue-61/live-provider-answer.txt).

The fixture's yesterday is relative to its fixed clock, November 14, 2023.
Its initial turns/summaries are seeded; the engine test above establishes its
facts with real turns. The synthetic screenshot bytes are removed before the
live provider request, so no display capture or privacy permission is needed.
The pre-existing injected search cue remains a separate progress assertion;
“Let me look that up.” in the screenshot is not evidence of a real web search.
Provider events are collected through completion before replay into the engine,
so this proves contextual correctness, not real-time streaming latency.

Native deletion removed the spare Silver Fern conversation and its summary
from the private store. New conversation, empty-history clearing and both ends
of the long thread also passed. These are owned-view bitmaps, not whole-display
screenshots. The final views were inspected:

- [History](issue-61/live-history-list.png).
- [Reopened thread](issue-61/live-reopened-thread.png).
- [Real follow-up](issue-61/live-continued-thread.png).
- [After deletion](issue-61/live-after-delete.png).

The [native receipt](issue-61/live-native-result.txt) records control presses and
scroll measurements. All test-owned windows and the signed host exited. No
permission prompt blocked this harness. Owner history was never modified;
existence and SHA256 before/after matched, so no backup restoration was needed.
No owner history content or digest is published.
The [input receipt](issue-61/live-inputs.json) pins the tested source files and
signed executable by SHA256.

### Required gates and limits

```sh
swift test --package-path BuddyCore
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-ci CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test
```

Full BuddyCore passed 551 tests in 50 suites, with opt-in live tests skipped.
Full unsigned app passed 56 tests in 20 suites, with opt-in rendering tests
skipped. The signed live check above supplies the focused opt-in rendering and
provider evidence. CI never enables either live flag.

Still unverified by design: normal app startup with the owner's selected talk
configuration, actual push-to-talk/audio and an owner-performed contextual
follow-up. The literal “by the owner” criterion cannot be completed by an agent.
Steven can reopen an actual prior conversation in the normally launched signed
app, type a contextual follow-up, verify its answer and delete a disposable
conversation. No issue checkbox, label or closure is changed by this batch.

## Current behavior and acceptance mapping

The thread and history share a labeled action row. Past conversations and Back
are on the left; a prominent New conversation button starts a fresh thread with
the native field focused. History cards show the first question, timestamp and
open chevron, with a separate destructive delete control. The 460-point viewport,
thread scrolling, native input geometry and existing shortcuts are preserved.

| Requirement | Implementation | Evidence |
| --- | --- | --- |
| Newest first, first question/time, back to current thread | `NotchConversation.Page` and history cards | Literal core regression; current signed native list/back presses and owned-view bitmaps. |
| Reopen the whole conversation | `conversationOpened`, durable history IDs | Literal core full-thread regression; current native open and first/latest long-thread scroll. |
| Continue the selected conversation with its own context | Reopen resets provider and primes own summary/recent turns | Typed and push-to-talk core regressions; current native click/editor/`x`/Return and injected `TurnRequest` equality. Real owner contextual correctness remains pending. |
| Delete turns/summary on disk and exclude future context | Durable IDs, summary cancellation, provider reset, `saveHistory` | Late completion regressions; current full unsigned actual owned `HistoryStore` deletion/reload/context and signed native deletion. |
| Clear history empties everything | Existing settings effect and store guard | Core clear/late callback regressions; current owned store clear/reload/unreadable-file tests. |
| New conversation is ready for typing | Visible New button starts a new typing turn | Current signed native New press asserts empty thread, key window and native field editor. |
| Owner reopens yesterday's conversation, gets a correct contextual answer and deletes another | Owner action required | Reopen/delete owner-reported pass on the earlier app. Contextual follow-up not passed; no waiver. |

## Reproduced first-click failure and repair

The bounded first-click batch ran from 08:10:15 to 08:19:46 UTC on 2026-11-03.
Its original selector exited zero but selected no tests. That result is invalid
as reproduction evidence. The corrected selector ran the regression and exited
65; the owned host crashed with signal `segv` during the critical mouse click.
A diagnostic rerun also exited 65 and captured the nested native stack:

```text
owned window mouse-down
  NotchInput.becomeFirstResponder
    engine textBoxFocused -> showTextBox
      NotchPanel.focusTextBox -> NSWindow._realMakeFirstResponder
        NotchInput.becomeFirstResponder -> repeat
```

End-editing callbacks between focus callbacks cleared the engine's focus state,
so its repeated-focus guard could not end this native recursion. No independent
stack for Steven's original process was available; the isolated trigger and
mechanism match his report without proving that process's exact stack.

The adapter now skips programmatic focus while the same field is already
becoming first responder. The first guarded attempt removed recursion but blocked
because native mouse tracking awaited mouse-up behind the synchronous mouse-down.
Only that test-owned host was terminated. It is an agent-interrupted fixture run,
not a spontaneous post-fix crash. Queuing the owned-window mouse-up before
sending mouse-down corrected the fixture. It does not pre-focus the critical
click, bypass first-mouse handling or replace it with an engine event.

The focused regression then passed one test in one suite, and the two existing
native field tests passed once in one suite, all without skips. Those focused
results precede the UI revision. Their seven complete command receipts, failures,
xcresults, diagnostic export and source/helper inventories remain under
`/tmp/buddy-frontier-issue-61/typing-first-click-*`.

## Current repaired UI qualification

The approved batch ran from 08:32:49 to 08:34:47 UTC on 2026-11-03. No source or
fixture correction was needed during this batch. Every command exited zero and
retained equal complete 294-input and three-helper before/after inventories.

| Gate | Result |
| --- | --- |
| Full BuddyCore | Historical 543 tests / 49 suites, including 9 opt-in skips. All 116 current core/voice/project/CI inputs equal that gate's source bytes; no native-only rerun. |
| Required full unsigned app | 53 tests / 20 suites, including 5 opt-in skips. |
| Signed `NotchPanelTests` | 4 tests / 1 suite, no skips. |
| App-only signed build | Exit 0; no normal app launch. |
| Strict artifact verification | Exit 0; stable bundle/team, Apple Development signature, no XCTest bundles, all 15 file hashes recorded. |

The unsigned skips are the owned render fixture, live pen-sound clock, live
shortcut settings, handwritten rendering and saved pen-sound switch rendering.
All real provider, capture, privacy, microphone, audio and global-input opt-ins
were absent. Only the signed run set `BUDDY_NOTCH_EVIDENCE` and
`TEST_RUNNER_BUDDY_NOTCH_EVIDENCE`, both to the task-owned `evidence-ui-1` path.
The exact environment clearing and command arrays are saved in
`/tmp/buddy-frontier-issue-61/owner-repair-ui-test-request.json`.

```sh
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-frontier-issue-61/ci CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test
BUDDY_NOTCH_EVIDENCE=/tmp/buddy-frontier-issue-61/repair-signed/evidence-ui-1 TEST_RUNNER_BUDDY_NOTCH_EVIDENCE=/tmp/buddy-frontier-issue-61/repair-signed/evidence-ui-1 xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-frontier-issue-61/repair-signed COMPILER_INDEX_STORE_ENABLE=NO -only-testing:BuddyTests/NotchPanelTests test
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-frontier-issue-61/owner-app-repair COMPILER_INDEX_STORE_ENABLE=NO build
python3 /tmp/buddy-frontier-issue-61/verify-owner-artifact.py /tmp/buddy-frontier-issue-61/owner-app-repair/Build/Products/Debug/Buddy.app
```

Commands ran through `record-command.py` and the shared `test_lane.py` guard.
The complete results, source manifest, native checkpoints, render digests and
artifact inventory are in `owner-repair-ui-batch-result.json`. Publication adds
exact-head hosted CI and independent committed reviews separately.

## Current owned-view renders

All eight settled bitmaps were inspected during the lease. They show labeled
navigation and distinct delete controls, the continued `x`/`Gold.` exchange,
the deleted fern absent, a caret in the new conversation, the empty list and
legible first/latest long-thread endpoints. They are 500-by-560 owned NSView
bitmaps containing the 460-point conversation viewport, not display captures.
The diagnostic ninth image is excluded from final evidence. The files below are
byte-for-byte copies of `repair-signed/evidence-ui-1`.

| Owned-view state | SHA256 |
| --- | --- |
| [history-list](issue-61/history-list.png) | `634eba13576f71eb1b7472e60d8d2c790ed9dffd9725e1c7222e1237aa5979f2` |
| [reopened-thread](issue-61/reopened-thread.png) | `d134df865fe8f7f0ebeaa32bf1a3ff31df33e21f23e23122619134af83e51633` |
| [continued-thread](issue-61/continued-thread.png) | `c89d00455e9104a8ec517df90d058b9ea1534cbe85abf70590039acab6168566` |
| [after-delete](issue-61/after-delete.png) | `cc0d7d2e01c28b1eef658fe0408d598d355dc88de355c29f5332e84f28484245` |
| [new-conversation](issue-61/new-conversation.png) | `8f1eae4885acead5b0c37101fed7383a326c077c8ecd355fa5bf3ee39377634c` |
| [empty-history](issue-61/empty-history.png) | `a7870eb7b3fd035b3b30238d696454bac6916c3af1cf5028d4cc3cd81e7fee78` |
| [long-thread-first](issue-61/long-thread-first.png) | `2276c007f3e674344f8f7c50b779a4d8c8a6d27d50491de4207a2d65c4fc0c62` |
| [long-thread-latest](issue-61/long-thread-latest.png) | `70841b731ef980abc4c17137a903397cf8968f89da98bcf6bc26fa90126cb9cf` |

## Replacement artifact and source attribution

The current app-only signed artifact is
`/tmp/buddy-frontier-issue-61/owner-app-repair/Build/Products/Debug/Buddy.app`.
Its bundle ID is `dev.steven.buddy`; the configured Apple Development identity
and team are unchanged. Strict codesign passed, no XCTest bundles are present,
and all 15 file digests are in `owner-artifact-repair.json`.

The artifact was built from the recorded **pending repaired/UI source manifest**.
`baa5fcdd` was the starting HEAD, not proof that its committed feature bytes alone
built this artifact. The app and test source hashes at qualification were:

- `Buddy/NotchPanel.swift`: `3fe3a2c607c444fecbf524a81d71d46ceea1c3606cc4ddaa697b509dc1eeeae6`.
- `BuddyTests/NotchPanelTests.swift`: `97686e430379e19ef423b86a87d17de4cbaed45a354198acaecfbf47364d3a58`.

Only evidence documentation and the promoted PNGs changed after that batch.
Product, package, project and configuration bytes must match the final committed
inputs; publication records that comparison separately. The prior 15-file
artifact manifest remains preserved as `owner-artifact-baa5fcdd.json`.
The installed earlier app is unchanged. Normal startup, a real provider/spoken
turn and the repaired owner contextual check have not been performed.

## Persistence and migration

History stays text only. Each conversation stores a stable integer `id`, and
history stores `nextConversationID` so deletion and relaunch cannot reuse an old
selection. Files without these fields receive IDs in stored order. Reopening
moves a record to the active end while retaining its ID. Summary requests use IDs
instead of mutable array positions. Deleting a summary target cancels its request
and rejects late results; other summaries follow their original records through
moves and deletions. The unreadable-file guard remains. Duplicate or exhausted
identifiers fail loading and preserve the file until explicit clearing. No screen
capture enters the Codable history model.

## Historical evidence retained

The first core-only batch (04:35:31 to 04:41:38 UTC) preserved genuine list,
reopen and deletion reds, an intermediate reopen fixture expectation failure,
eight focused passes and 50 affected compatibility passes across four suites.
The later full core gate passed 543/49; the first unsigned app gate passed 51/20.

The original signed-control batch (04:59:23 to 05:06:30 UTC) retained two exit-65
control-discovery failures. Lack of assistive-client exposure was an inference,
not a permission finding. The owned native rectangle helper repaired discovery
without replacing control presses or weakening semantic assertions. Earlier
incomplete/fade captures remain under `signed/evidence-3`; the old eight settled
captures remain under `signed/evidence-4` and in commit `baa5fcdd`. They are
historical stages, not the current UI evidence. The earlier full unsigned52/20,
signed3/1, app-only build/signature and hosted CI run41582628126 qualify that older
head only, subject to the concrete unchanged-input continuity above.

## Fixture boundaries

`NotchPanel(observesEnvironment: false)` disables environment enumeration, pointer
timers and workspace observation. Histories use a task-owned URL. Controls and
native text input receive only events addressed to their owned test window.
The fixture uses injected captures/provider effects and isolated store effects;
it does not call a real provider, capture a display, request consent, post global
input or access owner history/settings/audio/clipboard. All test-owned hosts and
windows ended before release; no owner process was stopped.

# Configurable shortcuts verification

Issue #20. Starting main and worktree head were `76d26de7a65d1bb8a1cc9f87e37b14f0443b092c`.

## Acceptance map

| Criterion | Code | Actual evidence |
| --- | --- | --- |
| Active talk/text-box settings, each held or double modifier, existing defaults | `ShortcutSettingsView`, `CompanionPanelView`, `Shortcuts` | Core defaults/both-kind tests pass. Signed actual settings panel rendered and inspected at 380-point width. Default, rebound and conflict artifacts below. |
| Reject conflicts with a message; persist across launches | `Shortcuts.conflict`, `BuddyEngine.shortcutChosen`, manager `shortcutsV1` | Literal core conflict/restore tests, real-manager persistence app test, and signed rendered conflict/payload/new-manager check all pass. Invalid/corrupt saved choices restore defaults with explanation. |
| Held/double matching and conflict tests | `ShortcutTests`, `TextBoxTests` | Actual red/green sequences below; post-integration full core passes 513 tests/46 suites. |
| Rebinding talk takes effect without relaunch | Settings Apply -> engine matcher -> existing manager | Signed actual controls changed Talk from Control+Option to Option+Shift. Direct native CGEvents through the real monitor/manager: old combo starts 0, new combo starts 1, separate modifier release stops 1. No relaunch between old/new input. |
| New logic tested with Swift Testing at public engine seam and literals | `ShortcutTests` calls `BuddyEngine.handle` | Literal effects/state/JSON cover both slots/kinds, equal/held subset/superset conflicts, invalid choices/restoration, rebind release, extra input, Esc, permission loss and secure input. |

Scope ruling is part of this map: cancelled dictation/hands-free slots are excluded under the linked owner decisions below; no placeholder controls/actions or invented default were added.

## Scope evidence

The active defaults are talk as Control + Option and text box as double-tapped Control.

Issues #17 and #19 were closed as not planned on November 2, with owner comments saying dictation is no longer needed. The coordinator explicitly ruled that those cancellations supersede stale dictation references in #20 and #1. Only talk and text box are active slots. No dead controls or unavailable actions will be exposed. The first acceptance criterion and obsolete #19 dependency in the live issue were amended and read back; the native dependency list now contains only #15.

## Design

The engine receives modifier snapshots through its existing public `handle` seam. A typed slot selects talk or text box. Each trigger is a held modifier set or a double-tap of one modifier. Settings offer explicit modifier choices and an Apply button, so editing a draft never runs a global capture session. The existing `DoubleTap` timing remains the detector for double modifiers. Talk double-taps start listening and a later pair sends; held text-box shortcuts open the box and leave it open when released.

Matching in the macOS event tap was considered and rejected because it would split shortcut timing and conflict rules across targets. Matching in BuddyCore concentrates those rules behind public input/configuration events and keeps semantic actions independent of the text box destination.

The throughput checkpoint is one owner for the coupled engine, event adapter and settings changes, followed by fresh read-only Standards and Spec reviewers. Source editing is independent of other issue worktrees. Executable checks share the coordinator's test permit and exclusive lane. The first held-combo regression is written before its implementation.

Shortcut matching belongs in BuddyCore. The macOS event tap should forward physical input and Esc, without deciding the shortcut or text box destination. The engine should retain semantic talk and text box actions so issue #60 can change the destination independently.

## Execution record

The first lane request returned exit 75 because issue #60 held the lease. After the coordinator granted #20 the lane, a bounded BuddyCore TDD batch ran on November 2. The lease was released at `2026-11-03T01:48:09Z`. No manager-based app tests, apps or helpers ran. No owner settings or running apps were changed.

Every command ran through the shared guard:

```sh
python3 ~/.codex-t3/orchestrate/heyclickyclone-frontier-2026-11-02/test_lane.py run --issue 20 --thread issue-20 -- \
  swift test --package-path BuddyCore --scratch-path /tmp/buddy-frontier-issue-20/core --filter ShortcutTests
```

| Slice | Red exit | Green exit | Logs in `/tmp/buddy-frontier-issue-20/` |
| --- | --- | --- | --- |
| Default held talk | 1, four literal expectation failures | 0, one test | `held-red.log`, `held-green.log` |
| Rebinding and saved restoration | 1, new public API not implemented | 0, two tests | `rebind-red.log`, `rebind-green.log` |
| Conflict rejection without saving | 1, four expectation failures | 0, three tests | `conflict-red.log`, `conflict-green.log` |
| Both trigger kinds for either active slot | 1, six expectation failures | 0, four tests | `kinds-red.log`, `kinds-green.log` |

The next granted core batch observed all six prepared review-edge regressions fail before repair: exit 1 with 30 expectation failures in `edges-red.log`. After repair, the ten shortcut tests passed with exit 0 in `edges-green.log`. Permission loss and other input during a hold then failed with seven expectations (`input-red.log`) before passing with exit 0. Secure input's double-tap suppression failed with two expectations (`secure-red.log`) before passing with exit 0. The final combined shortcut/text-box run passed 24 tests in two suites (`secure-green.log`).

The required `swift test --package-path BuddyCore` command passed 491 tests in 45 suites, exit 0, in `core-full.log`. SHA256 manifests of all core source/tests were identical before and after the gate (`core-source-before.json`, `core-source-after.json`). No sources changed during any active command. The lane was released at `2026-11-03T02:44:14Z`, with no helpers running and no owner settings/input/audio/provider/clipboard changes.

This is intermediate evidence on the working tree before integrating new main, not verification of a final PR head. App/CI gates and signed functional/UI evidence are still pending.

The coordinator restricted manager-based app tests and live probes until #60's reviewed screenshot-folder isolation fix reached this branch. Baseline `CompanionManager.emptyCodexScreenshotFolder()` deleted a shared temporary directory on initialization, so even ordinary manager-based tests could remove the owner's in-flight screenshots. On clearance, the exact four-file patch from `982ac3d53c29a7cbca15c5fffe05d221081cece7` was applied over the pending shortcut changes and committed as `95210a0d9353df3b47d9383aec894db350777713`. All four staged files were byte-compared against the reviewed source commit before committing. No shortcut hunks were included. The later app gate must confirm its two isolation regressions on this branch. Integration does not grant testing time.

## Intermediate independent review

Fresh read-only Standards and Spec reviewers inspected all pending tracked and untracked contents. Both identified rebinding during an active hold losing its release state, and subset/superset held shortcuts passing conflict detection. Standards also identified an extra modifier being treated as a send, while Spec identified Esc failing to spoil pending double-taps. Restoration validation was also noted. All of these defects were observed in the permitted red run, repaired and checked green.

A second fresh precommit review completed on both axes. Each independently found one P2 blocker: after Control + Option starts Talk, releasing Option and then Control leaves the double-Control detector spoiled. The first fresh double-Control is then ignored. `theFirstDoubleTapAfterFullyReleasingTalkOpensTheTextBox` is prepared at the public engine seam, and observed exit 1 with two literal expectation failures in `release-red.log` under the next explicit core permit. The minimal repair forwards waiting-for-release snapshots to the detectors as spoiled input, including the final empty release. The regression then passed (exit 0, `release-green.log`), followed by 25 shortcut/text-box tests in two suites (exit 0, `release-suites-green.log`). Product/test SHA256 manifests were recorded around the batch; red-run manifests were identical and the only implementation change was the detector-release repair. Neither reviewer edited files or ran tests, builds or apps. No additional Standards or Spec blockers were reported in that review. After the observed repair, another fresh intended-worktree review completed on both axes with zero remaining source blockers; those reviewers ran no executable checks.

## Integration and remaining gates

The reviewed shortcut implementation was committed as `ca0645d999f2cc9f584d4ea1c95c9553d16f934a`. Main `c093439ec6849e81f7f59e54c7203cadb010e6d2` (PR #74 pen sounds) was merged by preserving both additive manager/engine settings and effects. A fresh fetch then found PR #75, and main `a2a0863832a3f0682d01d446025ed6b1807ca1b3` (handwriting/paper cards) was merged cleanly. Integration head is `fef91c9d84b1e3cf60d9d4004877e06682a730a7`. The shared screenshot isolation patch remains present. The full core result above predates this integration and the new regression. Before/after product/test/probe manifests must accompany the next affected gate.

The core lane was released after the completed batch. No new acquisition or executable check is authorized until the coordinator explicitly grants issue #20 another batch. A later explicit permit authorized the completed integration/app/signed batch below. No owner settings, clipboard, audio, providers or picker consent dialog were changed by this thread.

## Post-integration required gates and signed evidence

The explicit post-integration permit was acquired at `2026-11-03T03:26:19Z` and released at `2026-11-03T03:30:47Z`. Source includes the integration head above plus the optional inert `Ears` dependency, internal event adapter callback and `ShortcutFunctionalTests`. All executable commands used the shared lane guard. Product source did not change during any active command. Final commit identity is bound by the unchanged manifests listed below; later changes are evidence/docs only.

| Check | Actual result | Local evidence under `/tmp/buddy-frontier-issue-20/` |
| --- | --- | --- |
| Full BuddyCore, `swift test --package-path BuddyCore --scratch-path /tmp/buddy-frontier-issue-20/core` | Exit 0, 513 tests / 46 suites | `integration-core.log` |
| Required unsigned Xcode command below | Exit 0, 47 tests / 18 suites | `integration-xcode.log` |
| Both shared screenshot-isolation regressions | Both pass inside unsigned gate | `constructingASecondManagerPreservesAnExistingScreenshot`, `managersKeepEachOthersScreenshotsAndRemoveOnlyTheirOwnDirectory` |
| Real-manager defaults persistence/rejection | Pass inside unsigned gate | `acceptedShortcutsPersistAcrossManagersAndRejectedChoicesDoNotReplaceThem` |
| Initial signed accessibility traversal attempts | Exit 65 twice: test helper cannot find SwiftUI AX children; panel renders correctly | `signed-shortcuts.log`, `signed-shortcuts-repair.log` |
| Signed actual control/native adapter check after helper repair | Exit 0, one opt-in functional test | `signed-shortcuts-local.log` |
| Required unsigned Xcode after test-helper change | Exit 0, 47 tests / 18 suites | `integration-xcode-final.log` |
| Signed `test-without-building` product provenance | Exit 0, same functional test and identical product/test binary hashes | `signed-provenance-check.log`, `signed-product-before.json`, `signed-product-after.json` |

```sh
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-frontier-issue-20/ci \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test
```

The signed command uses `/tmp/buddy-frontier-issue-20/signed`, the stable `dev.steven.buddy` identifier and configured Apple Development identity, `COMPILER_INDEX_STORE_ENABLE=NO`, `-only-testing:BuddyTests/ShortcutFunctionalTests`, and `BUDDY_LIVE_SHORTCUTS=1 TEST_RUNNER_BUDDY_LIVE_SHORTCUTS=1`. `signed-provenance.txt` records the identity; no signing configuration changed.

SwiftUI withheld the AX child tree with no assistive client attached. The helper therefore sent `NSEvent` mouse down/up directly to the test's owned nonactivating panel at the inspected controls, without posting global input. Actual Control/Shift toggle and Apply interactions saved the literal payload:

```json
{"talk":{"kind":"held","modifiers":6},"textBox":{"kind":"doubleTap","modifiers":1}}
```

The existing manager immediately ignored Control+Option and started once for Option+Shift. Releasing Shift and then Option stopped once. Injected inert ears returned an empty transcript, preventing microphone/capture/provider use. A conflicting held-Control assignment kept the saved payload and rendered the explanation. A new manager restored both slots. The frontmost process stayed unchanged throughout the owned-panel interaction. No tap was installed and no global CGEvents were posted: this proves native adapter delivery and immediate runtime rebinding, **not owner-wide physical event-tap delivery**. No microphone, screen capture, privacy consent, account, clipboard or audio changes were made. Own hosts ended; the installed owner Buddy was left running and untouched. Picker visibility remained unknown and was left untouched.

All tracked and new intended source/test/config files were hashed before and after batches: `integration-before.json`, `integration-core-after.json`, `integration-unsigned-after.json`; signed helper revisions have separate before/after manifests (`signed-repair-*`, `signed-local-*`). Final product/test source hashes are in `final-source-after.json`. The final signed test-without-building recorded identical entire Debug product and test-bundle hashes before/after. Core files did not change after the full core pass; the only test edit required the successful incremental unsigned and signed checks above.

Rendered artifacts were inspected directly:

- [Defaults](issue-20-defaults.png)
- [Rebound Talk](issue-20-rebound.png)
- [Conflict explanation](issue-20-conflict.png)

Hosted CI and exact-head committed Standards/Spec reviews remain pending publication. No merge slot has been granted.

## Final run-fallback integration (pending re-verification)

After PR #77 was initially verified at `6c05a88844f89efc2bee935373d20a6e59bf8612`, the coordinator relayed main `40f8f76830dc45987ed8577d7f15e8f1cb4a486b` (PR #76). It was fetched and merged with `--no-commit --no-ff` for intended-worktree review. The merge applied cleanly. All upstream changes remain: Auto run-provider selection, pause/resume effects and host APIs, generation/token stale-callback guards, retained asks/caps/consent, paper cards, handwriting, pen sounds and screenshot isolation. The shortcut matcher/config/editor, injected inert ears and native-adapter check remain intact.

The earlier local results and hosted CI/reviews are historical for this affected integration. A later explicit permit is required before rerunning full BuddyCore and the prescribed unsigned app gate (including run host, isolation and shortcut persistence), plus the scoped signed shortcut check because the real engine/manager path changed. No executable test or lane acquisition occurred while integrating or reviewing. Fresh committed Standards/Spec reviews and exact-head hosted CI are required on the new PR head. The nonblocking permission-recovery P3 remains source-only and unchanged.

# Handwriting and paper verification

Scope is issue 32, initially on baseline `76d26de7a65d1bb8a1cc9f87e37b14f0443b092c`. Integration now includes PR #74's main `c093439ec6849e81f7f59e54c7203cadb010e6d2`. The completed local checks below precede that integration. Pending checks are not passes.

| Criterion | Code | Actual evidence |
| --- | --- | --- |
| Handwriting, sticky notes, cards follow the draw API | `DrawMark`, `DrawSandbox`, `TalkInstructions`, `docs/draw-programs.md` | Focused `DrawProgramTests` passed, including literal mapped marks and cursor display with a negative origin. |
| Patrick Hand from Google Fonts with OFL | `BuddyCore/Sources/BuddyCore/Draw/Resources/PatrickHand/` and package resources | Official google/fonts bytes and retained licence verified independently. Signed `bundledHandwritingUsesPatrickHand` passed with literal PostScript name `PatrickHand-Regular`. |
| Close, drag, next-turn clearing unless pinned | Engine paper events/state, `DrawPaperPanel`, overlay adapter | Engine lifecycle tests passed. Signed native tests exercise actual card and sticky buttons/header events and the engine-to-overlay pin, close and next-turn workflow. |
| Recorded marks for every new piece | `DrawProgramTests` | Handwriting and paper API tests failed with missing-function errors, exit 1, before their implementation. Both passed afterward, exit 0. |
| Rendered handwritten explanation screenshot in PR | Native paper renderer | Signed `renderHandwrittenExplanation` showed a real panel, waited for its animation, and rendered its own view to PNG. [Actual rendered card](issue-32-handwritten-card.png), visually inspected with complete text. |
| Added logic tested at public engine seam with literal expectations | `BuddyEngine.handle` tests in `DrawProgramTests` | Focused suite passed 31 tests. Full BuddyCore gate passed 487 tests in 44 suites, exit 0. |

## Testing lane

Initial acquire returned exit 75 with issue #60 holding the lane. The coordinator granted a focused BuddyCore batch after #33. It completed and the lease was released at `2026-11-03T01:39:24Z`. No provider, app launch, screen or input operation ran. No owner settings, clipboard or audio changed.

The guarded focused runs were handwriting red (exit 1), handwriting green (exit 0), paper red (exit 1), recording/lifecycle green (exit 0), measurement red (exit 1), and final `swift test --package-path BuddyCore --filter DrawProgramTests` (31 tests, exit 0). Logs are in `/tmp/buddy-frontier-issue-32/`, ending with `focused-core-final.log`. Shared-duration expectations are literal `[0.25, 1.2, 0.9, 0.54]`. The focused suite also covers invalid arguments, the shared mark limit, nonfinite and stale owner actions, next-turn pin preservation, Esc, and Clear History.

The coordinator identified baseline `CompanionManager.emptyCodexScreenshotFolder()` as deleting a shared temporary directory during initialization. The exact reviewed #60 fix `982ac3d53c29a7cbca15c5fffe05d221081cece7` is integrated by provenance-preserving cherry-pick `9b6d47d`. It adds a manager-owned UUID screenshot directory and its two isolation regressions. The cherry-pick merged cleanly with #32's paper event callback; the helper and regression files match the source commit byte for byte. The later granted app gate must run those regressions too. This integration clears the code isolation blocker, but does not grant a testing slot.

Required final gates, each executed through `test_lane.py run --issue 32 --thread issue-32 --`:

```sh
swift test --package-path BuddyCore
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-frontier-issue-32/ci \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test
```

## Full and signed verification

Before this batch, `git fetch origin` and `git merge --no-edit origin/main` confirmed base `76d26de7a65d1bb8a1cc9f87e37b14f0443b092c`. The #60 helper and isolation test files matched the reviewed source commit exactly. Every executable command ran through the granted lane's run guard.

- `swift test --package-path BuddyCore` passed 487 tests in 44 suites, exit 0. Log `full-core.log`.
- The required unsigned `xcodebuild test` command above first failed, exit 65. The legacy-scrollbar regression needed 810 points for its label, but attributed-string measurement allocated 764. The renderer now measures the actual wrapping label cell at the configured scroll view's content width. The same full unsigned gate passed 40 tests in 14 suites, exit 0. Logs `unsigned-app.log` and `unsigned-app-fixed.log`.
- Signed native checks used the same scheme and destination, `/tmp/buddy-frontier-issue-32/signed`, normal Apple Development signing, and `-only-testing:BuddyTests/DrawPaperPanelTests -only-testing:BuddyTests/CodexScreenshotIsolationTests`. `TEST_RUNNER_BUDDY_DRAW_EVIDENCE=/tmp/buddy-frontier-issue-32/evidence` enabled the opt-in image test. The final run passed 8 tests in 2 suites, exit 0. Log `signed-native-verified.log`.
- The signed tests verified actual Patrick Hand loading; both paper kinds' close, pin and drag actions; captured-display placement despite out-of-canvas coordinates; reachable legacy-scrollbar overflow; and engine-to-overlay pin persistence and independent close controls. Both imported screenshot-isolation regressions passed in unsigned and signed runs.

The final signed run's runtime source tree SHA-256 was `e315b05f068c88bd90986e234752d00cf56c09124b4bc6fa5b3d6ce69bbb9cad`. The test source tree SHA-256 was `425ca6b68a4c0f2f76caf8e928a2c3e2e94de7390de128c213ee5cd6c5776754`. Both before/after manifests matched. They cover tracked app/core/project and test files, with each file hashed and the sorted JSON map hashed. Manifests are `final-native-source-before.json` and `final-native-source-after.json` under `/tmp/buddy-frontier-issue-32/`.

The PNG is an actual native panel view render, with no screen capture, DisplayCapture call, provider request, microphone, audio, pasteboard or global mouse/keyboard event. Tests target only their own windows and views, and close them afterward. No owner preference or history changes were made. The existing Buddy picker dialog's state was **unknown**; no owner windows or consent dialogs were inspected or driven. A front-app bookkeeping command failed because its executable path was absent; no follow-up privacy check or focus manipulation was attempted. Own app test hosts had exited before the lease was released at `2026-11-03T02:36:10Z`.

The full unsigned run preceded the additional native engine/overlay test and explicit control tint. Those final source bytes passed the signed checks above; exact-head CI must qualify the final full core and unsigned gates. PR #74's #33 timing/audio changes were not yet on main during this batch. This evidence is pre-integration; affected checks must be refreshed after merging its updated main.

## Timing compatibility

The `.draw([DrawMark<DisplayPoint>], on: DisplayRect)` effect stays intact. New marks use `DrawMark<DisplayPoint>.revealDuration`, the source shared with #33. The integrated manager gives native reveals and #33's audio the same host-clock start. Handwriting uses the existing pen-scratch scheduler; paper placement and ordinary text stay silent. Every mark advances subsequent cue offsets. No new audio generator or preference is introduced by #32.

PR #74 was merged into this branch by intent across the shared mark model, glyph paths, overlay and manager. The public-engine mixed-mark regression expects literal cues `[offset: 0, duration: 0.25]` for handwriting and `[offset: 1.15, duration: 0.5]` for the stroke after a silent 0.9-second card. Added regressions cover simultaneous short scratches with Reduce Motion and cancellation when pen sounds are disabled. Existing #33 coverage remains intact. A native regression checks the same host-clock offsets for handwriting, paper and stroke, plus immediate presentation without animation.

No local integration regressions have run while another issue holds the testing lane. Independent committed Standards and Spec reviews of `5171bcd` found zero blockers. Exact-head CI and an explicitly granted affected core/app/signed batch remain required for the correction below. Pre-integration test results and the rendered image above are retained with their original source hashes.

Hosted CI run 41568493388 tested integrated head `5171bcdc2c8f923ec615a974ad1a29c85473d8f8`. BuddyCore passed 498 tests in 45 suites. The app compiled, then its 45-test run failed with exit 65 on exactly two cases of the new native mixed-mark test. Both cases reached the final clear assertion after their real-layer and timing checks. AppKit returned `nil` for the empty sublayer collection, which the assertion incorrectly rejected. The correction requires the root and two real layers before clearing, accepts either empty representation afterward, and checks that both former layers are detached. Runtime code is unchanged. This is an observed hosted failure, not a local red run; verification of the correction remains pending.

## Intended-worktree review

Independent Standards review found no documented-standard blocker. Its optional duplication finding was resolved by removing unused renderer path-length calculations.

Independent Spec review found two native display defects. Screen selection now uses the captured display's center instead of the text coordinates, preventing top-edge or off-canvas text from selecting another display. Paper measurement and rendering now use the actual label cell and scroll view's content width. Both native regressions passed, including the initial real failure that led to the cell measurement correction. Fresh committed reviews and final exact-head CI remain required at PR publication.

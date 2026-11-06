# Target and type beats verification

Scope is issue 9, against the Beats and Dictation sections of the project spec.

## Acceptance mapping

| Acceptance criterion | Implementation and evidence |
| --- | --- |
| A target tag rings a spot. Later lines wait until the owner clicks inside it, says to continue, or presses push-to-talk. A timeout ends the walkthrough politely. | `BeatParser` reads `[TARGET:x1,y1,x2,y2]`, a box in screenshot pixels with an optional `:screenN`. As its line starts the engine draws a ring around it and arms it. When the line ends, a still-unclicked target puts the reply in a waiting state that holds its later lines. A `clicked` event inside the box, or up to 10 points outside it, releases them. A click during the target's own line counts too. Pressing push-to-talk or opening the text box ends the wait. If the new question is a continue phrase ("continue", "next", "okay", "go on", "done"…), the held lines play. Any other question is asked as usual and the walkthrough is dropped. With no click for 60 seconds, the next `clockTick` clears the marks and replaces the held lines with "I'll stop here. Ask me again whenever you want to keep going." |
| A type tag clicks into the field at its spot and inserts the text with the app's safe insertion | `[TYPE:x,y:text]`, where the text may hold colons, makes the engine send `type(text, at:)` as its line starts, after the line's point and marks. Without Accessibility the engine shows "Buddy needs Accessibility permission to type for you." instead. `PasteInserter` checks secure input, clicks the spot, waits 150 ms and checks secure input again. It saves every item on the general pasteboard, writes the text in an item that also carries `org.nspasteboard.TransientType` and `org.nspasteboard.ConcealedType`, and posts Command-V. After 500 ms it restores the saved items, unless something else changed the pasteboard meanwhile. A refusal comes back as `typingRefused`, and the engine says why. Requests run one after another. Push-to-talk, Esc, opening the text box and clearing history drop typing that hasn't clicked or pasted yet, and the manager ignores a refusal from an earlier turn. The event tap ignores the events Buddy posts, which carry `PasteInserter.postedEventMarker`. |
| Tests: a target beat holds later beats until a click inside its area, clicks outside do not release it, and the timeout path works | `TargetTests` in `TargetAndTypeTests.swift`: `aTargetRingsItsBoxAndHoldsLaterLinesUntilAClickInsideIt`, `clicksOutsideTheTargetDoNotReleaseIt` (6 spots, including 1 point past each margin and another display), `aClickInsideTheTargetOrJustShortOfItsEdgeReleasesIt` (6 spots), `aWalkthroughWithNoClickEndsPolitelyAfterAMinute` (nothing at 59 s, the polite line at 60 s), and 17 more on early clicks, last-line targets (including a click before the reply completes), run offers and run questions, streaming, continue phrases, Esc and clearing history while listening, written replies and second displays. At `edc3e4c`, a mutation check that removed the hold failed 16 of these expectations. At `c1cab7c`, one that dropped a click made before the reply completed failed 4. |
| Manual checks: a two-step System Settings walkthrough waits for each click, and asking Buddy to fill a search field types the text | Partly run in a harness on the real `claude` process, below. The real clicks and real typing need the owner's signed app, so they are listed under "Owner's in-app check". |
| Logic added in this ticket is covered by Swift Testing tests in BuddyCore, driven through the engine's public interface with literal expected values | Every new test drives `BuddyEngine.handle` and compares literal effects. `TypeTests` covers the TYPE effect and its mapping across displays, its order after the line's point and marks, the missing-permission notice, refusals during and after a reply, and written replies. `agentBeatsNeverWaitForAClickOrType` covers agent runs. The prompt-examples test now releases each example's target with a click and counts `type` effects. `PasteInserter` and the event tap are app adapters with no BuddyCore logic. |

Commands run on macOS 26.6.2 with Xcode 26.6, Swift 6.3.3 and Claude Code 2.1.316:

```sh
swift test --package-path BuddyCore
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-ci \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test
```

`swift test` passed 234 tests in 24 suites before main was merged in, 289 tests in 29 suites after merging main through `45a03fa`, and 342 tests in 33 suites after merging main through `826273d`, with the live tests skipped. `xcodebuild test` passed 8 tests in 5 suites before, 9 tests in 6 suites after the second merge and 13 tests in 8 suites after the third, with no Swift warnings.

## Harness check on the real provider

The owner's own Buddy was running, so this used a throwaway Swift executable outside the repo instead of the app. It wired `BuddyEngine` to a real `ClaudeBrain` from `ClaudeLaunch.talk` in an empty temporary folder, took real full-screen captures with `screencapture` scaled to 1,280 pixels, and reported each line as started and finished at once. It posted no clicks or keys. The display was 2056 × 1329 points, captured at 1280 × 827 pixels.

Walkthrough, starting with System Settings open on Wallpaper:

```text
2,989 ms  Claude: [POINT:787,478:Appearance] [TARGET:749,470,867,486] [ARROW:700,520,748,484]
            System Settings is already open, so click Appearance in the left sidebar.
2,989 ms  lineStarted -> point, arrow, ring; the turn stays in its reply, waiting on the target
          (the harness opened the Appearance pane, as the owner's click would)
5,040 ms  clicked at the ring's centre -> clearAnnotations, captureScreens
5,257 ms  sendTurn("I clicked it.") with the new capture
11,588 ms Claude: [POINT:985,262:Dark] [TARGET:950,243,1012,285] [ARROW:930,310,985,288]
            At the top of the Appearance pane, click the Dark option, just left of Auto.
            The screen should switch to dark right away.
11,589 ms line 1 starts with its point, arrow and ring; line 2 is held for the click
```

The first target's box surrounds Appearance in the sidebar exactly. In the second capture, taken 2 s after the pane opened, the Light and Dark thumbnails had not drawn yet and only Auto showed. Claude put the target where Dark sits, just left of Auto, without seeing it. Dark Mode was not switched on.

Typing, with System Settings in front:

```text
1,512 ms  Claude: [POINT:809,250:Search] [TYPE:809,250:wallpaper]
            Sure, I'm typing wallpaper into the search field in System Settings.
1,512 ms  lineStarted -> point, type("wallpaper", at: 1299.5, 927.2)
```

The spot is inside the System Settings search field in the capture. The harness recorded the `type` effect and did not perform it.

### Again after merging #50, #52 and #55

The talk prompt gained the Remembering section, so the harness ran again on the merge, `5e785f5`, with the same display and Claude Code 2.1.316. The owner's own screen was in use, with a video playing full width in the browser.

Walkthrough, with System Settings in front on Wallpaper:

```text
3,844 ms  Claude: System Settings is already open, so we can use it.
            [POINT:787,478:Appearance] [TARGET:747,470,870,487] [ARROW:690,520,748,484]
            First, click Appearance in the sidebar on the left.
3,845 ms  line 2 starts with its point, arrow and ring; the turn stays in its reply, waiting on the target
5,923 ms  clicked at the ring's centre -> clearAnnotations, captureScreens
6,257 ms  sendTurn("I clicked it.") with the new capture
8,401 ms  Claude: [POINT:1142,258:Dark] [RING:1118,242,1168,284]
            Good news, Dark is already selected here at the top right of the Appearance pane.
            So dark mode is already on, and you're done.
8,402 ms  both lines play and the turn ends idle, with nothing held
```

The engine behaved as before. This time the first box missed: in the capture it surrounds Desktop & Dock, the row under Appearance. A click on Appearance itself, about 15 pixels higher, would not have released it, since the 10 point margin is about 6 pixels in this capture. The harness clicks the ring's centre, so it carried on. In the second capture Dark was already on, and the box surrounds the Dark thumbnail exactly. Claude used a RING and no TARGET because no step was left.

Typing gave the same result as before: `[TYPE:810,250:wallpaper]` became `type("wallpaper", at: 1301.1, 927.2)`, inside the search field.

Two more walkthrough runs did not reach System Settings. In the first, Settings stayed behind the browser. In the second, its window floated over the video, and Claude said it was "just part of the video". Both times Claude targeted the Apple menu, with a box that surrounds the Apple logo exactly. The harness then opened the Appearance pane instead of the menu, so Claude saw no open menu and targeted the Apple logo again. That follows from the harness's stand-in click, not from the engine.

So targets work end to end on the real provider, but Claude's boxes are sometimes a row off in a dense sidebar. The owner's step 1 below checks this on the real screen.

## Owner's in-app check

These need the signed Debug build in place of the owner's Buddy, with Accessibility and Input Monitoring granted:

1. Open System Settings and ask "Walk me through turning on dark mode." Buddy rings Appearance and waits. Clicking elsewhere does nothing. Click Appearance. The ring clears, and after a moment Buddy rings Dark and waits again. Click it.
2. Ask the same again and say nothing for a minute. Buddy says "I'll stop here. Ask me again whenever you want to keep going."
3. In a reply with two target lines, hold push-to-talk while it waits and say "continue". The next line plays.
4. Copy some text, then ask "Can you type wallpaper into the search field?" in System Settings. The search field gets "wallpaper", and Command-V afterwards pastes the text you copied. A clipboard manager, if any, does not record "wallpaper".
5. Open a sign-in page in a browser, click into its password field, and ask Buddy to type there. Buddy says it didn't type because secure input is on.

## Limits

- Lines after a target in the same reply carry marks read from the screenshot taken before the click. The prompt tells Claude to tag only what it can see and to end the reply at a target when the next step appears only after the click. Claude then gets a fresh capture.
- "Says to continue" means a push-to-talk or text-box turn whose words are a continue phrase. It resumes held lines only when the reply had finished streaming before the wait ended.
- Typing moves the pointer to the field, because it really clicks there. The clipboard comes back 500 ms after Command-V, so an app that reads the pasteboard later than that would paste the owner's clipboard. Text can't hold `]` or line breaks, and Accessibility doesn't check that the text landed. That check is part of the dictation ticket.
- When a walkthrough times out or the owner moves on, history still holds the reply as Claude wrote it, including lines that were never played. This matches how an interrupted reply is recorded.
- The timeout is checked on the 2-second `clockTick`, so it ends between 60 and 62 seconds.

## Integration with main

The branch merges main through `6208a96`, the merge of #51 (run offers). A line can now carry a RUN offer, a TARGET and a TYPE together, and `Beat.shownOnly` keeps a line's offer while dropping its target and typing. In `ask`, a held run offer is used up first, then a continue phrase resumes a held walkthrough, then "new conversation" and a yes to the offer are checked. So with both held, "okay" or "next" plays the walkthrough and drops the offer, while "yes" starts the run and drops the walkthrough. `okayWithBothARunOfferAndAHeldWalkthroughPlaysTheWalkthrough` covers the first case. The automatic "I clicked it." turn skips `ask`, so it uses up a held offer itself (`aClickThatAsksAgainUsesUpARunOfferFromTheSameReply`). The prompt tells the provider never to offer a run in a walkthrough reply.

A second merge brings in #54 (talk on Codex) through `45a03fa`. Its one conflict was `replyLineRead`, which keeps this branch's `finishLine` beside main's new `talkCLIChosen` event. Codex reads the same `TalkInstructions`, so targets, typing and the "I clicked it." turn work on either provider. The live harness ran on Claude only. The talk prompt keeps both the run offer section and the target and type tags, and both suites passed on the merge.

A third merge brings in #50 (owner profile), #52 (conversation summaries) and #55 (run approvals and questions) through `826273d`. `BeatParser.parse` now returns main's `ParsedLines`, and its one beat carries the target and typing beside the profile edits. `beginTurn` stashes a held walkthrough and resets main's `profileCleared` flag. The talk prompt keeps the walkthrough paragraph before main's new Remembering section, and says "Apart from TYPE's text, words inside these tags have no colons or brackets." The automatic "I clicked it." turn goes through `screensCaptured`, so it carries the profile, summaries and recent turns like any other question, and resets the provider when the earlier summaries changed. The prompt-examples test grants Accessibility and counts both `type` and `saveProfile` effects. A continue phrase is checked before a run's waiting question, so with both waiting, "okay" plays the walkthrough and the run keeps waiting for the next turn (`okayWithARunsQuestionWaitingPlaysTheHeldWalkthroughAndTheQuestionWaitsForTheNextTurn`). An unmeant answer to an agent run would be worse than playing the next step.

## Merge and rollback

This is a two-way door. It changes the talk prompt and how tags are read, adds a click event and a typing effect, and stores nothing new. Reverting the commits restores TARGET and TYPE as tags that are cut from speech and skipped.

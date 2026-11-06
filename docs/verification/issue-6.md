# Per-line speech, per-line points and interruption verification

Scope is issue 6, against the Beats, Turn lifecycle and Voice sections of the project spec.

## Acceptance mapping

| Acceptance criterion | Implementation and evidence |
| --- | --- |
| The beat parser is incremental and emits a beat as soon as a line is complete, with that line's tags and words | `BeatParser` in `Beat.swift` keeps only the unfinished line. Each delta returns the beats of the lines it finished, and the end of the reply finishes the last one. A line starts with its POINT tags. Upstream's tag after the words is still read, so an old-style reply never speaks a tag aloud. A line with no words is skipped. `firstLineIsSpokenWhileTheRestOfTheReplyStreams` shows the delta that ends line 1 returning `speak` while the reply is still streaming. `pointTagLeadsItsLineOrFollowsItsWords` covers 10 one-line replies: tags leading, trailing, stacked, `none`, malformed and mid-line, plus a line with no tag. Malformed and mid-line tags are spoken as written. |
| The mouth speaks line by line and reports each line's start and end; a line's POINT fires when that line starts, and several points each fire on their own line | The engine's new `replying` phase holds the request, the parser, the lines not yet spoken and what the mouth is doing (`silent`, `starting(beat)` or `started`). Each `speak` effect is one line. The mouth reports `lineStarted` and `lineFinished`, and the next line goes out on `lineFinished`. `eachLinesPointFiresWhenTheMouthStartsThatLine` asserts three lines across two displays: no point before the mouth starts a line, line 1's point on its start, nothing for line 2, and line 3's point on the second display. A repeated start fires nothing. `AppleVoiceMouth` reports both callbacks on the main queue, so a line's start always comes before its end. |
| Push-to-talk or Esc during a reply interrupts the provider turn, stops speech mid-line and returns the buddy to the cursor; a press during a reply queues the new turn until the interrupt completes | The stop effects follow what the reply is still doing: `cancelReply` while it streams, then `stopSpeaking` while the mouth has a line, then `clearOverlay` for Esc or `showListening(heard: ""), startListening` for a press. The overlay now keeps its windows while the buddy is shown, so both effects fly the buddy back from its point to the cursor, and Esc then hides it once it lands. The overlay runs below rendered that flight from the app's own overlay code, before and after merging #7. Watching it in the running app is the owner's checks 3 and 4. The queue was already in `ClaudeStream` from #5, which holds the next turn's message until the interrupted reply's `result`. Its recorded test from #5 proves the hold. The harness run below shows a turn sent mid-interrupt being answered by the real CLI. |
| Tests: arbitrary delta splits give identical beats, beats fire on line-start events, interruption emits its stop effects in order | `deltasSplitAnywhereProduceTheSameBeats` splits one reply into chunks of 1, 2, 3, 5, 8, 21 and 1,000 Unicode scalars. Those chunks cut tags, words and CRLF pairs. Every split gives the same literal effects. `interruptionStopsTheProviderThenTheMouthThenReturnsTheBuddy` asserts the ordered stop effects in 7 states: waiting for the first line, speaking while streaming before and after the start, the gap between lines, and speaking after the reply completed, for both Esc and a press. In each state, the late line, text and completion events that follow do nothing. `providerFailureWhileSpeakingStopsTheMouthAndShowsItsNotice` covers a failure mid-line. |
| Manual check: the first spoken word comes before the reply finishes streaming, with timing | Passed in a harness on the real `claude` process and the real Apple voice. The in-app run is left to the owner (below). On the screenshot turn, the voice started line 1 between 361 and 696 ms before the stream completed, across three runs. On a longer reply it started at 1,174 ms, and the stream was still open at 2,433 ms when it was interrupted. |
| Logic added here is covered by Swift Testing tests in BuddyCore through the engine's public interface, with literal expected values | All new tests drive `BuddyEngine.handle`. `BeatParser`, `Beat` and the reply state are internal. A mutation sweep made 16 changes. They fired the point on `speak`, held lines until the reply ended, stopped the mouth before the provider, cancelled a completed reply, left the mouth speaking on interrupt or failure, spoke tag-only lines, never started the next line, split only on LF, stopped reading leading or trailing tags, fired a repeated start's point again, joined the record with spaces, handled provider events after completion, dropped the last line, and ignored a line that ended before it started. The first sweep left 3 survivors. Three tightened assertions killed them, so all 16 mutants now fail at least one test. After merging #7, the sweep caught all 16 again, each through a failing test rather than a build error. |

Commands run on macOS 26.6.2 with Xcode 26.6, Swift 6.3.3 and Claude Code 2.1.316:

```sh
swift test --package-path BuddyCore
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-ci \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test
```

After merging `main` with #7, `swift test` passed 58 tests, with the live test skipped, and `xcodebuild test` passed the three upstream tests with no Swift warnings. Before the merge, the branch passed 55 tests.

## Harness timing run

The owner's own Buddy was running. An in-app check would have meant quitting it, granting privacy permissions to a test build and posting keystrokes, so this run used a harness instead. It was a throwaway Swift executable outside the repo. It wired `BuddyEngine` to a real `ClaudeBrain` started by `ClaudeLaunch.talk` in an empty temporary folder. It used the app's `Ports.swift` and `AppleVoiceMouth.swift`, copied unchanged except for one added line that sets each utterance's volume to 0, so nothing played aloud. Volume shouldn't change when the synthesizer reports a start or an end, but that is inferred, not measured. Times run from `sendTurn`. In the app, transcript and capture add about 126 ms before that (#5).

The harness ran three times. The third run used the final engine and mouth. The second run is the one where the press came while the reply was still streaming. All three ran before #7 merged and renamed `showPushToTalk` to `showListening(heard:)`, so the press below shows the old name. The merge changed no other engine logic of this branch.

Turn 1 sent a synthetic 1280 × 800 Finder screenshot and asked how to make a new folder. In every run Claude started the first line with `[POINT:…:File menu]`, the line-start form the new prompt teaches. Runs 1 and 3 also pointed again on their third line.

| Turn 1 step | Run 3 | Run 2 |
| --- | --- | --- |
| First `provider.textDelta` | 4,360 ms | 3,336 ms |
| Line 1 finished streaming → `speak` | 4,558 ms | 3,566 ms |
| Apple voice starts line 1 → `point` to the File menu | **4,614 ms** | **3,611 ms** |
| `provider.completed` → `recordTurn` | 5,293 ms | 3,972 ms |
| First spoken word ahead of the end of the stream | **679 ms** | **361 ms** |
| Line 1 ends → line 2 `speak` → line 2 starts | 6,921 → 6,922 ms | 5,880 → 5,881 ms |
| Last line ends → `clearOverlay` | 18,985 ms | 17,912 ms |

Run 1 gave a five-line answer, and its first word was 696 ms ahead of the end of the stream. In all three runs, one line's end to the next line's start took 1 to 2 ms.

Turn 2 asked for an eight-sentence history of the Mac, and the harness pressed push-to-talk 1.26 s into line 1. Turn 3 was sent at once.

| Step | Run 2 | Run 3 |
| --- | --- | --- |
| Turn 2: Apple voice starts line 1 | 1,174 ms | 2,314 ms |
| Turn 2: `provider.completed` | not reached | 3,337 ms |
| Turn 2: the press | 2,433 ms → `cancelReply, stopSpeaking, showPushToTalk, startListening` | 3,573 ms → `stopSpeaking, showPushToTalk, startListening` |
| Turn 2: line or completion events after the press | none | none |
| Turn 3: `provider.completed` after its own `sendTurn` | 918 ms, sent while turn 2 was still being interrupted | 1,530 ms |
| Turn 3: last line ends → `clearOverlay` | 2,153 ms | 2,763 ms |

After each run the working folder was still empty. The first delta on the screenshot turn took 3.3 to 4.4 s, slower than #5's 1.0 s. A first turn in a fresh process with an image might explain it, but that is a guess.

## Overlay flight run

A second throwaway executable compiled the app's `OverlayWindow.swift`, `DesignSystem.swift` and `Ports.swift` from `4b01592` unchanged. It drove `OverlayWindowManager` on the built-in 2056 × 1329-point display, with Reduce Motion off. It rendered each overlay window's own view with `cacheDisplay` and found the buddy by its accent-colored pixels. That rendered Buddy's view, not the rest of the screen. Positions are view points from the top left. The cursor was at 722, 474, the first point should land at 308, 1041 and the second at 1764, 1041.

| Step | Windows | Buddy at |
| --- | --- | --- |
| `show(message: nil)`, 0.8 s later | 1 | 720, 476 |
| `point` to the first spot, 0.8 s later | same window | 306, 1043 |
| `point` to the second spot, 0.3 s later | same window | 661, 1028, flying from the first spot rather than the cursor |
| 0.8 s after that `point` | same window | 1762, 1043 |
| `hide()` while pointing, 0.3 s later | same window | 1471, 752, on its way back to the cursor |
| 0.8 s after that `hide()` | none | |
| `point` to the first spot again, 0.8 s later | a new window | 306, 1043 |
| `show(message: "Release to finish")`, 0.3 s later | same window | 430, 740, on its way back |
| 0.8 s after that `show` | same window | 720, 476 |
| `hide()` at the cursor | none, at once | |

After merging #7, the press shows #7's listening waveform and the heard words instead of "Release to finish". A new run on the merged code used the same three app files and #7's `MicrophoneLevel` class, copied unchanged. Its steps follow the merged effects, with `listen(heard:)` for the press and the words heard. It reads the cursor just before each render. Cursor positions include the buddy's offset from the pointer. The waveform and the triangle share the accent color, so each render's accent area tells them apart: the triangle covers about 181 square points and the waveform about 29 to 40. A bubble is the render's opaque near-black area. Times are measured from each call. The cursor moved during the first three steps, then stayed at 1546, 563.

| Step | Windows | Buddy at | Drawn as | Bubble |
| --- | --- | --- | --- | --- |
| `show(message: nil)`, 0.84 s later | 1 | 1357, 402, cursor at 1359, 399 | triangle | none |
| `point` to the first spot, 0.84 s later | same window | 306, 1044 | triangle | the label |
| `point` to the second spot, 0.31 s later | same window | 1056, 1023, flying from the first spot | triangle, enlarged in flight | the label |
| 0.82 s after that `point` | same window | 1762, 1044 | triangle | the label |
| `listen(heard: "")` while pointing, 0.31 s later | same window | 1653, 659, on its way back to the cursor | waveform | none, the label is gone |
| 0.82 s after that `listen` | same window | 1545, 563, at the cursor | waveform | none |
| `listen(heard: "where is the wi-fi menu")`, 0.10 s later | same window | 1545, 563 | waveform | the heard words |
| `show(message: nil)`, 0.10 s later | same window | 1544, 566 | triangle | none |
| `point` to the first spot, 0.84 s later | same window | 306, 1044 | triangle | the label |
| `hide()` while pointing, 0.31 s later | same window | 917, 669, on its way back | triangle | none |
| 0.82 s after that `hide()` | none | | | |
| `listen(heard: "")` with no windows, 0.84 s later | a new window | 1546, 563, at the cursor | waveform | none |
| `hide()` at the cursor | none, at once | | | |

Only one display was connected, so a flight between displays was not run.

## Owner's in-app check

These need the signed Debug build in place of the owner's Buddy, with its permissions, real displays and speakers:

1. Run `/usr/bin/log stream --predicate 'subsystem == "dev.steven.buddy"' --level debug`. In Finder, ask "How do I make a new folder?" Buddy starts talking while the reply is still arriving, and flies to each thing as the line that names it starts. In the log, the first `lineStarted` comes before `provider.completed`. Note both times after `pushToTalkReleased`.
2. When the reply ends, the buddy flies back to the cursor before it hides.
3. Ask a multi-line question and press Esc while a pointed line plays. Speech stops mid-word, the label goes, and the buddy flies back to the cursor and hides.
4. Repeat with push-to-talk instead of Esc. The buddy flies back to the cursor as the listening waveform, with the words heard beside it. The next question is answered.

## Limits

- The prompt asks for one sentence per line. A reply written as one long line is still spoken correctly, but only after that line finishes streaming.
- A line points at its first tag with coordinates. A line with only tags is skipped, so a point on its own line after the last sentence is dropped.
- A malformed tag is spoken as written, as before. Skipping malformed tags is #8.
- The turn record is written when the reply finishes streaming, with lines joined by newlines. A reply cut off before then is not recorded, as in #5.
- When a point moves to another display, the buddy appears there from the cursor instead of crossing between displays.
- With Reduce Motion on, the buddy jumps instead of flying, and a hide while pointing closes at once.
- If a display is added or removed while the buddy is shown, its windows are rebuilt at the next show, point or update of the words heard.
- The queue for a press during a reply lives in `ClaudeStream`. Codex (#10) will need its own unless this moves up into the engine.

## Merge and rollback

This is a two-way door. It changes the talk prompt, how replies are spoken and how the overlay moves, and stores nothing new. Reverting the commits restores whole-reply speech with one trailing point.

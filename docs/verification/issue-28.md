# Issue 28 verification

A talk reply can offer an agent run. Buddy says what the run would do, then asks aloud on a line tagged `[RUN:brief]` whether to do it as an agent run. A plain yes on the next turn starts the run with that brief, and anything else drops the offer.

## Acceptance evidence

| Criterion | Evidence |
| --- | --- |
| A run offer beat carries a brief, and Buddy asks aloud | `BeatParser` reads `[RUN:brief]` anywhere in a line, keeps the line's first one and cuts it from the spoken words. Only a line that asks a question offers the run. `buddyAsksAloudWhetherToDoTheOfferedBriefAsAnAgentRun` checks the literal `speak` effect "Want me to do that as an agent run?" and the held `state.runOffer`. `aTaggedLineThatDoesNotAskOffersNothing` covers a tagged statement. `TalkInstructions` teaches the tag and a brief that stands on its own, and tells Buddy to say what the run would do before asking. |
| A yes on the next turn starts the run, and anything else drops it | `aYesOnTheNextTurnStartsTheRunWithTheOfferedBrief` checks `startRun` with the offered brief and the offering turn's screens, the time cap, the saved history and the spoken confirmation, with no new capture. `aTypedYesAcceptsTheOffer` covers seven yes phrasings. `anythingButAYesDropsTheOffer` covers "no", "No thanks.", "yes, but only the PDFs", a question, "thanks", "OK, thanks.", "please", "Yes, 2" and "Do it?". |
| Tests: offer then yes, offer then an unrelated request | `aYesOnTheNextTurnStartsTheRunWithTheOfferedBrief` and `anUnrelatedRequestDropsTheOfferAndIsAnsweredAsUsual`. The second also checks that a later yes is sent to the provider as an ordinary turn. |
| Manual check: a batch rename produces an offer | Passed live on the owner's Claude sign-in with the production talk prompt, `ClaudeBrain` and engine. See below. |
| Swift Testing through the engine's public interface | `RunOfferTests` drives `BuddyEngine.handle` with literal expected effects and state. Further cases cover a written offer with Spoken replies off, an offer line that never starts because it was cut off or the Apple voice failed it, Esc, a failed reply, a stale offer, the conversation ending, "new conversation", clearing history, a yes while another run is going, a yes by push-to-talk while Buddy is still talking, a later question or statement in the same reply, a run's own beats, tag placement, an empty brief and a brief with a colon. |

## Design notes

- The offer is held only once its line starts speaking or is shown in writing, so the owner can't accept a question they never heard. A line cut off before it starts, or one the Apple voice fails, offers nothing.
- A yes answers the last question Buddy asked, so a later question in the same reply drops the offer. A later statement keeps it.
- The next asked turn always uses the offer up. A yes must be the whole answer, such as "yes", "yeah, go ahead" or "OK, do it". "OK, thanks" closes the topic and is not a yes, and neither is a yes with a number or a question mark. A yes with conditions goes to the provider as an ordinary turn. When the offering reply finished, the offer is among its recent turns.
- Accepting starts the run from the offering turn's screens without another capture, through the same path as the `agent` prefix. The one-run limit and the confirmation are the same.
- Esc, a failed reply, ending the conversation, "new conversation" and clearing history drop the offer. Beats from a run's `show_beats` never offer a run, and they drop an offer held before them, so a yes always answers Buddy's last question.
- An offer goes stale ten minutes after it was asked, as a conversation does, and the clock tick drops it then. This covers an offering turn that never finished, which leaves no conversation to end.
- With Spoken replies off, the offer is shown in writing and accepted the same way. This keeps that setting, as the `agent` confirmation does.
- The owner hears Buddy's summary of the run, not the brief itself. The brief appears as the request on the run card as soon as the run starts, and the card's Stop control ends it at once.

## Automated checks

```sh
swift test --package-path BuddyCore
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-ci-28 \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test
```

BuddyCore passes 231 tests in 23 suites; the two live tests are skipped without `BUDDY_LIVE_CLAUDE=1`. The app passes 8 tests in 5 suites. Before the engine change, 6 of the first 12 new `RunOfferTests` functions failed with 30 issues. Review then found that an offer line that never played could still be accepted. `anOfferWhoseLineNeverStartsIsNotKept` failed, including a yes that started a run after the Apple voice failed the offer line, and it passes now that the offer is held from the line's start. Later reviews found that "OK, thanks.", "Yes, 2" and "Do it?" started a run, that a later question, Esc or a failed reply kept the offer, and that a yes ten minutes later still started a run after an offering turn that never finished. Their new cases failed first and pass now.

## Live check

`BUDDY_LIVE_CLAUDE=1 swift test --package-path BuddyCore --filter liveClaude` ran on November 1, 2026 with the installed Claude Code and the default talk model. `liveClaudeOffersARunWhenAskedToRenameABatchOfFiles` typed "Rename all the screenshots on my Desktop so each name starts with the date it was taken." through the engine.

```text
Spoke: ["I can put the date each screenshot was taken at the front of its name, using the date from each file's own creation time.", "Want me to do that as an agent run?"]
Offered: Rename every screenshot file on the Desktop so its name starts with the date it was taken in YYYY-MM-DD format, using each file's creation date, and skip any that already start with a date
```

Both live tests passed. The test sends no screenshots and starts no run. In a one-off check that was not committed, "How do I make a new folder in Finder?" got three spoken steps and no offer.

The run's approval policy still denies renaming or moving the owner's files, so an accepted rename offer reports that limit until a later ticket lets runs ask before such changes.

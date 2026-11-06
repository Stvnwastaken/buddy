# Issue 16 verification

Scope is issue 16: when a question needs current information, Buddy searches the web during the talk turn on either provider.

## Acceptance evidence

| Criterion | Implementation | Evidence |
| --- | --- | --- |
| Claude talk allows only web search; Codex talk has web search on | `ClaudeLaunch.talk` passes `--tools WebSearch --allowedTools WebSearch`. The utility model keeps `--tools ""`. `CodexLaunch.talk` sets `web_search="live"`, and the new `CodexLaunch.utility` keeps `web_search="disabled"` for summaries. | `talkUsesTheCLIsOwnLoginAndTheOwnersOptOutsFromAnEmptyFolderWithOnlyWebSearchAndNoUserSettings`, `utilityRunsOnTheSmallModelWithItsOwnInstructionsAndNoTools`, `talkUsesTheOwnersChatGPTSignInWithLiveWebSearchButWithoutTheirProxyHooksPluginsOrOtherTools` and `utilityIsTheTalkServerWithWebSearchOff`. |
| A short spoken cue plays while a search runs | Both streams report a search start as `ProviderEvent.searching`. On a search, the engine plays any line written so far at once. If nothing has been said yet, it speaks "Let me look that up." once per reply. The cue is not saved in history, and with Spoken replies off it is shown instead. | `WebSearchTests` drives the public engine: the cue followed by the answer and its saved history, a written line playing in place of the cue, no second cue, and the shown cue. |
| Adapter tests replay recorded search transcripts and still produce the right text deltas | `ClaudeStream` reports a top-level `WebSearch` tool-use block start. `CodexStream` reports an `item/started` notification for a `webSearch` item in the current turn. | `search-turn.jsonl` and `codex-search-turn.jsonl` were recorded on November 1, 2026 from Claude Code 2.1.316 and `codex app-server` 0.166.0, then sanitized. `recordedSearchTurnReportsEachSearchThenStreamsTheAnswer` replays Claude's two searches at four chunk sizes. `recordedSearchTurnReportsTheSearchThenStreamsTheAnswer` replays Codex's search. Both check every delta literally. A cancelled reply reports usage only. |
| Manual check on both providers: today's news gets a current answer | Each talk turn says today's date in the owner's time zone, which the app passes to the engine as `.autoupdatingCurrent`. `TalkInstructions` tells the model when to search, to put the date in a search about today, and to leave links out of spoken replies. | See the live checks below. |
| Logic is covered by Swift Testing tests through the engine's public interface | | `WebSearchTests` uses only `BuddyEngine.handle` and `TurnRequest.content`, with literal expected lines, dates and content. Two time zones show that the date comes from the owner's zone. |

## Before

With `--tools WebSearch` but no allow rule, the print-mode CLI denied the search: `permission_denials` named `WebSearch`, and the reply said the search permission hadn't been granted. Without a date in the turn, Claude searched for "top news story today" and found only undated spam pages. Main's talk launch had `--tools ""` and Codex's `web_search="disabled"`, so neither provider could search.

## Live checks

These ran by hand on November 1, 2026 with `BUDDY_LIVE_CLAUDE=1 BUDDY_LIVE_CODEX=1 swift test --package-path BuddyCore --filter LiveWebSearchTests`. The tests go through the production `BuddyEngine`, `ClaudeLaunch.talk`/`ClaudeBrain` and `CodexLaunch.talk`/`CodexBrain`, ask "What's the top news story today?" from the text box with no screenshots, and play the reply back through the engine.

Codex, direct ChatGPT sign-in, with the final instructions:

```text
Asked with: Sunday, November 1, 2026
Spoke: ["Let me look that up.", "One of today’s biggest stories is the final push before the U.S. midterm elections, with control of Congress at stake.", "The Associated Press reports that Trump is rallying in Iowa and Kansas as Republicans fight to keep both chambers."]
```

Claude, direct sign-in, three runs with the final instructions:

```text
Spoke: ["Let me look that up.", "I couldn't find one clear top story for today, and the search results had unreliable dates.", "The biggest item that looks current is a Learjet with nine people aboard that crashed near Greenacres, Florida, on its way from Texas to the Bahamas, according to ABC News and Yahoo.", ...]
Spoke: ["Let me look that up.", "I can't confirm a single top story, but the biggest one in what I found is a small jet crash near Greenacres, Florida.", "Federal officials say all nine people on board died, according to Yahoo News.", ...]
Spoke: ["Let me look that up.", "I couldn't find one confirmed top story for today.", "The closest thing was an Associated Press news summary that leads with Iran-related talks about reopening the Strait of Hormuz.", "It also mentioned ... Sheila Chepkirui of Kenya winning the New York City Marathon.", ...]
```

An earlier run, before the instructions named the search tool's link reminder, ended with a spoken markdown link. The final wording produced no links in three runs.

Through CLIProxy, the same Claude Code transport with the final talk instructions and flags searched and answered with current stories on both models. Both streams began each search with the same top-level `WebSearch` tool-use block that `ClaudeStream` reports. The hub address and keys were kept out of the evidence.

```text
claude-sonnet-5-5 searched "top news story today November 1, 2026":
No single story dominates today, but the US midterms are leading the coverage.
Millions of people have already voted early ahead of Tuesday's election, and polls give Democrats an edge. ...
gpt-6.1-sol searched "top news today November 1 2026 Associated Press Reuters":
The U.S. midterm elections are a leading story today, with Election Day just two days away. ...
```

## Automated checks

```sh
swift test --package-path BuddyCore
# 376 tests in 36 suites passed after merging main at c4f5bbb. The live tests are skipped without their variables.
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-ci \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test
# 13 tests in 8 suites passed. TEST SUCCEEDED.
```

Main's draw programs replaced the reply's parser with `ReplyReader`. After the merge, a search asks `ReplyReader.endLine()` to finish the line written so far. Inside an open draw program it reads nothing, so a search part way through a program line can't split it. `searchPartWayThroughAProgramLineLeavesTheLineWhole` failed with a draw-program syntax error when the search fed a plain line break, and passes now. The live Codex search passed again on the merged head. The live Claude test couldn't run there, because the owner's Claude sign-in had reached its 5-hour limit.

Removing the engine's cue made six `WebSearchTests` expectations fail.

## Limits

- The cue plays at most once per reply, and only when nothing has been said yet. Back-to-back searches, or a search after a spoken line, can still leave a pause. Repeating "Let me look that up." in one reply would sound odd. A line the model writes before searching plays at once and stands in for the cue. With Spoken replies off, the written reply keeps the cue as its first line.

- Search quality depends on each provider's search backend. Claude's results are sometimes stale or spammy, and it says so instead of guessing. One run named "apnews.com or reuters.com" aloud.
- The checks above didn't run the installed app, so the cue wasn't heard through the speakers. A spoken check in the app would also send a screenshot of the owner's screen. To check it: double-tap Control, ask "What's the top news story today?", and listen for "Let me look that up." before the answer, on direct Claude, direct Codex and CLIProxy.
- The Claude fixture was recorded with an earlier draft of the search instructions. The adapter tests replay the wire protocol, which doesn't depend on that wording.

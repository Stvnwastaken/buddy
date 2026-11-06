# Conversation summaries verification

Scope is issue 13, against the summary lines of the project spec.

## Acceptance mapping

| Criterion | Implementation and evidence |
| --- | --- |
| A warm utility process on a small fast model, using the same provider selection as talk, writes a summary when a conversation ends | `UtilityModel` keeps one provider session warm and follows talk's CLI. With Claude Code it is a `claude -p` process from `ClaudeLaunch.utility`, on Haiku with the CLI login. In proxy mode `TalkConnections.utilityProxy` uses the same hub, token, provider and account as talk, with the provider's small model: `claude-haiku-5-5` or `gpt-6-luna`, checked against the hub's model list. Proxy mode never falls back to the CLI login. With direct Codex it is a second `codex app-server` whose `CodexThread` carries the utility instructions and prefers `gpt-6-luna`, then `gpt-5.6-luna`, when the account offers them. Each answer ends the session's conversation, so every question gets a fresh Claude process or Codex thread. The engine emits `writeSummary` when a conversation ends, whether by "new conversation", the ten-minute expiry or a press after it. `UtilityModelTests` cover the fresh process per question, a selection change during a question, stopping with a question pending, a missing CLI and the launch shape. `CodexStreamTests.aUtilityThreadUsesItsOwnInstructionsAndTheFirstPreferredModelOffered` covers the Codex utility thread. A provider change while a summary is in flight retries that summary on the new provider if it fails. |
| Recent summaries, within a fixed budget, are included when a conversation starts | `ConversationHistory.earlierSummaries` keeps the newest ended conversations' summaries, at most five and 2,000 characters, and lists them oldest first. `TurnRequest.content` puts them before the screenshots. `ClaudeBrain` sends them only in the first message to each process. If a summary lands after the new conversation's process was primed, the engine resets the provider at the next turn so that process is primed again. |
| A conversation that switches providers or restarts its process is primed with its own summary plus its recent turns | Once a turn falls out of the active conversation's last ten, the engine asks the utility model to fold that turn into the conversation's own summary. A fresh process then gets the earlier summaries, the conversation's own summary and its last ten uncovered turns. The final summary is folded in when the conversation ends. |
| Summaries are stored locally as text and cleared together with history | `Conversation.summary` is an optional `ConversationSummary`, holding the text and the number of turns it covers, inside `history.json`. Clear history removes the file, cancels the summary in progress and drops its late answer. History saved before this change still loads. |
| Tests: a summary is requested on conversation end, the inclusion budget holds, and the priming payload is right | `SummaryTests` has 14 engine tests through `handle`, all with literal expected effects. `ClaudeBrainTests.summariesPrimeOnlyTheFirstMessageToAProcess` checks the literal wire text for a fresh process and for a warm one, and `CodexStreamTests.summariesPrimeOnlyEachThreadsFirstTurn` does the same for a Codex thread. With the profile (#50), the owner's profile comes first on every turn, warm or fresh, and the summaries follow it only on a fresh process or thread. A utility model question carries no profile, which `UtilityModelTests.aQuestionReachesTheModelAsItsTextAloneWithoutTheOwnersProfile` checks. |
| Manual check: a fact mentioned in one conversation is known in the next | Passed against real Claude, twice: once with the production engine and adapters, once through the app's `CompanionManager` and the owner's CLIProxy selection. Details below. |
| Logic is covered by Swift Testing tests in BuddyCore through the engine's public interface | The summary policy, budget, rolling summary, retries, clearing and priming all live in `BuddyEngine` and `ConversationHistory`, and are driven through `handle`. The one piece of logic in the app target is the small-model choice in `TalkConnections.utilityProxy`, and the native harness below exercised it. |

## Automated checks

Commands run with Xcode 26.6:

```sh
swift test --package-path BuddyCore
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-ci-issue13 \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-build test
```

- **BuddyCore:** 314 tests passed, after merging main's annotation beats (#43), run offers (#51), direct Codex (#54), the profile (#50) and run approvals (#55).
- **App, unsigned and signed:** 13 tests passed in each build.
- **Warnings:** none in Swift.
- **Updated tests:** the nine existing conversation tests and one annotation test that end a conversation now expect the trailing `writeSummary` effect.

While hosting the app's tests, the app no longer calls `CompanionManager.start()`. Before this change, a local `xcodebuild test` launched the full app against the owner's real `history.json` and warmed real `claude` processes. With summaries, that launch would also have sent the owner's past conversations to the utility model. After all the runs above, the owner's real history still had three conversations and no summaries.

## Native runtime checks

`BUDDY_LIVE_CLAUDE=1 swift test --package-path BuddyCore --filter liveClaude` passed three times: on `dc18191`, then twice more before and after merging main into `9de9bf4`. On `a1c63ee` both live tests, including the existing one, failed only because the CLI login had hit its five-hour limit ("You've hit your 5-hour limit"). It failed the same way after merging direct Codex (#54), with the limit due to reset at 7am Pacific.

Once the limit reset, all three live Claude tests passed on `826273d`, the merge of #52 into main, which already includes the profile (#50) and run approvals (#55). They ran against the CLI login, not CLIProxy: `liveClaudeAnswersATinyTurnFromAnEmptyFolder`, `liveClaudeOffersARunWhenAskedToRenameABatchOfFiles` and `liveClaudeCarriesAFactIntoTheNextConversation`, in 6.8 seconds in total. The last one checks that:

- the conversation produced exactly one summary, containing "Copper Finch" and saved with `turns: 1`;
- the next conversation's first turn carried that summary in `earlierSummaries`;
- its reply named Copper Finch;
- the temporary folder was empty afterwards.

The test checks those facts rather than printing the texts, so they aren't quoted here. That commit changed only the `providerChanged` retry and the wording of the utility instructions, and the CLIProxy harness below ran that wording successfully. `liveClaudeCarriesAFactIntoTheNextConversation` drives the production engine, `ClaudeBrain`, `UtilityModel` and the real launch builders with the CLI login, in an empty temporary folder:

1. **First conversation.** "My paper kite is named Copper Finch. Reply with only the word noted." was answered on Sonnet.
2. **Conversation end.** "New conversation." ended it. The Haiku utility process returned a summary containing "Copper Finch", which the engine saved with `turns: 1`.
3. **Next conversation.** A fresh talk process received that summary in `earlierSummaries`. It answered "What is my paper kite named? Answer with only its name." with "Copper Finch".
4. **Folder.** The temporary folder was empty afterwards.

A temporary hosted app test, deleted afterwards and never committed, drove the real `CompanionManager`. It used a temporary history file and the owner's saved talk selection, which it read without changing:

```text
useProxy=true provider=claude account=any
unavailable=none talkModel=claude-opus-5-5 utilityModel=claude-haiku-5-5
summary=1 turn(s): The owner's paper kite is named Copper Finch.
savedFileHasSummary=true
afterClear fileExists=false conversations=0
codex talkModel=gpt-6.1-sol utilityModel=gpt-6-luna
codex summary=The owner has a paper kite named Copper Finch.
folderAfter=[]
```

That run showed:

- An expired conversation got its summary through the app's `writeSummary` wiring and the hub's small Claude model, and the summary was saved to the file.
- Clear history deleted the file.
- The Codex selection routes the utility model to `gpt-6-luna` and returns a correct summary.

A second run of the same harness sent the clock tick before CLIProxy had loaded, the order the app uses at launch, and sent no tick afterwards. Before the refresh it logged `beforeRefresh summary=none`. Once CLIProxy loaded, the manager's `providerChanged` retried the summary, and the run logged `summary=1 turn(s): The owner's paper kite is named Copper Finch.`. Both reviewers had found that this launch catch-up was never retried in proxy mode.

After merging direct Codex (#54), a temporary live test, deleted afterwards, built the app's direct-Codex utility the same way `CompanionManager` does: `UtilityModel` over a `CodexBrain` with the utility `CodexThread`, launched by `CodexLaunch.talk` with the owner's ChatGPT sign-in. It asked two summary prompts in a row:

```text
first=success("The owner’s paper kite is named Copper Finch.")
second=success("The owner’s bicycle is called Juniper.")
workAfter=[]
```

The second summary doesn't mention the kite, so the second question ran on a fresh thread.

## Limits and rollback

- **Spoken turns and relaunch.** The checks used typed synthetic events. They didn't speak a turn or physically relaunch the installed app. The owner can repeat the check by saying a fact, saying "new conversation" and asking about it.
- **Gap during a failure.** While a rolling summary is being written, or after one fails, the turn just past the last ten reaches neither the summary nor the priming. The next finished turn retries the summary.
- **Repeated failure.** If the utility model keeps failing, for example when signed out, summaries simply stop and talk continues. Nothing is shown to the owner.
- **First launch after the update.** The first event after launch catches up summaries for the last five ended conversations, one small-model call each. In proxy mode the first attempt fails while CLIProxy loads; the `providerChanged` event sent once it connects retries it.
- **Hung utility process.** A utility process that never answers holds the one summary in flight until relaunch. There is no timeout.
- **Rollback.** Reverting leaves the `summary` fields in `history.json`. The previous app ignores unknown keys when decoding, so the file keeps loading.

# Buddy

An open-source macOS buddy in the spirit of HeyClicky that runs on the owner's own Claude or ChatGPT subscription, forked from farzaa/clicky. Read `GLOSSARY.md` and `docs/adr/` before working here. Never copy code, prompts or assets from the HeyClicky app (ADR 0004).

## Agent skills

### Issue tracker

Issues and specs live in this repo's GitHub Issues, managed with `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one root `GLOSSARY.md` plus `docs/adr/`. See `docs/agents/domain.md`.

## Build and test

- `Buddy.xcodeproj`, shared scheme `Buddy`, contains the macOS app and the surviving upstream permission tests.
- `BuddyCore/` is a local Swift 6 package with no AppKit dependency. New domain logic is tested through its public event/effect engine. Each talk adapter is a stream that holds its protocol without I/O, plus a brain that runs it in a child process: `ClaudeStream` and `ClaudeBrain` in `BuddyCore/Sources/BuddyCore/Claude/` for stream-json, and `CodexStream` and `CodexBrain` in `Codex/` for `codex app-server` JSON-RPC. `Process/` holds the shared `ProcessLaunch`, `ChildProcess` and line helpers. The stream tests replay CLI output recorded in `Tests/BuddyCoreTests/Fixtures/`.
- Agent runs: the engine holds the run state machine, including the needs-owner state, and `Runs/` the approval policy, which allows, denies or asks the owner. `RunProcess` in `Runs/` runs one provider process per run through a `RunStream`. `ClaudeLaunch.run` and `ClaudeRunStream` in `Claude/` drive `claude -p` with `--permission-prompt-tool stdio`. `CodexLaunch.run` and `CodexRunStream` in `Codex/` drive `codex app-server` from Buddy's own Codex home with full disk access and an untrusted run folder, so every command and patch asks Buddy (ADR 0007). `MCP/` holds the loopback MCP server that tells runs apart by per-run bearer tokens. In the app, `AgentRunHost` makes each run's folder in `Application Support/Buddy/Runs/`, starts the CLI the owner chose for runs and serves the tools, and `RunCard.swift` holds the dock, one card per run, so several runs can work at once. A screen takeover lets a run use the mouse and keyboard after the owner allows it on the run's card, one run at a time. `Runs/Takeover.swift` holds its actions and key names, and the engine maps their pixels to the displays. In the app, `ScreenTakeover` blocks the owner's input with an event tap and posts the run's actions. Esc and push-to-talk pass the tap and end the takeover at once.
- Draw programs: `docs/draw-programs.md` is the API. In `BuddyCore/Sources/BuddyCore/Draw/`, `ReplyReader` reads plain beats until a ```` ```draw ```` fence, then the program up to its closing fence, and `DrawSandbox` runs the program in a fresh JavaScriptCore context under a time limit and records its beats and marks. The app's `DrawMarksView` in `OverlayWindow.swift` redraws the marks with Core Animation.
- Run `swift test --package-path BuddyCore` and `xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-build test`.
- `BuddyVoice/` is a local package that wraps FluidAudio's Kokoro text-to-speech for the app's neural voice. FluidAudio is the project's only remote package, pinned exactly in `BuddyVoice/Package.swift` and both `Package.resolved` files. Buddy never downloads the model. `swift run --package-path BuddyVoice install-voice` installs it in `~/Library/Application Support/Buddy/Voice`, with the extra voice packs listed in `NeuralVoice.extraVoices` for the settings voice picker. After bumping FluidAudio, repeat the offline check in `docs/verification/issue-21.md`, because FluidAudio can fetch a missing file even with its downloads switched off.
- `BUDDY_LIVE_CLAUDE=1 swift test --package-path BuddyCore --filter liveClaude` spends twelve small real turns on the owner's Claude sign-in: a one-word answer, a batch rename that should come back as a run offer, a question about today's news that should search the web, a question about how a run in the dock is going, and a fact carried into the next conversation by its summary, which takes two talk turns and one utility-model turn. The reopen/delete test adds three talk turns and two summary turns, establishes conflicting facts in A and B, reopens A, then deletes B and checks its absence from the reloaded history and next context. Run only that check with `--filter liveClaudeReopensItsOwnContextAndDeletesAnotherConversation`. `BUDDY_LIVE_CODEX=1 swift test --package-path BuddyCore --filter liveCodex` spends two real turns on their ChatGPT sign-in through Codex: a tiny one and the same news question. The news tests print what Buddy would say, so the owner can judge whether the answer is current. `BUDDY_LIVE_CODEX_RUN=1 swift test --package-path BuddyCore --filter LiveCodexRunTests` spends two small agent runs on Codex, one in a temporary run folder and one that leaves a `Buddy-issue29-…` folder on the Desktop. It denies anything left to the owner. With `BUDDY_RECORD_CODEX_RUN=<path>` it also saves what Codex printed. Run them by hand only, never in CI.
- Keep `dev.steven.buddy` and the Apple Development signing identity stable. The manual grant-persistence and process-network checks are in `docs/verification/issue-3.md`.

## CI

`.github/workflows/ci.yml` runs on every pull request and every push to `main`. It uses the `macos-26` runner and pins the Xcode named in its `DEVELOPER_DIR`. Bump that pin when the runner image drops the version. CI builds the app with code signing disabled, which fetches and compiles FluidAudio. With the same Xcode selected, these commands reproduce its checks locally. The separate derived data path keeps the unsigned build away from the signed app in `/tmp/buddy-build`.

```sh
swift test --package-path BuddyCore
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-ci \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO test
```

The runner has no privacy permissions and no provider sign-in. Permission checks stay manual, so no automated test may need a privacy permission. Live smoke tests use the owner's usage limits and run only when their environment variable is set. CI never sets it. Keep the job single and fast.

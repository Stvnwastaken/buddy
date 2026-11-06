<img src="assets/icon.svg" width="64" height="64" alt="">

# Buddy

**HeyClicky, but bring your own subscription.** Buddy is an open-source macOS buddy that sees your screen, talks back in a local voice, points at things and runs agent tasks. It does this on the Claude Code or ChatGPT (Codex) subscription you already pay for, with no account, server or API key of its own.

Buddy is an independent project, not affiliated with or endorsed by HeyClicky. It is forked from the MIT-licensed [farzaa/clicky](https://github.com/farzaa/clicky).

## What it does

Buddy runs from the macOS Dock and follows the cursor during push-to-talk. Hold **control + option**, ask about your screen and release. Or double-tap **control**, type the question in the notch and press Return. Buddy sends the question and a screenshot of every display to your own Claude Code or Codex, speaks the answer line by line in a local neural voice as it arrives and flies to anything each line points at. Press push-to-talk or Esc to cut it off. Esc also closes the text box.

Buddy needs the `claude` CLI installed. **Talk with** in settings chooses Claude or Codex. With **Use CLIProxy** on, your existing CLIProxy hub serves that provider, and you can pick an account and a model. Automatic leaves account rotation to CLIProxy. The choices save as you make them and persist across launches. Each provider keeps its own account and model, so switching from Codex back to Claude brings back the Claude account and model you last picked. With **Use CLIProxy** off, Claude uses the Claude CLI's own subscription login. Codex runs a long-lived `codex app-server` on your ChatGPT login with the built-in OpenAI provider, overriding any proxy provider in your Codex config, so it needs the `codex` CLI installed and signed in with `codex login`. Codex's MCP servers, hooks, plugins and apps are turned off, and each turn's temporary screenshot files are deleted when the turn ends. Codex still reads its global `AGENTS.md` and keeps some built-in tools; see [ADR 0006](docs/adr/0006-direct-codex-through-app-server.md) and [the verification](docs/verification/issue-10.md).

Buddy's text is in the notch at the top center of the screen with the cursor. Idle, a small buddy icon sits beside the camera notch, or in the same shape under the menu bar on a screen without one, and it is hidden over full-screen apps. During a turn a strip drops down from it with the heard words and a waveform, then **Thinking…**, then each line as it is spoken, and any notice. It closes a few seconds after the reply ends, or at once on Esc. Hover over its icon to open the current conversation and its text box. The thread scrolls with the newest turn at the bottom. Moving away closes it unless the field has focus or text. **New conversation** starts an empty thread and summarizes the one that ended. See [open notch verification](docs/verification/issue-60.md) and [compact strip verification](docs/verification/issue-59.md).

Turn off **Spoken replies** in Buddy's settings for written answers with pointing and no narration. The choice persists. The strip shows each line for 3–20 seconds, by its length, and **Latest answer** in settings provides the complete selectable text. Buddy points toward the target from a small gap so the item stays visible. See [turn feedback verification](docs/verification/turn-feedback.md).

Say "remember that…" and Buddy adds a note to your profile, a small Markdown file that Buddy writes at `~/Library/Application Support/Buddy/profile.md` with one bullet per note. Say "forget…" to take one out, or ask "what do you remember about me?" Buddy reads the profile with every question. **Profile** in settings lists the notes and clears them.

Buddy discovers the hub address in `~/.claude/settings.json` (`env.ANTHROPIC_BASE_URL`). It reads the existing access and management keys from `~/.config/cliproxyapi/`; the Claude settings' `ANTHROPIC_AUTH_TOKEN` is also accepted when the access-key file is absent. Keys stay in memory and are never written into Buddy preferences or history. Through the hub, both providers use the existing tool-free Claude CLI transport through CLIProxy's protocol translation. Screenshots travel through the selected hub when a question is sent.

Choosing a specific account uses a unique model prefix on the hub. Buddy reuses an existing unique prefix, or adds `buddy-<auth_index>` when the account has none and unprefixed routing is enabled. Existing unprefixed requests remain available. It never disables other accounts, changes the hub's global routing policy, or changes your shell's selected CLI profile. A missing account fails explicitly until you choose another; it does not silently select a different account. See [the design decision](docs/adr/0005-select-provider-accounts-through-cliproxy.md) and [verification](docs/verification/provider-accounts.md).

The settings window shows live Microphone, Speech Recognition, Screen Recording, Accessibility, and Input Monitoring permissions. Grant access from each row when you are ready. Input Monitoring enables the global shortcut. **Launch at login** is off until you enable it.

## Agent runs

Start a request with **“agent”** to have Buddy work in the background. For example, “agent, make a folder on my Desktop with a text file listing my open apps.” Buddy confirms aloud, or in writing when Spoken replies is off, plays a short launch sound and adds a card for the run to a dock at the right edge of the screen. Several runs can work at once, each with its own card showing its name, status, run note and final report. A card that needs you is highlighted, and Buddy plays a sound. **Stop** on a card ends that run immediately, and a run that ends by itself plays a done sound. Each run has limits of 100 tool uses and 20 minutes. Ask "how is the agent doing?" and Buddy answers from the dock.

The panel's **Agent runs** card picks the provider for new runs, Claude Code on Opus or Codex with your ChatGPT sign-in, and how their requests are approved. In **Auto**, runs may read files and apps, work inside their own folder, and create new visible Desktop files and folders. A few things, such as `cd`, are refused so the run does them another way. Anything else, such as sending, deleting or changing your files, waits on its card for you to approve or deny. **Approve only** also asks before every command and file change Auto would allow. **YOLO** allows everything without asking, so nothing stops a run from changing any of your files. See [the design decision](docs/adr/0008-run-approval-modes.md). Each run retains its request, screen captures, note, report, output and scratch files in `~/Library/Application Support/Buddy/Runs`. **Show in Finder** opens its folder after it ends. These folders remain until you remove them.

## Neural voice

Buddy speaks with [Kokoro 82M](https://huggingface.co/hexgrad/Kokoro-82M), by default its `af_heart` voice, run on the Neural Engine by [FluidAudio](https://github.com/FluidInference/FluidAudio). Buddy never downloads the model itself. Install it once from this folder:

```sh
swift run --package-path BuddyVoice install-voice
```

The first run builds FluidAudio and downloads 95 MB from [FluidInference/kokoro-82m-coreml](https://huggingface.co/FluidInference/kokoro-82m-coreml) into `~/Library/Application Support/Buddy/Voice`, plus six more English voice packs of about 0.5 MB each for the voice picker in settings (`af_bella`, `af_nicole`, `am_adam`, `am_michael`, `bf_emma`, `bm_george`). Then quit and reopen Buddy. Until the voice is installed and loaded, or if it fails, Buddy speaks with the Apple voice, and the settings window says why. FluidAudio, its text normalization library and the Kokoro weights are Apache-2.0. The pronunciation model and lexicon come from the same Apache-2.0 Core ML repository. To remove the voice, delete that folder.

## Run Buddy

Buddy opens its settings window on launch and has an icon in the macOS Dock, with no menu bar item. Closing the window leaves Buddy running for its shortcuts. Click the Dock icon or choose **Buddy > Settings…** to reopen it. Use **Buddy > Quit Buddy** or Command-Q to quit.

Use macOS 26 and Xcode 26. Open `Buddy.xcodeproj`, select the shared **Buddy** scheme, and run it. The project uses the owner's Apple Development team and bundle identifier `dev.steven.buddy`. To build it yourself, choose your own team under Signing & Capabilities.

To build from the terminal:

```sh
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-build build
open /tmp/buddy-build/Build/Products/Debug/Buddy.app
```

Keep the signed app at the same location for the permission-persistence check. Changing to ad-hoc signing does not verify permission persistence for the owner's build.

## Run tests

Domain policy and both talk adapters are a Swift 6 package with no AppKit dependency. Its Swift Testing tests drive the engine's public events and the adapter's public interface, and assert literal results. The app target remains in Swift 5 language mode with MainActor default isolation.

```sh
swift test --package-path BuddyCore
xcodebuild -project Buddy.xcodeproj -scheme Buddy -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/buddy-build test
```

Both adapters' tests replay output recorded from the real CLIs. The full Claude smoke group spends twelve small real turns on your sign-in; the Codex group spends two. The reopen/delete check alone spends five Claude turns (three talk turns and two summaries):

```sh
BUDDY_LIVE_CLAUDE=1 swift test --package-path BuddyCore --filter liveClaude
BUDDY_LIVE_CLAUDE=1 swift test --package-path BuddyCore --filter liveClaudeReopensItsOwnContextAndDeletesAnotherConversation
BUDDY_LIVE_CODEX=1 swift test --package-path BuddyCore --filter liveCodex
```

The Xcode suite preserves upstream's three permission-helper tests. Their legacy cached-screen helper is isolated from the live checklist. The template UI tests and upstream's remote packages are removed. FluidAudio, for the neural voice, is the only remote package.

See [baseline verification](docs/verification/issue-3.md) and [the first Claude turn](docs/verification/issue-5.md) for acceptance mappings and native runtime checks. Provider and voice work follows the project spec.

## Source

Upstream commit `e71105ce091d71dff4d89cf5d8d37ea1df460961` was imported as one snapshot without upstream history. Buddy is released under the [MIT License](LICENSE), which keeps upstream's notice. No code or assets come from the closed-source reference app. See [ADR 0004](docs/adr/0004-study-the-reference-app-never-copy-it.md).

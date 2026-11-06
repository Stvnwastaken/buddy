# Changelog

Buddy's version is `MARKETING_VERSION` in `Buddy.xcodeproj`, the same for the app and its tests. Before the MVP, versions stay below 1.0.0: fixes bump the patch number, and new features bump the minor number. 1.0.0 is reserved for the MVP. A version counts as released only once it is tagged `vX.Y.Z`.

## 0.1.0 (unreleased)

Buddy's first version, everything since the fork from farzaa/clicky.

- **Talk:** hold control + option and ask about your screen, or double-tap control and type in the notch. Answers come from your own Claude Code or Codex, optionally through CLIProxy with a chosen account and model, and use web search when the question needs current facts.
- **Voice:** each line is spoken in a local Kokoro neural voice as it arrives, with the Apple voice as fallback. Settings offers seven Kokoro voices, local previews, and a speed from 0.5× to 2×.
- **Pointing and drawing:** Buddy flies to what each line points at, and can annotate, write notes and draw on screen with pen sounds.
- **Notch:** a strip under the camera notch shows what Buddy heard, is thinking and says. Hover it to read the conversation, type a follow-up, start a new conversation, or reopen or delete a past one. Each past conversation shows when it started and when it was last active.
- **Memory:** conversations are saved and summarized so later ones keep context, and "remember that…" adds a note to your profile.
- **Shortcuts:** the push-to-talk and text box shortcuts can be changed in settings.
- **Agent runs:** start a request with "agent" to run Claude Code or Codex in the background, with a dock of run cards, approvals, run offers, provider fallback and screen takeover.

# Fork upstream Clicky instead of starting fresh

We build on the MIT-licensed farzaa/clicky codebase rather than a new Swift project. Upstream already solves push-to-talk via a CGEvent tap, multi-display ScreenCaptureKit capture, the click-through overlay, and pointing via POINT tags. We accept its weaknesses: a 1,000-line `CompanionManager`, untyped request JSON, near-zero tests, and Swift 5 language mode. Upstream is effectively unmaintained since April 2026, so we treat it as a one-time snapshot and never plan to merge from it again.

## Consequences

- The first work strips what we will never use: PostHog telemetry (it uploads full transcripts and replies), the email gate, the onboarding video and music, Sparkle, auto login-item registration, the Cloudflare worker, and the dead code.
- The upstream MIT license notice stays in the repo.

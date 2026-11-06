# Codex realtime voice

Spike for issue 23, run on 2026-11-01. The question was whether `codex app-server`'s experimental realtime voice works on the owner's ChatGPT sign-in well enough to power an optional, near-instant talk mode.

**Verdict: it works technically, but not well enough for a talk mode. No follow-up ticket.** A spoken question about a screenshot got a correct spoken answer on the ChatGPT sign-in. The realtime voice says a filler line a little before direct Codex talk starts its answer today. But even in the best runs, where an earlier turn had already sent the screen, the real answer arrived 4.5 to 5.5 seconds after the question ended, and about 8 seconds in the others. Direct Codex talk takes about 2.7 to 2.9 seconds today. On top of that, realtime voice needs a WebRTC stack in the app, gets the screen only through a normal Codex turn, rewrites the answer before speaking it, and depends on an alpha protocol. Reasons and numbers are below.

The throwaway code is on the `prototype/codex-realtime-voice` branch. None of it is product code.

## Setup

- Codex CLI 0.166.0 on macOS 26, signed in with ChatGPT (`account/read` reported `chatgpt`).
- Launched with the same overrides as `CodexLaunch.talk`, plus `capabilities.experimentalApi: true` in `initialize`. Every `thread/realtime/*` method and field is marked EXPERIMENTAL in the generated protocol (`codex app-server generate-ts --experimental`).
- An ephemeral, read-only thread with Buddy-style base instructions and the owner's MCP servers off, as in ADR 0006. The thread model was `gpt-6.1-sol`, talk's model, except in the first run.
- The question was `say -v Samantha "What do I click to keep my changes?"`, 2.1 seconds of speech. The screenshot was a synthetic 1280 × 800 Save dialog whose Save button is centred on pixel 860, 515.
- The client was a Python script using `aiortc`, sending the speech as the microphone track and recording the voice that came back.

## What the protocol offers

Client requests: `thread/realtime/start`, `appendAudio`, `appendText`, `appendSpeech`, `listVoices` and `stop`. Server notifications include `started`, `sdp`, `transcript/delta`, `transcript/done`, `itemAdded`, `outputAudio/delta`, `error` and `closed`. `start` takes a transport (`websocket`, `webrtc` with an SDP offer, or `existingCall`), a protocol version (`v1`, `v2` or `v3`), an output modality (`text` or `audio`), a voice and some handoff options.

No realtime method takes an image. The realtime voice model hands each question to the thread's own Codex model, here called a delegation, and speaks that model's answer. The screen can only reach that model as part of a normal turn on the thread.

## What the ChatGPT sign-in allows

| Transport and version | Result |
| --- | --- |
| websocket, any version, audio | `thread/realtime/error`: "realtime conversation requires API key auth" |
| websocket, `v2`, text | Same error. Text output is only allowed on `v2`. |
| webrtc, `v1` or default | Refused by OpenAI: "AVAS requires OpenAI-Alpha: quicksilver=v2." |
| webrtc, `v2`, audio or text | `thread/realtime/error`: "AVAS realtime calls require realtime v1 or v3" |
| webrtc, `v3` | Accepted. `started`, then `sdp` with the answer, about 1 to 2.3 seconds after `start`. |

Only WebRTC with v3 works on a subscription. With it, the audio goes directly between the client and OpenAI. Codex passes on the SDP offer and answer and runs the delegations. `appendAudio` and `outputAudio/delta` belong to the websocket transport, which needs an API key, so they are ruled out by ADR 0002.

## Runs

Times are taken from the realtime data channel and the app server log. "After speech" counts from the end of the question's audio, which corresponds to releasing push-to-talk. "Filler" is the line the voice says while it waits for Codex.

| Run | Screen | Filler after speech | Answer after speech | Codex delegation | Codex answered | Spoken |
| --- | --- | --- | --- | --- | --- | --- |
| plain | none | 2.2 s | about 8 s | 6.5 s, `gpt-6-astra` | "Can you share a screenshot of the dialog so I can point to the button that keeps your changes?" | "I'll take a quick look. Click save to keep your changes." |
| primed 1 | earlier turn | 1.9 s | 4.5 s | 1.2 s | `[POINT:860,516:Save] Click Save to keep your changes.` | "I'll take a quick look and point out the right button. Click Save." |
| primed 2 | earlier turn | 1.7 s | 5.1 s | 3.0 s | `[POINT:860,516:Save] Click Save to keep your changes.` | "Looking at it now. Click Save." |
| primed 3 | earlier turn | 2.7 s | 5.5 s | 2.2 s | `[POINT:860,516:Save] Click the blue Save button to keep your changes.` | "I'll take a look. Click the blue Save button." |
| client | sent at handoff | 2.0 s | about 8 s | 5.6 s | `[POINT:860,516:Save] Click the blue Save button to keep your changes.` | "I'll take a quick look at what you're seeing. Click the blue Save button." |

- **Primed** means a normal `turn/start` with the screenshot ran first ("Reply only OK"), which took 2.3 to 3.4 seconds, before realtime started. The delegation's Codex model could then see the screen and pointed one pixel from the Save button's centre each time.
- **Client** set `clientManagedHandoffs`. Codex still started its own delegated turn. Buddy's `turn/start` with the screenshot was added to that turn, and the answer was then sent with `appendSpeech`. The voice started 1.0 second after `appendSpeech`.
- The realtime service decides when the question is over. The last transcribed word arrived 0.9 to 1.2 seconds after the speech ended. The protocol has no request to end the question early, as releasing push-to-talk does now.
- Realtime calls report usage as `audio_duration_ms` (14.2 to 14.4 seconds per run), with an empty `backend_model_usage` and a null `usage_limit`. How voice minutes count against the ChatGPT plan is unknown. Each delegation is also a normal Codex turn.
- All runs were stable. Every realtime call started, answered and closed on `thread/realtime/stop`, with no errors or dropped connections. The sample is small: five calls of 20 to 40 seconds, each with one question. Long calls, reconnects and interrupting the voice were not tried.

## Compared with talk today

Buddy has no end-to-end measurement of talk today, so these figures come from separate measurements. From releasing push-to-talk, the transcript and capture take about 126 ms (issue 5). A one-line Codex reply completes 2,375 ms after the turn is sent (issue 10). The neural voice starts the line 150 to 423 ms later (issue 21). That puts the first sound of the real answer at about 2.7 to 2.9 seconds on direct Codex, and about 1.6 to 1.9 seconds on direct Claude.

Realtime's filler sounds 1.7 to 2.7 seconds after the question, a little before direct Codex's answer starts today. Its real answer comes 1.6 to 2.8 seconds later than direct Codex's in the primed runs, not counting the priming turn, because the voice model has to wait for the question to end, hand it over, and wait for the Codex turn.

## Why it doesn't fit a talk mode

- **Not near-instant.** It is only quick to say "I'll take a look". Speeding up the answer would need the screen to reach the voice model, and no realtime method takes an image.
- **The screen arrives the slow way.** Codex only sees the screen through a normal turn. Priming that turn while the owner speaks would add a turn per question. Sending it at the handoff, as in the client run, is slower still. Buddy captures the screen as the question ends, and the realtime answer would have to wait for that capture.
- **The answer is rewritten.** The voice model rewords Codex's reply and drops its tags (`[POINT:860,516:Save] Click Save to keep your changes.` became "I'll take a quick look and point out the right button. Click Save."). Beats would no longer line up: Buddy could still point from the delegation's text, but not on the line that talks about the thing. Annotations, targets, walkthroughs, draw programs and run offers would lose their timing in the same way.
- **The voice model makes things up.** Without the screen, Codex asked for a screenshot, but the voice said "Click save to keep your changes" anyway. Buddy couldn't check that the spoken words match the answer it shows.
- **It needs WebRTC in the app.** macOS has no public WebRTC framework, so Buddy would need Google's WebRTC library or something like it, a second remote package alongside FluidAudio. It would also need to stream the microphone through it for as long as realtime is on, with echo cancellation, and play the voice with its own audio route. That would replace both the on-device ears from issue 7 and the neural voice from issue 21.
- **The protocol is alpha.** Every field is experimental. The only transport allowed on a subscription is v3, which the binary calls "frameless bidi". The v1 error names an alpha header. Any Codex release could change or close it. ADR 0006 already accepts the risk of driving Codex through its app server, but this would go further, onto a surface OpenAI labels as unfinished.
- **Usage is opaque.** Each realtime call reports only its seconds of audio, with no figures Buddy's routing could read. A plan may also limit voice separately from its five-hour and weekly windows.

## Revisit when

Any of these would change the answer, and each can be checked again with the prototype branch:

- A realtime method takes an image, or the voice model can see the thread's latest image without a turn.
- The websocket transport accepts a ChatGPT sign-in, so audio flows through `appendAudio` and `outputAudio/delta` and Buddy needs no WebRTC.
- The voice can be told to speak the delegation's text word for word, so beats keep their tags.

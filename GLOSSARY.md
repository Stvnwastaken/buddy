# Buddy

A personal macOS buddy that lives next to the cursor. When summoned it sees the screen, talks back, points and draws on screen, and can operate apps for its owner.

## Language

### The buddy

**Buddy**:
The on-screen companion that follows the cursor and speaks for the app.
_Avoid_: companion, assistant, Clicky

**Owner**:
The one person who runs the app on their own Mac with their own AI subscriptions.
_Avoid_: user, customer, account

**Push-to-talk**:
Holding the hotkey. The only time the buddy listens.
_Avoid_: wake, activate, summon

**Notch**:
The strip at the top center of the screen where the buddy shows the conversation as text: the owner's words, the buddy's replies and its notices. It opens a little on its own while the buddy talks, and opens fully when the owner hovers over it. On a screen without a camera notch it hangs from the menu bar in the same shape.
_Avoid_: island, bubble, chat window

**Text box**:
The field at the bottom of the notch, opened by hovering over the notch or double-tapping Control, where the owner types a question instead of speaking it.
_Avoid_: prompt bar, chat input, search field

**Turn**:
One request, spoken during push-to-talk or typed in the text box, until the buddy finishes responding.
_Avoid_: message, exchange, interaction

**Provider**:
One of the owner's AI subscriptions the buddy can think with, either Claude or Codex.
_Avoid_: backend, model, LLM

**Headroom**:
The share of a provider's usage limit still unused, measured in its tightest window.
_Avoid_: quota, credits, balance

**Provider choice**:
Which provider answers talk with direct sign-ins: Auto, where each turn goes to the provider with more headroom, or Claude or Codex, which forces that provider. Not the same Auto as the approval mode's.
_Avoid_: model picker, backend switch

**Provider account**:
One of the owner's subscription sign-ins known to their CLIProxy hub. A provider can have several accounts, and Buddy can select one without changing the sign-in used by other apps.
_Avoid_: app account, Buddy account

**Screen capture**:
The images of every display, taken as the owner finishes asking a turn's question. The buddy never looks at the screen otherwise.
_Avoid_: recording, screen share

### What the buddy does

**Talk**:
The buddy answering a turn aloud.
_Avoid_: chat, voice mode

**Neural voice**:
The natural voice the buddy speaks in by default, generated on the Mac.
_Avoid_: TTS, Kokoro voice

**Apple voice**:
The macOS system voice, used whenever the neural voice isn't ready, isn't installed or fails a line.
_Avoid_: fallback voice, system TTS

**Web search**:
The provider looking something up online during a talk turn, when the question needs current information such as news or weather. If the buddy hasn't said anything yet, it speaks a short cue while the search runs.
_Avoid_: browsing, lookup

**Point**:
The buddy flying to a location on screen to show where something is.
_Avoid_: navigate, highlight

**Annotation**:
A mark the buddy draws on screen while it talks, such as an arrow, ring, highlight or label. It stays up after the reply until the next turn starts, the owner presses Esc or clears history.
_Avoid_: drawing, markup, overlay

**Target**:
A ring around something the owner should click. The buddy's next line waits until they click inside it.
_Avoid_: hotspot, click target

**Walkthrough**:
A reply that guides the owner through a task one click at a time with targets, asking again with a fresh look at the screen after the last one.
_Avoid_: tutorial, tour, guide

**Dictation**:
Speech transcribed and inserted into the focused app, with no answer from the buddy.
_Avoid_: transcription, voice typing

**Beat**:
One spoken line of a reply together with the tags or marks that fire while it plays.
_Avoid_: step, segment

**Draw program**:
A small program the buddy writes to produce annotations, which the app runs in a sandbox.
_Avoid_: script, drawing code

**Agent run**:
A task the buddy carries out in the background by operating apps for the owner. Several can be in progress at once.
_Avoid_: agent mode, automation, job

**Run offer**:
A line of a reply that asks whether to do a task as an agent run, carrying the brief the run would start from. A yes on the owner's next turn starts the run; anything else drops the offer.
_Avoid_: suggestion, proposal

**Screen takeover**:
The part of an agent run in which the buddy controls the mouse and keyboard, after the owner consents on the run's card. Only one run holds the screen at a time. The owner's own input is blocked until it ends, and Esc or push-to-talk takes control back at once.
_Avoid_: computer use, remote control

**Approval**:
The owner's yes or no, clicked on a run's card, for something the run may only do with consent, such as sending, posting, buying or deleting. A run waiting for an approval or an answer to its question needs the owner.
_Avoid_: permission, confirmation

**Approval mode**:
How much of an agent run the owner approves by hand: Auto, where the approval policy decides and asks about what it can't allow; Approve only, where every command and file change asks the owner; or YOLO, where everything is allowed. A run keeps the mode it started with.
_Avoid_: privacy mode, permission mode

**Run note**:
The live progress note an agent run keeps: a heading that names the run, then its plan, its current step and any question for the owner. The heading is the name on the run's card.
_Avoid_: status, log

**Dock**:
The strip at the screen edge holding one card per agent run, each showing its run note.
_Avoid_: sidebar, notch, panel

### What the buddy remembers

**Conversation**:
A run of turns that ends after a stretch of idle time or when the owner asks for a new one. The owner can reopen a past conversation from the notch and continue it.
_Avoid_: session, chat, thread

**History**:
The text record of past turns, kept across launches.
_Avoid_: memory, transcript, log

**Conversation summary**:
A short text summary of a conversation, finished when the conversation ends so later conversations have context. A long conversation keeps its summary up to date with the turns too old to prime a fresh provider process.
_Avoid_: memory, recap

**Utility model**:
The small fast model that writes conversation summaries, on the same provider and account as talk.
_Avoid_: helper model, background model

**Profile**:
The owner's "about you" notes, changed only when the owner asks the buddy to remember or forget something.
_Avoid_: memory, user data

### Sources

**Upstream**:
The open-source farzaa/clicky codebase this app is forked from.
_Avoid_: original, base

**Reference app**:
HeyClicky, the closed-source app whose behavior Buddy aims to match without copying any of it.
_Avoid_: target, competitor

# Draw program API proposal

Status: approved by the owner on 2026-11-01, as proposed in issue 31.

A draw program is a short JavaScript program that Buddy writes in place of a plain reply when a picture explains better than words. The app runs it in a sandbox. The program says what Buddy speaks and what it draws. It can't draw anything itself. Its calls record beats and marks, and the app redraws the recorded marks natively, in time with the voice. This API was written from scratch for Buddy. Nothing in it comes from the reference app (ADR 0004).

## Shape of a reply

The model is told to make a draw program its whole reply. It starts with a line that is only ```` ```draw ````, and everything up to the next line that is only ```` ``` ```` is the program. Anything after that line is ignored. If the model writes lines before the fence anyway, they are spoken first as plain beats, so the program is never read aloud. A reply with no fence is plain beats with tags, as before. A program still open when the reply ends runs then.

The app runs the program as soon as its closing fence arrives. Nothing is spoken until then, because a program can't run before it is complete.

## The program's world

A program sees the screenshot of the screen with the cursor, in that screenshot's pixels, counted from its top-left corner. This is the same space that tags use. A program can draw on one screen only.

| Name | What it does |
| --- | --- |
| `canvas` | `{ width, height }` of that screenshot, in pixels. |
| `beat(line)` | Starts the next beat. `line` is one sentence that Buddy speaks. Marks drawn after it belong to it. |
| `stroke(points)` | A freehand line through `points`, given as `[[x, y], ...]` with at least two points. |
| `arrow(x1, y1, x2, y2)` | An arrow from its tail at `x1, y1` to its head at `x2, y2`. |
| `ring(x1, y1, x2, y2)` | Circles the box with these opposite corners. |
| `text(words, x, y, size)` | Writes `words` with their top-left corner at `x, y`. `size` is the font size in pixels, 32 by default. |
| `handwriting(words, x, y, size)` | Writes in the bundled Patrick Hand font, with the same position and size rules as `text`. |
| `measureHandwriting(words, size)` | Returns `{ width, height }` for Patrick Hand, for positioning handwriting and marks around it. |
| `sticky(words, x, y, width, size)` | A yellow sticky note with wrapped handwriting. Its top-left corner is `x, y`. Width defaults to 240 pixels and font size to 32. |
| `card(words, x, y, width, size)` | A cream paper card with wrapped handwriting. Width defaults to 420 pixels and font size to 32. |
| `measureText(words, size)` | Returns `{ width, height }`: the box that `text(words, x, y, size)` fills. |
| `measurePath(points)` | Returns `{ length, left, top, right, bottom }` for the straight segments through `points`. |

Each mark belongs to the beat before it, and a mark before the first `beat` is an error. A beat with no marks is fine. It is just spoken.

### Example

```js
beat("A web address has three parts.");
const url = "https://example.com/docs";
const size = 44;
const x = 120, y = 160;
text(url, x, y, size);
const scheme = measureText("https://", size).width;
const host = measureText("example.com", size).width;
const h = measureText(url, size).height;
beat("The scheme says how to talk to the server.");
ring(x, y, x + scheme, y + h);
beat("The host names the server.");
stroke([[x + scheme, y + h + 8], [x + scheme + host, y + h + 8]]);
beat("And the path is the page on that server.");
arrow(x + scheme + host + 120, y + h + 90, x + scheme + host + 40, y + h + 10);
```

## How it plays

Each recorded beat becomes one spoken line. When the voice starts a line, its marks start drawing. Within a line, each mark strokes on after the one before it, at a steady pen speed, so a line with three marks draws them in order. Each mark takes 0.25 to 1.2 s. The text wipes on from left to right. The next line's marks start with that line, even if the last line's marks are still drawing. With Reduce Motion, marks appear at once.

The marks are drawn with Core Animation on the existing click-through overlay windows, beneath the buddy and its tag annotations. They count as annotations, so they stay up after the reply and clear when the next turn starts, on Esc, or when the owner clears history.

Sticky notes and cards use separate native panels. Only their paper takes clicks; the screen around them remains click-through. Drag a paper by its header, close it with its cross, or pin it with its pin. An unpinned paper clears on the next turn. A pinned paper stays until unpinned and another turn starts, closed, Esc, Clear History, or app exit. Pinning is the owner's choice, never the program's. Papers fit within the display when first shown and scroll if their text outgrows it.

Paper and handwriting marks share the existing mark queue and its `revealDuration`. Text and handwriting use their exact glyph-path width at 500 points per second. A paper uses its width at the same speed. Durations stay between 0.25 and 1.2 seconds. Reduce Motion shows all marks at once. Paper placement stays silent while preserving the timing of later strokes.

### Handwritten explanation

```js
beat("Three quarters means three of four equal parts.");
card("3 / 4 means three of four equal parts. The bottom number counts all the parts. The top number counts the parts we have.", 160, 140, 460, 36);
beat("The whole is split into four, and we keep three.");
sticky("Same-sized parts make a fair fraction.", 680, 160, 280, 30);
handwriting("3 out of 4", 180, 510, 40);
```

Patrick Hand comes from [Google Fonts' official repository](https://github.com/google/fonts/tree/main/ofl/patrickhand). The unmodified font, SIL Open Font License 1.1, and source record ship in BuddyCore's resource bundle. The app registers it only for its own process. No font or other asset comes from the reference app.

Strokes, arrows, rings and handwriting make Buddy's own synthesized paper scratch for their reveal duration. Text and paper placement are silent but keep their place in the mark sequence. **Pen sounds** in settings turns these sounds off independently of spoken replies, saves the choice across launches, and stops sounds already playing or waiting. Clearing the marks stops their sounds too. With Reduce Motion, the marks appear together and make short scratches together.

## The sandbox

- Each program runs in a fresh JavaScriptCore context in its own context group. It has the language's built-in objects and the functions above, and nothing else. There is no file, network, timer, module or app bridge. `console` and `WebAssembly` are removed.
- The program has 0.5 s of execution time. JavaScriptCore stops it when that runs out, including in an endless loop inside `try`. The time limit uses `JSContextGroupSetExecutionTimeLimit`. That function is exported by JavaScriptCore, but it isn't in the public headers, so the app looks it up at run time. If it's missing, no program runs.
- A program can have at most 30 beats and 200 marks. A stroke can have at most 500 points. A line can have at most 300 characters, and a text mark at most 200. Every number must be finite.
- A program that throws, runs out of time, breaks a limit or speaks no beats draws nothing. Buddy shows a short notice instead, and the turn ends.

## Choosing a program or beats

The system prompt teaches this API next to the tags and leaves the choice to the model. A reply about the screen uses beats and tags. A reply that explains how something is built or how parts connect can be a draw program.

## Left for later

- Drawing on a screen other than the cursor's, and pointing the buddy from a program.
- Streaming: the first line waits for the whole program.
- A memory limit. A program could still allocate a lot of memory within its time.

# The owner picks how much of a run they approve by hand

The owner picks an approval mode for agent runs in the panel's "Agent runs" card. A run keeps the mode it started with, including when Auto switches its provider at a usage limit (issue 30). The choice is saved as `runApprovalMode`.

- **Auto** is the approval policy as before. It allows what is safe, denies what the run must do another way, and asks the owner about the rest.
- **Approve only** asks the owner on the run card before every command and file change, including ones Auto would allow. Reads and Buddy's own tools still go through, and what Auto denies stays denied.
- **YOLO** allows every request without asking, including what Auto would deny, such as `cd`, unchecked shell syntax, deleting the owner's files, sending and network commands.

## Consequences

- YOLO removes the only gate on a run. A Codex run has full disk access (ADR 0007), so in YOLO nothing stops it from changing any of the owner's files. A Claude run is limited to the tools Buddy offers it, but those include its shell, so it can reach as far. The panel shows YOLO's caption in red.
- Approve only asks about every command, including `ls`. Codex asks Buddy about every command, and a Claude run's `permissions.ask` rules send every shell use through Buddy (issue 24).
- Each mode has its own run instructions, chosen when the run starts. Auto's describe what Buddy checks. Approve only's add that every command and file change waits on the card. YOLO's drop Buddy's checks, such as using paths instead of `cd`, because a live YOLO run on Codex refused a `cd` that YOLO would have allowed while its instructions still forbade it.
- The mode is read when a request arrives, from the run, so changing it doesn't touch a run that is already going or the asks it is waiting on.

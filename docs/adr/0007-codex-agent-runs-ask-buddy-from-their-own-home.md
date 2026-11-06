# Codex agent runs ask Buddy before every command, from their own Codex home

The owner can choose Codex for new agent runs. Each run is one `codex app-server` child process with one ephemeral thread in the run folder. It gets the same run instructions and Buddy MCP server as a Claude run, and the same approval policy judges its requests.

Codex's sandbox can't be the boundary. With Codex 0.166.0, `osascript` addressing System Events or Finder fails with error -10827 under both `read-only` and `workspace-write`, and works only under `danger-full-access`. Runs read apps with AppleScript, so a run thread uses `danger-full-access`. Buddy's approval policy is the boundary instead, as it is for Claude runs. The run folder is set as an `untrusted` project in the thread's config. With that setting, Codex sends a `requestApproval` for every command and every patch, including `ls`. Buddy starts the brief only after the thread reports that it will ask: its approval policy must be `untrusted` and its approvals reviewer `user`.

Rules in the owner's `~/.codex/rules` allow listed command prefixes without asking, such as `curl -s`, `rm`, `mv` and `gh issue`. In the owner's own Codex home, a run ran `curl -s -I` with no approval request. So runs use Buddy's own Codex home in `Application Support/Buddy/Codex run home`. It holds only symlinks to the owner's `auth.json` and `auth.lock`. Codex 0.166.0 saves a refreshed token by opening `auth.json` in place, which writes through the link into the owner's file under the owner's lock. Their terminal Codex and Buddy's runs therefore keep one sign-in instead of drifting copies (the reason ADR 0006 kept talk in the owner's home). No owner config, rules, MCP servers, hooks, skills or `AGENTS.md` reach a run.

## Consequences

- A denial is a `decline` that tells the run nothing more, so Buddy steers the turn with "Buddy declined `<action>`." and the reason. A live run saw the steer, didn't retry and said so in its report.
- Codex shows a command as `/bin/zsh -lc <script>`. The policy judges the script. A command run from any folder but the run folder is judged as a `cd` there first, which the policy denies. A patch is judged file by file, and a moved file counts as a delete of the old path plus a write of the new one.
- Codex approves Buddy's own MCP tools itself, with `default_tools_approval_mode = "approve"`, because the policy allows them anyway. The token reaches Codex through `BUDDY_MCP_TOKEN`, and the shell environment policy keeps it from commands.
- Runs that Codex writes in shell syntax Buddy can't check, such as a subshell for `set -o noclobber`, wait for the owner. The run instructions now name the subset Buddy checks.
- If Codex changes how it saves `auth.json`, for example to an atomic rename, the link would become a copy and could drift. Buddy then keeps that copy, since its token may be the only valid one, and Codex runs stop with a notice until the owner sorts it out. Recheck this after a Codex upgrade.

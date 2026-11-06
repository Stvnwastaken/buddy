# Direct Codex talk through its app server

With **Use CLIProxy** off and Codex chosen, talk runs on one long-lived `codex app-server` child process signed in with the owner's ChatGPT login. This is the Codex counterpart of ADR 0005's direct Claude option, and it restores ADR 0003's Codex adapter for that case. Through CLIProxy, both providers still speak the Claude stream-json transport.

The owner's Codex config sets a custom proxy provider, so every launch forces Codex's built-in OpenAI provider with `-c model_provider="openai"` and removes the owner's `OPENAI_*` and `CODEX_*` variables, except `CODEX_HOME`. Each conversation is one ephemeral thread with Buddy's talk instructions, Codex's default model, a read-only sandbox, no approvals, and every MCP server in the owner's config turned off. Its first turn carries the conversation's recent turns. A conversation boundary starts a fresh thread on the same process, and a new process starts priming again. Each turn's screenshots are temporary files, deleted when the turn ends or the process stops. Buddy refuses every request the server sends.

## Consequences

- Buddy keeps the owner's Codex home to reuse their sign-in and its token refresh, so Codex 0.166.0 still reads the owner's global `AGENTS.md` on every fresh thread. A separate home with a copied sign-in would avoid that, but the copied token could drift from the owner's terminal Codex.
- The overrides turn off hooks, plugins, apps, skills and the tools they can name. Since issue 16, talk turns web search on in its live mode and the utility model keeps it off. Codex's default model still keeps some built-in tools that no override removes, and Buddy's refusal of server requests does not reach tools implemented inside Codex.
- The read-only sandbox limits writes. It does not prevent reading local files, so screen content can still steer a provider that has local read access.
- Talk's choice doesn't pick the CLI for agent runs. The owner chooses that separately, and Codex runs follow ADR 0007. With direct sign-ins, the engine routes each talk turn between Claude and Codex by headroom.

# Think through the owner's own CLIs, routed by remaining usage

The buddy thinks through two providers: a long-lived `claude -p` stream-json child process and a long-lived `codex app-server` child process. Each turn goes to whichever has more usage left, staying on the current provider unless the other leads by a clear margin, so its warm process isn't lost to every small difference (issue 11 sets it at 15 points). Both run on the owner's own sign-in, launched with a clean environment that skips the owner's user settings and proxy. We rejected the Claude Agent SDK, because Anthropic discourages subscription login there, and the owner's tailnet proxy, which measured 2 to 3 times slower and fails off the tailnet. Talk-turn latency comes from keeping each child process warm, not from a server.

## Consequences

- Conversation history is the app's own provider-neutral record. Neither CLI's session store is the source of truth, because a conversation can move between providers mid-stream.
- Claude reports usage only inside a turn (`rate_limit_event`, 5-hour and 7-day utilization). Codex can be asked at any time (`account/rateLimits/read`). The router has to work from Claude's last reported figure.
- Agent tools live in one MCP server inside the app, so both providers can drive them.

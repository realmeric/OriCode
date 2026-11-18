/// The Agent SDK, imported when something first needs it. Its 1.6 MB of code is neither read nor
/// compiled nor held by the engine until Claude Code is first asked something it doesn't remember:
/// a launch that answers hello from the cache, and every other agent's threads, never load it.
export const sdk = () => import("@anthropic-ai/claude-agent-sdk");

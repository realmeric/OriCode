import type { Model } from "./models.ts";
import type { Provider } from "./provider.ts";
import type { Ray } from "./rays.ts";

// Workflows at any level. Claude Code runs its own: Ultracode at xhigh, and at any other level the
// Workflow tool, which it opens only on the user's own ask, so each message carries one. Codex runs
// its own `ultra` at Max on the models that have it. On any other model with levels whose agent
// can be a head, workflows are OriCode's own, on Rays: the head plans the task, sends its parts out
// to workers on its rays, or on its own model when the thread has none, checks what they bring and
// merges it, all at the thread's own level.

/// An agent's levels, ending in `ultracode` when it can run workflows: hello's way of saying so.
export function levels(agent: Provider): string[] {
  const own = agent.levels;
  return agent.capabilities.workers && own.length && !own.includes("ultracode") ? [...own, "ultracode"] : own;
}

/// An agent's models with OriCode's workflows on each one that has levels and no workflows of its
/// own, when the agent can be a head.
export function onRays(agent: Provider, models: Model[]): Model[] {
  if (!agent.capabilities.workers) return models;
  return models.map((model) => (model.ultra || !model.efforts.length ? model : { ...model, ultra: true, ultraRays: true }));
}

/// What goes ahead of each message a Claude Code head gets while workflows are on below xhigh.
/// Claude Code opens its Workflow tool only when the user asks in their own words; told so in the
/// system prompt, or asked for "every substantive task", Sonnet did three test files itself, and
/// told this, it ran a workflow for them and still answered a one-line question alone.
export const claudeLead = "[Workflows on] I turned workflows on for this thread, so use a workflow for this. Only a conversational turn, or a question you can answer in a line, goes without one.";

/// What goes ahead of each message an OriCode head gets while workflows are on. A real Codex head
/// told only in its developer instructions did every part itself; told with the message, it handed
/// them out.
export const lead = "[Workflows on] Hand this out: start a worker for each part with start_worker, then check what they bring and merge it.";

/// What the head is told in place of the rays' own brief while workflows are on.
export function brief(rays: Ray[]): string {
  return (
    `You are this thread's head, and workflows are on: you plan, workers do the work, and you check and merge it. Split each task into parts that can go on at once and start a worker for each with start_worker on these rays, as its agent and model: ${rays.map((ray) => `${ray.agent} ${ray.model}`).join(", ")}. ` +
    "Workers that edit files work isolated. Check what each brings back with worker_result, merge_worker what holds up, and answer with the merged result. " +
    "These tools are the oricode MCP server's; if they aren't among yours yet, load them with tool_search."
  );
}

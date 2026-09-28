import type { Model } from "./models.ts";
import type { Provider } from "./provider.ts";
import type { Ray } from "./rays.ts";

// OriCode's own Ultracode, on Rays. Claude Code's Ultracode is its workflows and Codex's is a
// model's `ultra`; on any other model with levels whose agent can be a head, Ultracode is the head
// planning the task, sending its parts out to workers on its rays, or on its own model when the
// thread has none, checking what they bring and merging it. The head hears it where it hears of
// its rays, and runs at xhigh itself, as Claude Code runs its own Ultracode.

/// An agent's levels with Ultracode at the top, when it can be a head and has levels to top.
export function levels(agent: Provider): string[] {
  const own = agent.levels;
  return agent.capabilities.workers && own.length && !own.includes("ultracode") ? [...own, "ultracode"] : own;
}

/// An agent's models with OriCode's Ultracode on each one that has levels and no Ultracode of its
/// own, when the agent can be a head.
export function onRays(agent: Provider, models: Model[]): Model[] {
  if (!agent.capabilities.workers) return models;
  return models.map((model) => (model.ultra || !model.efforts.length ? model : { ...model, ultra: true, ultraRays: true }));
}

/// The level the head runs at: xhigh, or the model's highest below it.
export function headLevel(model: Model): string | undefined {
  return model.efforts.includes("xhigh") ? "xhigh" : model.efforts.findLast((level) => level !== "max");
}

/// What goes ahead of each message the head gets while Ultracode is on. A real Codex head told
/// only in its developer instructions did every part itself; told with the message, it handed
/// them out.
export const lead = "[Ultracode] Hand this out: start a worker for each part with start_worker, then check what they bring and merge it.";

/// What the head is told in place of the rays' own brief while Ultracode is on.
export function brief(rays: Ray[]): string {
  return (
    `You are this thread's head, and Ultracode is on: you plan, workers do the work, and you check and merge it. Split each task into parts that can go on at once and start a worker for each with start_worker on these rays, as its agent and model: ${rays.map((ray) => `${ray.agent} ${ray.model}`).join(", ")}. ` +
    "Workers that edit files work isolated. Check what each brings back with worker_result, merge_worker what holds up, and answer with the merged result. " +
    "These tools are the oricode MCP server's; if they aren't among yours yet, load them with tool_search."
  );
}

/// A workflow's run as the app draws it. While one runs, the CLI's task_progress messages carry
/// `workflow_progress`, a snapshot of its phases and agents that the SDK's published types
/// leave out: `workflow_phase` entries as each phase is first used, `workflow_agent` entries
/// for the agents, and `workflow_log` lines, which the app doesn't show.

export type WorkflowAgent = {
  label: string;
  phase: string;
  state: "queued" | "running" | "done" | "failed";
  tokens: number;
  tools: number;
  /// The tool it's on, or last used, and what it was used on.
  lastTool: string | null;
  lastDetail: string | null;
  error: string | null;
};

export type WorkflowShape = { phases: string[]; agents: WorkflowAgent[] };

type Entry = Record<string, unknown>;

export function workflowShape(progress: unknown[]): WorkflowShape {
  const entries = progress.filter((entry): entry is Entry => typeof entry === "object" && entry !== null);
  const of = (type: string) => entries.filter((entry) => entry.type === type).sort((a, b) => number(a.index) - number(b.index));
  return {
    phases: of("workflow_phase").map((phase) => text(phase.title) ?? ""),
    agents: of("workflow_agent").map((agent) => ({
      label: text(agent.label) ?? text(agent.agentType) ?? "agent",
      phase: text(agent.phaseTitle) ?? "",
      state: state(agent),
      tokens: number(agent.tokens),
      tools: number(agent.toolCalls),
      lastTool: text(agent.lastToolName),
      lastDetail: text(agent.lastToolSummary)?.slice(0, 160) ?? null,
      error: text(agent.error)?.slice(0, 300) ?? null,
    })),
  };
}

/// An agent that has only been queued starts with a `start` entry and no `startedAt` yet.
function state(agent: Entry): WorkflowAgent["state"] {
  switch (agent.state) {
    case "done":
      return "done";
    case "error":
      return "failed";
    case "progress":
      return "running";
    default:
      return agent.startedAt ? "running" : "queued";
  }
}

function text(value: unknown): string | null {
  return typeof value === "string" && value !== "" ? value : null;
}

function number(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

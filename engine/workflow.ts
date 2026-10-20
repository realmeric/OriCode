/// A workflow's run as the app draws it. While one runs, the CLI's task_progress messages carry
/// `workflow_progress`, a snapshot of its phases and agents that the SDK's published types
/// leave out: `workflow_phase` entries as each phase is first used, `workflow_agent` entries
/// for the agents, and `workflow_log` lines, which the app doesn't show. An agent's own
/// transcript never comes through the SDK; the CLI writes it to the run's transcript folder as
/// agent-<agentId>.jsonl, which engine/follow.ts reads while the app shows that agent.

import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { progressLine } from "./progress.ts";

export type WorkflowAgent = {
  /// Claude Code's id for it, from the moment it starts; a queued agent has none yet.
  agentId: string | null;
  label: string;
  phase: string;
  state: "queued" | "running" | "done" | "failed";
  tokens: number;
  tools: number;
  /// The tool it's on, or last used, and what it was used on.
  lastTool: string | null;
  lastDetail: string | null;
  error: string | null;
  model: string | null;
  /// The start of what it returned, which the CLI cuts at about 400 characters.
  result: string | null;
};

export type WorkflowShape = { phases: string[]; agents: WorkflowAgent[] };

type Entry = Record<string, unknown>;

export function workflowShape(progress: unknown[]): WorkflowShape {
  const entries = progress.filter((entry): entry is Entry => typeof entry === "object" && entry !== null);
  const of = (type: string) => entries.filter((entry) => entry.type === type).sort((a, b) => number(a.index) - number(b.index));
  return {
    phases: of("workflow_phase").map((phase) => text(phase.title) ?? ""),
    agents: of("workflow_agent").map((agent) => ({
      agentId: text(agent.agentId),
      label: text(agent.label) ?? text(agent.agentType) ?? "agent",
      phase: text(agent.phaseTitle) ?? "",
      state: state(agent),
      tokens: number(agent.tokens),
      tools: number(agent.toolCalls),
      lastTool: text(agent.lastToolName),
      lastDetail: text(agent.lastToolSummary)?.slice(0, 160) ?? null,
      error: text(agent.error)?.slice(0, 300) ?? null,
      model: text(agent.model),
      result: text(agent.resultPreview)?.slice(0, 400) ?? null,
    })),
  };
}

/// The run's last snapshot once it has ended, which the CLI sends no more of: every agent with
/// what it returned. A run that ended by itself writes it to its task's output file; a stopped
/// one leaves that empty, and the run's record beside the session, workflows/<runId>.json, has it.
/// The transcript folder is <session>/subagents/workflows/<runId>.
export async function finalShape(outputFile: string | null, transcriptDir: string | null): Promise<WorkflowShape | undefined> {
  const record = transcriptDir ? join(dirname(dirname(dirname(transcriptDir))), "workflows", `${transcriptDir.split("/").pop()}.json`) : null;
  for (const path of [outputFile, record]) {
    if (!path) continue;
    try {
      const progress = (JSON.parse(await readFile(path, "utf8")) as { workflowProgress?: unknown }).workflowProgress;
      if (Array.isArray(progress)) return workflowShape(progress);
    } catch {
      // Not written, or not this run's JSON.
    }
  }
  return undefined;
}

/// How far a run has got by its agents, as engine/progress.ts says it: "3 of 8 done · about 12
/// min left". `ended` holds when each agent that is over was first seen over, in seconds, and
/// agents of a phase seen ending before are expected to take what that phase's took. Agents work
/// side by side, so the time between two endings stands for a step, which is the pace the rest
/// will come at. Null before the run has any agents.
export function workflowProgress(shape: WorkflowShape, began: number, ended: number[], now: number): string | null {
  if (shape.agents.length === 0) return null;
  const over = shape.agents.filter(ends);
  const order = [...over, ...shape.agents.filter((agent) => !ends(agent))];
  return progressLine(order.map((agent) => ({ kind: agent.phase || "agent", guess: 1 })), began, ended.slice(0, over.length), now);
}

/// The snapshot's agents that are over and weren't before are stamped `now`.
export function stampEnds(shape: WorkflowShape, ended: number[], now: number): void {
  const over = shape.agents.filter(ends).length;
  while (ended.length < over) ended.push(now);
}

function ends(agent: WorkflowAgent): boolean {
  return agent.state === "done" || agent.state === "failed";
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

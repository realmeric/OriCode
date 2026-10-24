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
  /// Its phase's place among the run's, from 1.
  phaseIndex: number | null;
  /// When it was queued and when it started, in ms; and which try at its task this is, from 1.
  queuedAt: number | null;
  startedAt: number | null;
  attempt: number;
  /// The start of its task, about 400 characters, and whether the CLI framed it as the script's.
  promptPreview: string | null;
  promptFramed: boolean;
};

/// `endedAt`, in ms, once the run is over.
export type WorkflowShape = { phases: string[]; agents: WorkflowAgent[]; endedAt?: number };

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
      phaseIndex: number(agent.phaseIndex) || null,
      queuedAt: number(agent.queuedAt) || null,
      startedAt: number(agent.startedAt) || null,
      attempt: number(agent.attempt) || 1,
      promptPreview: text(agent.promptPreview)?.slice(0, 400) ?? null,
      promptFramed: agent.promptFramed === true,
    })),
  };
}

/// The run's last snapshot once it has ended, which the CLI sends no more of: every agent with
/// what it returned. A run that ended by itself writes it to its task's output file; a stopped
/// one leaves that empty, and the run's record beside the session, workflows/<runId>.json, has it.
/// The transcript folder is <session>/subagents/workflows/<runId>. The record says when the run
/// ended, by when it started and how long it took.
export async function finalShape(outputFile: string | null, transcriptDir: string | null): Promise<WorkflowShape | undefined> {
  const record = transcriptDir ? join(dirname(dirname(dirname(transcriptDir))), "workflows", `${transcriptDir.split("/").pop()}.json`) : null;
  for (const path of [outputFile, record]) {
    if (!path) continue;
    try {
      const run = JSON.parse(await readFile(path, "utf8")) as { workflowProgress?: unknown; startTime?: unknown; durationMs?: unknown };
      if (!Array.isArray(run.workflowProgress)) continue;
      const shape = workflowShape(run.workflowProgress);
      if (number(run.startTime) && number(run.durationMs)) shape.endedAt = number(run.startTime) + number(run.durationMs);
      return shape;
    } catch {
      // Not written, or not this run's JSON.
    }
  }
  return undefined;
}

/// How far a run has got by its agents, as engine/progress.ts gives it: "3/8 · 12 min". `ended` holds when each agent that is over was first seen over, in seconds, and
/// agents of a phase seen ending before are expected to take what that phase's took. Agents work
/// side by side, so the time between two endings stands for a step, which is the pace the rest
/// will come at. Null before the run has any agents and once every one is over.
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

/// What each agent of a run that has ended returned, whole, by its id: the run's journal,
/// journal.jsonl in its transcript folder, has a `result` line for each, a script's structured
/// result as an object, which goes as the snapshot's preview has it, in JSON.
export async function journalResults(transcriptDir: string): Promise<Map<string, string>> {
  const results = new Map<string, string>();
  const journal = await readFile(join(transcriptDir, "journal.jsonl"), "utf8").catch(() => "");
  for (const line of journal.split("\n")) {
    if (!line.includes('"result"')) continue;
    try {
      const entry = JSON.parse(line) as Entry;
      if (entry.type !== "result" || typeof entry.agentId !== "string" || entry.result === undefined) continue;
      results.set(entry.agentId, typeof entry.result === "string" ? entry.result : JSON.stringify(entry.result));
    } catch {
      // A line the CLI is still writing.
    }
  }
  return results;
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

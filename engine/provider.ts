import type { EffortLevel, PermissionMode } from "@anthropic-ai/claude-agent-sdk";
import type { Model } from "./models.ts";
import type { Usage } from "./usage.ts";

// The seam every agent comes in through. A Provider finds its CLI, says whether it's signed in,
// lists its models and opens a Session for a thread; the engine talks to a thread only through
// its Session, and to the agent's CLI outside a thread only through its Provider.

export type Attachment = { mediaType: string; data: string };

export type SendParams = {
  threadId: string;
  sessionId?: string;
  cwd: string;
  text: string;
  model?: string;
  /// A level, or `ultracode`: xhigh with Claude Code's standing multi-agent workflows.
  effort?: EffortLevel | "ultracode";
  permissionMode: PermissionMode;
  attachments?: Attachment[];
  /// Fast mode for the thread. SDK sessions get it only when their flag settings ask for it.
  fast?: boolean;
  /// What the thread's turns have cost so far. A resumed CLI reports the session's saved
  /// running total in its first result, so this is the baseline a turn's cost is taken from.
  costSoFar?: number;
  /// A call the user allowed after a quit had ended the CLI that asked about it. Claude makes it
  /// again once resumed, and the first ask for the same call in the turn is allowed unasked.
  grant?: Grant;
  /// The app's id for the message. The CLI reports on a message by it: when a message sent
  /// during a turn is taken up, or cancelled before it was.
  id?: string;
};

export type Grant = { tool: string; input: Record<string, unknown> };

export type Command = { name: string; description: string; argumentHint: string };

/// What a thread talks to: one agent's session, its CLI started by the first send and resumed
/// by the first after a release.
export type Session = {
  readonly isRunning: boolean;
  /// Called once a turn has ended and the CLI sits idle.
  onIdle: (() => void) | undefined;
  /// Returns whether the message waits for the running turn to take it up.
  send(params: SendParams): Promise<boolean>;
  interrupt(): Promise<void>;
  /// Returns whether the running turn took the new mode.
  setMode(mode: PermissionMode): Promise<boolean>;
  setFast(fast: boolean): Promise<boolean>;
  watchHeads(on: boolean): void;
  stopTask(taskId: string): Promise<void>;
  /// The commands the session's CLI knows, when it has one running.
  commands(): Promise<Command[] | undefined>;
  releaseIfIdle(idleMs: number, now?: number): boolean;
  idleLeft(idleMs: number, now?: number): number | undefined;
  close(): void;
};

/// What an agent can do, which decides what the app offers in a thread on it.
export type Capabilities = {
  /// A message sent during a turn joins it.
  steer: boolean;
  /// A thread picks up its session after a quit or a release.
  resume: boolean;
  /// A new permission mode reaches the running turn.
  modeLive: boolean;
  attachments: boolean;
  /// The subagents, commands and workflows a turn starts are reported as heads.
  heads: boolean;
  stopTask: boolean;
  /// The plan's limits come with a turn.
  limits: boolean;
  /// The plan's usage can be asked for.
  usage: boolean;
  commands: boolean;
  compact: boolean;
  commitMessage: boolean;
  /// The Terminal line that opens a thread's session in the agent's own CLI, `{session}`
  /// standing for its id, or null when there's none.
  handoff: string | null;
};

/// Whether the agent can run: its CLI, what that CLI says its version is, and, when it can't
/// run, the one line that makes it.
export type Availability = {
  state: "ready" | "missing" | "signedOut" | "outdated";
  cli: string | null;
  version: string | null;
  hint: string | null;
};

/// What a `models` event carries.
export type ModelsEvent = { models: Model[]; settingsEffort: string | null; ultraKnown: boolean };

export type Provider = {
  id: string;
  name: string;
  /// What a thread's lines call the agent.
  agent: string;
  capabilities: Capabilities;
  levels: string[];
  modes: string[];
  /// What the engine answers when found() finds no CLI.
  missing: string;
  /// The CLI, or null. It asks nothing of it, so a send never waits on a login check.
  found(): Promise<string | null>;
  availability(): Promise<Availability>;
  /// Hello's list, read once `ready` says the CLI can be asked; `tell` sends the `models`
  /// events that follow it.
  models(ready: Availability, tell: (models: ModelsEvent) => void): Promise<Model[]>;
  session(threadId: string, cli: string): Session;
  fastCheck?(cli: string, model: string | undefined): Promise<{ state: string; reason: string | null }>;
  /// Commands for a folder when no thread there has a CLI running.
  folderCommands?(cli: string, cwd: string): Promise<Command[]>;
  usage?(cli: string): Promise<Usage>;
  /// One small tool-less answer to a prompt, for git.message.
  oneShot?(cli: string, cwd: string, prompt: string): Promise<string>;
};

export type Answer = {
  requestId: string;
  allow: boolean;
  updatedInput?: Record<string, unknown>;
  answers?: Record<string, string>;
  message?: string;
};

/// An ask waiting on the user, from whichever thread's session asked it.
export type Ask = {
  threadId: string;
  /// Hands the user's answer to the agent.
  answer: (answer: Answer) => void;
  /// Tells the agent the turn it asked in was stopped.
  stop: () => void;
};

/// Every ask still waiting, by its request id, so an answer finds its session.
export const asks = new Map<string, Ask>();

export function answer(params: Answer): void {
  const ask = asks.get(params.requestId);
  if (!ask) throw new Error("That question is no longer waiting.");
  asks.delete(params.requestId);
  ask.answer(params);
}

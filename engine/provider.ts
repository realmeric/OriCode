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
  effort?: EffortLevel;
  /// Workflows on: the head fans each task out at the thread's own level. Claude Code runs its
  /// workflows, as Ultracode at xhigh; another head sends workers out on its rays (ultracode.ts).
  workflows?: boolean;
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
  /// The URL of OriCode's own tools for a head, its MCP server, when the thread has rays.
  tools?: string;
  /// What the head is told of its rays: Claude Code takes it appended to its system prompt and
  /// Codex as developer instructions, and the ACP agents hear it only in the tools' MCP
  /// instructions, which say it too. A session opens again when it changes.
  instructions?: string;
};

export type Grant = { tool: string; input: Record<string, unknown> };

/// What every session is told of the window it's shown in, where its agent has somewhere to hear
/// it: the transcript draws an `svg` block (K-217), and nothing says so but this.
export const drawing =
  "Your replies are shown in OriCode, a window that draws a fenced ```svg block in a reply as a picture, where you put it. " +
  "When a diagram or a chart would say it better than words, or the user asks for one, write the SVG in such a block, on its own between paragraphs, instead of ASCII art or Mermaid, which the window doesn't draw. " +
  "It is drawn over dark glass, up to 720 points wide: give it a viewBox and no background, draw text and lines in white, with opacity for quieter ink (currentColor is white), " +
  "fill shapes with white at 6 to 10% opacity, set text at 13px in the default font, and use colour only where it means something.";

/// The engine's own words for a session: the window's, then what a head is told of its rays.
export function told(instructions?: string): string {
  return instructions ? `${drawing}\n\n${instructions}` : drawing;
}

/// The name OriCode's own tools go by among a head's MCP servers, and how long one call may take:
/// worker_result waits up to five minutes for a worker, and this leaves it room.
export const toolsServer = "oricode";
export const toolsTimeout = 600_000;

export type Command = { name: string; description: string; argumentHint: string };

/// What a thread talks to: one agent's session, its CLI started by the first send and resumed
/// by the first after a release.
export type Session = {
  readonly isRunning: boolean;
  /// How long its CLI is kept idle, for an agent that shouldn't be kept the engine's 90 seconds.
  readonly idleRelease?: number;
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
  /// It asks before nothing, Pi and Command Code, so a thread on it has no permission modes.
  unsupervised?: boolean;
  /// It takes OriCode's worker tools over MCP, so a thread on it can be a head with workers.
  workers?: boolean;
};

/// Whether the agent can run: its CLI, what that CLI says its version is, and, when it can't
/// run, the one line that makes it. `unknown` is found and not asked, or with no way to ask short
/// of a thread; `soon` is found and signed in, with no session in the engine yet.
export type Availability = {
  /// `noPlan` is signed in to an account with no plan for the agent, Copilot's with no Copilot.
  state: "ready" | "missing" | "signedOut" | "noPlan" | "outdated" | "unknown" | "soon";
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
  /// Asked at hello and again by provider.check, so after the first it asks the CLI only what a
  /// login in Terminal changes.
  availability(): Promise<Availability>;
  /// What the last check found, for hello to answer with before it asks again; undefined asks in full.
  remembered?(): Promise<Availability | undefined>;
  /// Hello's list, read once `ready` says the CLI can be asked; `tell` sends the `models`
  /// events that follow it.
  models(ready: Availability, tell: (models: ModelsEvent) => void): Promise<Model[]>;
  /// The models the agent's own CLI lists, asked by `models.list` when the app first needs them,
  /// so launch starts no agent's CLI. Claude Code's come with hello instead.
  listModels?(cli: string): Promise<Model[]>;
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
  /// The choice the user picked, for an ask that came with the agent's own.
  optionId?: string;
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

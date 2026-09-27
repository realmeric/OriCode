import { execFile } from "node:child_process";
import { rm } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { agentEnvironment } from "./acp.ts";
import { acpProvider } from "./acp-provider.ts";
import type { Model } from "./models.ts";
import { log } from "./wire.ts";

// Cursor through `cursor-agent acp`. Each folder it works in gets a worker-server that outlives
// it, which ends with the last of the folder's sessions. Effort, thinking and fast mode are part
// of its model ids, `gpt-5.5[context=272k,reasoning=medium,fast=false]`, so its models carry no
// levels of OriCode's. On the Free plan only Auto runs, though the list shows every model.

const run = promisify(execFile);

/// Auto's id, the one model the Free plan runs.
export const auto = "default[]";

/// A model as Cursor names it: its name, and the settings its id carries as its description.
export function named(model: Model): Model {
  const settings = /\[(.+)\]$/.exec(model.id)?.[1];
  return settings ? { ...model, description: settings.split(",").join(", ") } : model;
}

/// Only Auto on the Free plan, which `cursor-agent about` names; every model on any other plan, or
/// when it can't say.
export function onPlan(tier: string | null | undefined): (models: Model[]) => Model[] {
  return (models) => (tier === "Free" ? models.filter((model) => model.id === auto) : models).map(named);
}

async function plan(cli: string): Promise<(models: Model[]) => Model[]> {
  try {
    const { stdout } = await run(cli, ["about", "--format", "json"], { env: agentEnvironment(), timeout: 10_000 });
    return onPlan(JSON.parse(stdout).subscriptionTier);
  } catch (error) {
    log(`Cursor didn't say its plan: ${(error as Error).message.split("\n")[0]}`);
    return onPlan(null);
  }
}

/// Where Cursor keeps a session it opened over ACP, which listing its models shouldn't leave behind.
export function sessionFolder(sessionId: string, home = homedir()): string {
  if (!/^[\w-]+$/.test(sessionId)) throw new Error(`${sessionId} isn't a session id.`);
  return join(home, ".cursor", "acp-sessions", sessionId);
}

export const cursor = acpProvider({
  id: "cursor",
  args: ["acp"],
  // Cursor's Agent asks before a command and applies edits; Plan reads and changes nothing.
  permissions: (mode) => ({ mode: mode === "plan" ? "plan" : "agent" }),
  allowAlways: "Cursor adds this to its own allowlist, which every Cursor session on this Mac follows.",
  strays: true,
  resume: true,
  images: true,
  modeLive: true,
  // Its ACP sessions live apart from the chats `cursor-agent --resume` opens.
  handoff: null,
  modes: ["acceptEdits", "plan"],
  forget: (_cli, sessionId) => rm(sessionFolder(sessionId), { recursive: true, force: true }),
  runs: plan,
});

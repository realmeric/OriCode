import type { ModelInfo, Query } from "@anthropic-ai/claude-agent-sdk";

export type Model = {
  id: string;
  name: string;
  description: string;
  efforts: string[];
  fast: boolean;
  /// The level Claude Code uses when the thread picks none, or null when the model has no
  /// levels or it isn't known yet.
  defaultEffort: string | null;
  /// Whether the session can run as Ultracode on this model: xhigh effort with standing
  /// multi-agent workflows. Needs an xhigh model and workflows turned on for the account.
  ultra: boolean;
  /// Why an xhigh model has no Ultracode when the user can change it: `workflows` while
  /// enableWorkflows is off in their settings.
  ultraBlocked: "workflows" | null;
};

/// Models that take adaptive thinking, filled from the SDK's list. Asking one that doesn't
/// for it is an error, so a model the engine hasn't heard about gets no thinking option.
export const adaptive = new Set<string>();

export function fromSDK(models: ModelInfo[]): Model[] {
  for (const model of models) {
    if (model.supportsAdaptiveThinking) adaptive.add(model.value);
  }
  return models.map((model) => ({
    id: model.value,
    name: model.displayName,
    description: model.description,
    efforts: model.supportsEffort ? (model.supportedEffortLevels ?? []) : [],
    fast: model.supportsFastMode ?? false,
    defaultEffort: null,
    ultra: false,
    ultraBlocked: null,
  }));
}

const levels = ["low", "medium", "high", "xhigh", "max"];

/// What get_settings reports: `effective` is the settings the CLI loaded, merged, and `applied`
/// what the session will actually send. The SDK has the control request but not yet a typed
/// method for it, so any of it may be missing.
type Reported = {
  effective?: { effortLevel?: string; maxEffortLevel?: string; enableWorkflows?: boolean };
  applied?: Applied;
};
export type Applied = { effort?: string | null; ultracode?: boolean };

async function reported(session: Query): Promise<Reported> {
  return (await (session as unknown as { getSettings(): Promise<Reported | undefined> }).getSettings()) ?? {};
}

export async function applied(session: Query): Promise<Applied> {
  return (await reported(session)).applied ?? {};
}

/// Each model's default effort and whether it can run as Ultracode, read from idle CLIs by
/// switching them through the models: settings only, no model call. `ultraProbe` has to be
/// launched with Ultracode on, never switched to it: applyFlagSettings({ ultracode }) saves
/// Claude Code's unpin…LaunchEffort flags into the user's ~/.claude.json for good, where a
/// launch flag releases them for its own session only. `settingsEffort` is the effortLevel in
/// the probe's settings, when it names a level.
export async function withDefaults(probe: Query, ultraProbe: Query, models: Model[]): Promise<{ models: Model[]; settingsEffort: string | null }> {
  const effective = (await reported(probe)).effective ?? {};
  // The CLI clamps anything above a maxEffortLevel down to it, so those levels aren't offered.
  const cap = levels.indexOf(effective.maxEffortLevel ?? "");
  const above = cap < 0 ? [] : levels.slice(cap + 1);
  const found: Model[] = [];
  for (const model of models) {
    const efforts = model.efforts.filter((effort) => !above.includes(effort));
    await probe.setModel(model.id);
    const effort = (await applied(probe)).effort ?? null;
    found.push({ ...model, efforts, defaultEffort: effort && efforts.includes(effort) ? effort : null });
  }
  for (const model of found) {
    if (!model.efforts.includes("xhigh")) continue;
    await ultraProbe.setModel(model.id);
    model.ultra = (await applied(ultraProbe)).ultracode === true;
    if (!model.ultra && effective.enableWorkflows === false) model.ultraBlocked = "workflows";
  }
  const settingsEffort = effective.effortLevel && levels.includes(effective.effortLevel) ? effective.effortLevel : null;
  return { models: found, settingsEffort };
}

/// Fallback for when the SDK's supported-models call fails. Aliases, so they keep
/// pointing at the newest model of each family.
export const fallback: Model[] = [
  { id: "default", name: "Default", description: "The model Claude Code picks", efforts: ["low", "medium", "high", "xhigh", "max"], fast: false, defaultEffort: null, ultra: false, ultraBlocked: null },
  { id: "opus", name: "Opus", description: "Most capable", efforts: ["low", "medium", "high", "xhigh", "max"], fast: false, defaultEffort: null, ultra: false, ultraBlocked: null },
  { id: "sonnet", name: "Sonnet", description: "Fast and capable", efforts: ["low", "medium", "high", "xhigh", "max"], fast: false, defaultEffort: null, ultra: false, ultraBlocked: null },
  { id: "haiku", name: "Haiku", description: "Fastest", efforts: [], fast: false, defaultEffort: null, ultra: false, ultraBlocked: null },
];

import type { ModelInfo, Query } from "@anthropic-ai/claude-agent-sdk";
import type { CatalogModel } from "./catalog.ts";

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
  /// One of the account's older models, from the catalog's overflow section; the app lists
  /// them under More models. Absent on the SDK's own rows.
  more?: boolean;
  /// The Claude Code version a catalog model needs, when the running one is older: the app
  /// shows it dimmed and doesn't pick it.
  needs?: string;
};

/// Models that take adaptive thinking, filled from the SDK's list. Asking one that doesn't
/// for it is an error, so a model the engine hasn't heard about gets no thinking option.
export const adaptive = new Set<string>();

export function fromSDK(models: ModelInfo[], catalog: CatalogModel[] = []): Model[] {
  for (const model of models) {
    if (model.supportsAdaptiveThinking) adaptive.add(model.value);
  }
  return models.map((model) => ({
    id: model.value,
    ...versioned(model, catalog),
    efforts: model.supportsEffort ? (model.supportedEffortLevels ?? []) : [],
    fast: model.supportsFastMode ?? false,
    defaultEffort: null,
    ultra: false,
    ultraBlocked: null,
  }));
}

/// The catalog's older models for the More models list, each with the levels, default level and
/// fast mode the catalog gives it. One the SDK's rows already run is left out, and so is one
/// that names a Claude Code version, which a model new enough to need one isn't yet.
export function older(catalog: CatalogModel[], models: ModelInfo[]): Model[] {
  const running = new Set(models.map((model) => model.resolvedModel?.replace(/\[1m\]$/i, "")));
  return catalog
    .filter((row) => row.more && !row.minVersion && !running.has(row.id))
    .map((row) => {
      if (row.adaptive) adaptive.add(row.id);
      return {
        id: row.id,
        name: row.name,
        description: row.description ?? "",
        efforts: row.efforts,
        fast: row.fast,
        defaultEffort: row.defaultEffort,
        ultra: false,
        ultraBlocked: null,
        more: true,
      };
    });
}

/// The catalog's models this Claude Code can't run yet: one from the main section that names the
/// version it needs, which no row of the SDK's runs. Once Claude Code is updated a row runs it.
export function newer(catalog: CatalogModel[], models: ModelInfo[]): Model[] {
  const running = new Set(models.map((model) => model.resolvedModel?.replace(/\[1m\]$/i, "")));
  return catalog
    .filter((row) => !row.more && row.minVersion && !running.has(row.id))
    .map((row) => ({
      id: row.id,
      name: row.name,
      description: `Needs Claude Code ${row.minVersion}`,
      efforts: [],
      fast: false,
      defaultEffort: null,
      ultra: false,
      ultraBlocked: null,
      needs: row.minVersion ?? undefined,
    }));
}

/// Where Default lands on an older model: the effortLevel in the user's settings when the model
/// has it, as Claude Code does, or else the catalog's default. The CLI isn't switched to them to
/// read it, since switching to a full model id costs a request to confirm it.
export function settled(model: Model, settingsEffort: string | null): Model {
  return settingsEffort && model.efforts.includes(settingsEffort) ? { ...model, defaultEffort: settingsEffort } : model;
}

/// The SDK names a row by family ("Opus (1M context)") and puts the version in its line ("Opus 5
/// with 1M context · Best for…"). The name becomes the version, the catalog's for the model the
/// row runs or else the line's, and the line loses it. Default keeps its name and its line,
/// which says what it runs.
export function versioned(model: ModelInfo, catalog: CatalogModel[]): { name: string; description: string } {
  const unchanged = { name: model.displayName, description: model.description };
  if (model.value === "default") return unchanged;
  const runs = model.resolvedModel?.replace(/\[1m\]$/i, "");
  const head = model.description.split(" · ")[0].replace(/ with 1M context$/, "");
  const family = model.displayName.split(" (")[0];
  const name = catalog.find((row) => row.id === runs)?.name ?? (head.startsWith(`${family} `) ? head : undefined);
  if (!name) return unchanged;
  const description = model.description.startsWith(`${name} `)
    ? model.description.slice(name.length).replace(/^ (with |· )/, "")
    : model.description;
  return { name, description };
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

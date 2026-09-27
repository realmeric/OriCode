import { agent, allows, binary, isOn } from "./agents.ts";
import type { Model } from "./models.ts";
import { availability, capabilities, levels, listModels, PiSession } from "./pi.ts";
import type { Availability, Provider } from "./provider.ts";

// Pi behind the Provider seam: the user's own pi, found by the one login shell agents.ts runs, and
// a thread's session one `pi --mode rpc` of its own. A model pi reaches through a login its maker
// keeps to its own apps runs only once that login is turned on in Settings › Agents.

const entry = agent("pi")!;

const permitted = (maker: string) => allows(entry.id, maker);

async function check(): Promise<Availability> {
  if (!isOn(entry.id)) throw new Error(`${entry.name} is off in Settings › Agents.`);
  const cli = await binary(entry.id);
  if (!cli) return { state: "missing", cli: null, version: null, hint: entry.install };
  return availability({ command: cli });
}

/// Pi's models under their provider's name and how pi reaches it, pi's default first and the ones
/// behind a forbidden login last. A model without reasoning takes only off, which is no choice.
async function models(cli: string): Promise<Model[]> {
  const listed = (await listModels({ command: cli }, permitted)).flatMap((group) => group.models);
  return listed
    .sort((a, b) => Number(a.forbidden !== undefined) - Number(b.forbidden !== undefined) || Number(b.isDefault) - Number(a.isDefault))
    .map((model) => ({
      id: model.id,
      name: model.name,
      description: `${model.provider} · ${model.auth}`,
      efforts: model.efforts.length > 1 ? model.efforts : [],
      fast: false,
      defaultEffort: null,
      ultra: false,
      ultraBlocked: null,
      ...(model.forbidden ? { forbidden: model.forbidden } : {}),
    }));
}

export const pi: Provider = {
  id: entry.id,
  name: entry.name,
  agent: entry.agent,
  capabilities,
  levels,
  modes: [],
  missing: entry.install!,
  found: () => binary(entry.id),
  availability: check,
  models: async (ready) => (ready.state === "ready" && ready.cli ? models(ready.cli) : []),
  listModels: models,
  session: (threadId, cli) => new PiSession(threadId, { command: cli }, permitted),
};

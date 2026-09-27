import { agent, allows, binary, isOn, keyFor } from "./agents.ts";
import { AntigravitySession, check, route, settingsFile, type AntigravityModel } from "./antigravity.ts";
import type { Model } from "./models.ts";
import type { Availability, Provider } from "./provider.ts";

// Antigravity behind the Provider seam: the user's own agy, on the route its own settings.json
// chooses. On the Gemini API, the key Settings › Agents keeps in the Keychain goes to each agy
// process as GEMINI_API_KEY and nowhere else. agy takes `modelProvider` only from that file, with
// no flag or variable for one process, so choosing the route stays the user's and OriCode only
// reads it. On a Google account, which Google keeps to its own apps, agy isn't started at all
// until that login is turned on in Settings › Agents.

const entry = agent("antigravity")!;

const google = `Antigravity signs in with a Google account, which Google keeps to its own apps. Set "modelProvider": "gemini" in ~/.gemini/antigravity-cli/settings.json and add a Gemini API key here, or turn on “${entry.forbidden[0].title}”.`;

const noKey = "Add your Gemini API key in Settings › Agents.";

/// Tests stand in for /usr/bin/security and agy's settings.json.
export function antigravityProvider({ security, settings = settingsFile }: { security?: string; settings?: string } = {}): Provider {
  // The models `agy models` gave each CLI on each route, read by the check that found it ready.
  const lists = new Map<string, Promise<AntigravityModel[]>>();

  /// The environment an agy starts with, read as it starts, or why it may not start.
  async function launch(): Promise<Record<string, string>> {
    if ((await route(settings)) === "google") {
      if (!allows(entry.id, "google")) throw new Error(google);
      return {};
    }
    const key = await keyFor(entry.id, security);
    if (!key.GEMINI_API_KEY && !process.env.GEMINI_API_KEY) throw new Error(noKey);
    return key;
  }

  async function availability(): Promise<Availability> {
    if (!isOn(entry.id)) throw new Error(`${entry.name} is off in Settings › Agents.`);
    const cli = await binary(entry.id);
    if (!cli) return { state: "missing", cli: null, version: null, hint: entry.install };
    let env: Record<string, string>;
    try {
      env = await launch();
    } catch (refused) {
      return { state: "signedOut", cli, version: null, hint: (refused as Error).message };
    }
    const found = await check({ command: cli }, env);
    if (found.state === "ready") lists.set(`${cli} ${await route(settings)}`, Promise.resolve(found.models));
    return { state: found.state, cli, version: found.version, hint: found.hint };
  }

  async function models(cli: string): Promise<Model[]> {
    const listed = `${cli} ${await route(settings)}`;
    if (!lists.has(listed)) {
      const env = await launch();
      lists.set(listed, check({ command: cli }, env).then((found) => (found.state === "ready" ? found.models : Promise.reject(new Error(found.hint ?? "Antigravity listed no models.")))));
      lists.get(listed)!.catch(() => lists.delete(listed));
    }
    // A slug names its level, gemini-3.8-flash-high, so no model offers one of its own.
    return (await lists.get(listed)!).map(({ id, name }) => ({ id, name, description: "", efforts: [], fast: false, defaultEffort: null, ultra: false, ultraBlocked: null }));
  }

  return {
    id: entry.id,
    name: entry.name,
    agent: entry.agent,
    capabilities: {
      steer: false,
      resume: true,
      modeLive: false,
      attachments: false,
      heads: false,
      stopTask: false,
      limits: false,
      usage: false,
      commands: false,
      compact: false,
      commitMessage: false,
      handoff: "agy --conversation {session}",
      unsupervised: true,
    },
    levels: [],
    modes: ["default", "acceptEdits", "plan"],
    missing: entry.install!,
    found: () => binary(entry.id),
    availability,
    models: async (ready) => (ready.state === "ready" && ready.cli ? models(ready.cli) : []),
    listModels: models,
    session: (threadId, cli) => new AntigravitySession(threadId, { command: cli, launch }),
  };
}

export const antigravity = antigravityProvider();

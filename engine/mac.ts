import { randomUUID } from "node:crypto";
import { asks } from "./provider.ts";
import { askApp, Unanswered } from "./threads.ts";
import { event } from "./wire.ts";

// Seeing and using the Mac (K-290): a picture of an app's window, and clicks, keys and scrolls in
// it, served beside the thread tools while Settings › Agents has it on, and not listed at all while
// it's off. The app does the work, since it's the one macOS gave Screen Recording and
// Accessibility to: each call goes to it as an event and waits for its `app.reply`. The first call
// on an app in a thread asks the user in that thread, and an app allowed stays allowed for the
// thread until the engine ends or the switch goes off; nothing protected is read before that
// answer. The app never lets an agent see or use OriCode's own windows, where a click could answer
// the agent's own ask.

const app = { type: "string", description: "The app, by the name list_apps gives, such as Safari or OriCode Molten, or its bundle id." };

export const listApps = {
  name: "list_apps",
  description:
    "List the apps running on the user's Mac that have windows: each one's name, bundle id, whether it's in front, and whether this thread may see and use it yet. " +
    "It reads nothing from inside them. OriCode itself is never listed: you can't see or use its windows.",
  inputSchema: { type: "object", properties: {} },
};

export const screenshot = {
  name: "screenshot",
  description:
    "Take a picture of one of an app's windows, the frontmost unless `window` names another, and get it back as an image with the window's title and its other windows' titles. " +
    "The first call on an app in this thread asks the user to let you see and use it, and waits for their answer. " +
    "The picture is in points, at most 1568 pixels on its longer side, and its pixels are what click and scroll take: take one before you click, and another after to see what happened.",
  inputSchema: {
    type: "object",
    properties: {
      app,
      window: { type: "string", description: "Part of a window's title, for a window other than the frontmost." },
    },
    required: ["app"],
  },
};

const point = {
  x: { type: "number", description: "Pixels from the left of the app's latest screenshot." },
  y: { type: "number", description: "Pixels from the top of the app's latest screenshot." },
};

export const click = {
  name: "click",
  description:
    "Click in the window of the app's latest screenshot, at a point in that picture's pixels. The app comes to the front first, and the pointer moves there. " +
    "Take a screenshot of the app first; take another after to see what the click did.",
  inputSchema: {
    type: "object",
    properties: {
      app,
      ...point,
      button: { type: "string", enum: ["left", "right"], description: "Left when left out." },
      clicks: { type: "number", description: "2 for a double click. 1 when left out." },
    },
    required: ["app", "x", "y"],
  },
};

export const typeText = {
  name: "type_text",
  description: "Type text into the app, wherever its keyboard focus is: click the field first. The app comes to the front first.",
  inputSchema: {
    type: "object",
    properties: { app, text: { type: "string", description: "What to type." } },
    required: ["app", "text"],
  },
};

export const pressKey = {
  name: "press_key",
  description:
    "Press a key or a combination in the app, as `cmd+,`, `cmd+shift+k`, `return`, `escape`, `tab`, `space`, `delete`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown` or `f1` to `f12`, letters and digits as themselves. " +
    "Modifiers are cmd, shift, option and ctrl. The app comes to the front first.",
  inputSchema: {
    type: "object",
    properties: { app, keys: { type: "string", description: "The key, with its modifiers joined by +." } },
    required: ["app", "keys"],
  },
};

export const scroll = {
  name: "scroll",
  description: "Scroll at a point in the window of the app's latest screenshot, by lines: positive `down` scrolls down, negative up, and `right` the same across.",
  inputSchema: {
    type: "object",
    properties: {
      app,
      ...point,
      down: { type: "number", description: "Lines to scroll down, negative for up." },
      right: { type: "number", description: "Lines to scroll right, negative for left." },
    },
    required: ["app", "x", "y"],
  },
};

export const macTools = [listApps, screenshot, click, typeText, pressKey, scroll];

const names = new Set(macTools.map((tool) => tool.name));

export function isMacTool(name: string): boolean {
  return names.has(name);
}

/// What a session with the tools is told of them, where its agent has somewhere to hear it.
export const seeing =
  "With the oricode MCP server's list_apps, screenshot, click, type_text, press_key and scroll you can see and use the apps on the user's Mac: a picture of an app's window, and clicks, keys and scrolls in it. " +
  "Use them to check what you built in the running app, an interface change say, or when the user asks you to. The user lets you use each app once in this thread, and your first call on one asks them. " +
  "A click lands at a point in the app's latest screenshot, so take one before you click and another after. You can't see or use OriCode's own windows.";

/// A tool's answer that carries a picture, which the MCP server sends as an image beside the text.
export class Pictured {
  readonly data: string;
  readonly mimeType: string;
  readonly rest: Record<string, unknown>;

  constructor(data: string, mimeType: string, rest: Record<string, unknown>) {
    this.data = data;
    this.mimeType = mimeType;
    this.rest = rest;
  }
}

/// An app as the app finds it, which is what the user allows.
type Found = { name: string; bundleId: string };

/// A thread's calls on the Mac, with the apps the user has let it see and use.
export class Hands {
  private allowed = new Set<string>();
  /// The asks waiting, so a turn's end can take them back.
  private waiting = new Map<string, (allow: boolean) => void>();
  /// The question out on each app, by bundle id, which a second call on it waits on too.
  private asking = new Map<string, Promise<boolean>>();
  private threadId: string;

  constructor(threadId: string) {
    this.threadId = threadId;
  }

  async call(name: string, args: Record<string, any>): Promise<unknown> {
    if (name === "list_apps") {
      const listed = (await this.ask("mac.apps", {})) as { apps?: { bundleId: string }[] };
      return { apps: (listed.apps ?? []).map((one) => ({ ...one, allowed: this.allowed.has(one.bundleId) })) };
    }
    const [asked, fields] = request(name, args);
    const found = await this.allow(args.app);
    const answer = (await this.ask(asked, { bundleId: found.bundleId, ...fields })) as Record<string, unknown>;
    if (asked !== "mac.screenshot") return answer;
    const { image, mimeType, ...rest } = answer;
    if (typeof image !== "string") throw new Error("OriCode took no picture of that window.");
    return new Pictured(image, typeof mimeType === "string" ? mimeType : "image/jpeg", rest);
  }

  /// The app the call names, allowed: the app says which it is, and the user is asked in the
  /// thread the first time.
  private async allow(named: unknown): Promise<Found> {
    const wanted = String(named ?? "").trim();
    if (!wanted) throw new Error("Name the app in `app`, as list_apps gives it.");
    const found = (await this.ask("mac.find", { app: wanted })) as Found;
    if (this.allowed.has(found.bundleId)) return found;
    let asked = this.asking.get(found.bundleId);
    if (!asked) {
      asked = this.question(found).finally(() => this.asking.delete(found.bundleId));
      this.asking.set(found.bundleId, asked);
    }
    if (!(await asked)) throw new Error(`The user didn't let this thread see and use ${found.name}. Don't try it again in this turn unless they ask you to.`);
    this.allowed.add(found.bundleId);
    return found;
  }

  /// One ask in the thread, answered from its card like any permission: Allow or Deny.
  private question(found: Found): Promise<boolean> {
    const requestId = randomUUID();
    return new Promise((done) => {
      const settle = (allow: boolean) => {
        this.waiting.delete(requestId);
        done(allow);
      };
      this.waiting.set(requestId, settle);
      asks.set(requestId, { threadId: this.threadId, answer: ({ allow }) => settle(allow), stop: () => settle(false) });
      event("ask", {
        threadId: this.threadId,
        requestId,
        kind: "permission",
        tool: "Mac",
        input: { app: found.name, bundleId: found.bundleId },
        choices: [
          { id: "deny", name: "Deny", kind: "reject_once" },
          { id: "allow", name: "Allow", kind: "allow_always" },
        ],
      });
    });
  }

  /// The user allowed the app on an ask a quit cut off, which comes back with the send that
  /// carries the answer.
  grant(bundleId: string): void {
    this.allowed.add(bundleId);
  }

  /// The turn ended with an ask still waiting: the agent's call is gone, so the card is too.
  turnEnded(): void {
    for (const [requestId, settle] of this.waiting) {
      if (!asks.delete(requestId)) continue;
      event("ask.cancelled", { threadId: this.threadId, requestId });
      settle(false);
    }
  }

  /// The switch went off: every app is asked about again once it's back on.
  forget(): void {
    this.allowed.clear();
    this.turnEnded();
  }

  private async ask(name: string, fields: Record<string, unknown>): Promise<unknown> {
    try {
      return await askApp(name, { threadId: this.threadId, ...fields });
    } catch (error) {
      if (error instanceof Unanswered) throw new Error("OriCode took too long to do that on the Mac. Take a screenshot to see whether it happened.");
      throw error;
    }
  }
}

/// The event a call on an app becomes and what goes with it, checked before anyone is asked.
function request(name: string, args: Record<string, any>): [string, Record<string, unknown>] {
  switch (name) {
    case "screenshot":
      return ["mac.screenshot", typeof args.window === "string" && args.window.trim() ? { window: args.window.trim() } : {}];
    case "click":
      return ["mac.click", { ...at(args), button: args.button === "right" ? "right" : "left", clicks: args.clicks === 2 ? 2 : 1 }];
    case "type_text": {
      const text = String(args.text ?? "");
      if (!text) throw new Error("Say what to type in `text`.");
      return ["mac.type", { text }];
    }
    case "press_key": {
      const keys = String(args.keys ?? "").trim();
      if (!keys) throw new Error("Name the key in `keys`, such as cmd+, or return.");
      return ["mac.key", { keys }];
    }
    case "scroll": {
      const down = Number(args.down ?? 0);
      const right = Number(args.right ?? 0);
      if (!Number.isFinite(down) || !Number.isFinite(right) || (down === 0 && right === 0)) throw new Error("Say how far to scroll in `down` or `right`, in lines.");
      return ["mac.scroll", { ...at(args), down: Math.round(down), right: Math.round(right) }];
    }
    default:
      throw new Error(`OriCode has no tool called ${name}.`);
  }
}

function at(args: Record<string, any>): { x: number; y: number } {
  const x = Number(args.x);
  const y = Number(args.y);
  if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || y < 0) throw new Error("Give `x` and `y` in the pixels of the app's latest screenshot.");
  return { x, y };
}

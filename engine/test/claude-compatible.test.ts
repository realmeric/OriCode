// Z.ai and DeepSeek in Claude Code: the key from a stand-in `security`, the maker's endpoint a
// local stand-in that speaks just enough of the Messages API to stream one reply and writes down
// every request's headers. Nothing reaches a model, a maker or the real Keychain. The one test
// that runs the user's own claude does so with the claude.ai login it keeps, which is the point:
// the key has to outrank it on the wire.
import { chmod, mkdtemp, writeFile } from "node:fs/promises";
import { createServer, type IncomingHttpHeaders } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { binary, turnOn } from "../agents.ts";
import { claudeCompatible, deepseekMaker, zaiMaker } from "../claude-compatible.ts";
import { errorText, Thread } from "../thread.ts";

const key = "zai-stand-in-key-188";

type Request = { method: string; url: string; headers: IncomingHttpHeaders; body: any };
const requests: Request[] = [];
let endpoint = "";

/// Every Messages call answered with one streamed reply; anything else is a 404.
const server = createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    const parsed = body ? JSON.parse(body) : undefined;
    requests.push({ method: req.method!, url: req.url!, headers: req.headers, body: parsed });
    if (req.method !== "POST" || !req.url!.startsWith("/v1/messages") || req.url!.includes("count_tokens")) {
      res.writeHead(404, { "content-type": "application/json" });
      res.end(JSON.stringify({ type: "error", error: { type: "not_found_error", message: "Not here." } }));
      return;
    }
    if (!parsed.stream) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ id: "msg_0", type: "message", role: "assistant", model: parsed.model, content: [{ type: "text", text: "Title" }], stop_reason: "end_turn", stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } }));
      return;
    }
    res.writeHead(200, { "content-type": "text/event-stream" });
    const send = (type: string, fields: object) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...fields })}\n\n`);
    send("message_start", { message: { id: "msg_1", type: "message", role: "assistant", model: parsed.model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 1 } } });
    send("content_block_start", { index: 0, content_block: { type: "text", text: "" } });
    send("content_block_delta", { index: 0, delta: { type: "text_delta", text: "Hello from " } });
    send("content_block_delta", { index: 0, delta: { type: "text_delta", text: "the stand-in." } });
    send("content_block_stop", { index: 0 });
    send("message_delta", { delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 5 } });
    send("message_stop", {});
    res.end();
  });
});

let security = "";

before(async () => {
  await new Promise<void>((listening) => server.listen(0, "127.0.0.1", listening));
  endpoint = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const folder = await mkdtemp(join(tmpdir(), "oricode-compatible-"));
  security = join(folder, "security");
  await writeFile(
    security,
    `#!/bin/sh\ncase "$*" in\n  "find-generic-password -s OriCode.zai -a zai -w") echo "${key}" ;;\n  *) echo "security: The specified item could not be found in the keychain." >&2; exit 44 ;;\nesac\n`,
  );
  await chmod(security, 0o755);
  turnOn({ zai: { key: true }, deepseek: { key: true } });
});
after(() => server.close());

/// The events the threads write to stdout, kept here instead.
const events: Record<string, any>[] = [];
const write = process.stdout.write.bind(process.stdout);
process.stdout.write = ((chunk: string | Uint8Array, ...rest: any[]) => {
  if (typeof chunk === "string" && chunk.startsWith('{"event"')) {
    events.push(JSON.parse(chunk));
    return true;
  }
  return write(chunk, ...rest);
}) as typeof process.stdout.write;
after(() => (process.stdout.write = write));

/// What every Anthropic credential in the engine's own environment would look like, so a leak shows.
const planted = {
  ANTHROPIC_API_KEY: "sk-ant-api-planted",
  ANTHROPIC_AUTH_TOKEN: "sk-ant-planted-token",
  ANTHROPIC_BASE_URL: "https://api.anthropic.com",
  ANTHROPIC_OAUTH_TOKEN: "sk-ant-oat-planted",
  CLAUDE_CODE_OAUTH_TOKEN: "sk-ant-oat-planted-2",
};

async function withPlanted<T>(run: () => Promise<T>): Promise<T> {
  Object.assign(process.env, planted);
  try {
    return await run();
  } finally {
    for (const name of Object.keys(planted)) delete process.env[name];
  }
}

/// A CLI that never runs: it keeps the options each launch was given and yields what it's fed.
function capturing() {
  const launched: { env: Record<string, string | undefined>; model?: string; settingSources?: string[] }[] = [];
  const frames: unknown[] = [];
  let wake: (() => void) | undefined;
  const feed = (frame: unknown) => {
    frames.push(frame);
    wake?.();
  };
  const launch = ({ options }: { prompt: AsyncIterable<SDKUserMessage>; options: any }) => {
    launched.push(options);
    return {
      async *[Symbol.asyncIterator]() {
        while (true) {
          if (frames.length) yield frames.shift();
          else await new Promise<void>((resolve) => (wake = resolve));
        }
      },
      initializationResult: () => Promise.reject(new Error("no CLI here")),
      setPermissionMode: async () => {},
      applyFlagSettings: async () => {},
      interrupt: async () => {},
      close: () => {},
    };
  };
  return { launched, feed, launch: launch as never };
}

const params = (threadId: string, model?: string) => ({ threadId, cwd: tmpdir(), text: "Say hi", permissionMode: "default" as const, model });

test("a Z.ai thread's CLI gets the endpoint, the key and the maker's models, and nothing else of Anthropic's; a Claude thread beside it gets none of them", async () => {
  const cli = capturing();
  const zai = claudeCompatible(zaiMaker, { security, launch: cli.launch });
  await withPlanted(async () => {
    await zai.session("z", "claude").send(params("z", "glm-5.3[1m]"));
    await new Thread("c", "claude", cli.launch).send(params("c", "opus"));
  });
  const [onZai, onClaude] = cli.launched;
  assert.equal(onZai.model, "glm-5.3[1m]");
  assert.deepEqual(onZai.settingSources, ["user", "project", "local"]);
  const anthropic = Object.fromEntries(Object.entries(onZai.env).filter(([name]) => name.startsWith("ANTHROPIC_")));
  assert.deepEqual(anthropic, {
    ANTHROPIC_MODEL: "glm-5.3[1m]",
    ANTHROPIC_DEFAULT_OPUS_MODEL: "glm-5.3[1m]",
    ANTHROPIC_DEFAULT_SONNET_MODEL: "glm-5.3[1m]",
    ANTHROPIC_DEFAULT_HAIKU_MODEL: "glm-5.3-flash[1m]",
    ANTHROPIC_BASE_URL: "https://api.z.ai/api/anthropic",
    ANTHROPIC_AUTH_TOKEN: key,
  });
  assert.equal(onZai.env.CLAUDE_CODE_OAUTH_TOKEN, undefined);
  // The Claude thread keeps the engine's own environment, which is where a user's own
  // ANTHROPIC_* would come from; none of the maker's reaches it, and the key is nowhere.
  assert.equal(onClaude.env.ANTHROPIC_BASE_URL, planted.ANTHROPIC_BASE_URL);
  assert.equal(onClaude.env.ANTHROPIC_AUTH_TOKEN, planted.ANTHROPIC_AUTH_TOKEN);
  assert.equal(onClaude.env.ANTHROPIC_DEFAULT_OPUS_MODEL, undefined);
  assert.equal(onClaude.env.ANTHROPIC_MODEL, undefined);
  assert.ok(!JSON.stringify(onClaude.env).includes(key));
  assert.equal(process.env.ANTHROPIC_DEFAULT_OPUS_MODEL, undefined);
  assert.ok(!JSON.stringify(process.env).includes(key));
});

test("with no key found in the Keychain, a DeepSeek thread starts no CLI rather than one that would carry the login", async () => {
  const cli = capturing();
  const deepseek = claudeCompatible(deepseekMaker, { security, launch: cli.launch });
  await assert.rejects(deepseek.session("d", "claude").send(params("d", "deepseek-flash[1m]")), {
    message: "No DeepSeek key was found in your Keychain. Add it again in Settings › Agents.",
  });
  assert.equal(cli.launched.length, 0);
});

test("a Z.ai thread tells no Claude plan limits, and its errors name Z.ai", async () => {
  const cli = capturing();
  const zai = claudeCompatible(zaiMaker, { security, launch: cli.launch });
  const session = zai.session("zl", "claude");
  events.length = 0;
  await session.send(params("zl", "glm-5.3[1m]"));
  cli.feed({ type: "rate_limit_event", rate_limit_info: { status: "allowed_warning", rateLimitType: "five_hour", utilization: 0.9, resetsAt: 1 } });
  cli.feed({ type: "assistant", parent_tool_use_id: null, error: "authentication_failed", message: { id: "m", content: [] } });
  await new Promise((resolve) => setTimeout(resolve, 20));
  session.close();
  assert.deepEqual(
    events.filter((line) => line.threadId === "zl").map((line) => [line.event, line.message]),
    [["error", "Z.ai didn't take the key. Check it in Settings › Agents."]],
  );
  assert.equal(errorText("overloaded", "DeepSeek"), "DeepSeek is overloaded right now.");
  assert.equal(errorText("authentication_failed"), "Claude isn't logged in. Run `claude` in Terminal and log in.");
});

test("a second send while the key is read joins the CLI the first starts", async () => {
  const cli = capturing();
  const zai = claudeCompatible(zaiMaker, { security, launch: cli.launch });
  const session = zai.session("z2", "claude");
  const first = session.send(params("z2"));
  const second = session.send({ ...params("z2"), id: "b" }).catch((error: Error) => error.message);
  await first;
  // The first CLI's init never came, so the second waits in it rather than starting another.
  assert.equal(cli.launched.length, 1);
  session.close();
  assert.equal(await second, true);
});

// The user's own claude, with the claude.ai login it keeps on this Mac, pointed at the stand-in.
test("a turn on the user's own Claude Code streams from the maker's endpoint, and only the key goes with it", async (t) => {
  const claude = await binary("claude");
  if (!claude) return t.skip("Claude Code isn't installed here");
  const cwd = await mkdtemp(join(tmpdir(), "oricode-compatible-cwd-"));
  const zai = claudeCompatible({ ...zaiMaker, url: endpoint }, { security });
  const session = zai.session("real", claude);
  events.length = 0;
  requests.length = 0;
  const done = new Promise<void>((resolve) => {
    session.onIdle = resolve;
  });
  await withPlanted(() => session.send({ threadId: "real", cwd, text: "Say hi", permissionMode: "default", model: "glm-5.3[1m]" }));
  await done;
  session.close();

  const text = events.filter((line) => line.event === "text" && line.threadId === "real").map((line) => line.text ?? line.delta).join("");
  assert.match(text, /Hello from the stand-in\./);
  assert.ok(events.some((line) => line.event === "turn.done" && line.threadId === "real"));

  const messages = requests.filter((request) => request.method === "POST" && request.url.startsWith("/v1/messages"));
  assert.ok(messages.length > 0);
  const turn = messages.find((request) => request.body.stream);
  assert.equal(turn?.body.model, "glm-5.3");
  for (const request of requests) {
    const headers = JSON.stringify(request.headers);
    if (request.headers.authorization !== undefined) assert.equal(request.headers.authorization, `Bearer ${key}`, request.url);
    assert.equal(request.headers["x-api-key"], undefined, request.url);
    assert.equal(request.headers.cookie, undefined, request.url);
    assert.doesNotMatch(headers, /sk-ant-|planted|oauth/i, request.url);
    if (request.body) assert.doesNotMatch(JSON.stringify(request.body), /sk-ant-|planted/, request.url);
  }
  for (const request of messages) assert.equal(request.headers.authorization, `Bearer ${key}`);
  // Claude Code names no Anthropic account to the maker.
  assert.equal(JSON.parse(turn!.body.metadata.user_id).account_uuid, "");
});

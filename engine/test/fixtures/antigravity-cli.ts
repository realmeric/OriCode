// A stand-in for Antigravity's `agy`, for the engine's tests: `--version`, `models`, and print mode
// with stream-json both ways, in the shapes antigravity.google/docs/cli/headless documents for agy
// 1.2.11, a scripted turn for each prompt read from stdin, and no model anywhere. It picks its
// route from $HOME/.gemini/antigravity-cli/settings.json as agy does: "modelProvider": "gemini"
// needs GEMINI_API_KEY, and anything else is the Google account, which AGY_BANNED=1 answers as
// Google answers Meriç's. Each start logs its arguments, folder, route, key and CLAUDE variables
// to AGY_LOG, and the conversations it has made to AGY_LOG.conversations, which --conversation reads.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";

const args = process.argv.slice(2);
const key = process.env.GEMINI_API_KEY;
const settings = join(process.env.HOME ?? "", ".gemini/antigravity-cli/settings.json");
const gemini = existsSync(settings) && JSON.parse(readFileSync(settings, "utf8")).modelProvider === "gemini";
const logFile = process.env.AGY_LOG ?? "";
const record = (entry: unknown) => logFile && appendFileSync(logFile, JSON.stringify(entry) + "\n");

if (gemini && !key) {
  process.stderr.write('Error: modelProvider is set to "gemini" in settings.json, but the GEMINI_API_KEY environment variable is not set.\n');
  process.exit(1);
}

if (args[0] === "--version") {
  process.stdout.write("1.2.11\n");
  process.exit(0);
}

if (args[0] === "models") {
  record({ args, route: gemini ? "gemini" : "google", key: key ?? null });
  process.stdout.write("Fetching available models...\n");
  if (!gemini && process.env.AGY_BANNED === "1") {
    process.stdout.write(
      "Error: Eligibility check failed: PERMISSION_DENIED (code 403): This service has been disabled in this account for violation of Terms of Service. Please submit an appeal to continue using this product.. Please log out (/logout) and log back in (/login).\n",
    );
  } else if (gemini) {
    process.stdout.write("gemini-3.8-flash-high    Gemini 3.8 Flash (High)\ngemini-3.1-pro-high      Gemini 3.1 Pro (High)\n");
  } else {
    process.stdout.write("gemini-3.8-flash-high    Gemini 3.8 Flash (High)\nclaude-sonnet-4-6        Claude Sonnet 4.6 (Thinking)\n");
  }
  process.exit(0);
}

const flag = (name: string) => {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
};
const conversationsFile = `${logFile}.conversations`;
const known = existsSync(conversationsFile) ? readFileSync(conversationsFile, "utf8").split("\n").filter(Boolean) : [];
const asked = flag("--conversation");
if (asked && !known.includes(asked)) process.stderr.write(`warning: conversation ${asked} not found; starting a new one\n`);
const conversation = asked && known.includes(asked) ? asked : `c-${known.length + 1}`;
if (!known.includes(conversation)) appendFileSync(conversationsFile, conversation + "\n");
record({ args, cwd: process.cwd(), route: gemini ? "gemini" : "google", key: key ?? null, env: Object.keys(process.env).filter((name) => name.startsWith("CLAUDE")) });

const line = (message: object) => process.stdout.write(JSON.stringify(message) + "\n");
let index = 0;
/// A step's update; an ACTIVE step's DONE passes the index it was given.
const step = (fields: object, at = index++) => {
  line({ event: "step_update", step_update: { conversation_id: conversation, step_index: at, ...fields } });
  return at;
};
const spent = { input_tokens: 0, output_tokens: 0, thinking_tokens: 0, cache_read_tokens: 0, total_tokens: 0 };
let turns = 0;
function result(fields: object = {}) {
  line({ event: "result", result: { conversation_id: conversation, status: "SUCCESS", response: "", duration_seconds: 1, num_turns: turns, usage: { ...spent }, ...fields } });
}
function spend(input: number, cached: number, output: number) {
  spent.input_tokens += input;
  spent.cache_read_tokens += cached;
  spent.output_tokens += output;
  spent.total_tokens += input + output;
}
const pause = (ms = 5) => new Promise((resolve) => setTimeout(resolve, ms));

process.on("SIGINT", () => {
  record({ signal: "SIGINT" });
  process.exit(130);
});

line({ event: "init", conversation_id: conversation, init: { cwd: process.cwd(), tools: ["run_command", "write_to_file", "view_file"], permission_mode: args.includes("--mode") ? flag("--mode") : "request-review" } });

// One turn at a time, as agy takes them.
let queue = Promise.resolve();
createInterface({ input: process.stdin }).on("line", (text) => {
  const message = JSON.parse(text);
  queue = queue.then(() => turn(typeof message.message.content === "string" ? message.message.content : message.message.content[0].text));
});

async function turn(prompt: string): Promise<void> {
  turns += 1;
  record({ prompt });
  step({ state: "DONE", step_type: "user_input" });
  const file = join(process.cwd(), "hello.txt");
  switch (prompt) {
    case "wait":
      step({ state: "ACTIVE", step_type: "agent_response", text_delta: "Working" });
      setInterval(() => {}, 1000);
      return new Promise(() => {});
    case "fail":
      process.stderr.write('AGY_ERROR: {"status":"RESOURCE_EXHAUSTED","code":429,"retryable":true,"error_id":"e-1","message":"Gemini API quota exhausted for today."}\n');
      await pause(20);
      return result({ status: "ERROR", error: "RESOURCE_EXHAUSTED: quota exhausted" });
    case "crash":
      process.stderr.write('AGY_ERROR: {"short_error":"model unreachable"}\n');
      process.exit(3);
    case "late": {
      writeFileSync(file, readFileSync(file, "utf8").replace("two", "three"));
      const parameters = { TargetFile: file, TargetContent: "two", ReplacementContent: "three" };
      step({ state: "DONE", step_type: "tool", tool_name: "replace_file_content", tool_info: { name: "replace_file_content", parameters, output: "Edited." } });
      return result();
    }
    case "work": {
      const view = { name: "view_file", parameters: { AbsolutePath: file } };
      const viewing = step({ state: "ACTIVE", step_type: "tool", tool_name: "view_file", tool_info: view });
      step({ state: "DONE", step_type: "tool", tool_name: "view_file", tool_info: { ...view, output: "zero\none\nend\n" } }, viewing);
      const run = { name: "run_command", parameters: { CommandLine: "npm test", Cwd: process.cwd() } };
      step({ state: "DONE", step_type: "tool", tool_name: "run_command", tool_info: { ...run, error: { type: "permission_denied", message: "run_command requires approval that headless mode cannot prompt for." } } });
      const edit = { name: "replace_file_content", parameters: { TargetFile: "hello.txt", TargetContent: "one", ReplacementContent: "two" } };
      const editing = step({ state: "ACTIVE", step_type: "tool", tool_name: "replace_file_content", tool_info: edit });
      await pause(50);
      writeFileSync(file, readFileSync(file, "utf8").replace("one", "two"));
      step({ state: "DONE", step_type: "tool", tool_name: "replace_file_content", tool_info: { ...edit, output: "Edited hello.txt." } }, editing);
      const write = { name: "write_to_file", parameters: { TargetFile: join(process.cwd(), "new.txt"), CodeContent: "fresh\n" } };
      const writing = step({ state: "ACTIVE", step_type: "tool", tool_name: "write_to_file", tool_info: write });
      await pause(50);
      writeFileSync(join(process.cwd(), "new.txt"), "fresh\n");
      step({ state: "DONE", step_type: "tool", tool_name: "write_to_file", tool_info: { ...write, output: "Created new.txt." } }, writing);
      step({ state: "DONE", step_type: "agent_response", text_delta: "Done." });
      spend(200, 0, 20);
      return result({ response: "Done.", denied_actions: ["run_command(npm test)"] });
    }
    default:
      const answering = step({ state: "ACTIVE", step_type: "agent_response", thinking_delta: "A greeting." });
      step({ state: "ACTIVE", step_type: "agent_response", text_delta: "Hi" }, answering);
      step({ state: "DONE", step_type: "agent_response", text_delta: " there." }, answering);
      step({ state: "DONE", step_type: "checkpoint" });
      spend(1000, 800, 10);
      return result({ response: "Hi there." });
  }
}

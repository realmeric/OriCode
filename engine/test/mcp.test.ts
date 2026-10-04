// Settings › MCP, with the SDK's query stood in for.
import { test } from "node:test";
import assert from "node:assert/strict";
import { addArguments, mcpServers } from "../mcp.ts";

test("a folder's servers are listed without claude.ai's, a switch goes through the CLI first, and a server still connecting is looked at again", async () => {
  const calls: any[] = [];
  let looks = 0;
  const launch = ((args: any) => {
    calls.push(["query", args.options.cwd, args.options.settingSources]);
    return {
      initializationResult: async () => ({}),
      toggleMcpServer: async (name: string, on: boolean) => void calls.push(["toggle", name, on]),
      mcpServerStatus: async () => {
        looks += 1;
        return [
          { name: "linear", status: looks > 1 ? "connected" : "pending", scope: "user", config: { type: "http", url: "https://mcp.linear.app/mcp" }, tools: looks > 1 ? [{ name: "a" }, { name: "b" }] : undefined },
          { name: "files", status: "failed", scope: "local", error: "spawn ENOENT", config: { command: "npx", args: ["files-mcp", "--root", "."] } },
          { name: "claude.ai Gmail", status: "pending", scope: "claudeai" },
        ];
      },
      close: () => calls.push(["close"]),
    };
  }) as never;
  const servers = await mcpServers("/bin/claude", "/tmp/p", { name: "files", on: false }, launch);
  assert.deepEqual(servers, [
    { name: "linear", status: "connected", scope: "user", error: null, tools: 2, target: "https://mcp.linear.app/mcp" },
    { name: "files", status: "failed", scope: "local", error: "spawn ENOENT", tools: 0, target: "npx files-mcp --root ." },
  ]);
  assert.deepEqual(calls, [["query", "/tmp/p", ["user", "project", "local"]], ["toggle", "files", false], ["close"]]);
  assert.equal(looks, 2);
});

test("a URL is added as an HTTP server and anything else as a command, its quoted words kept whole", () => {
  assert.deepEqual(addArguments("linear", " https://mcp.linear.app/mcp ", "user"), ["mcp", "add", "--scope", "user", "--transport", "http", "linear", "https://mcp.linear.app/mcp"]);
  assert.deepEqual(addArguments("files", `npx files-mcp --root "My Notes"`, "local"), ["mcp", "add", "--scope", "local", "files", "--", "npx", "files-mcp", "--root", "My Notes"]);
});

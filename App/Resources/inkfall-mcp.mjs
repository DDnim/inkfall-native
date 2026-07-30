#!/usr/bin/env node
// Inkfall notes MCP bridge (stdio). Zero dependencies; Node 18+.
//
// Exposes the running Inkfall app's local notes API (127.0.0.1:48765/api) as
// five MCP tools. The bearer token is read from the app's data directory on
// every call, so regenerating the token in 设置 → 集成 needs no
// reconfiguration here.
//
// Register in Claude Code:
//   claude mcp add inkfall -- node /path/to/inkfall-mcp.mjs

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

// Overridable for remote-ish setups (devcontainer → host, another Mac):
//   INKFALL_API        base URL, e.g. http://host.docker.internal:48765
//   INKFALL_TOKEN      the token itself (wins over the file)
//   INKFALL_TOKEN_PATH read the token from this file instead of the default
const API = process.env.INKFALL_API || "http://127.0.0.1:48765";
const TOKEN_PATH =
  process.env.INKFALL_TOKEN_PATH ||
  join(homedir(), "Library/Application Support/app.inkfall.native/integration_token");

const TOOLS = [
  {
    name: "list_notes",
    description:
      "List Inkfall notes (id, title, createdAtMs, preview). Newest first.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "read_note",
    description: "Read one Inkfall note's full text by id.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string", description: "note id" } },
      required: ["id"],
      additionalProperties: false,
    },
  },
  {
    name: "create_note",
    description: "Create a new Inkfall note.",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "note body" },
        title: { type: "string", description: "optional title" },
      },
      required: ["text"],
      additionalProperties: false,
    },
  },
  {
    name: "update_note",
    description: "Update an Inkfall note's title and/or text by id.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" },
        title: { type: "string" },
        text: { type: "string" },
      },
      required: ["id"],
      additionalProperties: false,
    },
  },
  {
    name: "delete_note",
    description: "Delete an Inkfall note by id. This cannot be undone.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string" } },
      required: ["id"],
      additionalProperties: false,
    },
  },
];

function token() {
  if (process.env.INKFALL_TOKEN) {
    return process.env.INKFALL_TOKEN.trim();
  }
  try {
    return readFileSync(TOKEN_PATH, "utf8").trim();
  } catch {
    throw new Error(
      `无法读取令牌文件 ${TOKEN_PATH} —— 请先启动落音并在 设置 → 集成 中启用本地 API（容器内请设置 INKFALL_TOKEN）`,
    );
  }
}

async function api(method, path, body) {
  let response;
  try {
    response = await fetch(`${API}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token()}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
  } catch {
    throw new Error("连不上落笔（127.0.0.1:48765）——请先启动 Inkfall.app");
  }
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || payload.ok === false) {
    throw new Error(payload.message || `API ${response.status}`);
  }
  return payload;
}

async function callTool(name, args = {}) {
  switch (name) {
    case "list_notes":
      return (await api("GET", "/api/notes")).notes;
    case "read_note":
      return (await api("GET", `/api/notes/${encodeURIComponent(args.id)}`)).note;
    case "create_note":
      return (await api("POST", "/api/notes", { text: args.text, title: args.title })).note;
    case "update_note": {
      const body = {};
      if (args.title !== undefined) body.title = args.title;
      if (args.text !== undefined) body.text = args.text;
      await api("PATCH", `/api/notes/${encodeURIComponent(args.id)}`, body);
      return { updated: args.id };
    }
    case "delete_note":
      await api("DELETE", `/api/notes/${encodeURIComponent(args.id)}`);
      return { deleted: args.id };
    default:
      throw new Error(`unknown tool: ${name}`);
  }
}

// ---- MCP stdio plumbing: one JSON-RPC message per line. ----

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

function reply(id, result) {
  send({ jsonrpc: "2.0", id, result });
}

function replyError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  line = line.trim();
  if (!line) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  void handle(message);
});

async function handle(message) {
  const { id, method, params } = message;
  if (method === "initialize") {
    reply(id, {
      protocolVersion: params?.protocolVersion || "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "inkfall-notes", version: "1.0.0" },
    });
    return;
  }
  if (method === "notifications/initialized" || method?.startsWith("notifications/")) {
    return; // notifications need no reply
  }
  if (method === "ping") {
    reply(id, {});
    return;
  }
  if (method === "tools/list") {
    reply(id, { tools: TOOLS });
    return;
  }
  if (method === "tools/call") {
    try {
      const result = await callTool(params.name, params.arguments);
      reply(id, {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      });
    } catch (error) {
      reply(id, {
        content: [{ type: "text", text: String(error.message || error) }],
        isError: true,
      });
    }
    return;
  }
  if (id !== undefined) {
    replyError(id, -32601, `method not found: ${method}`);
  }
}

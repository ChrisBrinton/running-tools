import { Hono } from "hono";
import type { Store } from "../db.js";
import { TOOL_DESCRIPTORS, callTool } from "./tools.js";

interface JsonRpcRequest {
  jsonrpc?: string;
  id?: unknown;
  method?: string;
  params?: Record<string, unknown>;
}

export function mountMCP(app: Hono, store: Store) {
  app.post("/mcp", async (c) => {
    const auth = c.get("auth");
    let req: JsonRpcRequest;
    try {
      req = await c.req.json();
    } catch {
      return c.json(
        { jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } },
        400
      );
    }

    const id = req.id ?? null;
    if (!req.method) {
      return c.json({
        jsonrpc: "2.0",
        id,
        error: { code: -32600, message: "Invalid Request — missing 'method'" },
      });
    }
    const params = req.params ?? {};

    try {
      const result = await dispatch(store, auth.user.id, req.method, params);
      if (result === undefined) return new Response(null, { status: 204 });
      return c.json({ jsonrpc: "2.0", id, result });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return c.json({
        jsonrpc: "2.0", id,
        error: { code: -32000, message: msg },
      });
    }
  });
}

async function dispatch(
  store: Store, userID: number, method: string, params: Record<string, unknown>
): Promise<unknown> {
  switch (method) {
    case "initialize":
      return {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "pacerunner-home", version: "0.2" },
      };
    case "notifications/initialized":
      return undefined;
    case "tools/list":
      return { tools: TOOL_DESCRIPTORS };
    case "tools/call": {
      const name = params.name as string | undefined;
      if (!name) throw new Error("Missing 'name'");
      const args = (params.arguments as Record<string, unknown> | undefined) ?? {};
      const payload = await callTool(store, userID, name, args);
      return {
        content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
      };
    }
    default:
      throw new Error(`Method not found: ${method}`);
  }
}

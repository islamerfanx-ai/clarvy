// Run Clarvy on any Node host (Render, Railway, a VPS, or your laptop): `npm start`
import http from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { ask, search, config } from "./lib/core.js";
import { brief, criteria, decide, faq, helper, question, roles, startDecideWorker, triage, voice, admin, adminGrowth, adminAccess, adminRevenue, adminAsk, adminOrgs, orgInvite } from "./lib/rooms.js";

const root = join(fileURLToPath(new URL(".", import.meta.url)), "public");
const types = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".json": "application/json", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".ico": "image/x-icon" };
const routes = { "/api/ask": ask, "/api/search": search, "/api/config": config, "/api/rooms/decide": decide, "/api/rooms/triage": triage, "/api/rooms/criteria": criteria, "/api/rooms/roles": roles, "/api/rooms/question": question, "/api/rooms/voice": voice, "/api/rooms/brief": brief, "/api/rooms/helper": helper, "/api/faq": faq, "/api/admin/overview": admin, "/api/admin/growth": adminGrowth, "/api/admin/access": adminAccess, "/api/admin/revenue": adminRevenue, "/api/admin/ask": adminAsk, "/api/admin/orgs": adminOrgs, "/api/org/invite": orgInvite };
const MAX_BODY = 8 * 1024 * 1024;

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  const route = routes[url.pathname];
  if (route) {
    let size = 0; const chunks = [];
    for await (const c of req) { size += c.length; if (size > MAX_BODY) { res.writeHead(413); return res.end('{"code":"prompt_too_large"}'); } chunks.push(c); }
    try { req.body = JSON.parse(Buffer.concat(chunks).toString() || "{}"); } catch { req.body = {}; }
    const out = await route(req);
    res.writeHead(out.status, { "Content-Type": "application/json" });
    return res.end(JSON.stringify(out.body));
  }
  const path = normalize(url.pathname === "/" ? "/index.html" : url.pathname).replace(/^(\.\.[/\\])+/, "");
  try {
    const file = await readFile(join(root, path));
    res.writeHead(200, { "Content-Type": types[extname(path)] || "application/octet-stream" });
    res.end(file);
  } catch { res.writeHead(404); res.end("Not found"); }
}).listen(process.env.PORT || 3000, process.env.HOST, () => { console.log(`Clarvy running on http://localhost:${process.env.PORT || 3000}`); startDecideWorker(); });

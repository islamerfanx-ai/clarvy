import { config as roomsConfig } from "../lib/core.js";
export default async function handler(req, res) {
  const out = await roomsConfig(req);
  res.status(out.status).json(out.body);
}

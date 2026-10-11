import { search } from "../lib/core.js";
export const config = { maxDuration: 60 };
export default async function handler(req, res) {
  const out = await search(req);
  res.status(out.status).json(out.body);
}

// Writes build.json (version, build number, commit, date, message) for the admin page. The deploy runs it
// (`npm run build`); without git history it writes what it can and never fails the build.
import { execSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const git = cmd => { try { return execSync(`git ${cmd}`, { stdio: ["ignore", "pipe", "ignore"] }).toString().trim() || null; } catch { return null; } };
const shallow = git("rev-parse --is-shallow-repository") === "true";
const info = {
  version: JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version,
  build: shallow ? null : Number(git("rev-list --count HEAD")) || null,
  commit: git("rev-parse --short HEAD"),
  date: git("log -1 --format=%cI") || new Date().toISOString(),
  message: git("log -1 --format=%s")
};
writeFileSync(new URL("../build.json", import.meta.url), JSON.stringify(info) + "\n");
console.log("build.json:", info.version, info.build ?? "", info.commit ?? "");

// Secrets on hosts without a service manager (Hostinger): KEY=value lines in ~/.dxrooms.env, outside the
// deployed folder so a redeploy never replaces them. Imported first by server.js; variables already set win.
import { homedir } from "node:os";
import { join } from "node:path";

try { process.loadEnvFile(process.env.ENV_FILE || join(homedir(), ".dxrooms.env")); } catch {}

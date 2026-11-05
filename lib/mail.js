// Email from noreply@dxrooms.com through Private Email (or any SMTP server with TLS on connect), with no extra
// packages. SMTP_HOST, SMTP_PORT (465), SMTP_USER, SMTP_PASS; MAIL_FROM is the From line (the mailbox by default,
// and the server only accepts its own address). Plain text only, UTF-8, so Arabic needs nothing special.
import tls from "node:tls";
import crypto from "node:crypto";

export const mailReady = () => !!(process.env.SMTP_HOST && process.env.SMTP_USER && process.env.SMTP_PASS);
const fromLine = () => process.env.MAIL_FROM || `Decision Rooms <${process.env.SMTP_USER}>`;

// Header words outside plain ASCII go as UTF-8 encoded-words, a few characters each so every line stays short.
const header = s => {
  s = String(s).replace(/[\r\n]+/g, " ");
  if (/^[\x20-\x7e]*$/.test(s)) return s;
  const ch = [...s], words = [];
  for (let i = 0; i < ch.length; i += 11) words.push(`=?UTF-8?B?${Buffer.from(ch.slice(i, i + 11).join("")).toString("base64")}?=`);
  return words.join("\r\n ");
};

// One reply at a time: a reply ends at the line whose code is followed by a space ("250 OK", not "250-...").
function talk(sock) {
  let buf = "", err = null;
  const waiting = [];
  const pump = () => {
    while (waiting.length) {
      const lines = buf.split("\r\n"), whole = lines.slice(0, -1), end = whole.findIndex(l => /^\d{3} /.test(l));
      if (end < 0) { if (!err) return; waiting.shift().reject(err); continue; }
      buf = lines.slice(end + 1).join("\r\n");
      waiting.shift().resolve({ code: Number(whole[end].slice(0, 3)), text: whole.slice(0, end + 1).join(" ") });
    }
  };
  const fail = e => { err = err || e; pump(); };
  sock.setEncoding("utf8");
  sock.on("data", d => { buf += d; pump(); });
  sock.on("error", fail);
  sock.on("close", () => fail(new Error("smtp: connection closed")));
  return async (line, ok) => {
    if (line != null) sock.write(line + "\r\n");
    const r = await new Promise((resolve, reject) => { waiting.push({ resolve, reject }); pump(); });
    if (!ok.includes(r.code)) throw new Error(`smtp: ${r.text.slice(0, 200)}`);
    return r;
  };
}

export async function sendMail({ to, subject, text }) {
  if (!/^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(String(to))) throw new Error("smtp: bad address");
  const host = process.env.SMTP_HOST, port = Number(process.env.SMTP_PORT) || 465;
  const m = fromLine().match(/^\s*(.*?)\s*<([^>]+)>\s*$/), name = m ? m[1] : "", addr = m ? m[2] : fromLine().trim();
  const domain = addr.split("@")[1];
  const body = Buffer.from(String(text).replace(/\r?\n/g, "\r\n")).toString("base64").replace(/.{76}/g, "$&\r\n");
  const message = [
    `From: ${name ? `${header(name)} <${addr}>` : addr}`, `To: ${to}`, `Subject: ${header(subject)}`,
    `Date: ${new Date().toUTCString()}`, `Message-ID: <${crypto.randomUUID()}@${domain}>`,
    "MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64",
    "Auto-Submitted: auto-generated", "", body
  ].join("\r\n");

  const sock = tls.connect({ host, port, servername: host });
  sock.setTimeout(20000, () => sock.destroy(new Error("smtp: timeout")));
  const say = talk(sock);
  try {
    await say(null, [220]);
    await say(`EHLO ${domain}`, [250]);
    await say(`AUTH PLAIN ${Buffer.from(`\0${process.env.SMTP_USER}\0${process.env.SMTP_PASS}`).toString("base64")}`, [235]);
    await say(`MAIL FROM:<${addr}>`, [250]);
    await say(`RCPT TO:<${to}>`, [250, 251]);
    await say("DATA", [354]);
    await say(`${message}\r\n.`, [250]);
    await say("QUIT", [221]).catch(() => {});
  } finally { sock.destroy(); }
}

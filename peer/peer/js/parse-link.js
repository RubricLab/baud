// The native-free parser for a static add page: reads kind, name, user and expiry so the page can
// say "Dexter wants to be friends" before anything is dialed. Leaves `meet` and `secret` opaque.
// Mirrors SPEC.md "Links" and passes vectors/links.json. No dependencies, ES2020.

const VERSION = "peer1";
const MAX_NAME_BYTES = 64;
// The dotless form's first byte, for `peer1` (SPEC.md Links, 0.2.10).
const DOTLESS = 1;
// The grouped form's first byte (SPEC.md Links, 0.2.19): base32 in dash-joined groups.
const GROUPED = 2;

function b64url(s) {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) throw new Error("base64");
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

/** The grouped form's bytes, or null when it isn't one: base32 in one case, dashes and spaces dropped. */
function base32(frag) {
  const t = frag.replace(/[-\s]/g, "");
  if (!t || !(/^[a-z2-7]+$/.test(t) || /^[A-Z2-7]+$/.test(t))) return null;
  const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  if ([1, 3, 6].includes(t.length % 8)) return null;
  const out = [];
  let bits = 0, acc = 0;
  for (const c of t.toUpperCase()) {
    acc = (acc << 5) | A.indexOf(c);
    bits += 5;
    if (bits >= 8) { bits -= 8; out.push((acc >> bits) & 0xff); }
  }
  if (acc & ((1 << bits) - 1)) return null;
  return Uint8Array.from(out);
}

const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
const b64urlOf = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** One base64url token: version, kind, name length and name, user, expires (big-endian), secret, meet. */
function parseDotless(frag) {
  const b = b64url(frag);
  if (b.length < 3) throw new Error("fields");
  if (b[0] !== DOTLESS) throw new Error("version");
  const kind = String.fromCharCode(b[1]);
  if (kind !== "f" && kind !== "m" && kind !== "r") throw new Error("kind");
  const n = b[2];
  if (n > MAX_NAME_BYTES) throw new Error("name");
  if (b.length < 3 + n + 32 + 8 + 32) throw new Error("fields");
  const name = new TextDecoder("utf-8", { fatal: true }).decode(b.subarray(3, 3 + n));
  const user = b.subarray(3 + n, 35 + n);
  const expires = Number(new DataView(b.buffer, b.byteOffset + 35 + n, 8).getBigUint64(0));
  if (!Number.isSafeInteger(expires)) throw new Error("expires");
  const secret = b.subarray(43 + n, 75 + n);
  // `meet` stays opaque, in the dotted form's shape: its base64url.
  return { kind, name, user: hex(user), expires, meet: b64urlOf(b.subarray(75 + n)), secret: b64urlOf(secret) };
}

/** The grouped form: version, kind, name length and name, user, expires (big-endian), secret, packed meet. */
function parseGrouped(b) {
  const kind = String.fromCharCode(b[1]);
  if (kind !== "f" && kind !== "m" && kind !== "r") throw new Error("kind");
  const n = b[2];
  if (n > MAX_NAME_BYTES) throw new Error("name");
  if (b.length < 3 + n + 32 + 8 + 32 + 32 + 1) throw new Error("fields");
  const name = new TextDecoder("utf-8", { fatal: true }).decode(b.subarray(3, 3 + n));
  const user = b.subarray(3 + n, 35 + n);
  const expires = Number(new DataView(b.buffer, b.byteOffset + 35 + n, 8).getBigUint64(0));
  if (!Number.isSafeInteger(expires)) throw new Error("expires");
  const secret = b.subarray(43 + n, 75 + n);
  // `meet` stays opaque: its packed bytes, base64url.
  return { kind, name, user: hex(user), expires, meet: b64urlOf(b.subarray(75 + n)), secret: b64urlOf(secret) };
}

/** @returns {{kind: "f"|"m"|"r", name: string, user: string, expires: number, meet: string, secret: string}} user is hex */
export function parseLink(input) {
  const s = input.trim();
  const frag = s.includes("#") ? s.slice(s.lastIndexOf("#") + 1) : s;
  const g = base32(frag);
  if (g && g[0] === GROUPED) return parseGrouped(g);
  if (!frag.includes(".")) return parseDotless(frag);
  const f = frag.split(".");
  if (f.length !== 7) throw new Error("fields");
  if (f[0] !== VERSION) throw new Error("version");
  if (f[1] !== "f" && f[1] !== "m" && f[1] !== "r") throw new Error("kind");
  const nameBytes = b64url(f[2]);
  if (nameBytes.length > MAX_NAME_BYTES) throw new Error("name");
  const name = new TextDecoder("utf-8", { fatal: true }).decode(nameBytes);
  const user = b64url(f[3]);
  if (user.length !== 32) throw new Error("user");
  if (!/^(0|[1-9][0-9]*)$/.test(f[4])) throw new Error("expires");
  const expires = Number(f[4]);
  if (!Number.isSafeInteger(expires)) throw new Error("expires");
  b64url(f[5]); // well-formed; its meaning is the app's
  const secret = b64url(f[6]);
  if (secret.length !== 32) throw new Error("secret");
  return { kind: f[1], name, user: hex(user), expires, meet: f[5], secret: f[6] };
}

export const expired = (link, nowSecs = Math.floor(Date.now() / 1000)) => nowSecs >= link.expires;

/** "Dexter wants to be friends", "Add this computer to Dexter's" or, for a reply to a friend
 * link, "Dexter's reply: open it in the app to finish adding them", for the page. */
export function describe(link) {
  const who = link.name || "Someone";
  if (link.kind === "r") return `${who}'s reply: open it in the app to finish adding them`;
  return link.kind === "f" ? `${who} wants to be friends` : `Add this device to ${who}'s`;
}

// Runs vectors/links.json against parse-link.js. `bun js/test.mjs` or `node js/test.mjs`.
import { readFileSync } from "node:fs";
import { parseLink, expired } from "./parse-link.js";

const vectors = JSON.parse(readFileSync(new URL("../vectors/links.json", import.meta.url), "utf8"));
let failed = 0;
for (const c of vectors.cases) {
  // The page parser leaves `meet` opaque by design (SPEC.md Links); only the native parser judges it.
  if (c.expect.error === "meet") continue;
  let got;
  try {
    got = parseLink(c.input);
  } catch (e) {
    if (c.expect.error) continue;
    console.log(`FAIL ${c.name}: threw ${e.message}`);
    failed++;
    continue;
  }
  if (c.expect.error) {
    console.log(`FAIL ${c.name}: expected error ${c.expect.error}, parsed ${JSON.stringify(got)}`);
    failed++;
    continue;
  }
  const checks = [
    [got.kind, c.expect.kind], [got.name, c.expect.name], [got.user, c.expect.user],
    [got.expires, c.expect.expires], [expired(got, vectors.now), c.expect.expired],
  ];
  for (const [a, b] of checks) {
    if (a !== b) {
      console.log(`FAIL ${c.name}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`);
      failed++;
      break;
    }
  }
}
console.log(`${vectors.cases.length - failed}/${vectors.cases.length} link vectors pass in JS`);
process.exit(failed ? 1 : 0);

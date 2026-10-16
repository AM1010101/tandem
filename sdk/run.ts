// Runs a script against a Tandem project and prints only what it returns.
//
//   bun sdk/run.ts <project.tandem | folder> script.ts
//   bun sdk/run.ts <project.tandem | folder> -e 'const p = await t.project(); return p.transitions().length'
//   echo '...' | bun sdk/run.ts <project> -
//
// A script file default-exports `async (t, sdk) => result`. Inline code (-e or stdin) runs as
// the body of an async function with `t` (the open Tandem), `cmd`, `fixCaptionWords` and `sdk`
// (the whole module) in scope. The result prints as compact JSON (a string prints as is).
// If nothing serves the project, `tandem serve` is started for the run and stopped after.

import { resolve } from "node:path";
import * as sdk from "./tandem";

const [projectArg, scriptArg, code] = process.argv.slice(2);
if (!projectArg || !scriptArg || (scriptArg === "-e" && !code)) {
  console.error("Usage: bun sdk/run.ts <project.tandem | folder> <script.ts | -e '<code>' | ->");
  process.exit(2);
}

let fn: (t: sdk.Tandem, mod: typeof sdk) => unknown;
if (scriptArg === "-e" || scriptArg === "-") {
  const body = scriptArg === "-e" ? code : await new Response(Bun.stdin.stream()).text();
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const inner = new AsyncFunction("t", "cmd", "fixCaptionWords", "sdk", body);
  fn = (t, mod) => inner(t, mod.cmd, mod.fixCaptionWords, mod);
} else {
  fn = (await import(resolve(scriptArg))).default;
  if (typeof fn !== "function") {
    console.error(`${scriptArg} must default-export an async function (t, sdk) => result`);
    process.exit(2);
  }
}

const t = await sdk.Tandem.open(projectArg);
let exitCode = 0;
try {
  const result = await fn(t, sdk);
  if (result !== undefined) console.log(typeof result === "string" ? result : JSON.stringify(result));
} catch (e) {
  exitCode = 1;
  if (e instanceof sdk.TandemError) console.error(`error: ${e.message}`);
  else console.error(e instanceof Error ? (e.stack ?? e.message) : e);
} finally {
  await t.close();
}
process.exit(exitCode);

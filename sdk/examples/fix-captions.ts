// Patch the captions' misheard words (text, per-word list and name) in one labelled edit.
//   bun sdk/run.ts "Video Shorts.tandem" sdk/examples/fix-captions.ts
import { fixCaptionWords, type Tandem } from "../tandem";

export default async (t: Tandem) => {
  const p = await t.project();
  const { commands, changes } = fixCaptionWords(p, {
    comics: "Convex",
    evils: "evals",
    roots: "routes",
    rights: "writes",
  });
  return { changes: changes.map((c) => `${c.before} -> ${c.after}`), edit: await t.edit("Fix misheard caption words", commands) };
};

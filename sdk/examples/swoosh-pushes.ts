// Give every push that has no sound yet the light swoosh, peaking on the cut.
//   bun sdk/run.ts Video.tandem sdk/examples/swoosh-pushes.ts
import { cmd, type Tandem } from "../tandem";

export default async (t: Tandem) => {
  const p = await t.project();
  const mediaID = p.media("swoosh.m4a").id; // or the med_ ID `tandem assets use` printed
  const pushes = p.transitions((tr) => tr.type === "push" && !tr.soundClipID);
  return t.edit(
    "Swooshes on the pushes",
    pushes.map((tr) => cmd.updateTransition({ transitionID: tr.id, patch: { sound: { mediaID, gainDB: -23.3, offset: -0.39 } } })),
  );
};

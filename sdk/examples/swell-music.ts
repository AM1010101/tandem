// Swell the music bed +6 dB in every pause long enough, skipping pauses a sound effect plays in.
// audio.gainDB keyframes set the gain outright and are clip-relative.
//   bun sdk/run.ts Video.tandem sdk/examples/swell-music.ts
import { cmd, type Keyframe, type Tandem } from "../tandem";

const MIN_PAUSE = Number(process.env.MIN_PAUSE ?? 1.6);

export default async (t: Tandem) => {
  const p = await t.project();
  const { pauses } = await t.pauses(MIN_PAUSE);
  const music = p.track("Music").clips[0];
  const base = music.audio?.gainDB ?? 0;
  const sfx = p.clips((c) => c.track.name.startsWith("SFX"));
  const quiet = pauses.filter((x) => !sfx.some((c) => c.start < x.end && x.start < c.end));
  const keyframes: Keyframe[] = [{ time: 0, value: base }];
  for (const x of quiet) {
    const s = x.start - music.start;
    const e = x.end - music.start;
    const r = Math.min(0.1, (e - s) / 3);
    keyframes.push({ time: s, value: base }, { time: s + r, value: base + 6 }, { time: e - r, value: base + 6 }, { time: e, value: base });
  }
  return t.edit(`Swell the music +6 dB in ${quiet.length} pauses`, [
    cmd.setKeyframes({ clipID: music.id, parameter: "audio.gainDB", keyframes }),
  ]);
};

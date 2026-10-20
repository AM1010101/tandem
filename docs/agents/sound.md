# Sound

Recipes for levelling the voice, measuring the mix instead of guessing (loudness over time, checking gain lanes), and putting a swoosh on every push. Gain keyframes and clip gain are in [edit-commands.md](edit-commands.md#keyframes).

## Level the voice

Speech is levelled per take to the project's speech level, -20 LUFS, and
export brings the whole mix to the project's `loudnessTarget` (-14 LUFS
unless set) with true peaks under its `truePeakCeiling` (-1 dBTP), and says
what it mastered to. So the speech level sets how the voice sits against
the music and sound effects (and how loud the app plays), not how loud the
video is. Placing media levels new speech by itself; a project imported
with its own gains, or made before the speech level existed, gets there
with one command:

```bash
tandem loudness                              # each file's loudness, each track's levels
tandem apply - <<< '{"normalizeSpeech": {}}'
tandem loudness                              # "Speech is levelled to -20.0 LUFS" and no stragglers
```

To move the voice for the whole video, change the level (clips normalised
to the old level follow it), then check a review clip:

```json
{"label": "Voice a little louder", "commands": [
  {"updateSettings": {"patch": {"speechLoudness": -18}}}
]}
```

A single clip can still differ: `{"updateClip": {"clipID": "clip_voc7",
"patch": {"audio": {"gainDB": 2}}}}` plays it 2 dB over the rest.

## Check the sound

Don't run ffmpeg on a review clip to hear how loud something is. Tandem
measures the mix itself, through the same composition, gain taps and
time-pitch as export:

```bash
tandem loudness --from 1:00 --to 1:30              # the mix, a row every 0.5 s
tandem loudness --from 1:00 --to 1:30 --tracks Music --step 0.2
tandem loudness --from 1:00 --to 1:30 --gains      # does the render follow the gain lanes?
tandem loudness --from 0 --to 18:00 --tracks Voice --over 0   # where does the voice clip?
tandem clip 1:00 1:30 --tracks Music --audio-only  # listen to the music bed alone
tandem assets show elevenlabs:music_2p839smz       # its prompt, licence, loudness and file
```

Each row has the momentary loudness (the 400 ms centred on its time), the
short-term (3 s) and the highest sample, with the range's integrated
loudness, true peak and a sparkline above. They're the levels the timeline
plays at, before export's master gain, which moves the whole range by the
same amount, so compare things with each other: a swell 6 dB over the bed
around it, the bed about 25 LU under the voice, a sound effect's peak
against the speech. `--tracks` measures only those audio tracks (names or
IDs); `--json` gives every point. A long range at a small step reads as
the summary without the rows; the JSON still has them.

`--over <dBFS>` lists only the windows whose highest sample is over that
level, merged into stretches with their peak: the direct answer to "where
does this clip" (`--over 0`) or "what touches the ceiling" (`--over -1`).
Without `--step` it measures every 0.4 s, so the windows cover the range.

`--gains` checks the render against the gain lanes (the clips' levelling,
gain, gain keyframes and fades). It renders each track (the `--tracks`
ones, or every one that plays there) as it is and again with its gain
flattened, and compares their difference with the lane 10 ms at a time.
It says when a change lands late and by how much, and lists where the
render plays more than 1 dB off the lane. If Mike says a gain change
plays late, run it before arguing: it checks the render does what the
lanes say (a lane set in the wrong place is a different problem, which
`tandem timeline` shows).

## Put a swoosh on every push

A swoosh belongs to its transition: give a push a `sound` and it goes
where the push goes, and away with it. The light swoosh Mike likes (the
app's default for push, slide, cut slide and wipe) is
`elevenlabs:sfx_2ybnc2tu` in his asset library. Copy it into the project
once, find the pushes that have no sound yet, and give them all one in one
batch:

```bash
tandem assets use elevenlabs:sfx_2ybnc2tu     # adds it to the media: med_rgm8r7d7
tandem timeline --json | jq -r '.project.videoTracks[].transitions[] | select(.type == "push" and .soundClipID == null) | .id'
# tr_k3f9x2mq
# tr_p8zq4w2m
```

```json
{"label": "Swooshes on the pushes", "commands": [
  {"updateTransition": {"transitionID": "tr_k3f9x2mq", "patch": {"sound": {"mediaID": "med_rgm8r7d7", "gainDB": -23.3, "offset": -0.39}}}},
  {"updateTransition": {"transitionID": "tr_p8zq4w2m", "patch": {"sound": {"mediaID": "med_rgm8r7d7", "gainDB": -23.3, "offset": -0.39}}}}
]}
```

Each goes on SFX (SFX 2 where SFX is taken) starting 0.39 s before the
cut, so its loudest moment lands where the push moves fastest (the light
swoosh is loudest 0.39 s in). -23.3 dB is for speech at Tandem's -20 LUFS:
its loudest 400 ms then sits 15 LU under the voice, as the section card
whooshes do. In a project whose speech plays elsewhere (`tandem loudness`
says where), move the gain by the difference: -32 for speech at -28.7. For
another sound, `offset` is minus the moment it's loudest, and the gain puts
that 15 LU under the speech. A push that already has a whoosh placed by
hand beside it can keep that one: tie it with `{"soundClipID": "clip_..."}`
in the patch, and it moves and goes with the push from then on. A new push
can get its sound in the same command:

```json
{"addTransition": {"trackID": "trk_camera", "transition": {"type": "push", "fromClipID": "clip_a", "toClipID": "clip_b"}, "sound": {"mediaID": "med_rgm8r7d7", "gainDB": -23.3, "offset": -0.39}}}
```

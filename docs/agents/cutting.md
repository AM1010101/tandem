# Cutting the take

Recipes for tightening pauses, cutting a phrase, a false start or a rough cut pause to pause, joining through-edits back up, keeping the camera's picture in sync with its sound, and adding another camera angle or an external mic.

## Tighten pauses

```bash
tandem pauses --min 0.5                      # what's there
tandem tighten --mike                        # the plan, nothing changes
tandem tighten --mike --protect 2:14.5,5:03 --widen --apply
tandem clip 0:00 1:00 -o /tmp/review.mp4     # watch the result
tandem undo                                  # if it's too tight
```

`--mike` is Mike's rules ("How Mike likes a take cut" in the skill): 0.4 s
after a sentence, 0.12 s after a comma and 0.08 s for a thinking pause
mid-sentence, and only pauses of 0.5 s or more change, so breaths and
natural pauses stay as he said them. What a pause follows comes from the
punctuation on the word before it: `. ? !` (or `...`) end a sentence,
`, ; :` are a comma, anything else is mid-sentence. Set or override each
keep with `--sentence`, `--comma` and `--mid`; a kind with no keep is left
alone, and a comma without one uses `--mid`. `--min` (default 0.5 here) is
the shortest sentence pause that changes and `--mid-min` (default 0.5) the
shortest comma or mid-sentence one. Each cut is as many whole frames as fit,
so what's kept is within a frame of the keep.

`--protect` takes timeline times, comma separated (or the option again):
the pauses containing them are left alone, for the beats Mike wants kept (a
point landing, a reaction, something animating on screen). The plan lists
what it protected.

`--widen` also opens up joins that are too tight: where a cut between two
speech clips leaves less than the keep for what it follows (0.2 s between
sentences after a retake was cut, say), it brings back silence from the take
either side with ripple trims, so the camera and screen stay in sync. It
only takes silence before the take's next transcribed word (less 40 ms) and
nothing where a word runs through the clip's edge, so it never brings back
speech the transcript knows about; an "um" the transcript left out can come
back, so listen to widened joins. It's off unless you ask, and leaves
through-edits and protected joins alone.

Without any of those, every pause of at least `--min` (0.6) is shortened to
`--keep` (0.15), half the kept pause after the last word and half before the
next one, with the cut edges rounded inwards to frames.

The transcript only finds the pauses. Each one is then listened to, on
every unmuted audio track of the take that plays there (the voice, another
mic, a device's own recording cut with the take; not music, sound effects
or video tracks' sound), each against its own file's floor, the way
`check --cuts` reads the sound:

- The keep is measured from the sound: from the end of the last word's
  sound to the start of the next word's, not the transcript's times (they
  can be 0.2 s off). `--min` is too, so a gap the transcript makes 0.6 s
  that's 0.4 s in the sound isn't cut.
- The cut goes in a real pause (quiet on every track) and never through
  sound no word accounts for: someone off mic, an app talking, a breath,
  an "um" the transcript left out. That sound stays where it is and the
  cut goes in the longest quiet beside it, keeping at least 30 ms either
  side, so a gap with sound in it can end up longer than the keep. If
  there's no quiet long enough, the pause is left alone.
- Both sides of every join are judged as `check --cuts` judges them, and a
  cut whose join wouldn't be clean is left out.

The plan says which pauses it left alone and why (sound in them, with
where and on which track; under the minimum in the sound; a join that
wouldn't be clean), and each cut beside sound says where that sound is, so
listen to those with `tandem clip`. To take out an "um" it kept, cut it
with `tandem cut --range`. A file whose sound can't be read is tightened
from the transcript's gaps as before, with a warning. The plan is a batch of
`rippleDeleteRange` commands (and the widening's `trim`s), latest first so
every time is in the current timeline's times; `--json` prints it if you'd
rather adjust it and `apply` it yourself. `--from` and `--to` limit it to
part of the video. In MCP: `tighten {"mike": true, "protect": [134.5],
"widen": true}`, then again with `"apply": true, "expectedRevision": <the
plan's revision>`.

## Cut a phrase

```bash
tandem cut "as I said before"                # the plan, nothing changes
tandem cut "as I said before" --apply
```

```
Cut 1 stretch pause to pause (dry run, revision 57), removing 2.150s: 12:04.300 -> 12:02.150.
  02:14.060-02:16.210  "as I said before"  ...so the model | picks the...  keeps 0.120s of pause; join clean (28 and 26 dB under the speech)
Nothing changed yet. Run again with --apply (or apply: true) to make the cut.
```

Don't cut at the times `tandem search` gives. Transcript times are 30 to
200 ms off the sound, and a cut there chops the word that stays while it's
still sounding (#64). `tandem cut` finds the phrase as `search` does, then
puts the start of the cut in the real pause before its first word and the
end in the real pause after its last, found in the voice's own sound (the
raw mic, read the way `check --cuts` reads it). The transcript only says
roughly where the words are and which ones stay. A real pause is 80 ms or
more of quiet, full band and above 4 kHz alike; a word the transcript has
0.2 s late still lands on the right side of it.

The join keeps the pause Mike's tighten rules would (0.4 s after a
sentence, 0.12 s after a comma, 0.08 s mid-sentence, by the word before the
cut), split either side as `tighten` splits it but never under 0.03 s after
the word before or 0.08 s before the word after, and never closer than
0.03 s to the words cut. Where neither pause was 0.5 s, the join keeps the
longer one as it was. Each edge goes on a frame where one lands in its
pause. The pauses are timeline time, so on a clip at 2x the join keeps
twice as much of the file. Each edge goes in a pause its own clip plays: a
pause in the file past the clip's end isn't heard there. Both sides of
every join are judged as `check --cuts` judges them, and the plan gives
each side's margin under the speech; a side that doesn't judge clean isn't
cut.

A stretch with no pause round it, like a filler or a repeat inside running
speech ("do that [because of] to keep"), is left in, with the reason:
cutting there clips a word however exactly it's placed, and on the Ian
video leaving the filler in is what sounded right. So is one where the
voice runs on more than 0.3 s past where the transcript has its words.
Sound no transcript word claims, inside the stretch or within 0.3 s of it,
is cut with it. When cutting it would also cut a word that stays, it's
left and the stretch's `missed` says how much, so listen there.

A phrase said more than once needs `--at` with (roughly) the time of the
one to cut, and that counts overlapping ones ("very very" is said twice in
"very very very"); with several phrases, the first `--at` goes with the
first phrase. Each voice track's words are matched on their own, so a
phrase both mics of an interview hear is said once. In MCP and HTTP: `cut {"remove": [{"phrase": "as I said before"},
{"phrase": "you know", "at": "3:10"}]}`, then again with `"apply": true,
"expectedRevision": <the plan's revision>`.

Every stretch goes into one `cutRanges`, so the whole take (camera, screen
and voice) loses the same time, B-roll, music and titles follow, and one
undo puts it all back. `--json` prints the plan with its `commands` if
you'd rather adjust them and `apply` them yourself. Listen to the result
with `tandem clip 2:08 2:20`.

## Rough cuts and false starts

For a rough cut, give `tandem cut` every stretch to drop as a timeline
range, from roughly where its first word starts to where its last ends, in
any order; it plans each one as it does a phrase:

```bash
tandem cut --range 0-18.15 --range 25.6-46.24 "as I said before" --apply
```

A stretch over 2 s is a long false start: when there's no pause between
its last word and the restart, it's cut pause to pause anyway, ending in
the last pause inside it, so a word of it can come back ("the way we, we do
it"). The result says which words come back. On the Ian video putting back
a cut of 2 s or less sounded right, so anything longer costs more to keep
than a repeated word. `--false-start` (or `"falseStart": true` on a
stretch) does the same for a shorter one.

For an exact cut at times you've checked by ear, `cutRanges` still cuts
exactly where you say. Its ranges are all in the times before it, in any
order; Tandem cuts them latest first, cuts overlapping or touching ranges
once, and one undo puts them all back. Then check it with
`tandem check --cuts --from 2:10 --to 2:20`, which gives the fix if a word
got clipped (a trim into a pause, or putting a short cut back):

```json
{"label": "Rough cut: drop the false starts", "expectedRevision": 57, "commands": [
  {"cutRanges": {"ranges": [{"start": 0, "end": 18.15}, {"start": 25.6, "end": 46.24}, {"start": 134.2, "end": 136.05}]}}
]}
```

## Join through-edits

Putting cuts back with ripple trims (or cutting the take and changing your
mind) leaves through-edits: cuts where the same file carries straight on,
so nothing changes there, but the timeline still looks cut up. Join them
rather than lifting and trimming clips by hand:

```bash
tandem join                                  # what it would join, and the cuts it leaves and why
tandem join --apply                          # one undo step
tandem join --from 2:00 --to 3:30 --apply    # only cuts in that stretch
tandem apply '{"join": {"clipID": "clip_k3f9x2mq"}}'   # only the cut after that clip
```

Each joined clip keeps the first clip's ID and link group and plays exactly
what the two did; the camera, screen and voice of a take join together,
and hundreds of cuts join in one go. As nothing Mike would see or hear
changes, a join (with `join` or by hand) adds nothing to his review, and a
piece still waiting for it is highlighted in the clip it joined. A cut is
left, and listed with the reason, when joining would change what plays: a
transition or a fade on it, clips with different settings (a gain, a crop,
an effect), animation that wouldn't carry on across it, or a linked clip
cut somewhere else (a split edit). Take away what's in the way first if
that cut should go too. In MCP: `join {}`, then `join {"apply": true,
"expectedRevision": <the plan's revision>}`.

## Keep the camera in sync

```bash
tandem sync                                  # how late each file's picture is
tandem sync 0.08                             # every camera take: picture 80 ms late
tandem sync 0.05 --media med_screen          # one file
tandem sync 0.08 --default                   # also what new camera takes get
```

A webcam's picture lags its microphone (Mike's by about 75 ms), so lips
and voice drift apart. A file's `pictureDelay` makes every clip of it show
its picture that much later in the file, in the app, frames, review clips,
`check` and exports. The sound, the cuts and the transcript's word times
stay where they are, so nothing else moves. New webcam takes get Tandem's
default (Settings in the app, or `--default`); a camera's take (a timecode
track, or a phone's make and model) records in step and gets none. Never slip clips by hand as
well, or the delay doubles. `tandem media` shows it as "picture 80 ms
late, shown in sync". In MCP: `sync {"delay": 0.08}`.

Record It now takes the lag out as it records (its Settings → Camera
delay) and tags the file `com.mikerosoft.record-it.camera-delay`. Tandem
reads the tag (`pictureDelayCorrected`, "in sync as recorded" in `tandem
media`), gives those takes no delay of its own, and `tandem sync` leaves
them alone.

## Add another angle or an external mic

A second camera or a separate recorder starts at its own moment, so line
it up with the camera take by sound rather than by hand:

```bash
tandem sync "source/Ian close-up.mov" "source/Ian mic.wav"   # measure, set their take, place them
tandem apply '{"showAngle": {"range": {"start": "4:57", "end": "5:18"}, "trackID": "Angle 2"}}'
tandem clip 4:50 5:25 -o /tmp/angle.mp4                       # watch and listen
```

```
Lined up with source/Ian.mov by sound (how much further into each file the same moment is):
  med_uqkd2zsq  source/Ian close-up.mov  +2.856 s, drift 6 ms over 17:56.954, confidence 54. On "Angle 2".
  med_z7q5wmz7  source/Ian mic.wav  +2.856 s, drift 6 ms over 17:56.933, confidence 54. On "Voice".
Applied "Sync 2 files to Ian by sound" by claude as revision 9.
```

The offset is how much further into the file the same moment is (here
the close-up and mic started 2.856 s before the camera), measured at the
middle of where they overlap; the file can cover any part of the take.
Drift is how far the two clocks part over the overlap. It's good to a
couple of milliseconds, since someone walking between the cameras moves
their sound about 3 ms a metre, and it warns when it's over half a frame.
Unrelated sound scores under 10 for confidence, and under 15 is refused
with nothing changed, so check the file before trying again.

In one undo step each file joins the camera's take (`takeID`,
`takeOffset`, shown by `tandem media`) and goes beside the take's clips,
linked one clip a track, so ripple cuts, trims and moves keep it in step.
The take is cut where the file starts and stops (through-edits; nothing
plays differently).

- An angle goes on its own cut track right above the camera's, "Angle 2",
  with its clips off, so the camera still shows. Its own sound isn't
  placed.
- A sound file goes on Voice, and the camera's own sound there moves to a
  muted "Camera sound" track, so the mic is what plays and what gets
  transcribed. Outside the mic's stretch the camera's sound stays on
  Voice.

`showAngle` shows an angle over a range: its clips there come on and the
take's other angles go off. `"trackID": "Camera"` shows the camera again.
The range snaps to frames, and the take is cut at its edges on every track
as through-edits, so the sound doesn't change and later cuts keep the
switch where it was in the take. Don't untick clips or unlink by hand.

`--dry-run` measures and checks the edit without changing anything,
`--no-place` only sets the takes (then `placeSynced` places one), and
`--to` names the camera file when there's more than one. A 46 min camera
take and an 18 min file take about 20 s. In MCP: `sync {"files":
["source/Ian mic.wav"]}`.

# Review, checks and history

What `tandem check` looks for (including clipped words at cuts), seeing what changed with `diff` and `history`, putting clips back with `restore`, doing Mike's comments, review clips, and working in turns with Mike.

## Check an edit before handing it back

`check` looks for what Mike would otherwise catch in review, so his rounds
go on the edit itself. It renders every frame of the stretch small (384
wide, from proxies where they're ready), and the screen recordings again on
their own beside it, and reports, with the clips on screen there:

- black frames, and gaps with nothing on any video track;
- flickers: one to three frames unlike the frames either side, like a
  stale still or a frame of the wrong shot. Where the flicker is inside one
  clip of a video and the check can tell which picture flashed (the only
  video there, or the screen recording when its own scan flickers too),
  it comes with the `holdFrame` that holds the frame before it over it, as
  Mike fixed a one-frame jump in a screen recording in the Tandem video;
  the last line is a `tandem apply` that makes them all. One at a cut is
  usually a frame of the wrong shot: trim it instead;
- green screen that didn't key, and flat white blocks that come and go
  (a key or matte that failed);
- as notes that don't fail it:
  - pictures zoomed past three times their own pixels (1080p past 150%
    on a 4K frame), which look soft;
  - dead air: 0.8 s or more with nothing said, no sound effect, no music
    swell and a still picture. Speech is the words `pauses` reads, with
    their edges on the voice, so a 0.4 s sentence pause never shows up.
    Every other clip that's heard counts as sound while it plays (sound
    effects, demo sounds), and music only where its `audio.gainDB`
    keyframes rise or a new bed comes in. Mike moving in his camera
    corner, the Dock popping up along the frame's edge and a cursor nudged
    now and then don't count as movement; an animation, a result
    appearing, a slow fade or a cursor that keeps moving do. Section cards
    are never dead air. Cut it (`rippleDeleteRange`, leaving Mike's 0.4 s
    between sentences), or keep it only if the pause earns it: a point
    landing, the end of a paragraph. Until the take has a transcript, the
    check says so and doesn't judge its pauses.
  - page changes with no transition: the screen recording, judged on its
    own (as recorded, not zoomed, without the camera over it), changes a
    large share of its picture at once and then holds, where the viewer
    sees it (not under full-frame B-roll or the camera full frame) and no
    transition covers it. Typing, scrolling, a moving cursor and a demo's
    animations don't count. If it's a new page in an explainer or slides,
    push it: at a cut, a 0.7 s push on the Screen track with the light
    swoosh (`addTransition`); inside a clip, freeze 0.35 s either side of
    the flip (`freezeFrame` clips) and push between the freezes. A button
    that changes most of a page can show up too; leave those.
  - slivers: an enabled clip shorter than a frame at the project's frame
    rate, or a gap that short between two clips on a track, on any track.
    They're usually rounding left by a batch: delete the clip, or trim a
    neighbour to close the gap.
  - low frame rates: a screen recording the viewer sees (not under
    full-frame B-roll or the camera full frame) playing fewer than 12
    frames a second on the timeline, and under half the project's, for a
    second or more while its picture moves. macOS records the screen as it
    changes, so a recording's rate drops (to 4 to 7 fps while Mike was
    away from his desk in the Tandem video). A still page or a blinking
    caret at 4 fps looks the same as at 60, so those don't count. The rate
    is the file's own frame times (read from its sample table, cached per
    file) at the clip's speed, so a slowed-down clip can be low too. Cover
    it: Mike went full screen on his camera over it; B-roll works too, or
    cut it.

Run `tandem check --changed` before handing an edit back: it checks only
what agents changed that's waiting for Mike's review, half a second either
side. It exits 1 when it finds a problem; notes never fail it. `--quick`
skips rendering, so it only finds gaps, soft pictures, slivers and nothing
that needs the screen recordings scanned (page changes, low frame rates).

It renders the timeline in 10 s pieces, several at once, and keeps what it
measured in each in `.tandem/cache/check`. A piece is rendered again only
when something that draws in it changed (a clip, a transition near it,
the project's settings, a file or its proxy or matte becoming ready), so
the next check after a fix renders just the pieces the fix touched.

```
Checked 05:40.000-06:11.000 (930 frames) in 0.9 s: 1 problem:
  05:56.900-05:57.167  White block: a flat white patch over 13% of the frame comes and goes in 8 frames (a key or matte that failed?).  On: clip_w2fkvxg9 m-outro1
```

In Build Your Own Convex, two pauses on a chapter's title page, then the
explainer turning to the chapter's first page with no push:

```
Checked 13:30.000-13:50.000 (600 frames) in 2.1 s: no problems.
Notes (not problems):
  13:34.380-13:35.180  Dead air: 0.80 s with nothing said, no sound effect or music swell, and a still picture (after "is called the committer."). Cut it, or keep it if the pause earns it.  On: clip_nyc6dj73 2026-10-02_110856-camera, clip_5z5qpmkz 2026-10-02_110856-screen
  13:44.650-13:45.467  Dead air: 0.82 s with nothing said, no sound effect or music swell, and a still picture (after "one at a time."). Cut it, or keep it if the pause earns it.  On: clip_p8v54ivp 2026-10-02_110856-camera, clip_cmqvrmad 2026-10-02_110856-screen
  13:45.467-13:45.633  Page change inside a clip, with no transition: 18% of the screen recording changes at once, then holds. If it's a new page, push it: freeze 0.35 s either side and push between the freezes.  On: clip_huxupr6f 2026-10-02_110856-screen
```

### Clipped words at cuts (`--cuts`)

`tandem check --cuts` (MCP and HTTP `cuts: true`) checks only for words
clipped at cuts, and renders nothing, so it's quick. Run it after cutting
the take, with `--changed` or `--from`/`--to` as above. Most of Mike's
"word gets cut off" comments were cuts placed from transcript word times,
which can be half a second out, or snapped to the quietest point near a
word's end, which lands in the gaps inside words. So it goes by the sound
instead. For every cut edge on the speech tracks (two pieces of the take
meeting, not a through-edit, or a piece beside a gap) it reads the file's
own sound either side of the edit, in 10 ms frames, over the full band and
again above 4 kHz, where a final "s" or "t" is heard. Levels come from the
take's own sound around its cuts: quiet is 10 dB over its noise floor (the
quietest tenth), and never more than 25 dB under its loud tenth (15 dB
above 4 kHz, where breath and room tone reach too); speech is within 20 dB
of the loud tenth (10 dB above 4 kHz). A real pause is quiet for 0.08 s or
more in both bands; a shorter gap (the closure before the "k" of "takes")
is inside a word. A take with no voice in it (a screen recording's system
sound) isn't judged.

An edge is fine if the frame on either side of it is in a real pause: the
clip ends in silence, or ends right as a word it doesn't keep starts. It's
also fine with less than 0.05 s of speech on either side (a tail nobody
misses, or a fragment), or in a dip between two sounds, 12 dB under the
voice either side, as a cut between words in fluent speech is; unless a
clip's end is in a closure with the "k" or "t" released loudly right after
it. Otherwise the voice runs through the cut and a word is clipped, a
problem that fails the check. On the Tandem video, an edit Mike approved,
it flags 6 of 758 edges. Each one says which clip's start or end, how much
of the voice is cut off, and the trim (with ripple) that moves the edge
into the nearest real pause within 0.3 s, 0.04 s into it and on a frame
where one lands there. The nearer pause is the side with less of the word,
so it finishes a word that's mostly kept and drops a fragment that's mostly
cut, as transcript placement does. The last line is a `tandem apply` that
makes every fix (in `--json`, `commands`, latest first, and `revision`;
each problem's `cut` has `clipID`, `edge`, `to` and `fix`). Listen to the
ones it can't fix (no pause within reach) with `tandem clip`.

```
Checked 00:00.000-01:00.000 (4 cut edges) in 0.1 s: 1 problem:
  00:30.000  Clipped word at the end of clip_voc1: the voice runs on 0.12 s past the cut. Trim the end 0.167 s later, into the pause after it.  On: clip_voc1 take1-camera, clip_voc2 take1-camera
Fix: tandem apply --expect 7 --label "Move clipped cuts into pauses" '[{"trim":{"clipID":"clip_voc1","edge":"end","ripple":true,"to":30.166667}}]'
```

## What changed, and putting it back

`tandem diff --since <revision>` (MCP `diff`) says what changed on the
timeline since then, clip by clip, grouped by edit with who made it and
where it was. Use it to find what Mike changed since your last round
(the revision you handed back at, or the one `status` gave you then)
instead of diffing `timeline --json` yourself:

```
$ tandem diff --since 95
Since revision 95 (now revision 98): 1 added, 1 removed, 2 changed, 14 moved.
r96  Trim  by user  00:12.000-00:12.500 on V2 Camera, A1 Voice
    changed  clip_cam4  V2 Camera  00:12.000-00:20.000  take1-camera.mov: start trimmed +0.500s, rippled
    changed  clip_voc4  A1 Voice  00:12.000-00:20.000  take1-camera.mov: start trimmed +0.500s, rippled
    moved  14 clips by -0.500s on V3 B-roll, V2 Camera, V1 Screen, A1 Voice (from 00:20.500)
r97  Swap the server shot  by user  00:40.000-00:44.000 on V3 B-roll
    removed  clip_brl3  V3 B-roll  00:40.000-00:44.000  servers.mp4
    added  clip_k2m9x8qa  V3 B-roll  00:40.000-00:43.000  racks.mp4
r98  Quieter music  by user  00:00.000-05:00.000 on A2 Music
    changed  clip_mus1  A2 Music  00:00.000-05:00.000  bed.m4a: gain -31 -> -35 dB
```

Each clip says what changed: added, removed, `moved`, a trimmed `start`
or `end` (and `start trimmed ..., rippled` where a ripple trim took it
off the start), `slipped`, a cut (`cut at ..., the rest is clip_...`),
and settings like `scale`, `position`, `opacity`, `crop`, `layout`,
`gain`, `fade in`, `level`, effects and keyframes. Clips that moved
together by the same amount, riding a ripple, are one line. Edits that
changed no clips (Tandem finding new media) are one line too. Media,
markers, transitions and settings aren't compared. `--json` has each
clip as it was and is (`before`, `after`).

`--since` takes:

- a revision. The edit history is walked back to it, so the changes come
  grouped by edit. Past the start of the history, a backup in
  `.tandem/backups` saved at that revision is used instead; otherwise it
  says where the history starts and what to use.
- a `.tandem` file: a backup, another version, or the snapshot every
  export writes beside itself (`exports/v3.mp4.tandem`). A backup of this
  project that the history reaches comes grouped by edit as well.
- an export (`exports/v3.mp4`), read from the snapshot beside it.

Paths are absolute or relative to the project folder (the CLI makes them
absolute from where you run it).

`tandem history` says where each edit was, so you can tell Mike's trims
apart without diffing anything:

```
$ tandem history
Revision 98.
Undo, newest first:
  Quieter music  (user)  00:00.000-05:00.000 on A2 Music
  ...
Edits, newest first (kept across restarts; tandem diff --since <revision> shows what each did to the clips):
  r98  10:42:01  Quieter music  (user)  00:00.000-05:00.000 on A2 Music  1 changed
  r97  10:41:30  Swap the server shot  (user)  00:40.000-00:44.000 on V3 B-roll  1 added, 1 removed
  r56-r95  09:58:02-10:30:12  Found new media x40  (system)
```

`tandem restore --from <revision, file or export>` (MCP `restore`) puts
clips back as they were there: where they were, their trims, settings and
keyframes. Name them with `--clips clip_a,clip_b`, or take every clip that
was between `--from-time` and `--to-time` (in that timeline's times), on
`--track` if given. A clip that's gone is put back on its track, one
that's changed is changed back, and one that wasn't there comes out. It's
a dry run until `--apply`, and then one undo step, made through the same
edit path as any batch (so it's checked, journaled and highlighted for
Mike). Transitions, media and markers aren't restored. If something now
sits where a clip goes back, the dry run says it wouldn't apply: restore
that clip too, or move it first. To rebuild a round Mike rejected:

```
$ tandem restore --from "exports/v3.mp4" --from-time 2:00 --to-time 3:30 --track B-roll
Restore 4 clips as they were in the export snapshot exports/v3.mp4.tandem (dry run, revision 120):
  put back  clip_b7  V3 B-roll  02:04.000-02:09.500  config.mp4
  ...
Nothing changed yet. Run again with --apply (or apply: true) to restore them. Transitions, media and markers aren't restored.
```

## Do Mike's comments

```bash
tandem comments                              # what he asked, where, with what's said and playing there
tandem apply '{"label": "Cut the umm before \"so\" (your comment at 08:40)", "commands": [
  {"rippleDeleteRange": {"range": {"start": 520.1, "end": 520.7}}},
  {"removeMarker": {"markerID": "mk_k3f9x2mq"}}]}'
tandem comments resolve mk_7hd2p4xa          # one you did in an edit without removing it
```

While he reviews, Mike leaves comments at moments on the timeline (Add
comment, Shift-C, or a double-click on an empty stretch in the app): notes
like "cut the umm here" or "this B-roll is wrong", shown in a Comments
strip under the ruler. They're markers of kind `comment`. When he asks you
to look at them, do each one, label the edit with what you did (he reads
the labels beside your highlighted changes), and remove the comment in the
same batch, so one undo puts both back. Comments move with ripple edits
like any marker, so list them again after one rather than reusing the
times you read first. Leave a comment you couldn't do, or weren't sure
about, and say why when you hand back.

## Export a review clip

```bash
tandem frame 2:14.5 -o /tmp/frame.png        # one frame
tandem clip 2:00 2:30 -o /tmp/review.mp4     # 720p review render
tandem export                                # the full video, loudness matched
```

Plain `export` picks the preset that fits the canvas: YouTube 1080p for a
canvas 1080 pixels or less on its short side (1920x1080, 1080x1920),
YouTube 4K for anything bigger. A preset sets the codec, bitrate and
resolution class and keeps the canvas's shape, so `--preset youtube1080`
of a 4K project is 1920x1080 and of a 9:16 one 1080x1920 (`tandem help
export` lists the presets).

`clip` defaults to `exports/review <start>-<end>.mp4` in the project folder
and `export` to `exports/<name> r<revision>.mp4`. In MCP, `frame` returns
the picture directly, so you can look at the result of an edit.

## Work alongside Mike

- Read before you write: take the revision from `timeline` or `status` and
  pass it as `expectedRevision`. On `staleRevision`, read again.
- Note the revision you hand back at. Next round, `tandem diff --since
  <it>` says what Mike changed in between, edit by edit, and `tandem
  restore` brings back anything he took out that he wants again.
- Try a big batch with `dryRun` first.
- Give retried batches an `idempotencyKey`.
- Undo with `expectedRevision` so you only undo your own edit, and with
  `count` to undo several at once.
- `tandem watch --once` (MCP `watch`) waits until the project changes, for
  example after asking Mike to fix something in the app. `tandem watch`
  prints every change as it happens.
- Mike reviews your edits in the app rather than watching the whole video
  again: every batch that changes the timeline and isn't his is
  highlighted there (the clips it added or changed, a mark where it took
  something out) until he plays through them (each clears once he's
  watched all of it) or marks them reviewed, and he steps from one to
  the next. Label batches with what they do (`"B-roll over the config
  file"`), since that's what he reads when he hovers one.
- `tandem status` lists your edits still waiting for him as `waiting for
  Mike's review` (`reviewPending` in JSON: each edit's label, author, date
  and the clip IDs it added or changed). It's read-only; only Mike clears
  it, from the app.

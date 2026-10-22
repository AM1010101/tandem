# JSON output

The shapes of the `--json` results you'll read most (timeline, media, transcript, wait, status, history, diff, clips, restore, apply, cut), and which fields can be missing.

A `--json` result is an object, and the project's `revision` is in it.
A field marked `?` can be missing (or `null`), so read it with a default
(`clip.get("video")` in Python, not `clip["video"]`). Errors are
`{"error": {...}}` on standard output with exit code 1.

## timeline

`tandem timeline --json` (MCP `timeline` with `format: json`) wraps the
project. Tracks are in two lists, not one `tracks`, and video tracks go
bottom to top (`videoTracks[0]` is V1, Screen). With `--from`/`--to`, each
track keeps only the clips that overlap the range.

```
{"revision": 4,
 "project": {"id", "name", "schemaVersion", "settings": {"width", "height", "frameRate": {"numerator", "denominator"}, ...},
             "metadata": {}, "markers": [{"id", "time", "duration", "name", "kind", "note"?}],
             "media": [{"id", "path", "kind", "role", "duration", ...}],
             "videoTracks": [Track], "audioTracks": [Track]}}

Track: {"id", "name", "kind", "rippleMode", "muted", "solo", "locked", "hidden", "targeted",
        "clips": [Clip], "transitions": [{"id", "type", "duration", "direction"?, "fromClipID"?, "toClipID"?, "soundClipID"?}]}

Clip:  {"id", "start", "duration", "sourceStart", "speed", "enabled", "freezeFrame", "keyframes": {}, "tags": [],
        "content": one of {"media": {"mediaID"}}, {"text": {"text", "preset"?, ...}},
                          {"graphic": {...}}, {"solid": {"color"}}, {"adjustment": {}},
        "name"?, "linkGroup"?, "video"?, "audio"?}
```

- A clip on the timeline from a file has its media ID at
  `content.media.mediaID`, and its source range is `sourceStart` for
  `duration * speed`.
- `name` is missing on clips with no name (titles, solids).
- `video` is missing until something sets it (a default transform, full
  opacity, no crop), and `audio` likewise. Once set, `video` has
  `transform` (`position {x, y}` 0 to 1, `scale`, `rotation`), `crop`,
  `opacity`, `effects`, and maybe `layoutPreset` and `cutout`; `audio` has
  `gainDB`, `fadeIn`, `fadeOut`, `muted`, `effects`, and maybe
  `normalizeTo`.
- `linkGroup` is missing on clips that aren't linked; linked clips share it.

## media

```
{"revision": 4, "added": ["med_..."],          // what --refresh added, usually []
 "items": [{"id", "path", "kind", "role", "hasVideo", "hasAudio", "clips", "exists",
            "duration"?, "width"?, "height"?, "frameRate"?, "takeID"?, "takeOffset"?,
            "analysis": {"transcript": {"state", "progress"?, "message"?}, "loudness": ..., "waveform": ..., "proxy": ..., "thumbnails": ...}}]}
```

`clips` is how many timeline clips use the file, and `state` is `ready`,
`queued`, `running`, `failed`, `cancelled` or `none`.

## transcript

```
{"revision": 4, "scope": "timeline" | "clip" | "media", "id"?, "timelineTimes": true,
 "words": [{"text", "start", "end", "clipID"?, "confidence"?}],
 "missing": ["med_..."]}                       // media whose transcript isn't ready
```

`timelineTimes` is false for a media transcript, whose times are the
file's own. `clipID` is set on timeline transcripts.

## wait and transcribe

`tandem wait --json` (and `waited` in `tandem transcribe --json`, which also
has `revision`, `applied`, `files` and `headless`):

```
{"what": "transcript", "done": true, "timedOut": false, "elapsed": 3.2,
 "finished": [{"kind", "mediaID"?, "path", "state", "progress"?, "message"?, "words"?, "mode"?}],
 "pending": [...]}                             // what's still going after a timeout
```

`state` is `ready` (`done` for a job) or `failed` when finished, and
`waiting`, `queued` or `running` when not. `words` is a ready transcript's
word count, 0 when there's no speech.

## status

```
{"name", "path", "revision", "savedRevision", "dirty", "duration", "width", "height", "frameRate",
 "tracks", "clips", "media", "markers", "headless", "recoveredEdits", "apiVersion",
 "undo"?, "redo"?, "openIn"?: {"owner", "pid", "started"},
 "jobs": [...], "exports": [...], "warnings": [...],
 "reviewPending": [{"label", "author", "date", "clipIDs", "removals"}]}
```

## history

```
{"revision": 4, "undo": [{"label", "author", "start"?, "end"?, "tracks"?}],  // newest first
 "redo"?: "label", "events": [{"seq", "kind", "date", "revision"?, "label"?, "author"?}],
 "edits"?: [{"revision", "kind", "label", "author", "date", "start"?, "end"?, "tracks"?, "summary"?}]}  // newest first
```

`events` are the changes this server saw; `edits` is the edit history,
which lasts across restarts. `kind` is `edit`, `undo`, `redo`, `reload`
or `opened` (where the history starts again). `tracks` are labels like
`"V2 Camera"`.

## diff

```
{"revision": 98, "since": "revision 95", "sinceRevision"?: 95,
 "changes": [Change],                            // every clip that's different now
 "edits"?: [{"revision", "kind", "label", "author", "date", "start"?, "end"?, "tracks"?, "changes": [Change]}]}

Change: {"id", "kind": "added" | "removed" | "changed", "track", "trackID", "start", "end", "content",
         "details": ["start +0.500s", ...], "wasTrack"?, "wasStart"?, "wasEnd"?, "shift"?, "before"?: Clip, "after"?: Clip}
```

`edits` is there when the history reaches `since`. `shift` is set on a
clip that only moved along its track.

## clips

```
{"revision": 7, "clips": [{"id", "track", "trackID", "start", "end", "duration", "content", "mediaID"?, "name"?, "enabled"}]}
```

## restore and apply

`tandem restore --json` gives `{"revision", "from", "items": [{"id",
"action": "putBack" | "changeBack" | "remove" | "unchanged", "track",
"start", "end", "content", "details"}], "commands", "applied"?,
"problem"?}`.

`tandem apply --json` gives `{"revision", "label", "author", "createdIDs",
"added", "changed", "removed", "duration", "warnings", "dryRun",
"repeated"}`; `createdIDs` lists new clips, tracks, transitions and markers
in the order the commands made them.

`tandem check --cuts --json` has `commands` (the fixes, latest first) and
`revision`. Each problem's `cut` has `clipID`, `edge`, `margin` (dB under
the speech level), `fixKind` (`trimToPause`, `putBack` or
`nothingNearby`), and `to` and `fix` when there's a fix; a `putBack`
fix trims the clip before the join, which may not be `clipID`. `drops`
is the kept word (the transcript's text) a trim back would have dropped,
when that's why the fix isn't a trim; it's missing otherwise.
`lastWordCut` is the last word of a sentence or clause the clip ends just
before, cut with what follows, when that's what clips it. Marginal
joins are notes of kind `marginalJoin`, with `cut.margin`.
A plain `tandem check --json` has `commands` and `revision` too when it
can fix a flicker, and that problem's `fix` is the `holdFrame`.

## cut

```
{"revision": 57, "removed": 2.15, "durationBefore", "durationAfter",
 "commands": [{"cutRanges": {...}}],              // empty when nothing's cut
 "applied"?: {...apply's result}, "warnings": [],
 "cuts": [{"asked", "text", "start", "end", "status": "cut" | "kept", "before", "after", "falseStart",
           "cut"?: {"start", "duration"}, "mediaID"?, "mediaStart"?, "mediaEnd"?, "keptBefore"?, "keptAfter"?,
           "startEdge"?: {"verdict", "margin"}, "endEdge"?: {"verdict", "margin"},
           "broughtBack"?, "missed"?, "reason"?, "problem"?, "problemEdge"?}]}   // in the order asked
```

`cuts` has one entry per stretch asked for. `start` and `end` are the
stretch as found (a phrase's words, or the range given); `cut` is what
comes out, on the timeline, and `mediaStart`/`mediaEnd` the same in the
voice's file. `keptBefore` and `keptAfter` are the pause left either side
of the join, in timeline seconds. `startEdge` and `endEdge` say how each side of the join
sounds, as `check --cuts` judges it (`verdict` `clean`, `marginal` or
`clipped`, and `margin` in dB under the speech level); in a long silence
the margin is small because there's no speech near to measure against.
A `kept` stretch has a `reason`, and a `problem` (`fluent`, `runsOn`,
`noSpeech`, `nothingLeft` or `notClean`) at `problemEdge` (`start` or
`end`) when the sound was read. `broughtBack` is the words a false start
brings back. `missed` is sound in the stretch (or within 0.3 s of it) that
no transcript word claims and the cut keeps, because cutting it would cut
a word that stays too: listen there.

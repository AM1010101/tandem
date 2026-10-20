# JSON output

The shapes of the `--json` results you'll read most (timeline, media, transcript, wait, status, history, diff, clips, restore, apply), and which fields can be missing.

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
`revision`, and each problem's `cut` has `clipID`, `edge`, `to` and `fix`.
A plain `tandem check --json` has `commands` and `revision` too when it
can fix a flicker, and that problem's `fix` is the `holdFrame`.

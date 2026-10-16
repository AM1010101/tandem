# Tandem SDK

A thin TypeScript client for Tandem's local HTTP API, for "code mode": write
one short script that reads the project, works out the edit and applies it as
one labelled batch, and print only the result. Use it for bulk or
cross-referencing jobs (every caption, every push, every pause). For a single
read or a small hand-written batch, `tandem` is just as good.

Needs Bun (`~/.bun/bin/bun`). No runtime dependencies.

## Run a script

```bash
bun sdk/run.ts "<video folder>/<name>.tandem" script.ts
bun sdk/run.ts "<project>" -e 'const p = await t.project(); return p.transitions().length'
bun sdk/run.ts "<project>" - < script.txt
```

- A script file default-exports `async (t) => result` (see `examples/`).
- Inline code (`-e` or stdin) is the body of an async function with `t`,
  `cmd`, `fixCaptionWords` and `sdk` in scope.
- What it returns prints as compact JSON. Errors print as
  `error: <code>: <message>` with exit code 1, nothing half applied.
- It talks to whatever serves the project (the app, or `tandem serve`), found
  from `<folder>/.tandem/<name>.lock`. If nothing does, it starts
  `tandem serve` for the run and stops it after (saved on the way out).
- Credited to `$TANDEM_AUTHOR`, or `claude`.

## The API

```ts
const p = await t.project();             // whole timeline as JSON + helpers (from/to for part)
p.track("Screen")                        // by name or ID; .clips, .transitions
p.clips(c => c.track.name === "B-roll")  // every clip with .track and .end, in time order
p.transitions(tr => tr.type === "push" && !tr.soundClipID)
p.captions()                             // caption clips with .text
p.at(12.5)                               // clips playing at a time, top first
p.media("swoosh.m4a")                    // by ID, path (or its end) or role

await t.status(); await t.media(); await t.history();
await t.transcript(id?)                  // words in timeline time
await t.search("phrase"); await t.pauses(0.6);
await t.findWords(/^comics$/i)           // words with a few either side
await t.timelineText({ from: 60, to: 90 })  // the readable view, if you want to look
await t.check({ changed: true }); await t.frame(12, "/tmp/f.png");

await t.edit("Label", [cmd.blade({ at: 12.5 }), ...])
// dry-runs, then applies with expectedRevision = the revision of your last read,
// returns { label, revision, commands, added, changed, removed, createdIDs, warnings }.
// { dryRun: "only" } stops after the dry run. No commands: nothing is sent.
await t.call("any-operation", { ...json })  // anything else, same JSON as the MCP tool
fixCaptionWords(p, { comics: "Convex", "news models": "Muse models" })
// -> { commands, changes }: patches each caption's text, words and name
```

`cmd.<command>(args)` builds `{ "<command>": args }` with the args typed from
the edit schema (`commands.gen.ts`). The server checks every command too and
says what's wrong (`unknown field "transitionId" (did you mean
"transitionID"?)`), so a script fails before anything changes.

## Examples

`examples/` has three jobs, each one call:

```bash
bun sdk/run.ts Video.tandem sdk/examples/fix-captions.ts    # misheard words in captions
bun sdk/run.ts Video.tandem sdk/examples/swoosh-pushes.ts   # swoosh on every bare push
MIN_PAUSE=1.6 bun sdk/run.ts Video.tandem sdk/examples/swell-music.ts  # music swells in pauses
```

## Rules

The tandem skill's rules still apply: `tandem status` first, small labelled
batches, look at what you changed, `tandem check --changed` before handing
back.

Undo: a project served by `tandem serve` (including the one `run.ts` starts)
keeps no CLI undo history once it stops, so `tandem undo` can't take back a
script's edit afterwards. When the app is closed and you might want to undo,
keep `tandem serve` running for the session (`run.ts` reuses it) and undo
before stopping it. In the app, Mike's undo menu has every edit as usual.

## Maintaining

- `bun sdk/gen-types.ts <project.tandem>` regenerates `commands.gen.ts` from
  the running server's `GET /v1/schema` after edit commands change.
- `types.ts` holds the read results' shapes by hand.
- `cd sdk && bun install && bun run typecheck` checks the SDK and examples.

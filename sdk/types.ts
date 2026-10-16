// Hand-written shapes of what the read operations return over HTTP.
// Edit command types are generated into commands.gen.ts.

import type { Clip, Marker, MediaItem, Transition } from "./commands.gen";

/** A JSON merge patch: send only what changes, nested objects merge, null removes. */
export type Patch<T> = T extends readonly unknown[]
  ? T
  : T extends object
    ? { [K in keyof T]?: Patch<T[K]> | null }
    : T;

export type TrackFields = {
  name: string;
  hidden: boolean;
  locked: boolean;
  muted: boolean;
  solo: boolean;
  targeted: boolean;
  rippleMode: "cut" | "follow" | "off";
};

/** A clip as the project holds it: id and start are always there. */
export type ProjectClip = Clip & { id: string; start: number; duration: number };
export type ProjectTransition = Transition & { id: string; duration: number };

export type Track = TrackFields & {
  id: string;
  kind: "video" | "audio";
  clips: ProjectClip[];
  transitions: ProjectTransition[];
};

export type Project = {
  id: string;
  name: string;
  schemaVersion: number;
  settings: Record<string, any>;
  metadata?: Record<string, unknown>;
  /** Bottom to top: videoTracks[0] is V1. */
  videoTracks: Track[];
  audioTracks: Track[];
  markers: (Marker & { id: string })[];
  media: (MediaItem & { id: string })[];
};

export type Word = { clipID?: string; text: string; start: number; end: number; confidence?: number };

export type TranscriptResult = {
  revision: number;
  scope: "timeline" | "clip" | "media";
  timelineTimes: boolean;
  words: Word[];
  missing: unknown[];
};

export type SearchHit = {
  text: string;
  start: number;
  end: number;
  before: string;
  after: string;
  clipIDs: string[];
  mediaID: string;
  mediaStart: number;
  mediaEnd: number;
  partial: boolean;
  /** Set on matches in material that was cut out. */
  cut?: boolean;
};
export type SearchResult = { revision: number; hits: SearchHit[] };

export type Pause = { start: number; end: number; duration: number; before: string; after: string; clipIDs: string[] };
export type PausesResult = { revision: number; minimum: number; total: number; pauses: Pause[]; missing: unknown[] };

export type MediaInfo = {
  id: string;
  path: string;
  role: string;
  kind: string;
  duration: number;
  clips: number;
  exists: boolean;
  hasAudio: boolean;
  hasVideo: boolean;
  analysis: Record<string, { state: string }>;
};
export type MediaResult = { revision: number; added: string[]; items: MediaInfo[] };

export type StatusResult = {
  name: string;
  path: string;
  revision?: number;
  duration: number;
  clips: number;
  media: number;
  markers: number;
  dirty: boolean;
  headless: boolean;
  openIn?: { owner: string; pid: number; port: number };
  reviewPending: { author: string; label?: string; clipIDs: string[] }[];
  jobs: { id: string; kind: string; state: string; progress: number }[];
  [k: string]: unknown;
};

export type ApplyResult = {
  revision: number;
  label?: string;
  author: string;
  dryRun: boolean;
  repeated: boolean;
  duration: number;
  added: string[];
  changed: string[];
  removed: string[];
  createdIDs: string[];
  warnings: string[];
};

export type HistoryEvent = { seq: number; revision: number; kind: string; label?: string; author: string; date: string };

export type CheckResult = {
  ok: boolean;
  frames: number;
  problems: unknown[];
  notes: unknown[];
  ranges: { start: number; duration: number }[];
  [k: string]: unknown;
};

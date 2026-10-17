import Foundation
import TandemCore

// `diff`, `restore` and `clips`: what changed on the timeline since a
// revision, a backup or an export; putting clips back as they were there;
// and finding clips without reading the whole timeline.

// MARK: - Requests and results

/// What changed on the timeline since `since`: a revision (`95`), a
/// project file (a backup in `.tandem/backups`, or the `.mp4.tandem`
/// snapshot every export writes) or an export (`exports/v3.mp4`, read from
/// the snapshot beside it).
public struct DiffRequest: ServiceCall {
    public static let operation = ServiceOperation.diff
    public var since: String

    public init(since: String) {
        self.since = since
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        since = try c.decodeReference(.since)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> DiffResult {
        try service.diff(self)
    }
}

public struct DiffResult: Codable, Sendable {
    public var revision: Int
    /// What it was compared with, in words.
    public var since: String
    /// The revision it was compared with, when that's known.
    public var sinceRevision: Int?
    /// Every clip that's different now, in timeline order.
    public var changes: [ClipChange]
    /// The edits in between, oldest first, each with the clips it changed,
    /// when the edit history reaches back that far.
    public var edits: [DiffEdit]?
}

/// One edit in the history, with what it did to the clips.
public struct DiffEdit: Codable, Sendable {
    public var revision: Int
    public var kind: HistoryRecord.Kind
    public var label: String
    public var author: String
    public var date: Date
    public var start: Time?
    public var end: Time?
    public var tracks: [String]?
    public var changes: [ClipChange]
}

/// Puts clips back as they were in a revision, a backup or an export's
/// snapshot, as one undo step. A dry run unless `apply`.
public struct RestoreRequest: ServiceCall {
    public static let operation = ServiceOperation.restore
    /// Where the clips come from: a revision, a project file or an export.
    public var from: String
    /// These clips. Ones that weren't there are taken out.
    public var clips: [String]?
    /// Or every clip there between these times (on `track`), and what's in
    /// that stretch now that wasn't there.
    public var fromTime: Time?
    public var toTime: Time?
    public var track: String?
    public var apply: Bool?
    public var label: String?
    public var author: String?
    public var expectedRevision: Int?

    public init(
        from: String, clips: [String]? = nil, fromTime: Time? = nil, toTime: Time? = nil, track: String? = nil,
        apply: Bool? = nil, label: String? = nil, author: String? = nil, expectedRevision: Int? = nil
    ) {
        self.from = from
        self.clips = clips
        self.fromTime = fromTime
        self.toTime = toTime
        self.track = track
        self.apply = apply
        self.label = label
        self.author = author
        self.expectedRevision = expectedRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decodeReference(.from)
        clips = try c.decodeIfPresent([String].self, forKey: .clips)
        fromTime = try c.decodeTime(.fromTime)
        toTime = try c.decodeTime(.toTime)
        track = try c.decodeIfPresent(String.self, forKey: .track)
        apply = try c.decodeIfPresent(Bool.self, forKey: .apply)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> RestoreResult {
        try service.restore(self, context: context)
    }
}

public struct RestoreResult: Codable, Sendable {
    /// The revision the plan was made against.
    public var revision: Int
    /// Where the clips come from, in words.
    public var from: String
    public var items: [RestoreItem]
    /// The batch that does it. Pass it to `apply` to run it yourself.
    public var commands: [EditCommand]
    /// Set when it was applied.
    public var applied: ApplyResult?
    /// Why it wouldn't apply as it stands, for a dry run.
    public var problem: String?
}

public struct RestoreItem: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// It's gone now; it goes back.
        case putBack
        /// It's there but different; it goes back to how it was.
        case changeBack
        /// It wasn't there; it comes out.
        case remove
        /// Already as it was.
        case unchanged
    }

    public var id: String
    public var action: Action
    /// Where it'll be (where it is, for one that comes out).
    public var track: String
    public var start: Time
    public var end: Time
    public var content: String
    /// What changes back, for `changeBack`.
    public var details: [String]
}

/// Clips on the timeline, filtered, so agents find IDs without reading the
/// whole timeline JSON.
public struct ClipsRequest: ServiceCall {
    public static let operation = ServiceOperation.clips
    /// A track ID, name ("Camera") or label ("V2").
    public var track: String?
    /// Clips that overlap from-to.
    public var from: Time?
    public var to: Time?
    /// A media ID, path or file name.
    public var media: String?
    /// Only the IDs, one a line, in the text.
    public var ids: Bool?

    public init(track: String? = nil, from: Time? = nil, to: Time? = nil, media: String? = nil, ids: Bool? = nil) {
        self.track = track
        self.from = from
        self.to = to
        self.media = media
        self.ids = ids
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = try c.decodeIfPresent(String.self, forKey: .track)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        media = try c.decodeIfPresent(String.self, forKey: .media)
        ids = try c.decodeIfPresent(Bool.self, forKey: .ids)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ClipsResult {
        try service.clips(self)
    }
}

public struct ClipsResult: Codable, Sendable {
    public var revision: Int
    /// Tracks top to bottom as the timeline shows them, then by start.
    public var clips: [ClipListing]
    /// Whether the text is just the IDs.
    public var idsOnly: Bool?
}

public struct ClipListing: Codable, Equatable, Sendable {
    public var id: String
    /// "V2 Camera".
    public var track: String
    public var trackID: String
    public var start: Time
    public var end: Time
    public var duration: Time
    /// What it plays, as `timeline` says it ("take1-camera.mov [00:00.000-00:30.000]").
    public var content: String
    public var mediaID: String?
    public var name: String?
    public var enabled: Bool
}

extension KeyedDecodingContainer {
    /// A revision or a path, given as a number or a string.
    func decodeReference(_ key: Key) throws -> String {
        if let number = try? decode(Int.self, forKey: key) { return String(number) }
        return try decode(String.self, forKey: key)
    }
}

// MARK: - Where clips come from

/// A timeline to compare with or restore from.
struct TimelineSource {
    var description: String
    var clips: TimelineClips
    var revision: Int?
    /// The edits from it to now, oldest first, and the clips at each step,
    /// when the history reaches it.
    var records: [HistoryRecord]?
    var states: [TimelineClips]?
    var names: [String: String]
    /// Its tracks, by ID, for clips whose track has gone since.
    var trackNames: [String: String] = [:]
}

extension TandemService {
    /// Reads `reference`: a revision number (`95` or `r95`), or a path to a
    /// project file or an export (absolute, `~/`, or relative to the
    /// project folder).
    func timelineSource(_ reference: String) throws -> TimelineSource {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix("r") ? String(trimmed.dropFirst()) : trimmed
        if let revision = Int(digits) { return try source(atRevision: revision) }
        return try source(atPath: trimmed)
    }

    private func source(atRevision revision: Int) throws -> TimelineSource {
        let (project, current) = coordinator.snapshot()
        guard revision <= current else {
            throw ServiceError(.badRequest, "Revision \(revision) is newer than the project, which is at revision \(current).", revision: current)
        }
        guard revision >= 0 else { throw ServiceError(.badRequest, "Revisions start at 0.") }
        let names = ClipChanges.mediaNames(project)
        let records = session.history.records()
        do {
            let walk = try HistoryChain.walk(records, current: TimelineClips(project), currentRevision: current, back: revision)
            return TimelineSource(
                description: "revision \(revision)", clips: walk.states[0], revision: revision,
                records: walk.records, states: walk.states, names: names
            )
        } catch let gap as HistoryGap {
            let backups = backupRevisions()
            if let backup = backups.last(where: { $0.revision == revision }) {
                var source = try source(atPath: backup.url.path)
                source.description = "revision \(revision), from the backup \(backup.url.lastPathComponent)"
                source.revision = revision
                return source
            }
            var message = "Revision \(revision) is older than the edit history, which goes back to revision \(gap.earliest) (Tandem keeps it in .tandem/\(session.fileURL.deletingPathExtension().lastPathComponent).history.jsonl from this version on, and older edits weren't recorded)."
            let older = backups.map(\.revision).filter { $0 < gap.earliest }
            if !older.isEmpty {
                let listed = Array(Set(older)).sorted().suffix(8).map(String.init).joined(separator: ", ")
                message += " Backups in .tandem/backups have revisions \(listed)."
            }
            message += " Compare with one of those, a backup file, or an export's snapshot instead (every export writes <name>.mp4.tandem beside it): tandem diff --since \"exports/<name>.mp4\"."
            throw ServiceError(.notFound, message, revision: current)
        }
    }

    private func source(atPath path: String) throws -> TimelineSource {
        var url = folder.url(forPath: path).standardizedFileURL
        let fm = FileManager.default
        if url.pathExtension.lowercased() != ProjectFile.fileExtension {
            let snapshot = URL(fileURLWithPath: url.path + "." + ProjectFile.fileExtension)
            guard fm.fileExists(atPath: snapshot.path) else {
                let what = fm.fileExists(atPath: url.path)
                    ? "\(url.lastPathComponent) has no snapshot beside it (\(snapshot.lastPathComponent)), which Tandem writes with every export."
                    : "There's no file at \(url.path)."
                throw ServiceError(.notFound, what + " Give a revision, a .tandem file (a backup in .tandem/backups) or an export Tandem made.")
            }
            url = snapshot
        }
        guard fm.fileExists(atPath: url.path) else {
            throw ServiceError(.notFound, "There's no file at \(url.path).")
        }
        let loaded: (project: Project, revision: Int)
        do {
            loaded = try ProjectFile.load(from: url)
        } catch {
            throw ServiceError(.invalid, "\(url.lastPathComponent) couldn't be read as a Tandem project: \(ServiceError.wrap(error).message)")
        }
        let (project, current) = coordinator.snapshot()
        let clips = TimelineClips(loaded.project)
        let isExport = loaded.project.metadata["export.output"] != nil
        let kind = isExport ? "the export snapshot" : url.path.contains("/.tandem/backups/") ? "the backup" : "the project file"
        var source = TimelineSource(
            description: "\(kind) \(folder.path(for: url))", clips: clips, revision: nil,
            names: ClipChanges.mediaNames(project, loaded.project),
            trackNames: Dictionary(loaded.project.allTracks.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        )
        // A backup of this project knows its revision; when the history
        // reaches it and agrees, the edits since come with it.
        if !isExport, loaded.project.id == project.id, loaded.revision <= current,
           let walk = try? HistoryChain.walk(session.history.records(), current: TimelineClips(project), currentRevision: current, back: loaded.revision),
           walk.states[0].matches(clips) {
            source.revision = loaded.revision
            source.records = walk.records
            source.states = walk.states
            source.description += " (revision \(loaded.revision))"
        }
        return source
    }

    /// The backups of this project and the revision each was saved at,
    /// oldest first. The revision is the envelope's last key, so it's read
    /// from the end of the file.
    func backupRevisions() -> [(url: URL, revision: Int)] {
        ProjectFile.backups(of: session.fileURL).compactMap { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 256 ? size - 256 : 0)
            let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            guard let match = tail.range(of: #""revision"\s*:\s*(\d+)\s*\}\s*$"#, options: .regularExpression) else { return nil }
            let digits = tail[match].filter(\.isNumber)
            return Int(digits).map { (url, $0) }
        }
    }
}

// MARK: - diff

extension TandemService {
    public func diff(_ request: DiffRequest) throws -> DiffResult {
        let source = try timelineSource(request.since)
        let (project, revision) = coordinator.snapshot()
        let now = TimelineClips(project)
        let changes = ClipChanges.between(source.clips, now, names: source.names)
        var edits: [DiffEdit]?
        if let records = source.records, let states = source.states {
            edits = records.enumerated().map { index, record in
                DiffEdit(
                    revision: record.revision, kind: record.kind, label: record.label, author: record.author, date: record.date,
                    start: record.place?.start, end: record.place?.end, tracks: record.place?.tracks,
                    changes: ClipChanges.between(states[index], states[index + 1], names: source.names)
                )
            }
        }
        return DiffResult(revision: revision, since: source.description, sinceRevision: source.revision, changes: changes, edits: edits)
    }
}

// MARK: - restore

extension TandemService {
    public func restore(_ request: RestoreRequest, context: CallContext) throws -> RestoreResult {
        let hasRange = request.fromTime != nil || request.toTime != nil
        guard request.clips?.isEmpty == false || hasRange else {
            throw ServiceError(.badRequest, "Say which clips to restore: clips (IDs), or fromTime and toTime (with track to keep to one track).")
        }
        guard request.clips == nil || !hasRange else {
            throw ServiceError(.badRequest, "Give clips or a time range, not both.")
        }
        let source = try timelineSource(request.from)
        let (project, revision) = coordinator.snapshot()
        let now = TimelineClips(project)
        let labels = TrackLabels.of(project)

        var ids: [String]
        if let clips = request.clips {
            ids = []
            for id in clips where !ids.contains(id) {
                guard source.clips[id] != nil || now[id] != nil else {
                    throw ServiceError(.notFound, "\(id) isn't on the timeline now or in \(source.description).")
                }
                ids.append(id)
            }
        } else {
            let from = request.fromTime ?? .zero
            let to = request.toTime ?? Time(flicks: .max / 2)
            guard from < to else { throw ServiceError(.badRequest, "fromTime has to be before toTime.") }
            var trackID: String?
            if let reference = request.track {
                guard let track = TrackLabels.find(reference, in: project) else {
                    throw ServiceError(.notFound, "There's no track \"\(reference)\". `tandem timeline --summary` lists them.")
                }
                trackID = track.id
            }
            func inRange(_ placed: PlacedClip) -> Bool {
                (trackID == nil || placed.trackID == trackID) && placed.clip.start < to && placed.clip.end > from
            }
            let there = source.clips.clips.values.filter(inRange).map(\.clip.id)
            // What's in that stretch now that wasn't there at all.
            let since = now.clips.values.filter { inRange($0) && source.clips[$0.clip.id] == nil }.map(\.clip.id)
            ids = (there + since).sorted()
        }

        var items: [RestoreItem] = []
        var removals: [String] = []
        var updates: [EditCommand] = []
        var inserts: [EditCommand] = []
        for id in ids {
            switch (source.clips[id], now[id]) {
            case (let was?, let current?) where was.trackID == current.trackID:
                if ClipChanges.same(was.clip, current.clip) {
                    items.append(item(id, .unchanged, current, details: []))
                    continue
                }
                let details = ClipChanges.between(TimelineClips([id: current]), TimelineClips([id: was]), names: source.names).first?.details ?? []
                guard let patch = try JSONValue.mergePatch(from: JSONValue.from(current.clip), to: JSONValue.from(was.clip)) else { continue }
                updates.append(.updateClip(clipID: id, patch: patch))
                items.append(item(id, .changeBack, PlacedClip(clip: was.clip, trackID: current.trackID, track: current.track), details: details, names: source.names))
            case (let was?, let current):
                let trackID = try restoreTrack(for: was, in: project, source: source)
                if current != nil { removals.append(id) }
                inserts.append(.insertClip(trackID: trackID, clip: was.clip, mode: nil))
                let placed = PlacedClip(clip: was.clip, trackID: trackID, track: labels[trackID] ?? was.track)
                items.append(item(id, current == nil ? .putBack : .changeBack, placed, details: current.map { ["track \($0.track) -> \(placed.track)"] } ?? [], names: source.names))
            case (nil, let current?):
                removals.append(id)
                items.append(item(id, .remove, current, details: [], names: source.names))
            case (nil, nil):
                continue
            }
        }
        let shown = Self.trackDisplayOrder(project)
        items.sort { (shown[$0.track] ?? 99, $0.start, $0.id) < (shown[$1.track] ?? 99, $1.start, $1.id) }

        var commands: [EditCommand] = []
        if !removals.isEmpty { commands.append(.removeClips(clipIDs: removals, ripple: false, includeLinked: false)) }
        commands += updates + inserts
        var result = RestoreResult(revision: revision, from: source.description, items: items, commands: commands)
        guard !commands.isEmpty else { return result }

        let changed = items.filter { $0.action != .unchanged }.count
        let apply = ApplyRequest(
            label: request.label ?? "Restore \(changed) clip\(changed == 1 ? "" : "s") from \(Self.shortName(source))",
            author: request.author, commands: commands, expectedRevision: request.expectedRevision ?? revision,
            dryRun: request.apply == true ? nil : true
        )
        if request.apply == true {
            result.applied = try self.apply(apply, context: context)
        } else {
            do {
                _ = try self.apply(apply, context: context)
            } catch let error as ServiceError {
                result.problem = error.message
            }
        }
        return result
    }

    private func item(_ id: String, _ action: RestoreItem.Action, _ placed: PlacedClip, details: [String], names: [String: String] = [:]) -> RestoreItem {
        RestoreItem(
            id: id, action: action, track: placed.track, start: placed.clip.start, end: placed.clip.end,
            content: ClipChanges.content(placed.clip, names: names.isEmpty ? ClipChanges.mediaNames(coordinator.project) : names),
            details: details
        )
    }

    /// The track a clip goes back on: the one it was on, or one with that
    /// track's name if it was replaced.
    private func restoreTrack(for placed: PlacedClip, in project: Project, source: TimelineSource) throws -> String {
        if project.track(placed.trackID) != nil { return placed.trackID }
        let name = source.trackNames[placed.trackID] ?? String(placed.track.drop { $0 != " " }.dropFirst())
        let kind: TrackKind = placed.track.hasPrefix("A") ? .audio : .video
        if let track = project.track(named: name, kind: kind) { return track.id }
        throw ServiceError(.notFound, "\(placed.clip.id) was on \(placed.track), which isn't in the project any more. Add the track back first.")
    }

    /// "revision 95", or the file's name.
    static func shortName(_ source: TimelineSource) -> String {
        if source.description.hasPrefix("revision ") { return source.revision.map { "revision \($0)" } ?? source.description }
        return source.description.components(separatedBy: "/").last.map { name in
            name.replacingOccurrences(of: " (revision", with: "").components(separatedBy: " (").first ?? name
        } ?? source.description
    }

    /// Track labels in the order `timeline` shows them: video top down,
    /// then audio.
    static func trackDisplayOrder(_ project: Project) -> [String: Int] {
        let labels = TrackLabels.of(project)
        var order: [String: Int] = [:]
        for track in project.videoTracks.reversed() { order[labels[track.id] ?? track.name] = order.count }
        for track in project.audioTracks { order[labels[track.id] ?? track.name] = order.count }
        return order
    }
}

// MARK: - clips

extension TandemService {
    public func clips(_ request: ClipsRequest) throws -> ClipsResult {
        let (project, revision) = coordinator.snapshot()
        var trackID: String?
        if let reference = request.track {
            guard let track = TrackLabels.find(reference, in: project) else {
                let names = project.allTracks.map(\.name).joined(separator: ", ")
                throw ServiceError(.notFound, "There's no track \"\(reference)\". The tracks are \(names).", revision: revision)
            }
            trackID = track.id
        }
        var mediaIDs: Set<String>?
        if let reference = request.media {
            let wanted = reference.lowercased()
            let matches = project.media.filter { item in
                item.id == reference || item.path.lowercased() == wanted
                    || (item.path as NSString).lastPathComponent.lowercased() == wanted
                    || item.path.lowercased().hasSuffix("/" + wanted)
            }
            guard !matches.isEmpty else {
                throw ServiceError(.notFound, "No media matches \"\(reference)\". `tandem media` lists the files and their IDs.", revision: revision)
            }
            mediaIDs = Set(matches.map(\.id))
        }
        let labels = TrackLabels.of(project)
        let names = TimelineDump.mediaNames(project)
        let tracks = project.videoTracks.reversed() + project.audioTracks
        var listed: [ClipListing] = []
        for track in tracks where trackID == nil || track.id == trackID {
            for clip in track.clips {
                if let from = request.from, clip.end <= from { continue }
                if let to = request.to, clip.start >= to { continue }
                if let mediaIDs, !(clip.mediaID.map(mediaIDs.contains) ?? false) { continue }
                listed.append(ClipListing(
                    id: clip.id, track: labels[track.id] ?? track.name, trackID: track.id,
                    start: clip.start, end: clip.end, duration: clip.duration,
                    content: TimelineDump.content(clip, project: project, names: names),
                    mediaID: clip.mediaID, name: clip.name, enabled: clip.enabled
                ))
            }
        }
        return ClipsResult(revision: revision, clips: listed, idsOnly: request.ids == true ? true : nil)
    }
}

// MARK: - Text

extension DiffResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        let counts = Self.counts(changes)
        let head = "Since \(since) (now revision \(revision))"
        if changes.isEmpty {
            lines.append("\(head): No clips changed.")
        } else {
            lines.append("\(head): \(counts).")
        }
        if let edits {
            var quiet: [DiffEdit] = []
            func flushQuiet() {
                guard !quiet.isEmpty else { return }
                let span = quiet.count == 1 ? "r\(quiet[0].revision)" : "r\(quiet[0].revision)-r\(quiet[quiet.count - 1].revision)"
                let labels = Dictionary(grouping: quiet, by: \.label).map { $0.value.count > 1 ? "\($0.key) x\($0.value.count)" : $0.key }.sorted()
                lines.append("\(span)  \(quiet.count == 1 ? "1 edit" : "\(quiet.count) edits") that changed no clips: \(labels.joined(separator: ", "))")
                quiet = []
            }
            for edit in edits {
                guard !edit.changes.isEmpty else {
                    quiet.append(edit)
                    continue
                }
                flushQuiet()
                var header = "r\(edit.revision)  \(Self.title(edit))  by \(edit.author)"
                if let start = edit.start, let end = edit.end {
                    header += "  " + EditPlace(start: start, end: end, tracks: edit.tracks ?? []).description
                }
                lines.append(header)
                lines += Self.lines(edit.changes, indent: "    ")
            }
            flushQuiet()
        } else {
            lines += Self.lines(changes, indent: "  ")
        }
        if !changes.isEmpty {
            lines.append("Full detail (each clip before and after) with --json. Put clips back with tandem restore --from <revision or file> --clips <ids>.")
        }
        return lines.joined(separator: "\n")
    }

    static func title(_ edit: DiffEdit) -> String {
        switch edit.kind {
        case .undo: return "Undo \(edit.label)"
        case .redo: return "Redo \(edit.label)"
        default: return edit.label
        }
    }

    static func counts(_ changes: [ClipChange]) -> String {
        var parts: [String] = []
        func count(_ n: Int, _ what: String) { if n > 0 { parts.append("\(n) \(what)") } }
        count(changes.filter { $0.kind == .added }.count, "added")
        count(changes.filter { $0.kind == .removed }.count, "removed")
        count(changes.filter { $0.kind == .changed && $0.shift == nil }.count, "changed")
        count(changes.filter { $0.shift != nil }.count, "moved")
        return parts.joined(separator: ", ")
    }

    /// One line per clip, with clips that moved by the same amount (riding
    /// a ripple) summed up on one line.
    static func lines(_ changes: [ClipChange], indent: String) -> [String] {
        var lines: [String] = []
        let shifts = Dictionary(grouping: changes.filter { $0.shift != nil }, by: { $0.shift! })
        let summed = Set(shifts.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
        for change in changes where !summed.contains(change.id) {
            var line = "\(indent)\(change.kind.rawValue)  \(change.id)  \(change.track)  \(change.start)-\(change.end)  \(change.content)"
            if !change.details.isEmpty { line += ": " + change.details.joined(separator: ", ") }
            lines.append(line)
        }
        for (shift, group) in shifts.sorted(by: { $0.key < $1.key }) where group.count > 1 {
            var tracks: [String] = []
            for change in group where !tracks.contains(change.track) { tracks.append(change.track) }
            let from = group.map { $0.wasStart ?? $0.start }.min() ?? .zero
            lines.append("\(indent)moved  \(group.count) clips by \(String(format: "%+.3fs", shift.seconds)) on \(tracks.joined(separator: ", ")) (from \(from))")
        }
        return lines
    }
}

extension RestoreResult: ReadableResult {
    public var readableText: String {
        let changing = items.filter { $0.action != .unchanged }
        var lines: [String] = []
        if changing.isEmpty {
            lines.append("Nothing to restore: \(items.count == 1 ? "the clip is" : "the clips are") already as \(items.count == 1 ? "it was" : "they were") in \(from).")
        } else {
            let mode = applied == nil ? "dry run" : "applied"
            lines.append("Restore \(changing.count) clip\(changing.count == 1 ? "" : "s") as \(changing.count == 1 ? "it was" : "they were") in \(from) (\(mode), revision \(revision)):")
        }
        for item in items {
            let action: String
            switch item.action {
            case .putBack: action = "put back"
            case .changeBack: action = "change back"
            case .remove: action = "take out"
            case .unchanged: action = "already so"
            }
            var line = "  \(action)  \(item.id)  \(item.track)  \(item.start)-\(item.end)  \(item.content)"
            if !item.details.isEmpty { line += ": " + item.details.joined(separator: ", ") }
            lines.append(line)
        }
        if let problem { lines.append("It wouldn't apply as it stands: \(problem)") }
        if let applied {
            lines.append("Applied as revision \(applied.revision) (\"\(applied.label)\"), one undo step. Undo with `tandem undo`.")
        } else if !changing.isEmpty {
            lines.append("Nothing changed yet. Run again with --apply (or apply: true) to restore them. Transitions, media and markers aren't restored.")
        }
        return lines.joined(separator: "\n")
    }
}

extension ClipsResult: ReadableResult {
    public var readableText: String {
        if idsOnly == true { return clips.map(\.id).joined(separator: "\n") }
        guard !clips.isEmpty else { return "No clips match." }
        let idWidth = clips.map(\.id.count).max() ?? 0
        let trackWidth = clips.map(\.track.count).max() ?? 0
        var lines = ["\(clips.count) clip\(clips.count == 1 ? "" : "s") (revision \(revision)):"]
        for clip in clips {
            let id = clip.id.padding(toLength: idWidth, withPad: " ", startingAt: 0)
            let track = clip.track.padding(toLength: trackWidth, withPad: " ", startingAt: 0)
            lines.append("  \(id)  \(track)  \(clip.start)-\(clip.end)  \(clip.content)\(clip.enabled ? "" : "  off")")
        }
        return lines.joined(separator: "\n")
    }
}

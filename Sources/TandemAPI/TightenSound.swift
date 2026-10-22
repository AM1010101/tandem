import Foundation
import TandemCore
import TandemMedia

/// Tighten's cuts, placed in the sound rather than the transcript's gaps.
///
/// Tighten used to cut the middle out of each gap between two transcript
/// words. Those words' edges come from where the waveform is over one floor
/// for the whole take, so a second speaker with no mic or an app talking
/// read as silence and got cut through (#11), and a word whose time was
/// 0.2 s off had its start cut off (#64). So each gap the transcript finds
/// is listened to on every track of the take that plays there
/// (`GapSound`): the cut goes in a real pause, keeps Mike's gap measured
/// from the end of the last word's sound to the start of the next, and
/// never goes through sound. Then both sides of each join are judged as
/// `tandem check --cuts` would, and a join that isn't clean isn't cut.
///
/// The CLI, MCP and the app's Tighten pauses all plan with this, so they
/// agree. Where a file's sound can't be read, its pauses are planned from
/// the transcript as before, with a warning.
public enum SoundTightening {
    public struct Plan: Sendable {
        public var cuts: [PlannedCut] = []
        public var skipped: [SkippedPause] = []
        public var warnings: [String] = []
    }

    /// The tracks a cut through the take is heard on: every unmuted audio
    /// track that ripples with the take (Voice, another mic, a device's own
    /// recording cut to match), or every unmuted audio track when none
    /// does. Music and sound effects aren't the take, and follow tracks
    /// aren't cut, so their sound is never cut through anyway. Video
    /// tracks' sound isn't played. Solo is left out on purpose: it's a way
    /// of listening, and a track that's only quiet because another is
    /// soloed is still in the video.
    public static func audibleTracks(_ project: Project) -> [Track] {
        let unmuted = project.audioTracks.filter { !$0.muted }
        let take = unmuted.filter { $0.rippleMode == .cut }
        return take.isEmpty ? unmuted : take
    }

    static func plays(_ clip: Clip, in project: Project) -> MediaItem? {
        guard TranscriptTools.isHeard(clip), let id = clip.mediaID, let item = project.media(id), item.hasAudio,
              item.role != .music, item.role != .sfx else { return nil }
        return item
    }

    /// Sound read either side of what a gap needs: the floor and speech
    /// level `CutPlacer` takes over 3 s, a second's chunk of floors, and
    /// the reach a join's judge looks over.
    static var readMargin: Double { CutAudit.around + CutAudit.reach + 1.5 }

    /// What `listen` heard: the sound under each pause (nil where it
    /// couldn't be heard) and the tracks it was heard on.
    struct Listening {
        var sounds: [GapSound?]
        var layers: [[SoundLayer]]
        /// Files whose sound couldn't be read.
        var unread: [String]
    }

    /// The words either side of a pause, in timeline seconds.
    static func words(around pause: Pause, in map: TranscriptTools.SpeechMap) -> (before: ClosedRange<Double>, after: ClosedRange<Double>)? {
        let tolerance = Time(seconds: 0.001)
        guard let before = map.words.filter({ $0.end <= pause.start + tolerance }).max(by: { $0.end < $1.end }),
              let after = map.words.first(where: { $0.start >= pause.end - tolerance }) else { return nil }
        return (before.start.seconds...max(before.start.seconds, before.end.seconds), after.start.seconds...max(after.start.seconds, after.end.seconds))
    }

    /// The timeline stretch `GapSound.listen` looks at for a pause.
    static func window(_ pause: Pause, before: ClosedRange<Double>, after: ClosedRange<Double>) -> ClosedRange<Double> {
        min(before.lowerBound - 0.1, pause.start.seconds - CutPlanner.slack)...max(after.upperBound + 0.1, pause.end.seconds + CutPlanner.slack)
    }

    static func listen(_ pauses: [Pause], map: TranscriptTools.SpeechMap, project: Project, folder: ProjectFolder) async -> Listening {
        let tracks = audibleTracks(project)
        let around = pauses.map { words(around: $0, in: map) }
        let windows = zip(pauses, around).map { pause, words in words.map { window(pause, before: $0.before, after: $0.after) } }

        // Each file's stretches the pauses need, read once each.
        var needed: [String: [ClosedRange<Double>]] = [:]
        var items: [String: MediaItem] = [:]
        for window in windows.compactMap({ $0 }) {
            for track in tracks {
                for clip in track.clips where clip.start.seconds < window.upperBound && clip.end.seconds > window.lowerBound {
                    guard let item = plays(clip, in: project) else { continue }
                    let from = max(window.lowerBound, clip.start.seconds), to = min(window.upperBound, clip.end.seconds)
                    let media = { (time: Double) in clip.sourceStart.seconds + (time - clip.start.seconds) * clip.speed }
                    needed[item.id, default: []].append(max(0, media(from) - readMargin)...(media(to) + readMargin))
                    items[item.id] = item
                }
            }
        }
        var readings: [String: [CutPlacer]] = [:]
        var unread: [String] = []
        for (id, ranges) in needed.sorted(by: { $0.key < $1.key }) {
            guard let item = items[id] else { continue }
            var merged: [ClosedRange<Double>] = []
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            do {
                var energies: [SpeechEnergy] = []
                for range in merged {
                    energies.append(try await SpeechEnergy.read(url: folder.url(for: item), from: range.lowerBound, to: range.upperBound))
                }
                let levels = SpeechLevels(of: energies)
                readings[id] = energies.map { CutPlacer($0, levels: levels) }
            } catch {
                unread.append(item.path)
            }
        }

        var sounds: [GapSound?] = []
        var layers: [[SoundLayer]] = []
        for (index, pause) in pauses.enumerated() {
            guard let words = around[index], let window = windows[index] else {
                sounds.append(nil)
                layers.append([])
                continue
            }
            var heard: [SoundLayer] = []
            // The same file at the same point on two tracks is one sound.
            var seen = Set<String>()
            for track in tracks {
                var pieces: [SoundLayer.Piece] = []
                for clip in track.clips where clip.start.seconds < window.upperBound && clip.end.seconds > window.lowerBound {
                    guard let item = plays(clip, in: project), let placers = readings[item.id] else { continue }
                    let start = clip.sourceStart.seconds, from = max(window.lowerBound, clip.start.seconds)
                    let media = start + (from - clip.start.seconds) * clip.speed
                    guard let placer = placers.first(where: { $0.energy.start <= media && media <= $0.energy.end }) else { continue }
                    let key = "\(item.id)@\(((start - clip.start.seconds * clip.speed) * 1000).rounded())x\(clip.speed)"
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)
                    pieces.append(SoundLayer.Piece(timeline: clip.start.seconds..<clip.end.seconds, mediaStart: start, speed: clip.speed, placer: placer))
                }
                if !pieces.isEmpty { heard.append(SoundLayer(name: track.name, pieces: pieces)) }
            }
            layers.append(heard)
            sounds.append(heard.isEmpty ? nil : GapSound.listen(gap: pause.start.seconds...pause.end.seconds, before: words.before, after: words.after, layers: heard))
        }
        return Listening(sounds: sounds, layers: layers, unread: unread)
    }

    /// A gap's sound as the service reports it.
    static func report(_ sound: GapSound) -> PauseSound {
        func time(_ seconds: Double) -> Time { Time(seconds: (seconds * 1000).rounded() / 1000) }
        return PauseSound(
            start: time(sound.span.lowerBound), end: time(sound.span.upperBound),
            duration: time(sound.span.upperBound) - time(sound.span.lowerBound),
            quiet: sound.pauses.map { TimeRange(start: time($0.lowerBound), end: time($0.upperBound)) },
            heard: sound.heard.map { HeardSound(start: time($0.range.lowerBound), end: time($0.range.upperBound), tracks: $0.layers) },
            runsThrough: sound.runsThrough
        )
    }

    /// The pauses with what's in the sound under each (`tandem pauses`).
    public static func listened(_ pauses: [Pause], map: TranscriptTools.SpeechMap, project: Project, folder: ProjectFolder) async -> (pauses: [Pause], warnings: [String]) {
        let heard = await listen(pauses, map: map, project: project, folder: folder)
        var result = pauses
        for index in result.indices { result[index].sound = heard.sounds[index].map(report) }
        return (result, unreadWarnings(heard.unread, fallback: "so pauses there are as the transcript has them"))
    }

    static func unreadWarnings(_ unread: [String], fallback: String) -> [String] {
        unread.map { "Couldn't read the sound of \(URL(fileURLWithPath: $0).lastPathComponent), \(fallback)." }
    }

    /// Plans the cuts for `pauses` (already found from the transcript and
    /// filtered for `protect`), one per pause at most: each in the longest
    /// real pause in its sound, leaving the keep for what it follows
    /// between the two words' sound, on whole frames (`snug` as
    /// `TranscriptTools.plan` has it), with both sides of its join clean.
    public static func plan(
        _ pauses: [Pause], rules: TranscriptTools.PauseRules, snug: Bool,
        map: TranscriptTools.SpeechMap, project: Project, folder: ProjectFolder
    ) async -> Plan {
        let rate = project.settings.frameRate
        let frame = rate.frameDuration
        // Only pauses the rules change are listened to.
        let changing = pauses.filter { pause in
            let kind = TranscriptTools.pauseKind(after: pause.before)
            return rules.keep(for: kind) != nil && pause.duration >= rules.shortest(for: kind)
        }
        let heard = await listen(changing, map: map, project: project, folder: folder)
        var plan = Plan()
        var guessed = false
        // No margin when no track there carries a voice: nothing to clip.
        func side(_ join: GapSound.Join) -> CutJoinSide? {
            join.margin.map { CutJoinSide(verdict: join.verdict, margin: (Double($0) * 10).rounded() / 10) }
        }
        for (index, original) in changing.enumerated() {
            let kind = TranscriptTools.pauseKind(after: original.before)
            guard let keep = rules.keep(for: kind) else { continue }
            guard let sound = heard.sounds[index] else {
                // No sound to go by: the transcript's gap, as tighten always cut it.
                let fallback = TranscriptTools.plan([original], rules: rules, frameRate: rate, snug: snug)
                guessed = guessed || !fallback.isEmpty
                plan.cuts += fallback
                continue
            }
            var pause = original
            pause.sound = report(sound)
            func skip(_ reason: SkippedPause.Reason, start: CutJoinSide? = nil, end: CutJoinSide? = nil) {
                plan.skipped.append(SkippedPause(pause: pause, reason: reason, kind: kind, keep: keep, startEdge: start, endEdge: end))
            }
            let placement: GapSound.Placement
            switch sound.place(keep: keep.seconds, minimum: rules.shortest(for: kind).seconds, frame: frame.seconds) {
            case .success(let placed): placement = placed
            case .failure(.fits): continue
            case .failure(.speech): skip(.speech); continue
            case .failure(.sound): skip(.sound); continue
            case .failure(.short): skip(.short); continue
            }

            // On frames, inside the pause and `GapSound.edgeGuard` from its
            // ends, never leaving less than the keep.
            let lowest = TimeText.ceilToFrame(Time(seconds: placement.earliest), rate)
            let highest = TimeText.floorToFrame(Time(seconds: placement.latest), rate)
            var cut: TimeRange?
            if snug {
                var frames = Int64(((placement.to - placement.from) / frame.seconds + 1e-9).rounded(.down))
                while frames > 0, cut == nil {
                    let length = Time.frames(frames, at: rate)
                    let start = max(lowest, min(Time(seconds: placement.from).roundedToFrame(rate), highest - length))
                    if start >= lowest, start + length <= highest { cut = TimeRange(start: start, duration: length) }
                    frames -= 1
                }
            } else {
                let start = TimeText.ceilToFrame(Time(seconds: placement.from), rate)
                let end = TimeText.floorToFrame(Time(seconds: placement.to), rate)
                if end - start >= frame { cut = TimeRange(start: start, end: end) }
            }
            guard let cut else { continue }

            let joins = GapSound.judge(heard.layers[index], from: cut.start.seconds, to: cut.end.seconds)
            guard joins.start.verdict == .clean, joins.end.verdict == .clean else {
                skip(.notClean, start: side(joins.start), end: side(joins.end))
                continue
            }
            plan.cuts.append(PlannedCut(pause: pause, cut: cut, kind: kind, keep: keep, startEdge: side(joins.start), endEdge: side(joins.end)))
        }
        if guessed {
            plan.warnings += unreadWarnings(heard.unread, fallback: "so pauses there were cut from the transcript's gaps alone. Listen to them")
            if heard.unread.isEmpty {
                plan.warnings.append("Some pauses have no sound to listen to, so they were cut from the transcript's gaps alone. Listen to them.")
            }
        } else {
            plan.warnings += unreadWarnings(heard.unread, fallback: "so it wasn't listened to")
        }
        plan.cuts.sort { $0.cut.start < $1.cut.start }
        return plan
    }
}

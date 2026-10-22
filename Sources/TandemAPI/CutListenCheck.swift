import Foundation
import TandemCore
import TandemMedia
import TandemRender

/// One join heard by `tandem check --cuts --listen`.
public struct HeardJoin: Codable, Equatable, Sendable {
    /// Where the join is on the timeline.
    public var time: Time
    /// The take's kept words across it (the transcript as the clips play
    /// it), " | " at the join.
    public var said: String
    /// What the engine heard across it.
    public var heard: String
    /// What doesn't match near the join. A `slip` finding is as likely the
    /// engine's mistake: a note, not a problem.
    public var findings: [CutListen.Finding]
    /// The clips either side.
    public var clipIDs: [String]
    /// Heard on an earlier check: the sound there hasn't changed since.
    public var cached: Bool

    public init(time: Time, said: String, heard: String, findings: [CutListen.Finding], clipIDs: [String], cached: Bool) {
        self.time = time
        self.said = said
        self.heard = heard
        self.findings = findings
        self.clipIDs = clipIDs
        self.cached = cached
    }

    /// A finding that isn't slip-prone.
    public var clipped: Bool { findings.contains { !$0.slip } }
}

/// What `--listen` heard.
public struct ListenSummary: Codable, Equatable, Sendable {
    /// The engine that heard them: Bark 3.0 Pro, or SpeechAnalyzer when
    /// Bark's model isn't there.
    public var engine: String
    /// Every join checked, in timeline order.
    public var joins: [HeardJoin]
    /// How many were heard this time, and how many came from the cache.
    public var heard: Int
    public var cached: Int
    /// Seconds each join heard this time took, rendering and listening.
    public var secondsPerJoin: Double?

    public init(engine: String, joins: [HeardJoin], heard: Int, cached: Int, secondsPerJoin: Double?) {
        self.engine = engine
        self.joins = joins
        self.heard = heard
        self.cached = cached
        self.secondsPerJoin = secondsPerJoin
    }
}

extension CutCheck {
    /// What `--listen` hears with: an engine's name and a call that hears
    /// 16 kHz mono samples. Tests swap in their own.
    struct Ear: Sendable {
        var engine: String
        var listen: @Sendable ([Float]) async throws -> [CutListen.Word]

        /// Bark 3.0 Pro when its model is ready, as transcripts use;
        /// SpeechAnalyzer otherwise (macOS 26); nil with neither.
        static func standard() -> Ear? {
            let bark = BarkListener.standard
            if bark.isReady { return Ear(engine: BarkListener.engine) { try await bark.listen($0) } }
            if #available(macOS 26, *) {
                let speech = SpeechAnalyzerListener()
                return Ear(engine: SpeechAnalyzerListener.engine) { try await speech.listen($0) }
            }
            return nil
        }
    }

    /// How the voice is rendered for listening: mono at `rate`, timeline
    /// seconds from and to. Tests swap in their own.
    struct Mix: Sendable {
        var rate: Double
        var render: @Sendable (_ from: Double, _ to: Double) async throws -> [Float]

        /// The speech tracks as export plays them, every other audio track
        /// muted, so music and sound effects don't get in the engine's way.
        static func speech(_ project: Project, folder: ProjectFolder, analysis: MediaAnalysis?) async throws -> Mix {
            let speech = Set(TranscriptTools.speechTracks(project).map(\.id))
            let context = RenderContext(project: AudioLevels.soloing(project, audioTrackIDs: speech), folder: folder, analysis: analysis)
            let reader = try await MixReader(context)
            return Mix(rate: MixReader.sampleRate) { try await reader.mono(from: $0, to: $1) }
        }
    }

    struct Listened: Sendable {
        var summary: ListenSummary
        var warnings: [String] = []
    }

    /// Renders the voice `CutListen.span` either side of each join among
    /// `edges`, hears it (from the cache where that sound was heard before)
    /// and compares it with the take's words there.
    ///
    /// - Parameters:
    ///   - said: the transcript's words as the speech clips play them
    ///     (timeline time).
    ///   - words: each file's transcript words (media time), by media ID:
    ///     for the cut words beside each join.
    static func listen(
        project: Project, edges: [Edge], said: [CutListen.Word], words: [String: [CutAudit.Word]], mix: Mix, ear: Ear, cache: CutListenCache
    ) async -> Listened {
        let tolerance = project.settings.frameRate.flicksPerFrame / 2
        var groups: [[Edge]] = []
        for edge in edges.sorted(by: { $0.time < $1.time }) {
            if let last = groups.last?.first, abs((last.time - edge.time).flicks) <= tolerance {
                groups[groups.count - 1].append(edge)
            } else {
                groups.append([edge])
            }
        }
        var joins: [HeardJoin] = []
        var warnings: [String] = []
        var fresh = 0, cached = 0
        var seconds = 0.0
        for group in groups {
            let time = group[0].time
            let join = time.seconds
            let from = join - CutListen.span
            let started = Date()
            let input: [Float]
            do {
                input = try CutListen.prepare(try await mix.render(from, join + CutListen.span), rate: mix.rate)
            } catch {
                warnings.append("Couldn't render the voice at \(time) to listen to it: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                continue
            }
            let key = CutListenCache.key(input, engine: ear.engine)
            var heard = cache.heard(key)
            let wasCached = heard != nil
            if heard == nil {
                do {
                    heard = try await ear.listen(input)
                    cache.store(heard!, for: key)
                } catch {
                    // An engine that fails once (a model that won't load)
                    // fails for every join: say so once.
                    let left = groups.count - joins.count
                    let what = left == 1 ? "1 join wasn't" : "\(left) joins weren't"
                    warnings.append("\(ear.engine) couldn't listen at \(time), so \(what) heard: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                    break
                }
                fresh += 1
                seconds += Date().timeIntervalSince(started)
            } else {
                cached += 1
            }
            let offset = from - CutListen.padding
            let heardWords = heard!.map { CutListen.Word(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
            let window = (join - CutListen.span)...(join + CutListen.span)
            let kept = said.filter { $0.end > window.lowerBound && $0.start < window.upperBound }
            let (past, before) = cutWords(beside: group, words: words)
            let result = CutListen.compare(said: kept, heard: heardWords, at: join, cutPast: past, cutBefore: before)
            var clipIDs: [String] = []
            for edge in group.sorted(by: { ($0.edge == .end ? 0 : 1) < ($1.edge == .end ? 0 : 1) }) where !clipIDs.contains(edge.clip.id) {
                clipIDs.append(edge.clip.id)
            }
            joins.append(HeardJoin(time: time, said: result.said, heard: result.heard, findings: result.findings, clipIDs: clipIDs, cached: wasCached))
        }
        let summary = ListenSummary(engine: ear.engine, joins: joins, heard: fresh, cached: cached, secondsPerJoin: fresh > 0 ? seconds / Double(fresh) : nil)
        return Listened(summary: summary, warnings: warnings)
    }

    /// The take's words cut beside a join, by the transcript: the first two
    /// cut past the end of the clip before it, and the last two cut before
    /// the start of the clip after it.
    static func cutWords(beside group: [Edge], words: [String: [CutAudit.Word]]) -> (past: [String], before: [String]) {
        func middle(_ word: CutAudit.Word) -> Double { (word.start + word.end) / 2 }
        var past: [String] = [], before: [String] = []
        for edge in group {
            let said = (words[edge.media.id] ?? []).sorted { $0.start < $1.start }
            if edge.edge == .end {
                let gone = edge.cutAway ?? edge.mediaTime...(edge.mediaTime + CutListen.span)
                past = said.filter { middle($0) >= edge.mediaTime && gone.contains(middle($0)) }.prefix(2).map(\.text)
            } else {
                let gone = edge.removed ?? max(0, edge.mediaTime - CutListen.span)...edge.mediaTime
                before = said.filter { middle($0) < edge.mediaTime && gone.contains(middle($0)) }.suffix(2).map(\.text)
            }
        }
        return (past, before)
    }

    /// The transcript's words as the speech tracks play them, in timeline
    /// seconds. Where two tracks play the same voice (a camera's sound and
    /// a mic), a word is said once.
    static func said(in project: Project, analysis: AnalysisSource) -> [CutListen.Word] {
        var words: [CutListen.Word] = []
        for word in TranscriptTools.speechMap(project, analysis: analysis).words.sorted(by: { $0.start < $1.start }) {
            let candidate = CutListen.Word(text: word.text, start: word.start.seconds, end: word.end.seconds)
            let twice = words.suffix(4).contains { earlier in
                let overlap = min(earlier.end, candidate.end) - max(earlier.start, candidate.start)
                return overlap > 0.5 * min(earlier.end - earlier.start, candidate.end - candidate.start)
                    && earlier.text.lowercased().filter(\.isLetter) == candidate.text.lowercased().filter(\.isLetter)
            }
            if !twice { words.append(candidate) }
        }
        return words
    }

    /// A problem for each join heard cut off, and a note for each heard
    /// differently in a way that's as likely the engine's slip.
    static func problems(_ summary: ListenSummary) -> (problems: [CheckProblem], notes: [CheckProblem]) {
        var problems: [CheckProblem] = [], notes: [CheckProblem] = []
        for join in summary.joins where !join.findings.isEmpty {
            let shown = join.findings.filter { join.clipped ? !$0.slip : true }
            let what = shown.map { "\($0.summary) (\($0.why))" }.joined(separator: "; ")
            let words = "Take: \"\(join.said)\". Heard: \"\(join.heard)\"."
            if join.clipped {
                problems.append(CheckProblem(
                    kind: .heardCutOff, start: join.time, end: join.time,
                    message: "Heard cut off at the join: \(what). \(words) Listen with tandem clip and recut it.", clipIDs: join.clipIDs
                ))
            } else {
                notes.append(CheckProblem(
                    kind: .heardDifferently, start: join.time, end: join.time,
                    message: "Heard differently at the join, likely \(summary.engine)'s slip: \(what). \(words)", clipIDs: join.clipIDs
                ))
            }
        }
        return (problems, notes)
    }
}

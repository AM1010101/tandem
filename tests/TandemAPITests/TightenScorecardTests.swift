import AVFoundation
import XCTest
@testable import TandemAPI
@testable import TandemCore
@testable import TandemMedia

/// How tighten's cuts land on a real take, the old planner (the middle of
/// each transcript gap) against the new one (in the sound): cuts planned,
/// seconds removed, and every join judged by `CutPlacer.judge` on the raw
/// mic, as `tandem check --cuts` judges it. Ian's uncut whiteboard take
/// (#64) is the take it was made for.
///
/// Opt-in, and it prints a scorecard rather than asserting thresholds:
///
///     TANDEM_TIGHTEN_PROJECT="<…>/ian-whiteboard/Ian Whiteboard.tandem" \
///       swift test --filter TightenScorecardTests
///
/// It's a dry run on a copy: the project file is copied into a folder in
/// `.build`, with the voice's file linked beside it, and never saved. The
/// voice's transcript comes from the project's own cache, aligned to its
/// cached waveform as the app aligns it. Add TANDEM_TIGHTEN_ALL=1 for a
/// line on every join that isn't clean.
final class TightenScorecardTests: XCTestCase {
    struct Score {
        var cuts = 0
        var removed = 0.0
        var joins: [CutAudit.Verdict: Int] = [:]
        var sides: [CutAudit.Verdict: Int] = [:]
        var lines: [String] = []
    }

    func testScorecard() async throws {
        guard let path = ProcessInfo.processInfo.environment["TANDEM_TIGHTEN_PROJECT"] else {
            throw XCTSkip("set TANDEM_TIGHTEN_PROJECT to a .tandem project to score tighten")
        }
        let original = URL(fileURLWithPath: path)
        let source = original.deletingLastPathComponent()
        let copy = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/tighten-scorecard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        let projectURL = copy.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: projectURL)

        let session = try ProjectSession.open(projectURL, owner: .cli)
        session.autosaveDelay = 3600
        let analysis = FakeAnalysis()
        analysis.transcripts = [:]
        let service = TandemService(session: session, mode: .headless, analysis: analysis, renderer: FakeRenderer())
        defer {
            service.shutdown()
            session.close()
        }
        let project = service.coordinator.project

        // Each voice file linked in, with its transcript from the cache.
        let cache = source.appendingPathComponent(".tandem/cache")
        func entry(_ kind: String, for item: MediaItem) throws -> URL? {
            let folder = cache.appendingPathComponent(kind)
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
                let url = folder.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url.appendingPathComponent("entry.json")),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["source"] as? String == item.path else { continue }
                return url
            }
            return nil
        }
        let voiceClips = TranscriptTools.speechTracks(project).flatMap(\.clips)
        var voices: [String: SpeechEnergy] = [:]
        for id in Set(voiceClips.compactMap(\.mediaID)).sorted() {
            guard let item = project.media(id) else { continue }
            let link = copy.appendingPathComponent(item.path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source.appendingPathComponent(item.path))
            guard let transcriptFolder = try entry("transcript", for: item), let raw = TranscriptJob.read(from: transcriptFolder) else { continue }
            let waveform = try entry("waveform", for: item).flatMap { WaveformJob.read(from: $0) }
            analysis.transcripts[id] = waveform.map { raw.aligned(to: $0) } ?? raw
            voices[id] = try Self.energy(link)
        }
        XCTAssertFalse(analysis.transcripts.isEmpty, "no transcript in the cache")

        // Old: the transcript's gaps, cut in the middle, Mike's rules.
        let started = Date()
        let map = TranscriptTools.speechMap(project, analysis: analysis)
        let rules = TranscriptTools.mikeRules
        let gaps = TranscriptTools.pauses(in: map, minimum: min(rules.minimum, rules.midMinimum))
        let old = TranscriptTools.plan(gaps, rules: rules, frameRate: project.settings.frameRate, snug: true)
        // New: in the sound.
        let new = try await service.tighten(TightenRequest(mike: true), context: CallContext(author: "scorecard"))
        let took = Date().timeIntervalSince(started)
        XCTAssertNil(new.applied)

        let levels = voices.mapValues { SpeechLevels(of: [$0]) }
        let all = ProcessInfo.processInfo.environment["TANDEM_TIGHTEN_ALL"] == "1"
        func score(_ cuts: [PlannedCut]) -> Score {
            var score = Score()
            for planned in cuts {
                score.cuts += 1
                score.removed += planned.cut.duration.seconds
                let cut = planned.cut
                guard let before = voiceClips.first(where: { $0.start < cut.start && cut.start <= $0.end }),
                      let after = voiceClips.first(where: { $0.start <= cut.end && cut.end < $0.end }),
                      let a = before.mediaID, let b = after.mediaID, let ea = voices[a], let eb = voices[b] else { continue }
                func media(_ time: Time, _ clip: Clip) -> Double { clip.sourceStart.seconds + (time - clip.start).seconds * clip.speed }
                let from = media(cut.start, before), to = media(cut.end, after)
                let removed = a == b && from < to ? from...to : nil
                let start = CutPlacer(ea, levels: levels[a]!).judge(at: from, keeps: .before, removed: removed)
                let end = CutPlacer(eb, levels: levels[b]!).judge(at: to, keeps: .after, removed: removed)
                let rank: [CutAudit.Verdict: Int] = [.clean: 0, .marginal: 1, .clipped: 2]
                let join = rank[start.verdict]! >= rank[end.verdict]! ? start.verdict : end.verdict
                score.joins[join, default: 0] += 1
                score.sides[start.verdict, default: 0] += 1
                score.sides[end.verdict, default: 0] += 1
                if all, join != .clean {
                    func margin(_ edge: CutAudit.Edge) -> String { edge.margin.map { String(format: "%.1f", $0) } ?? "pause" }
                    score.lines.append("    \(cut.start)-\(cut.end)  start \(start.verdict.rawValue) \(margin(start)), end \(end.verdict.rawValue) \(margin(end))  ...\(planned.pause.before) | \(planned.pause.after)...")
                }
            }
            return score
        }
        let before = score(old), after = score(new.cuts)
        func row(_ name: String, _ score: Score) -> String {
            let joins = [CutAudit.Verdict.clipped, .marginal, .clean].map { "\(score.joins[$0, default: 0]) \($0.rawValue)" }.joined(separator: " / ")
            let sides = [CutAudit.Verdict.clipped, .marginal, .clean].map { "\(score.sides[$0, default: 0])" }.joined(separator: " / ")
            return String(format: "  %@: %d cuts, %.1f s removed; joins %@ (sides %@)", name, score.cuts, score.removed, joins, sides)
        }
        var lines = ["Tighten scorecard (--mike, dry run) on \(original.lastPathComponent): \(gaps.count) transcript gaps of 0.5 s or more"]
        lines.append(row("old, transcript gaps", before))
        lines += before.lines
        lines.append(row("new, in the sound  ", after))
        lines += after.lines
        let reasons = Dictionary(grouping: new.skipped, by: \.reason).mapValues(\.count)
        lines.append("  new left alone: \(reasons[.sound, default: 0]) with sound in them, \(reasons[.speech, default: 0]) with the voice running through, \(reasons[.short, default: 0]) under 0.5 s measured from the sound, \(reasons[.notClean, default: 0]) whose join wouldn't be clean")
        // Where the new plan keeps what the old one cut.
        let beside = new.cuts.filter { !($0.pause.sound?.heard.isEmpty ?? true) }
        let heardSeconds = beside.flatMap { $0.pause.sound?.heard ?? [] }.reduce(0) { $0 + ($1.end - $1.start).seconds }
        let shortened = new.cuts.reduce(0.0) { total, cut in
            total + max(0, cut.pause.duration.seconds - (cut.pause.sound?.duration.seconds ?? cut.pause.duration.seconds))
        }
        let shorts = new.skipped.filter { $0.reason == .short }
        let shortGap = shorts.reduce(0) { $0 + $1.pause.duration.seconds }
        let shortSound = shorts.reduce(0) { $0 + ($1.pause.sound?.duration.seconds ?? 0) }
        lines.append(String(format: "  new cuts beside sound no word accounts for: %d, keeping %.1f s of it", beside.count, heardSeconds))
        lines.append(String(format: "  the cut pauses are %.1f s shorter in the sound than in the transcript", shortened))
        lines.append(String(format: "  the %d short ones: %.1f s of transcript gap, %.1f s in the sound", shorts.count, shortGap, shortSound))
        lines.append(String(format: "  (both plans in %.1f s)", took))
        if all {
            for cut in beside.prefix(25) {
                let heard = cut.pause.sound?.heard.map { "\($0.start)-\($0.end)" }.joined(separator: ", ") ?? ""
                lines.append("    beside \(heard): cut \(cut.cut.start)-\(cut.cut.end) in \(cut.pause.start)-\(cut.pause.end)  ...\(cut.pause.before) | \(cut.pause.after)...")
            }
            for skip in shorts.prefix(15) {
                lines.append("    short \(skip.pause.start)-\(skip.pause.end) \(TimeText.duration(skip.pause.duration)), heard \(skip.pause.sound.map { "\($0.start)-\($0.end)" } ?? "")  ...\(skip.pause.before) | \(skip.pause.after)...")
            }
            for skip in new.skipped where skip.reason == .notClean {
                lines.append("    not clean \(skip.pause.start)-\(skip.pause.end) start \(skip.startEdge.map { "\($0.verdict.rawValue) \($0.margin)" } ?? "-"), end \(skip.endEdge.map { "\($0.verdict.rawValue) \($0.margin)" } ?? "-")")
            }
        }
        if all {
            for skip in new.skipped where skip.reason == .sound || skip.reason == .speech {
                let heard = skip.pause.sound?.heard.map { "\($0.start)-\($0.end)" }.joined(separator: ", ") ?? ""
                lines.append("    left \(skip.pause.start)-\(skip.pause.end) \(skip.reason.rawValue) \(heard)  ...\(skip.pause.before) | \(skip.pause.after)...")
            }
        }
        for warning in new.warnings { lines.append("  warning: \(warning)") }
        print(lines.joined(separator: "\n"))
    }

    /// The whole file, read with AVAudioFile.
    static func energy(_ url: URL) throws -> SpeechEnergy {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let count = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
        try file.read(into: buffer, frameCount: count)
        let channels = Int(file.processingFormat.channelCount)
        var samples = [Float](repeating: 0, count: Int(buffer.frameLength))
        for channel in 0..<channels {
            let data = try XCTUnwrap(buffer.floatChannelData)[channel]
            for i in samples.indices { samples[i] += data[i] / Float(channels) }
        }
        return SpeechEnergy(samples: samples, sampleRate: rate, start: 0)
    }
}

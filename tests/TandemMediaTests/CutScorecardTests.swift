import AVFoundation
import XCTest
@testable import TandemMedia

/// How `CutAudit` does on the cut edges of a real edit, labelled by ear and
/// by measurement: how many clipped edges it catches, how many clean ones it
/// flags, and how near its trims land to the fixes that worked. The Ian
/// whiteboard video's 124 edges (#64) are the set it was made for.
///
/// Opt-in, and it prints a scorecard rather than asserting thresholds:
///
///     TANDEM_CUT_EDGES=<edges.json> TANDEM_CUT_MEDIA=<folder of the files they name> \
///       swift test --filter CutScorecardTests
///
/// Add TANDEM_CUT_ALL=1 for a line on every edge, not just the misses.
///
/// TANDEM_CUT_WORDS=<folder> scores it with a transcript: one JSON per
/// file, named for it (`<name>.json` for `<name>.wav`), as
/// `{"words": [{"start", "end", "text"}]}` in the engine's own times.
/// TANDEM_CUT_ALIGN=1 aligns them to the file's sound first, as Tandem does
/// when it reads a transcript (`TranscriptAlignment`).
///
/// Each edge is `{"id", "file", "edge", "keeps": "before"|"after",
/// "removed": [start, end] or null, "label": "clipped"|"marginal"|"clean",
/// "fixedEdge", "fix", "kind"}`, times in the file's own media time.
/// `fixedEdge` is where the edit moved the edge (null where the cut was put
/// back), and when an edge there is labelled too, it's that edge's fix that
/// counts: on the Ian video most of the first round's fixes were flagged
/// again and put back in the second. The final cut's set adds `source`
/// (`heard`: Mike heard it clipped; `fixed`: an agent fixed it; `approved`:
/// a join in the final cut) and `under` (music or a sound effect playing
/// over an approved join).
final class CutScorecardTests: XCTestCase {
    struct Labelled: Decodable {
        var id: String
        var file: String
        var edge: Double
        var keeps: String
        var removed: [Double]?
        var label: String
        var fixedEdge: Double?
        var fix: String?
        var kind: String?
        var source: String?
        var under: [String]?
        var fixedBy: String?

        /// Mike heard something an audio check can't: a sentence left
        /// hanging, an off-mic question, a breath cut short, a leftover
        /// fragment of a cut phrase.
        var isEditorial: Bool {
            kind.map { $0.hasPrefix("editorial") || $0.hasPrefix("other") || $0 == "fragment" || $0 == "halfThought" } ?? false
        }
    }

    /// What finally worked for an edge: a trim to a time, or putting the
    /// cut back.
    enum Worked: Equatable {
        case trim(Double)
        case putBack
        case unknown
    }

    /// The speech level and floor's 3 s either side of an edge, and room to
    /// reach a pause.
    private static let around = CutAudit.around + CutAudit.reach

    func testScorecard() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let edgesPath = environment["TANDEM_CUT_EDGES"], let mediaPath = environment["TANDEM_CUT_MEDIA"] else {
            throw XCTSkip("set TANDEM_CUT_EDGES and TANDEM_CUT_MEDIA to score the cut check")
        }
        let edges = try JSONDecoder().decode([Labelled].self, from: Data(contentsOf: URL(fileURLWithPath: edgesPath)))
        let media = URL(fileURLWithPath: mediaPath, isDirectory: true)
        let wordsFolder = environment["TANDEM_CUT_WORDS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let align = environment["TANDEM_CUT_ALIGN"] == "1"

        var results = try judgeAll(edges, media: media, wordsFolder: wordsFolder, align: align).results
        results.sort { ($0.0.file, $0.0.edge) < ($1.0.file, $1.0.edge) }

        var lines = ["Cut scorecard: \(results.count) edges, " + (wordsFolder == nil ? "no transcript" : align ? "aligned transcript" : "transcript in the engine's times")]
        if results.contains(where: { $0.0.source != nil }) { lines += bySource(results, edges: edges) }
        for label in ["clipped", "marginal", "clean"] {
            for editorial in [false, true] {
                let these = results.filter { $0.0.label == label && $0.0.isEditorial == editorial }
                guard !these.isEmpty else { continue }
                let counts = Dictionary(grouping: these, by: { $0.1.verdict }).mapValues(\.count)
                let what = editorial ? "editorial or other, no audio check can hear these" : "acoustic"
                lines.append("  labelled \(label), \(what) (\(these.count)): judged clipped \(counts[.clipped] ?? 0), marginal \(counts[.marginal] ?? 0), clean \(counts[.clean] ?? 0)")
            }
        }
        let caught = results.filter { $0.0.label == "clipped" && $0.1.clipped }
        let fixes = Dictionary(grouping: caught, by: { fixName($0.1.fix) }).mapValues(\.count)
        lines.append("  fixes for caught clipped edges: " + fixes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        let worked = caught.map { ($0, Self.worked($0.0, in: edges)) }
        let trimsThatWorked = worked.filter { if case .trim = $0.1 { true } else { false } }
        let offsets = trimsThatWorked.compactMap { pair -> Double? in
            guard case .trim(let fixed) = pair.1, let to = pair.0.1.suggestion else { return nil }
            return abs(to - fixed)
        }.sorted()
        lines.append(String(
            format: "  caught edges the edit fixed with a trim (%d): trimmed %d, median %.0f ms from it, within 60 ms %d, over 150 ms %d",
            trimsThatWorked.count, offsets.count, offsets.isEmpty ? 0 : offsets[offsets.count / 2] * 1000,
            offsets.filter { $0 <= 0.0605 }.count, offsets.filter { $0 > 0.15 }.count
        ))
        let putBack = worked.filter { $0.1 == .putBack }
        let putBackFixes = Dictionary(grouping: putBack, by: { fixName($0.0.1.fix) }).mapValues(\.count)
        lines.append("  caught edges the edit put back (\(putBack.count)): " + putBackFixes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            + " (with no transcript here, a trim can't tell it's bringing a cut word back)")

        func row(_ pair: (Labelled, CutAudit.Edge)) -> String {
            let (labelled, edge) = pair
            let margin = edge.margin.map { String(format: "%5.1f dB", $0) } ?? "  pause "
            let lost = edge.lost.map { String(format: "%.2f", $0) } ?? "-"
            let gap = edge.gap.map { String(format: "%.3f", $0) } ?? "-"
            let to = edge.suggestion.map { String(format: "%.3f", $0) } ?? ""
            let fixed: String
            switch Self.worked(labelled, in: edges) {
            case .trim(let time): fixed = String(format: "trim %.3f", time) + (edge.suggestion.map { String(format: ", %+.0f ms", ($0 - time) * 1000) } ?? "")
            case .putBack: fixed = "putBack"
            case .unknown: fixed = "-"
            }
            return "    \(labelled.id) \(String(format: "%.3f", labelled.edge)) keeps \(labelled.keeps): \(edge.verdict.rawValue), \(margin), lost \(lost), gap \(gap), fix \(fixName(edge.fix)) \(to)\(edge.betweenWords ? " between words" : "")\(edge.drops.map { " drops \"\($0)\"" } ?? "")\(edge.lastWordCut.map { " last word \"\($0)\"" } ?? "")\(edge.firstWordCut.map { " first word \"\($0)\"" } ?? "")\(edge.fragment.map { " fragment \"\($0)\"" } ?? "")\(edge.beforeFiller.map { " before a filler \"\($0)\"" } ?? "") (worked: \(fixed)) [\(labelled.kind ?? "")\(labelled.under.map { " under " + $0.joined(separator: "+") } ?? "")]"
        }
        let missed = results.filter { $0.0.label == "clipped" && !$0.1.clipped && $0.0.source != "fixed" }
        let falseAlarms = results.filter { $0.0.label == "clean" && $0.1.clipped }
        lines.append("  clipped edges not judged clipped (\(missed.count))" + (results.contains { $0.0.source == "fixed" } ? ", leaving out the ones an agent fixed:" : ":"))
        lines += missed.map(row)
        lines.append("  clean edges flagged (\(falseAlarms.count)):")
        lines += falseAlarms.map(row)
        let lastWord = results.filter { $0.1.lastWordCut != nil }
        lines.append("  ending just before the last word of a sentence (\(lastWord.count)):")
        lines += lastWord.map { "  \($0.0.source ?? $0.0.label)" + row($0) }
        let firstWord = results.filter { $0.1.firstWordCut != nil }
        lines.append("  starting just after the first word of a sentence (\(firstWord.count)):")
        lines += firstWord.map { "  \($0.0.source ?? $0.0.label)" + row($0) }
        let fragment = results.filter { $0.1.fragment != nil }
        lines.append("  starting on the last word of a cut sentence (\(fragment.count)):")
        lines += fragment.map { "  \($0.0.source ?? $0.0.label)" + row($0) }
        let beforeFiller = results.filter { $0.1.beforeFiller != nil }
        lines.append("  cutting a filler and the word before it (\(beforeFiller.count)):")
        lines += beforeFiller.map { "  \($0.0.source ?? $0.0.label)" + row($0) }
        if environment["TANDEM_CUT_ALL"] == "1" {
            for label in ["clipped", "marginal", "clean"] {
                lines.append("  every \(label) edge:")
                lines += results.filter { $0.0.label == label }.map(row)
            }
        }
        print(lines.joined(separator: "\n"))
        XCTAssertFalse(results.isEmpty)
    }

    /// How `check --cuts --listen` does on the same edit: each join whose
    /// two sides come from one file (an edge with a `removed` range says
    /// both, whichever of them is labelled) is spliced from the mic as the
    /// edit plays it (the kept sound before the out-edge, then from the
    /// in-edge on, butt joined), heard with Bark 3.0 Pro, and compared with
    /// the take's transcript (TANDEM_CUT_WORDS, needed here) as `CutListen`
    /// compares them. Joins between files are skipped and counted. Each
    /// line says whether the levels (`testScorecard`'s judgement) flag
    /// either edge too, since `--listen` runs beside them.
    ///
    /// Needs Bark's model in Tandem's folder, or TANDEM_CUT_LISTEN_WITH: a
    /// command that hears `<key>.f32` files (16 kHz mono float, padding and
    /// all) and writes `<key>.json` beside each, as `[{"text", "start",
    /// "end"}]`, for another runtime of the model where CoreML can't run.
    /// What's heard is kept in TANDEM_CUT_LISTEN_CACHE (default
    /// `$TMPDIR/tandem-listen-scorecard`), so a second run only compares.
    func testListeningScorecard() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let edgesPath = environment["TANDEM_CUT_EDGES"], let mediaPath = environment["TANDEM_CUT_MEDIA"],
              let wordsPath = environment["TANDEM_CUT_WORDS"] else {
            throw XCTSkip("set TANDEM_CUT_EDGES, TANDEM_CUT_MEDIA and TANDEM_CUT_WORDS to score listening")
        }
        let listener = BarkListener.standard
        guard listener.isReady || environment["TANDEM_CUT_LISTEN_WITH"] != nil else { throw XCTSkip("Bark 3.0 Pro isn't downloaded") }
        let edges = try JSONDecoder().decode([Labelled].self, from: Data(contentsOf: URL(fileURLWithPath: edgesPath)))
        let media = URL(fileURLWithPath: mediaPath, isDirectory: true)
        let cache = CutListenCache(folder: environment["TANDEM_CUT_LISTEN_CACHE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tandem-listen-scorecard", isDirectory: true))
        let (judged, transcripts) = try judgeAll(edges, media: media, wordsFolder: URL(fileURLWithPath: wordsPath, isDirectory: true), align: environment["TANDEM_CUT_ALIGN"] == "1")
        let levels = Dictionary(judged.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })

        /// One join: the out-edge and the in-edge of one stretch cut out of
        /// a file.
        struct Join {
            var file: String
            var removed: ClosedRange<Double>
            var out: [Labelled] = []
            var into: [Labelled] = []
            var all: [Labelled] { out + into }
        }
        var joins: [Join] = []
        var betweenFiles = 0
        for edge in edges {
            guard let range = edge.removed, range.count == 2, range[1] > range[0] else {
                betweenFiles += 1
                continue
            }
            let removed = range[0]...range[1]
            var index = joins.firstIndex { $0.file == edge.file && abs($0.removed.lowerBound - removed.lowerBound) < 0.0015 && abs($0.removed.upperBound - removed.upperBound) < 0.0015 }
            if index == nil {
                joins.append(Join(file: edge.file, removed: removed))
                index = joins.count - 1
            }
            if edge.keeps == "before" { joins[index!].out.append(edge) } else { joins[index!].into.append(edge) }
        }

        // Every join's splice first, so what isn't in the cache is heard in
        // one go.
        let external = environment["TANDEM_CUT_LISTEN_WITH"]
        let engine = external == nil ? BarkListener.engine : BarkListener.engine + " (\(external!))"
        // Another runtime's model is its own: the command names it.
        let model = external == nil ? BarkListener.model : "external v\(CutListen.version)"
        let ordered = joins.sorted(by: { ($0.file, $0.removed.lowerBound) < ($1.file, $1.removed.lowerBound) })
        var splices: [(input: [Float], key: String, offset: Double)] = []
        for join in ordered {
            let url = media.appendingPathComponent(join.file)
            let (before, rate) = try samples(url, from: join.removed.lowerBound - CutListen.span, to: join.removed.lowerBound)
            let (after, _) = try samples(url, from: join.removed.upperBound, to: join.removed.upperBound + CutListen.span)
            let input = try CutListen.prepare(before + after, rate: rate)
            splices.append((input, CutListenCache.key(input, engine: engine, model: model), CutListen.padding + Double(before.count) / rate))
        }
        let missing = splices.filter { cache.heard($0.key) == nil }
        let started = Date()
        if let external, !missing.isEmpty {
            // Another runtime of the same model, where CoreML can't run (a
            // sandbox that can't write its compile cache): it reads each
            // `<key>.f32` (16 kHz mono float) and writes `<key>.json`.
            try FileManager.default.createDirectory(at: cache.folder, withIntermediateDirectories: true)
            var paths: [String] = []
            for splice in missing {
                let path = cache.folder.appendingPathComponent("\(splice.key).f32")
                try splice.input.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: path)
                paths.append(path.path)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", external + " \"$@\"", "listen"] + paths
            try process.run()
            process.waitUntilExit()
            for path in paths { try? FileManager.default.removeItem(atPath: path) }
        } else {
            for splice in missing { cache.store(try await listener.listen(splice.input), for: splice.key) }
        }
        let heardSeconds = Date().timeIntervalSince(started), listened = missing.count

        var rows: [(join: Join, heard: CutListen.Join, cut: [String])] = []
        for (join, splice) in zip(ordered, splices) {
            let out = join.removed.lowerBound, into = join.removed.upperBound
            let heard = try XCTUnwrap(cache.heard(splice.key), "nothing heard for \(join.file) \(join.removed)")
            // The splice's own time: the join at 0.
            let heardWords = heard.map { CutListen.Word(text: $0.text, start: $0.start - splice.offset, end: $0.end - splice.offset) }
            let words = transcripts[join.file] ?? []
            func middle(_ word: CutAudit.Word) -> Double { (word.start + word.end) / 2 }
            let said = words.filter { middle($0) < out && $0.end > out - CutListen.span }.map { CutListen.Word(text: $0.text, start: $0.start - out, end: $0.end - out) }
                + words.filter { middle($0) >= into && $0.start < into + CutListen.span }.map { CutListen.Word(text: $0.text, start: $0.start - into, end: $0.end - into) }
            // As `CutCheck.cutWords`: a word the edge runs through counts.
            let past = words.filter { $0.end > out && $0.start < into }.prefix(2).map(\.text)
            let before = words.filter { $0.start < into && $0.end > out }.suffix(2).map(\.text)
            let result = CutListen.compare(said: said, heard: heardWords, at: 0, cutPast: Array(past), cutBefore: Array(before))
            rows.append((join, result, Array(past) + Array(before)))
        }

        func source(_ join: Join) -> String {
            if join.all.contains(where: { $0.source == "heard" && !$0.isEditorial }) { return "heard" }
            if join.all.contains(where: { $0.source == "heard" }) { return "heard, editorial" }
            if join.all.allSatisfy({ $0.source == "approved" }) { return "approved" }
            return "fixed"
        }
        func byLevels(_ join: Join) -> Bool { join.all.contains { levels[$0.id]?.clipped == true } }
        func line(_ row: (join: Join, heard: CutListen.Join, cut: [String])) -> String {
            let ids = row.join.all.map(\.id).joined(separator: "+")
            let findings = row.heard.findings.map { "\($0.slip ? "note" : "CLIP") \($0.summary) (\($0.why))" }.joined(separator: "; ")
            return String(format: "    %@ %@ %.3f-%.3f [%@]%@\n      said:  %@\n      heard: %@%@", ids, String(row.join.file.suffix(12)), row.join.removed.lowerBound, row.join.removed.upperBound,
                          row.join.all.compactMap(\.kind).joined(separator: ","), byLevels(row.join) ? " (levels: clipped)" : "",
                          row.heard.said, row.heard.heard, findings.isEmpty ? "" : "\n      " + findings)
        }
        var lines = ["Listening scorecard: \(rows.count) joins cut out of one file heard (\(betweenFiles) edges between files, skipped)"]
        lines.append("  engine: \(engine)")
        if listened > 0 { lines.append(String(format: "  listened to %d joins in %.1f s, %.2f s a join (the rest from the cache)", listened, heardSeconds, heardSeconds / Double(listened))) }
        for kind in ["heard", "heard, editorial", "fixed", "approved"] {
            let these = rows.filter { source($0.join) == kind }
            guard !these.isEmpty else { continue }
            let listen = these.filter(\.heard.clipped).count
            let notes = these.filter { !$0.heard.clipped && !$0.heard.findings.isEmpty }.count
            let either = these.filter { $0.heard.clipped || byLevels($0.join) }.count
            lines.append("  \(kind) (\(these.count)): listening flags \(listen), notes only \(notes); levels \(these.filter { byLevels($0.join) }.count); either \(either)")
        }
        for kind in ["heard", "heard, editorial"] {
            lines.append("  every \(kind) join:")
            lines += rows.filter { source($0.join) == kind }.map(line)
        }
        lines.append("  fixed joins listening flags:")
        lines += rows.filter { source($0.join) == "fixed" && $0.heard.clipped }.map(line)
        lines.append("  approved joins listening flags:")
        lines += rows.filter { source($0.join) == "approved" && $0.heard.clipped }.map(line)
        lines.append("  approved joins with notes only:")
        lines += rows.filter { source($0.join) == "approved" && !$0.heard.clipped && !$0.heard.findings.isEmpty }.map(line)
        lines += combined(rows.map { ($0.join.all, $0.heard, $0.cut) }, source: { join in source(Join(file: "", removed: 0...0, out: join, into: [])) }, levels: levels)
        if environment["TANDEM_CUT_ALL"] == "1" {
            lines.append("  every other join:")
            lines += rows.filter { source($0.join) == "fixed" || (source($0.join) == "approved" && $0.heard.findings.isEmpty) }.map(line)
        }
        print(lines.joined(separator: "\n"))
        XCTAssertFalse(rows.isEmpty)
    }

    /// The levels and the transcript's rules weighed against what's heard
    /// (`CutEvidence`), as `check --cuts --listen` reports them: each
    /// join's flag stands unless listening dismisses it, and listening's own
    /// finding stands unless the take's transcript explains it.
    private func combined(
        _ rows: [(edges: [Labelled], heard: CutListen.Join, cut: [String])], source: ([Labelled]) -> String, levels: [String: CutAudit.Edge]
    ) -> [String] {
        func judge(_ row: (edges: [Labelled], heard: CutListen.Join, cut: [String])) -> (flagged: Bool, levels: Bool, listening: Bool, verdict: CutEvidence.Verdict, why: String) {
            let flagged = row.edges.compactMap { edge in levels[edge.id].map { (edge, $0) } }.filter { $0.1.clipped }
            let flags = flagged.map { CutEvidence.Flag($0.1, keeps: $0.0.keeps == "before" ? .before : .after) }
            let verdict = CutEvidence.judge(row.heard, flags: flags, cut: row.cut)
            let standing = flags.indices.filter { verdict.dismissed[$0] == nil }
            let why = flagged.indices.map { index in
                let (edge, judged) = flagged[index]
                var rule = judged.margin.map { String(format: "levels %.1f dB", $0) } ?? "levels"
                if let word = judged.lastWordCut { rule = "last word \"\(word)\"" }
                if let word = judged.firstWordCut { rule = "first word \"\(word)\"" }
                if let word = judged.fragment { rule = "fragment \"\(word)\"" }
                if let word = judged.beforeFiller { rule = "before a filler \"\(word)\"" }
                return "\(edge.id) \(rule): " + (verdict.dismissed[index] ?? (verdict.confirming.isEmpty ? "stands" : "stands, heard too"))
            } + (verdict.heardCutOff ? ["listening finding stands"] : []) + verdict.explained.sorted { $0.key < $1.key }.map { "\(row.heard.findings[$0.key].summary): \($0.value)" }
            return (!standing.isEmpty || verdict.heardCutOff, !flags.isEmpty, row.heard.clipped, verdict, why.joined(separator: "; "))
        }
        var lines = ["  combined (levels and the transcript's rules confirmed or dismissed by listening):"]
        let judged = rows.map { ($0, judge($0)) }
        for kind in ["heard", "heard, editorial", "fixed", "approved"] {
            let these = judged.filter { source($0.0.edges) == kind }
            guard !these.isEmpty else { continue }
            let either = these.filter { $0.1.levels || $0.1.listening }.count
            lines.append("    \(kind) (\(these.count)): levels or listening \(either), combined \(these.filter(\.1.flagged).count)")
        }
        let heard = judged.filter { source($0.0.edges) == "heard" }
        for kind in Array(Set(heard.flatMap { $0.0.edges.compactMap(\.kind) })).sorted() where kind != "join" {
            let these = heard.filter { $0.0.edges.contains { $0.kind == kind } }
            lines.append("    heard \(kind): either \(these.filter { $0.1.levels || $0.1.listening }.count), combined \(these.filter(\.1.flagged).count) of \(these.count)")
        }
        let fixed = judged.filter { source($0.0.edges) == "fixed" }
        lines.append("    fixed by an agent, by kind: " + Array(Set(fixed.flatMap { $0.0.edges.compactMap(\.kind) })).sorted().filter { $0 != "join" }.map { kind in
            let these = fixed.filter { $0.0.edges.contains { $0.kind == kind } }
            return "\(kind) either \(these.filter { $0.1.levels || $0.1.listening }.count), combined \(these.filter(\.1.flagged).count) of \(these.count)"
        }.joined(separator: "; "))
        func row(_ pair: ((edges: [Labelled], heard: CutListen.Join, cut: [String]), (flagged: Bool, levels: Bool, listening: Bool, verdict: CutEvidence.Verdict, why: String))) -> String {
            "      \(pair.0.edges.map(\.id).joined(separator: "+")) [\(pair.0.edges.compactMap(\.kind).joined(separator: ","))]: \(pair.1.why)\n        said:  \(pair.0.heard.said)\n        heard: \(pair.0.heard.heard)"
        }
        let lost = heard.filter { ($0.1.levels || $0.1.listening) && !$0.1.flagged }
        lines.append("    heard joins flagged before and not now (\(lost.count)):")
        lines += lost.map(row)
        lines.append("    heard joins still flagged (\(heard.filter(\.1.flagged).count)):")
        lines += heard.filter(\.1.flagged).map(row)
        lines.append("    approved joins still flagged:")
        lines += judged.filter { source($0.0.edges) == "approved" && $0.1.flagged }.map(row)
        lines.append("    approved joins dismissed:")
        lines += judged.filter { source($0.0.edges) == "approved" && ($0.1.levels || $0.1.listening) && !$0.1.flagged }.map(row)
        return lines
    }

    /// Mono samples of the file from `from` to `to`, and their rate.
    private func samples(_ url: URL, from: Double, to: Double) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let start = max(0, from)
        file.framePosition = AVAudioFramePosition((start * rate).rounded())
        let count = AVAudioFrameCount(((to - start) * rate).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
        try file.read(into: buffer, frameCount: count)
        return (Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength))), rate)
    }

    /// How `CutPlanner` (`tandem cut`) does on the same edit: for every
    /// labelled join cut out of one file (it has a `removed` range), plan
    /// removing that same stretch from the sound alone. The set has no
    /// transcript, so the removed range's ends stand in for the words'
    /// times, as they are and shifted by up to 0.2 s either way, as off as
    /// SpeechAnalyzer was on the Ian video (#64).
    func testPlannerScorecard() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let edgesPath = environment["TANDEM_CUT_EDGES"], let mediaPath = environment["TANDEM_CUT_MEDIA"] else {
            throw XCTSkip("set TANDEM_CUT_EDGES and TANDEM_CUT_MEDIA to score the cut planner")
        }
        let edges = try JSONDecoder().decode([Labelled].self, from: Data(contentsOf: URL(fileURLWithPath: edgesPath)))
        let media = URL(fileURLWithPath: mediaPath, isDirectory: true)

        /// One join: a stretch cut out of a file, and the labelled edges
        /// either side of it.
        struct Join {
            var file: String
            var removed: ClosedRange<Double>
            var edges: [Labelled]
            var clipped: Bool { edges.contains { $0.label == "clipped" } }
        }
        var joins: [Join] = []
        for edge in edges {
            guard let range = edge.removed, range.count == 2, range[1] > range[0] else { continue }
            let removed = range[0]...range[1]
            if let index = joins.firstIndex(where: { $0.file == edge.file && abs($0.removed.lowerBound - removed.lowerBound) < 0.0015 && abs($0.removed.upperBound - removed.upperBound) < 0.0015 }) {
                joins[index].edges.append(edge)
            } else {
                joins.append(Join(file: edge.file, removed: removed, edges: [edge]))
            }
        }
        joins.sort { ($0.file, $0.removed.lowerBound) < ($1.file, $1.removed.lowerBound) }

        // The sound either side of each join's two edges, with room for the
        // floor, the speech level and the shifts.
        let around = CutAudit.around + CutAudit.reach + CutPlanner.slack + 0.2
        var placers: [String: (start: CutPlacer, end: CutPlacer)] = [:]
        for (file, group) in Dictionary(grouping: joins, by: \.file) {
            let url = media.appendingPathComponent(file)
            var windows: [(String, SpeechEnergy, SpeechEnergy)] = []
            for join in group {
                let key = "\(join.removed)"
                windows.append((key,
                    try energy(url, from: join.removed.lowerBound - around, to: join.removed.lowerBound + around),
                    try energy(url, from: join.removed.upperBound - around, to: join.removed.upperBound + around)))
            }
            let levels = SpeechLevels(of: windows.flatMap { [$0.1, $0.2] })
            for (key, start, end) in windows { placers[file + key] = (CutPlacer(start, levels: levels), CutPlacer(end, levels: levels)) }
        }

        func plan(_ join: Join, shift: Double) -> CutPlan {
            let placer = placers[join.file + "\(join.removed)"]!
            let from = join.removed.lowerBound + shift, to = join.removed.upperBound + shift
            return CutPlanner.plan(
                start: placer.start, CutPlanner.Boundary(time: from), end: placer.end, CutPlanner.Boundary(time: to),
                keep: 0.08, falseStart: to - from > CutPlanner.falseStartFrom
            )
        }
        func kind(_ plan: CutPlan) -> String {
            if plan.cuts { return plan.falseStart ? "falseStart" : "clean" }
            return plan.problem?.rawValue ?? "?"
        }

        var lines = ["Cut planner scorecard: \(joins.count) joins cut out of one file (\(joins.filter(\.clipped).count) with a clipped edge)"]
        for shift in [0, -0.1, 0.1, -0.2, 0.2] {
            let kinds = Dictionary(grouping: joins.map { kind(plan($0, shift: shift)) }, by: { $0 }).mapValues(\.count)
            lines.append(String(format: "  ends shifted %+.1f s: ", shift) + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }

        // Against what finally worked, unshifted and shifted, every edge.
        for shift in [0, -0.2, 0.2] {
            var offsets: [Double] = []
            var putBackAndKept = 0, putBackButCut = 0
            var clippedCut = 0, clippedKept = 0, clippedNotClean = 0, clippedNear = 0
            for join in joins {
                let result = plan(join, shift: shift)
                let worked = join.edges.map { Self.worked($0, in: edges) }
                var near = true
                for (labelled, fix) in zip(join.edges, worked) {
                    guard case .trim(let time) = fix, result.cuts, let planned = labelled.keeps == "before" ? result.from : result.to else { continue }
                    offsets.append(abs(planned - time))
                    near = near && abs(planned - time) <= 0.0605
                }
                if worked.contains(.putBack) { if result.cuts { putBackButCut += 1 } else { putBackAndKept += 1 } }
                guard join.clipped else { continue }
                if result.cuts {
                    clippedCut += 1
                    if near { clippedNear += 1 }
                } else if result.problem == .notClean {
                    clippedNotClean += 1
                } else {
                    clippedKept += 1
                }
            }
            offsets.sort()
            lines.append(String(format: "  shifted %+.1f s:", shift))
            lines.append(String(
                format: "    planned edges against the fix that worked (%d): median %.0f ms, within 60 ms %d, over 150 ms %d",
                offsets.count, offsets.isEmpty ? 0 : offsets[offsets.count / 2] * 1000, offsets.filter { $0 <= 0.0605 }.count, offsets.filter { $0 > 0.15 }.count
            ))
            lines.append("    joins the edit put back: planner kept \(putBackAndKept), cut pause to pause \(putBackButCut)")
            lines.append("    clipped joins avoided: \(clippedCut + clippedKept) of \(joins.filter(\.clipped).count) (cut clean pause to pause \(clippedCut), \(clippedNear) of them within 60 ms of every fix that worked; kept \(clippedKept)); planned but not clean \(clippedNotClean)")
        }

        lines.append("  every join, unshifted (planned from-to, fixes that worked):")
        for join in joins {
            let result = plan(join, shift: 0)
            let planned = result.from.map { String(format: "%.3f-%.3f", $0, result.to ?? 0) } ?? "-"
            let worked = join.edges.map { labelled -> String in
                switch Self.worked(labelled, in: edges) {
                case .trim(let time): return "\(labelled.keeps) trim " + String(format: "%.3f", time)
                case .putBack: return "\(labelled.keeps) putBack"
                case .unknown: return "\(labelled.keeps) -"
                }
            }.joined(separator: ", ")
            let margins = [result.start?.margin, result.end?.margin].map { $0.map { String(format: "%.0f", $0) } ?? "-" }.joined(separator: "/")
            let labels = join.edges.map(\.label).joined(separator: "+")
            lines.append(String(format: "    %@ %.3f-%.3f [%@]: %@ %@ margins %@ (worked: %@)", join.file.prefix(24).description, join.removed.lowerBound, join.removed.upperBound, labels, kind(result), planned, margins, worked))
        }
        print(lines.joined(separator: "\n"))
        XCTAssertFalse(joins.isEmpty)
    }

    /// Every edge judged, levels per file from every window read, as
    /// `tandem check --cuts` works them out per take; and each file's
    /// transcript, when there's one.
    private func judgeAll(_ edges: [Labelled], media: URL, wordsFolder: URL?, align: Bool) throws -> (results: [(Labelled, CutAudit.Edge)], words: [String: [CutAudit.Word]]) {
        var results: [(Labelled, CutAudit.Edge)] = []
        var transcripts: [String: [CutAudit.Word]] = [:]
        for (file, group) in Dictionary(grouping: edges, by: \.file).sorted(by: { $0.key < $1.key }) {
            let url = media.appendingPathComponent(file)
            let words = try wordsFolder.map {
                try BarkWords.load($0.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".json"), aligningTo: align ? url : nil)
            }
            transcripts[file] = words
            let windows = try group.map { try energy(url, from: $0.edge - Self.around, to: $0.edge + Self.around) }
            let levels = SpeechLevels(of: windows)
            for (labelled, window) in zip(group, windows) {
                let removed = labelled.removed.flatMap { $0.count == 2 ? $0[0]...$0[1] : nil }
                let side: CutAudit.Side = labelled.keeps == "before" ? .before : .after
                let edge: CutAudit.Edge
                if let words {
                    // As `tandem check --cuts` passes them: the words its 3 s
                    // either side of the edge reach, and all of the cut with
                    // 3 s past it.
                    let around = (labelled.edge - CutAudit.around)...(labelled.edge + CutAudit.around)
                    let near = removed.map { min(around.lowerBound, $0.lowerBound)...max(around.upperBound, $0.upperBound + CutAudit.around) } ?? around
                    let nearby = words.filter { $0.range.overlaps(near) }
                    edge = CutAudit.judge(window, levels: levels, at: labelled.edge, keeps: side, removed: removed, transcript: nearby)
                } else {
                    edge = CutAudit.judge(window, levels: levels, at: labelled.edge, keeps: side, removed: removed)
                }
                results.append((labelled, edge))
            }
        }
        return (results, transcripts)
    }

    /// The final cut's set by where each edge came from: what Mike heard,
    /// by kind; the joins he approved that are flagged, plain and under
    /// music or a sound effect; and how near the fixes land to the ones the
    /// edit made.
    private func bySource(_ results: [(Labelled, CutAudit.Edge)], edges: [Labelled]) -> [String] {
        var lines: [String] = []
        let heard = results.filter { $0.0.source == "heard" }
        for kind in Array(Set(heard.compactMap(\.0.kind))).sorted() {
            let these = heard.filter { $0.0.kind == kind }
            let what = these[0].0.isEditorial ? " (content, no audio check hears it)" : ""
            lines.append("  heard \(kind)\(what): caught \(these.filter(\.1.clipped).count) of \(these.count)" + (these.contains { $0.1.verdict == .marginal } ? ", marginal \(these.filter { $0.1.verdict == .marginal }.count)" : ""))
        }
        let acoustic = heard.filter { !$0.0.isEditorial }
        lines.append("  heard, acoustic: caught \(acoustic.filter(\.1.clipped).count) of \(acoustic.count)")
        let fixed = results.filter { $0.0.source == "fixed" }
        lines.append("  fixed by an agent: judged clipped \(fixed.filter(\.1.clipped).count) of \(fixed.count), marginal \(fixed.filter { $0.1.verdict == .marginal }.count) ("
            + Array(Set(fixed.compactMap(\.0.kind))).sorted().map { kind in "\(kind) \(fixed.filter { $0.0.kind == kind && $0.1.clipped }.count) of \(fixed.filter { $0.0.kind == kind }.count)" }.joined(separator: ", ") + ")")
        let approved = results.filter { $0.0.source == "approved" }
        let plain = approved.filter { ($0.0.under ?? []).isEmpty }, under = approved.filter { !($0.0.under ?? []).isEmpty }
        lines.append("  approved flagged: \(approved.filter(\.1.clipped).count) of \(approved.count) (plain \(plain.filter(\.1.clipped).count) of \(plain.count), under music or sfx \(under.filter(\.1.clipped).count) of \(under.count)); marginal \(approved.filter { $0.1.verdict == .marginal }.count)")
        for source in ["heard", "fixed"] {
            let caught = results.filter { $0.0.source == source && !$0.0.isEditorial && $0.1.clipped }
            let offsets = caught.compactMap { pair -> Double? in
                guard case .trim(let fixed) = Self.worked(pair.0, in: edges), let to = pair.1.suggestion else { return nil }
                return abs(to - fixed)
            }.sorted()
            let withTrim = caught.filter { if case .trim = Self.worked($0.0, in: edges) { true } else { false } }.count
            let putBack = caught.filter { Self.worked($0.0, in: edges) == .putBack || $0.0.fixedBy == "putBack" }
            lines.append(String(
                format: "  %@ and caught, where the edit trimmed (%d): trimmed too %d, median %.0f ms from it, within 60 ms %d, over 150 ms %d; where it put the cut back (%d): ",
                source, withTrim, offsets.count, offsets.isEmpty ? 0 : offsets[offsets.count / 2] * 1000, offsets.filter { $0 <= 0.0605 }.count, offsets.filter { $0 > 0.15 }.count, putBack.count
            ) + Dictionary(grouping: putBack, by: { fixName($0.1.fix) }).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        return lines
    }

    /// Follows an edge's fix on to the labelled edge it made, if any, and
    /// says what finally worked there.
    static func worked(_ edge: Labelled, in edges: [Labelled]) -> Worked {
        var current = edge
        var seen: Set<String> = [edge.id]
        while let fixed = current.fixedEdge {
            guard let next = edges.first(where: {
                !seen.contains($0.id) && $0.file == current.file && $0.keeps == current.keeps && abs($0.edge - fixed) < 0.0015
            }) else { return .trim(fixed) }
            // A join in the final cut is where the fix ended up.
            if next.source == "approved" { return .trim(next.edge) }
            seen.insert(next.id)
            current = next
        }
        if current.fixedBy == "putBack" { return .putBack }
        return current.fix?.contains("restor") == true ? .putBack : .unknown
    }

    private func fixName(_ fix: CutAudit.Fix?) -> String {
        switch fix {
        case .trim: "trim"
        case .putBack: "putBack"
        case .nothingNearby: "nothingNearby"
        case nil: "none"
        }
    }

    /// Frames of the file from `from` to `to`, read straight from there.
    private func energy(_ url: URL, from: Double, to: Double) throws -> SpeechEnergy {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let start = max(0, from)
        file.framePosition = AVAudioFramePosition((start * rate).rounded())
        let count = AVAudioFrameCount(((to - start) * rate).rounded())
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
        try file.read(into: buffer, frameCount: count)
        let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[0], count: Int(buffer.frameLength)))
        return SpeechEnergy(samples: samples, sampleRate: rate, start: start)
    }
}

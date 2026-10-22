import AVFoundation
import CryptoKit
import Foundation
import Speech

/// `tandem check --cuts --listen`: hears each join as it plays and compares
/// what's heard with what the take says there.
///
/// The levels and the transcript's times can't hear everything. On the Ian
/// video's final cut, after it was signed off, a reading pass (transcribe
/// the rendered voice, read the words across every join, listen to what
/// reads wrong) found five more cut-offs, and `check --cuts` had passed
/// three of them: a kept side opening on "do,", the last word of the cut
/// sentence; "the" dropped from "And [the,] like,"; and a cut inside
/// "okay" that the aligned transcript put after the edge. So this renders
/// the voice `span` either side of the join, transcribes it with the app's
/// own engine, and lines the words heard up with the take's.
///
/// What's flagged, near the join (`near`):
/// - a kept word that isn't heard, or is heard as something else (a word
///   cut short: "extra" for "extract");
/// - a word heard that isn't kept: what's left of a cut word ("oh" from
///   "okay"), named when it sounds like the cut word beside the join.
///
/// Transcription slips are real: on the Ian pass 2 of the 5 joins flagged
/// were the engine's mistakes. So words match loosely (case, punctuation,
/// numbers, "wanna" for "want to", "t. s." for "TS", an inflection, a
/// letter out in a longer word), and a mismatch on a short function word
/// or a filler is a slip-prone note, not a clipped word. Each finding says
/// how it was matched.
public enum CutListen {
    /// Seconds either side of the join rendered and heard: room for the
    /// engine to hear a sentence's worth of context.
    public static let span = 3.0
    /// Silence before and after the render, which helps the engine with
    /// the first and last words (the Ian session padded about 0.5 s). The
    /// whole input stays under the 8 s of Bark's short encoder, so it never
    /// switches between encoders.
    public static let padding = 0.5
    /// Words this near the join (seconds, either side) are compared; past
    /// it, a mismatch is the window's own edge or the engine's.
    public static let near = 0.6
    /// What the engines hear at.
    public static let sampleRate = 16_000.0

    /// A word, in seconds: timeline time for the take's words, and from the
    /// start of the samples for what an engine hears.
    public struct Word: Codable, Equatable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }

        var middle: Double { (start + end) / 2 }
    }

    public struct Finding: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// A kept word near the join isn't heard.
            case notHeard
            /// A kept word near the join is heard as something else.
            case heardAs
            /// A word is heard near the join that the take doesn't keep there.
            case extra
        }

        public var kind: Kind
        /// The take's word, for `notHeard` and `heardAs`.
        public var said: String?
        /// What was heard, for `heardAs` and `extra`.
        public var heard: String?
        /// Timeline time of the word.
        public var time: Double
        /// As likely the engine's mistake as a cut-off: a short function
        /// word, a filler or a near spelling. A note, not a clipped word.
        public var slip: Bool
        /// How it was matched, or why it's slip-prone.
        public var why: String

        public init(kind: Kind, said: String? = nil, heard: String? = nil, time: Double, slip: Bool, why: String) {
            self.kind = kind
            self.said = said
            self.heard = heard
            self.time = time
            self.slip = slip
            self.why = why
        }

        /// "\"okay\" isn't heard" and the like.
        public var summary: String {
            switch kind {
            case .notHeard: return "\"\(said ?? "")\" isn't heard"
            case .heardAs: return "\"\(said ?? "")\" is heard as \"\(heard ?? "")\""
            case .extra: return "\"\(heard ?? "")\" is heard, which the take doesn't keep here"
            }
        }
    }

    /// One join heard.
    public struct Join: Codable, Equatable, Sendable {
        /// Timeline time of the join.
        public var time: Double
        /// The take's kept words across it, " | " at the join.
        public var said: String
        /// What was heard across it.
        public var heard: String
        public var findings: [Finding]
        /// A finding that isn't slip-prone: a word cut off or left in.
        public var clipped: Bool { findings.contains { !$0.slip } }

        public init(time: Double, said: String, heard: String, findings: [Finding]) {
            self.time = time
            self.said = said
            self.heard = heard
            self.findings = findings
        }
    }

    // MARK: - Comparing

    /// Lines up what's heard across the join at `join` with the take's kept
    /// words there, both in timeline time.
    ///
    /// - Parameters:
    ///   - cutPast: the take's words cut just past the end of the clip
    ///     before the join, in order: what it would have said next.
    ///   - cutBefore: the take's words cut just before the start of the
    ///     clip after the join, in order.
    public static func compare(said: [Word], heard: [Word], at join: Double, cutPast: [String] = [], cutBefore: [String] = []) -> Join {
        let said = said.sorted { $0.start < $1.start }
        let heard = heard.sorted { $0.start < $1.start }
        let steps = align(said.map(\.text), said.map(\.middle), heard.map(\.text), heard.map(\.middle))
        func isNear(_ word: Word) -> Bool { word.end >= join - near && word.start <= join + near }
        // The cut words beside the join a word heard there could be: the
        // ones cut past the clip before it, and before the clip after it.
        func cutBeside(_ time: Double) -> [String] {
            time <= join ? Array(cutPast.prefix(2) + cutBefore.suffix(1)) : Array(cutBefore.suffix(2) + cutPast.prefix(1))
        }
        // A cut word heard whole: the transcript's times put it in the cut,
        // but the cut keeps all of it (on the Ian video's final cut that was
        // most of the cut words heard at approved joins), so it's a note.
        func wholeCut(_ text: String, at time: Double) -> String? {
            let heard = canonical(text)
            return heard.isEmpty ? nil : cutBeside(time).first { canonical($0) == heard }
        }
        // Part of a cut word heard: its start before the join, its end after
        // it, or a sound or two of it heard as the nearest short word ("oh"
        // for the start of "okay").
        func partOfCut(_ text: String, at time: Double) -> String? {
            let heard = canonical(text)
            guard !heard.isEmpty else { return nil }
            return cutBeside(time).first { word in
                let cut = canonical(word)
                guard cut.count > heard.count else { return false }
                return cut.hasPrefix(heard) && time <= join || cut.hasSuffix(heard) && time > join || heard.count <= 2 && cut.first == heard.first
            }
        }

        var findings: [Finding] = []
        for step in steps {
            switch step {
            case .match(let s, let h, let how):
                guard isNear(said[s]) || isNear(heard[h]) else { continue }
                let saidText = said[s].text, heardText = heard[h].text
                // The same word, or written differently: nothing to say.
                guard let how else { continue }
                if case .loose = how { continue }
                let a = canonical(saidText), b = canonical(heardText)
                func add(_ slip: Bool, _ why: String) {
                    findings.append(Finding(kind: .heardAs, said: saidText, heard: heardText, time: said[s].middle, slip: slip, why: why))
                }
                if let part = truncation(of: a, b) {
                    add(false, "only \"\(part)\" of it: cut short")
                } else if let cut = wholeCut(heardText, at: heard[h].middle) {
                    add(true, "\"\(cut)\" is heard whole, which the take's transcript has in the cut: its times are off, or the cut keeps it")
                } else if let cut = partOfCut(heardText, at: heard[h].middle), how == .different {
                    add(false, "sounds like part of \"\(cut)\", which is cut")
                } else if b.hasPrefix(a) {
                    add(true, "more of the word than the transcript has")
                } else {
                    let slip = how != .different || isFunctionWord(saidText) || isFunctionWord(heardText) || a.count <= 2 || b.count <= 2
                    add(slip, how.why)
                }
            case .missing(let s):
                guard isNear(said[s]) else { continue }
                let text = said[s].text
                let slip = isFunctionWord(text) || canonical(text).count <= 2
                findings.append(Finding(kind: .notHeard, said: text, time: said[s].middle, slip: slip,
                                        why: slip ? "a short or filler word the engine often leaves out" : "nothing heard for it"))
            case .extra(let h):
                guard isNear(heard[h]) else { continue }
                let text = heard[h].text
                func add(_ slip: Bool, _ why: String) {
                    findings.append(Finding(kind: .extra, heard: text, time: heard[h].middle, slip: slip, why: why))
                }
                if let cut = wholeCut(text, at: heard[h].middle) {
                    add(true, "\"\(cut)\" is heard whole, which the take's transcript has in the cut: its times are off, or the cut keeps it")
                } else if let cut = partOfCut(text, at: heard[h].middle) {
                    add(false, "sounds like part of \"\(cut)\", which is cut")
                } else if isFunctionWord(text) || canonical(text).count <= 2 {
                    add(true, "a short or filler word the engine often adds")
                } else {
                    add(false, "a word the take doesn't keep here")
                }
            }
        }
        return Join(time: join, said: text(said, at: join), heard: text(heard, at: join), findings: findings)
    }

    /// The words with " | " where the join falls.
    static func text(_ words: [Word], at join: Double) -> String {
        var parts: [String] = []
        var marked = false
        for word in words {
            if !marked, word.middle > join {
                parts.append("|")
                marked = true
            }
            parts.append(word.text)
        }
        if !marked { parts.append("|") }
        return parts.joined(separator: " ")
    }

    /// How two words that line up differ, when they do.
    enum Difference: Equatable {
        /// The same once loosened, by: numbers, a joined or split word.
        case loose(String)
        /// An inflection ("happen" for "happened") or a letter or two out.
        case near
        case different

        var why: String {
            switch self {
            case .loose(let how): return how
            case .near: return "a near spelling, which the engine gets wrong"
            case .different: return "a different word"
            }
        }
    }

    enum Step: Equatable {
        /// Said word, heard word, and how they differ (nil: the same).
        case match(Int, Int, Difference?)
        case missing(Int)
        case extra(Int)
    }

    /// An edit-distance alignment over words, with a cheap step for one word
    /// heard as two or three ("t. s." for "TS", "want to" for "wanna") and
    /// back. Words far apart in time cost more to line up, so a repeated
    /// word lines up with the one said at that time.
    static func align(_ said: [String], _ saidTimes: [Double], _ heard: [String], _ heardTimes: [Double]) -> [Step] {
        let a = said.map(canonical), b = heard.map(canonical)
        let n = a.count, m = b.count
        let gap = 0.75
        func cost(_ i: Int, _ j: Int) -> (Double, Difference?) {
            let far = abs(saidTimes[i] - heardTimes[j]) > 0.6 ? 0.5 : 0
            if a[i] == b[j] {
                let how: Difference? = said[i].lowercased().filter(\.isLetter) == heard[j].lowercased().filter(\.isLetter) ? nil : .loose("the same word written differently")
                return (far, how)
            }
            if similar(a[i], b[j]) { return (0.5 + far, .near) }
            return (1 + far, .different)
        }
        var table = [[Double]](repeating: [Double](repeating: .infinity, count: m + 1), count: n + 1)
        var back = [[(Int, Int, Step?)]](repeating: [(Int, Int, Step?)](repeating: (0, 0, nil), count: m + 1), count: n + 1)
        table[0][0] = 0
        for i in 0...n {
            for j in 0...m {
                let here = table[i][j]
                guard here.isFinite else { continue }
                func relax(_ i2: Int, _ j2: Int, _ value: Double, _ step: Step?) {
                    guard i2 <= n, j2 <= m, value < table[i2][j2] - 1e-9 else { return }
                    table[i2][j2] = value
                    back[i2][j2] = (i, j, step)
                }
                if i < n, j < m {
                    let (c, how) = cost(i, j)
                    relax(i + 1, j + 1, here + c, .match(i, j, how))
                }
                if i < n { relax(i + 1, j, here + gap, .missing(i)) }
                if j < m { relax(i, j + 1, here + gap, .extra(j)) }
                // One said word heard as two or three, or two or three said
                // heard as one.
                for k in 2...3 {
                    if i < n, j + k <= m, !a[i].isEmpty, b[j..<(j + k)].joined() == a[i] {
                        relax(i + 1, j + k, here + 0.05, .match(i, j, .loose("heard as \"\(heard[j..<(j + k)].joined(separator: " "))\"")))
                    }
                    if j < m, i + k <= n, !b[j].isEmpty, a[i..<(i + k)].joined() == b[j] {
                        relax(i + k, j + 1, here + 0.05, .match(i, j, .loose("heard as one word, \"\(heard[j])\"")))
                    }
                }
            }
        }
        var steps: [Step] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            let (pi, pj, step) = back[i][j]
            guard let step else { break }
            // A merged step covers several words on one side: say it once,
            // on the first.
            steps.append(step)
            i = pi
            j = pj
        }
        return steps.reversed()
    }

    // MARK: - Loose matching

    /// Contractions and run-together words the engines write either way.
    static let spoken: [String: String] = [
        "wanna": "wantto", "gonna": "goingto", "gotta": "gotto", "kinda": "kindof", "sorta": "sortof", "lemme": "letme",
        "dunno": "dontknow", "ok": "okay", "yep": "yeah", "yup": "yeah", "cause": "because", "cos": "because", "til": "until",
    ]

    /// Lower case letters and digits only, numbers as words, and spoken
    /// forms spelled out ("wanna" is "wantto").
    static func canonical(_ text: String) -> String {
        let plain = text.lowercased().filter { $0.isLetter || $0.isNumber }
        if let number = Int(plain), number >= 0 { return numberWords(number) }
        return spoken[plain] ?? plain
    }

    /// "15" as "fifteen", "2026" as "twothousandtwentysix": how the
    /// engines' two ways of writing a number compare.
    static func numberWords(_ number: Int) -> String {
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
                    "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        func words(_ n: Int) -> String {
            if n < 20 { return ones[n] }
            if n < 100 { return tens[n / 10] + (n % 10 == 0 ? "" : ones[n % 10]) }
            if n < 1000 { return ones[n / 100] + "hundred" + (n % 100 == 0 ? "" : words(n % 100)) }
            if n < 1_000_000 { return words(n / 1000) + "thousand" + (n % 1000 == 0 ? "" : words(n % 1000)) }
            return String(n)
        }
        return words(number)
    }

    /// Endings an engine adds or drops: an inflection, not a cut-off.
    static let endings = ["s", "es", "ed", "d", "ing", "n", "re", "ll", "ve", "t"]

    /// Close enough to be the engine's slip: an inflection, or one letter
    /// out (two in a word of seven or more).
    static func similar(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        if long.hasPrefix(short), endings.contains(String(long.dropFirst(short.count))) { return true }
        // "by" and "buy": short words a letter apart that start the same.
        if max(a.count, b.count) <= 3 { return a.first == b.first && distance(a, b) <= 1 }
        guard min(a.count, b.count) >= 3 else { return false }
        return distance(a, b) <= (max(a.count, b.count) >= 7 ? 2 : 1)
    }

    /// What's heard of a word cut short: the start of it (or its end, for a
    /// word that starts before a clip does), two letters or more short.
    static func truncation(of said: String, _ heard: String) -> String? {
        // A short word heard as a shorter one ("it's" as "I") is as likely
        // the engine's.
        guard said.count >= 4, heard.count >= 1, said.count - heard.count >= 2, heard != said else { return nil }
        if said.hasPrefix(heard), endings.contains(String(said.dropFirst(heard.count))) { return nil }
        if said.hasPrefix(heard) || said.hasSuffix(heard) { return heard }
        return nil
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(1, b.count) where !b.isEmpty {
                let saved = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = saved
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }

    /// Short words and fillers the engines leave out, add or swap often
    /// enough that a mismatch on one is a note.
    static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "to", "of", "in", "on", "at", "it", "is", "i", "you", "we", "that", "this", "um", "uh",
        "uhm", "erm", "er", "ah", "oh", "mm", "hmm", "like", "yeah", "just", "be", "was", "are", "do", "for", "with", "as", "if", "then",
        "there", "they", "he", "she", "its", "im", "thats", "know", "okay", "right", "well", "kind", "sort", "really", "actually", "no", "not",
        "were", "were", "youre", "theyre", "by", "from", "about", "what", "when", "where", "how", "who", "can", "have", "has", "had", "will",
    ]

    static func isFunctionWord(_ text: String) -> Bool {
        let plain = text.lowercased().filter(\.isLetter)
        return plain.isEmpty || functionWords.contains(plain)
    }

    // MARK: - Audio

    /// Mono samples at `rate` as the engines take them: 16 kHz, with
    /// `padding` of silence either side.
    public static func prepare(_ samples: [Float], rate: Double) throws -> [Float] {
        let resampled = try resample(samples, from: rate)
        let silence = [Float](repeating: 0, count: Int(padding * sampleRate))
        return silence + resampled + silence
    }

    static func resample(_ samples: [Float], from rate: Double) throws -> [Float] {
        guard rate != sampleRate else { return samples }
        guard !samples.isEmpty else { return [] }
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output),
              let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw MediaError.failed("Couldn't set up the audio for listening")
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * sampleRate / rate) + 1024
        guard let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { throw MediaError.failed("Out of memory for listening") }
        nonisolated(unsafe) var given = false
        var error: NSError?
        let status = converter.convert(to: target, error: &error) { _, state in
            if given {
                state.pointee = .endOfStream
                return nil
            }
            given = true
            state.pointee = .haveData
            return source
        }
        if status == .error { throw error ?? MediaError.failed("Couldn't resample the audio for listening") }
        return Array(UnsafeBufferPointer(start: target.floatChannelData![0], count: Int(target.frameLength)))
    }
}

/// Hears a few seconds of audio with Bark 3.0 Pro, as transcripts do
/// (`BarkTranscription`): one piece, 0.25 s of lead-in, the short encoder.
public struct BarkListener: Sendable {
    public static let engine = BarkTranscription.engine
    var store: BarkModelStore

    /// Tandem's own copy of the model.
    public static var standard: BarkListener { BarkListener(store: .standard) }

    public init(store: BarkModelStore) {
        self.store = store
    }

    /// Whether the model is downloaded and compiled.
    public var isReady: Bool { store.readyFolder() != nil }

    /// The words in `samples` (16 kHz mono, at most about 14 s), times in
    /// seconds from the first sample.
    public func listen(_ samples: [Float]) async throws -> [CutListen.Word] {
        guard let models = store.readyFolder() else { throw BarkTranscription.Unavailable(reason: "\(Self.engine) isn't downloaded") }
        guard samples.count <= BarkTranscription.pieceLimit else { throw MediaError.failed("Too long to listen to in one go") }
        let runtime = BarkRuntime.shared
        let lease = try await runtime.lease(models: models, vocabulary: store.folder.appendingPathComponent(BarkModelStore.vocabulary))
        defer { Task { await runtime.release() } }
        let tokens = try await lease.tokens(for: samples, short: true)
        return BarkTranscription.place(BarkTranscription.words(from: tokens), pieceStart: 0, pieceSamples: samples.count).map {
            CutListen.Word(text: $0.text, start: $0.start.seconds, end: $0.end.seconds)
        }
    }
}

/// What each join was heard as, by what was rendered: a hash of the
/// samples the engine heard (as 16-bit, padding and all) and the engine's
/// name. A re-check after edits renders every join again, which is quick,
/// and only listens again where the sound changed.
public struct CutListenCache: Sendable {
    public var folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// The project's, in `.tandem/cache/listen`.
    public init(project: ProjectFolder) {
        self.init(folder: project.cacheFolder.appendingPathComponent("listen", isDirectory: true))
    }

    public static func key(_ samples: [Float], engine: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(engine)|\(CutListen.sampleRate)|".utf8))
        let quantised = samples.map { Int16(clamping: Int(($0 * 32767).rounded())) }
        quantised.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func heard(_ key: String) -> [CutListen.Word]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(key).json")) else { return nil }
        return try? JSONDecoder().decode([CutListen.Word].self, from: data)
    }

    public func store(_ words: [CutListen.Word], for key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(words).write(to: folder.appendingPathComponent("\(key).json"), options: .atomic)
    }
}

/// Hears a few seconds of audio with SpeechAnalyzer, as transcripts do
/// when Bark can't (`SpeechTranscription`), straight from the samples.
@available(macOS 26, *)
public struct SpeechAnalyzerListener: Sendable {
    public static let engine = SpeechTranscription.engine
    public var localeID: String

    public init(localeID: String = "en-US") {
        self.localeID = localeID
    }

    /// The words in `samples` (16 kHz mono), times in seconds from the
    /// first sample.
    public func listen(_ samples: [Float]) async throws -> [CutListen.Word] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw MediaError.notApplicable("SpeechAnalyzer doesn't support \(localeID)")
        }
        let transcriber = SpeechTranscription.makeTranscriber(locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MediaError.failed("SpeechAnalyzer has no audio format for \(locale.identifier)")
        }
        let buffer = try Self.buffer(samples, format: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        let collector = Task { () -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            for try await result in transcriber.results where result.isFinal { words += SpeechTranscription.words(in: result.text) }
            return words
        }
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: .zero))
        continuation.finish()
        do {
            if let last = try await analyzer.analyzeSequence(inputs) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return try await collector.value.map { CutListen.Word(text: $0.text, start: $0.start.seconds, end: $0.end.seconds) }
    }

    /// The samples in the analyzer's format.
    static func buffer(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: CutListen.sampleRate, channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(max(1, samples.count))),
              let converter = AVAudioConverter(from: mono, to: format),
              let target = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * format.sampleRate / CutListen.sampleRate) + 1024) else {
            throw MediaError.failed("Couldn't set up the audio for SpeechAnalyzer")
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        nonisolated(unsafe) var given = false
        var error: NSError?
        let status = converter.convert(to: target, error: &error) { _, state in
            if given {
                state.pointee = .endOfStream
                return nil
            }
            given = true
            state.pointee = .haveData
            return source
        }
        if status == .error { throw error ?? MediaError.failed("Couldn't convert the audio for SpeechAnalyzer") }
        return target
    }
}

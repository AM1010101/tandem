import Foundation
import TandemCore
import TandemRender

// Checking sound without ffmpeg: `tandem loudness --from --to` measures the
// rendered mix over time (or only some tracks), and `--gains` checks each
// track's render against its gain lane. Both read the mix the way export
// does (`MixMeter`).

extension TandemService {
    /// The per-file report, and with a range, step, tracks or gains, the
    /// rendered mix over time.
    public func loudness(_ request: LoudnessRequest) async throws -> LoudnessResult {
        var result = try loudness(mediaID: request.mediaID)
        guard request.overTime else { return result }
        if request.mediaID != nil {
            throw ServiceError(.badRequest, "A range, step or tracks measure the mix on the timeline, so leave out the media ID (or leave them out to see that file's loudness).")
        }
        let project = coordinator.project
        let start = request.from ?? .zero
        let end = request.to ?? project.duration
        guard start >= .zero else { throw ServiceError(.badRequest, "--from can't be before 0.") }
        guard end > start else { throw ServiceError(.badRequest, "The range is empty (\(start) to \(end)).") }
        let range = TimeRange(start: start, end: end)
        // Looking for peaks, the 400 ms windows tile the range unless a step
        // says otherwise, so no sample goes unchecked.
        let step = try Self.loudnessStep(request.step ?? (request.over != nil ? Self.peakWindow : nil), over: range.duration)
        var tracks: [Track]?
        if let names = request.tracks, !names.isEmpty {
            tracks = try audioTracks(named: names, in: project)
        }
        let whole = try renderContext(project, format: nil)
        var context = whole
        if let tracks {
            context.project = AudioLevels.soloing(project, audioTrackIDs: Set(tracks.map(\.id)))
        }
        result.curve = try await renderer.loudness(context: context, range: range, step: step)
        result.tracks = tracks?.map(\.name)
        if let over = request.over, let curve = result.curve { result.peaks = Self.peaks(in: curve, over: over) }
        if request.gains == true {
            let ids = tracks?.map(\.id) ?? Self.playingTracks(project, in: range)
            result.gains = try await renderer.checkGains(context: whole, range: range, trackIDs: ids)
        }
        return result
    }

    /// The window a point's peak is measured over.
    static let peakWindow = Time(seconds: 0.4)
    /// Rows a curve can have: a whole 46 minute take at 0.4 s is about
    /// 7,000, and the plain text sums up anything over `SoundText.readableRows`.
    static let maximumRows = 100_000.0

    /// The step asked for, or the shortest of a few round ones that gives
    /// at most 60 rows. Steps are whole tenths of a second, the meter's
    /// blocks.
    static func loudnessStep(_ asked: Time?, over duration: Time) throws -> Time {
        let seconds = duration.seconds
        if let asked {
            guard asked.seconds >= 0.1 else { throw ServiceError(.badRequest, "--step is at least 0.1 s, the meter's block.") }
            let rounded = (asked.seconds * 10).rounded() / 10
            guard seconds / rounded <= maximumRows else {
                throw ServiceError(.badRequest, "That's more than \(Int(maximumRows)) rows. Use a bigger --step or a shorter range.")
            }
            return Time(seconds: rounded)
        }
        let steps = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        return Time(seconds: steps.first { seconds / $0 <= 60 } ?? 600)
    }

    /// The windows that peak over `threshold` dBFS, neighbours merged into
    /// stretches that run from the first window's start to the last one's
    /// end, inside the range.
    static func peaks(in curve: MixLoudness, over threshold: Double) -> LoudnessPeaks {
        let half = Time(seconds: peakWindow.seconds / 2)
        var stretches: [PeakStretch] = []
        var previous: Time?
        var windows = 0
        for point in curve.points {
            guard let peak = point.peakDBFS, peak > threshold else { continue }
            windows += 1
            let start = max(curve.start, point.time - half)
            let end = min(curve.end, point.time + half)
            if let previous, var last = stretches.last, point.time - previous <= curve.step {
                last.end = end
                last.peakDBFS = max(last.peakDBFS, peak)
                last.windows += 1
                stretches[stretches.count - 1] = last
            } else {
                stretches.append(PeakStretch(start: start, end: end, peakDBFS: peak, windows: 1))
            }
            previous = point.time
        }
        return LoudnessPeaks(threshold: threshold, windows: windows, stretches: stretches)
    }

    /// Audio tracks by name (any case) or ID, in timeline order, explaining
    /// a name that isn't one.
    func audioTracks(named names: [String], in project: Project) throws -> [Track] {
        var wanted = Set<String>()
        for name in names {
            let lower = name.lowercased()
            if let track = project.audioTracks.first(where: { $0.id == name || $0.name.lowercased() == lower }) {
                wanted.insert(track.id)
                continue
            }
            let audio = project.audioTracks.map(\.name).joined(separator: ", ")
            if let video = project.videoTracks.first(where: { $0.id == name || $0.name.lowercased() == lower }) {
                throw ServiceError(.badRequest, "\(video.name) is a video track, and they don't play sound. Pick audio tracks: \(audio).")
            }
            throw ServiceError(.notFound, "No audio track called \"\(name)\". Audio tracks: \(audio).")
        }
        return project.audioTracks.filter { wanted.contains($0.id) }
    }

    /// The audio tracks heard somewhere in `range`: not muted (or soloed,
    /// when any is), with an enabled clip there.
    static func playingTracks(_ project: Project, in range: TimeRange) -> [String] {
        let soloing = project.audioTracks.contains { $0.solo && !$0.muted }
        return project.audioTracks.filter { track in
            !track.muted && (!soloing || track.solo)
                && track.clips.contains { $0.enabled && !($0.audio?.muted ?? false) && $0.range.overlaps(range) }
        }.map(\.id)
    }
}

enum SoundText {
    /// "Music", "Music and SFX", "Voice, Music and SFX".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    static func level(_ value: Double?, _ unit: String) -> String {
        value.map { String(format: "%.1f %@", $0, unit) } ?? "silent"
    }

    static func seconds(_ time: Time) -> String {
        CommandText.number(time.seconds)
    }

    /// One character a point, ▁ for -60 LUFS or quieter up to █ for -10 or
    /// louder, and · for silence. Past `width` points each character is
    /// the loudest of its share of them.
    static func sparkline(_ values: [Double?], width: Int = 200) -> String {
        let bars = Array("▁▂▃▄▅▆▇█")
        var values = values
        if values.count > width {
            values = (0..<width).map { index in
                values[(index * values.count / width)..<((index + 1) * values.count / width)].compactMap { $0 }.max()
            }
        }
        return String(values.map { value -> Character in
            guard let value else { return "·" }
            let index = Int(((value + 60) / 50 * Double(bars.count - 1)).rounded())
            return bars[min(max(index, 0), bars.count - 1)]
        })
    }

    /// More rows than this read as a summary; the JSON has every point.
    static let readableRows = 2000
    /// Stretches listed before the rest are left to the JSON.
    static let readableStretches = 200

    static func curve(_ curve: MixLoudness, tracks: [String]?, peaks: LoudnessPeaks? = nil) -> [String] {
        let what = tracks.map(list) ?? "The mix"
        var lines = ["\(what) from \(curve.start) to \(curve.end), every \(seconds(curve.step)) s, as the timeline plays it (export's master gain moves it all by the same amount)."]
        var summary = "Integrated \(level(curve.integratedLUFS, "LUFS")), true peak \(level(curve.truePeakDBTP, "dBTP"))."
        if let loudest = curve.points.filter({ $0.momentaryLUFS != nil }).max(by: { $0.momentaryLUFS! < $1.momentaryLUFS! }) {
            summary += " Loudest: \(level(loudest.momentaryLUFS, "LUFS")) momentary at \(loudest.time)."
        }
        lines.append(summary)
        lines.append("Short-term: " + sparkline(curve.points.map(\.shortTermLUFS)))
        if let peaks { return lines + self.peaks(peaks) }
        guard curve.points.count <= readableRows else {
            lines.append("\(curve.points.count) rows: --json gives every one, and --over <dBFS> lists the stretches that peak over a level.")
            return lines
        }
        lines.append("  time        momentary   short-term  peak")
        for point in curve.points {
            let cells = [level(point.momentaryLUFS, "LUFS"), level(point.shortTermLUFS, "LUFS")].map { $0.padding(toLength: 10, withPad: " ", startingAt: 0) }
            lines.append("  \(point.time)   \(cells[0])  \(cells[1])  \(point.peakDBFS.map { String(format: "%.1f dBFS", $0) } ?? "")"
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        lines.append("Momentary is the 400 ms centred on each time, short-term the 3 s, peak the highest sample in the 400 ms.")
        return lines
    }

    /// "98 windows peak over 0.0 dBFS, in 23 stretches:" and the stretches.
    static func peaks(_ peaks: LoudnessPeaks) -> [String] {
        let level = String(format: "%.1f dBFS", peaks.threshold)
        guard peaks.windows > 0 else { return ["No window peaks over \(level)."] }
        let count = peaks.stretches.count
        var lines = ["\(peaks.windows) window\(peaks.windows == 1 ? "" : "s") peak\(peaks.windows == 1 ? "s" : "") over \(level), in \(count) stretch\(count == 1 ? "" : "es"):"]
        for stretch in peaks.stretches.prefix(readableStretches) {
            lines.append(String(format: "  %@-%@  peak %.1f dBFS (%d window%@)", stretch.start.description, stretch.end.description, stretch.peakDBFS, stretch.windows, stretch.windows == 1 ? "" : "s"))
        }
        if count > readableStretches { lines.append("And \(count - readableStretches) more; --json lists them all.") }
        lines.append("A window is the 400 ms centred on a row; its peak is its highest sample.")
        return lines
    }

    static func gains(_ checks: [GainFollow], start: Time, end: Time) -> [String] {
        var lines = ["Gain lanes against the render, \(start) to \(end):"]
        if checks.isEmpty { lines.append("  No audio track plays here.") }
        let width = checks.map(\.track.count).max() ?? 0
        for check in checks {
            let name = "  " + check.track.padding(toLength: width, withPad: " ", startingAt: 0) + "  "
            if check.compared == 0 {
                lines.append(name + "nothing to compare (silent, or only crossfades)")
                continue
            }
            if check.mismatches.isEmpty && check.lateBy == nil {
                lines.append(name + String(format: "follows its lane (%@ s compared, within %.1f dB)", CommandText.number((check.compared * 10).rounded() / 10), check.worstDB ?? 0))
                continue
            }
            var parts: [String] = []
            if let late = check.lateBy {
                let ms = Int((abs(late) * 1000).rounded())
                parts.append(late > 0 ? "lands \(ms) ms late" : "lands \(ms) ms early")
            }
            if !check.mismatches.isEmpty { parts.append("plays off its lane at:") }
            lines.append(name + parts.joined(separator: "; "))
            for miss in check.mismatches {
                lines.append(String(format: "    %@-%@  the lane says %.1f dB, the render plays %.1f dB", miss.start.description, miss.end.description, miss.expectedDB, miss.measuredDB))
            }
        }
        return lines
    }
}

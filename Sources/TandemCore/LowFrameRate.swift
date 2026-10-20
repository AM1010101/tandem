import Foundation

// Screen recordings that play at a low frame rate where the picture moves,
// for `tandem check`.
//
// macOS records the screen when it changes, so a screen recording's frame
// rate wanders. In the Tandem video it dropped to 4 to 7 fps while Mike was
// away from his desk, and he spotted "a really low frame rate" in review.
// A still page at 4 fps looks the same as at 60, so the rate alone isn't
// enough: it's only choppy where the picture moves. The rate comes from the
// file's own frame times (its sample table, read without decoding), mapped
// onto the timeline through each clip's start and speed; the movement from
// the screen recordings scanned on their own (`screenOnly`), which the
// check renders for page changes anyway.

extension QualityCheck {
    /// Frames a second on the timeline under which a moving screen
    /// recording looks choppy, while that's under `lowShare` of the
    /// project's rate.
    static let lowRate = 12.0
    static let lowShare = 0.5
    /// The rate is measured over this long, every `lowSlot`...
    static let lowWindow = Time(seconds: 1)
    static let lowSlot = Time(seconds: 0.5)
    /// ...and a stretch has to be low, moving and seen for this long to be
    /// noticed.
    static let lowLongest = Time(seconds: 1)
    /// Moving means the recording's picture changing (a tile by more than
    /// `pageLevel`) at least this often a second through the stretch. A
    /// blinking caret changes too little to count.
    static let movingChanges = 1.5

    /// Stretches in `ranges` where a screen recording the viewer sees plays
    /// fewer than `lowRate` frames a second (and under half the project's)
    /// while its picture moves, as notes. `frameTimes` has each screen
    /// recording's frame times (file time, sorted), by media ID; recordings
    /// without them aren't judged. `screenFrames` is the recordings scanned
    /// on their own, which say where they move.
    public static func lowFrameRates(in project: Project, ranges: [TimeRange], frameTimes: [String: [Time]], screenFrames: [FrameStats]) -> [CheckProblem] {
        let fps = project.settings.frameRate.framesPerSecond
        let limit = min(lowRate, fps * lowShare)
        let frameDuration = project.settings.frameRate.frameDuration
        let media = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // When the recording's picture visibly changed, and what was scanned.
        var changes: [Time] = []
        var scanned: [TimeRange] = []
        for run in contiguousRuns(screenFrames, frameDuration: frameDuration) {
            let frames = screenFrames[run]
            guard let first = frames.first, let last = frames.last else { continue }
            scanned.append(TimeRange(start: first.time, end: last.time + frameDuration))
            for index in frames.indices.dropFirst() where changedShare(screenFrames[index - 1], screenFrames[index]) > 0 {
                changes.append(screenFrames[index].time)
            }
        }
        var found: [CheckProblem] = []
        for track in project.videoTracks where !track.hidden {
            for clip in track.clips where clip.enabled && !clip.freezeFrame && clip.speed > 0 {
                guard let id = clip.mediaID, media[id]?.role == .screen, let times = frameTimes[id], !times.isEmpty else { continue }
                for range in merge(ranges) {
                    guard let part = clip.range.intersection(range), part.duration >= lowLongest else { continue }
                    found += lowStretches(of: clip, in: part, times: times, limit: limit, changes: changes, scanned: scanned, project: project, media: media)
                }
            }
        }
        return found
    }

    /// The low, moving, seen stretches of one clip within `part`.
    private static func lowStretches(
        of clip: Clip, in part: TimeRange, times: [Time], limit: Double, changes: [Time], scanned: [TimeRange],
        project: Project, media: [String: MediaItem]
    ) -> [CheckProblem] {
        // The recording's frames, where they reach the timeline.
        func timeline(_ source: Time) -> Time { clip.start + (source - clip.sourceStart).scaled(by: 1 / clip.speed) }
        let from = clip.sourceTime(atTimelineTime: max(clip.start, part.start - lowWindow))
        let to = clip.sourceTime(atTimelineTime: min(clip.end, part.end + lowWindow))
        let arrivals = times[lowerBound(times, from)..<lowerBound(times, to)].map(timeline)
        func count(_ list: [Time], in window: TimeRange) -> Int { lowerBound(list, window.end) - lowerBound(list, window.start) }

        var flagged: [(slot: TimeRange, frames: Int)] = []
        var slotStart = part.start
        while slotStart + lowSlot.scaled(by: 0.5) <= part.end {
            let slot = TimeRange(start: slotStart, end: min(slotStart + lowSlot, part.end))
            slotStart = slot.end
            let middle = slot.start + slot.duration.scaled(by: 0.5)
            // A second around the slot, inside the clip.
            let window = TimeRange(start: max(clip.start, middle - lowWindow.scaled(by: 0.5)), end: min(clip.end, middle + lowWindow.scaled(by: 0.5)))
            guard window.duration >= lowSlot else { continue }
            let rate = Double(count(arrivals, in: window)) / window.duration.seconds
            let moving = Double(count(changes, in: slot)) >= movingChanges * slot.duration.seconds
            let looked = scanned.contains { $0.contains(middle) }
            guard rate < limit, moving, looked, screenClip(at: middle, in: project, media: media)?.clip.id == clip.id,
                  screenShows(at: middle, in: project, media: media) else { continue }
            flagged.append((slot, count(arrivals, in: slot)))
        }

        var found: [CheckProblem] = []
        var index = 0
        while index < flagged.count {
            var end = index
            while end + 1 < flagged.count, flagged[end + 1].slot.start == flagged[end].slot.end { end += 1 }
            let stretch = TimeRange(start: flagged[index].slot.start, end: flagged[end].slot.end)
            if stretch.duration >= lowLongest {
                let frames = flagged[index...end].reduce(0) { $0 + $1.frames }
                let rate = max(1, Int((Double(frames) / stretch.duration.seconds).rounded()))
                let fps = project.settings.frameRate
                let projectRate = fps.denominator == 1 ? "\(fps.numerator)" : String(format: "%.2f", fps.framesPerSecond)
                found.append(CheckProblem(
                    kind: .lowFrameRate, start: stretch.start, end: stretch.end,
                    message: "Low frame rate: the screen recording moves at about \(rate) fps here, against the project's \(projectRate), for \(seconds(stretch.duration)), so it looks choppy. macOS records the screen as it changes, and slowed right down here. Cover it: in the Tandem video Mike went full screen on his camera over it (B-roll works too), or cut it.",
                    clipIDs: [clip.id]
                ))
            }
            index = end + 1
        }
        return found
    }

    /// The index of the first time in sorted `times` at or after `time`.
    static func lowerBound(_ times: [Time], _ time: Time) -> Int {
        var low = 0, high = times.count
        while low < high {
            let middle = (low + high) / 2
            if times[middle] < time { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

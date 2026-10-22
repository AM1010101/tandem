import Foundation
import TandemAPI
import TandemCore
import TandemMedia

/// Finds the long pauses in the take and cuts them out with ripple deletes,
/// so the camera, screen and voice stay in sync and B-roll and music follow.
///
/// It plans exactly as `tandem tighten --min <minimum> --keep <keep>` does
/// (`SoundTightening`), so a tighten from the app and one from an agent
/// agree: each cut in a real pause in the sound, never through sound the
/// transcript doesn't know about, with a clean join.
enum PauseTightening {
    /// The plan for pauses between words of `minimum` or more (found the
    /// way `tandem pauses` finds them, from words trimmed to the voice and
    /// placed through the cuts), leaving `keep` of pause between the words'
    /// sound, only pauses wholly inside `within` if given. Locked tracks
    /// aren't tightened, so their words don't count.
    static func plan(
        in project: Project,
        transcript: (MediaItem) -> Transcript?,
        folder: ProjectFolder,
        minimum: Time,
        keep: Time,
        within: TimeRange? = nil
    ) async -> SoundTightening.Plan {
        var unlocked = project
        for index in unlocked.audioTracks.indices where unlocked.audioTracks[index].locked {
            unlocked.audioTracks[index].clips = []
        }
        let map = TranscriptTools.speechMap(unlocked, transcripts: transcript)
        let pauses = TranscriptTools.pauses(in: map, minimum: minimum, from: within?.start, to: within?.end)
        return await SoundTightening.plan(
            pauses, rules: .uniform(keep: keep, minimum: minimum), snug: false, map: map, project: project, folder: folder
        )
    }

    /// One batch cutting every planned pause, latest first so earlier cuts
    /// don't move under later ones.
    static func batch(_ cuts: [PlannedCut]) -> EditBatch? {
        guard !cuts.isEmpty else { return nil }
        let total = cuts.reduce(0) { $0 + $1.cut.duration.seconds }
        return EditBatch(
            label: String(format: "Tighten %d %@ (%.1f s)", cuts.count, cuts.count == 1 ? "pause" : "pauses", total),
            commands: TranscriptTools.commands(for: cuts)
        )
    }
}

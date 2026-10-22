import SwiftUI
import TandemAPI
import TandemCore

/// "Tighten pauses…": previews how many pauses it would cut, planned in the
/// take's sound as `tandem tighten` plans them, and cuts them in one
/// undoable batch.
struct TightenPausesPopover: View {
    let model: EditorModel
    let dismiss: () -> Void
    @State private var minimum = TranscriptTools.defaultMinimum
    @State private var keep = TranscriptTools.defaultKeep
    @State private var onlyInOut = false
    /// The plan for the settings it was made with: reading the take's sound
    /// takes a moment, so it's made off the slider's drag.
    @State private var plan: (settings: PauseTightening.Settings, plan: SoundTightening.Plan)?

    private var settings: PauseTightening.Settings {
        PauseTightening.Settings(
            revision: model.revision, minimum: Time(seconds: minimum), keep: Time(seconds: keep),
            within: onlyInOut ? model.inOutRange : nil
        )
    }

    var body: some View {
        let settings = settings
        let current = plan.flatMap { $0.settings == settings ? $0.plan : nil }
        let cuts = current?.cuts ?? []
        let total = cuts.reduce(0) { $0 + $1.cut.duration.seconds }
        let pauses = Set(cuts.map(\.pause.start)).count
        let notes = current.map(PauseTightening.notes) ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text("Tighten pauses")
                .font(.ui(13, .bold))
                .foregroundStyle(Theme.text.color)
            Text("Cuts silences between words out of the take, only where every track is quiet. Camera, screen and voice stay in sync; B-roll and music follow.")
                .font(.ui(11.5))
                .foregroundStyle(Theme.textMuted.color)
                .fixedSize(horizontal: false, vertical: true)
            SliderRow(label: "Longer than", value: minimum, range: 0.3...2, format: { String(format: "%.1f s", $0) }) { minimum = $0 }
            SliderRow(label: "Leave", value: keep, range: 0...0.5, format: { String(format: "%.2f s", $0) }) { keep = $0 }
            if model.inOutRange != nil {
                HStack {
                    Text("Only between in and out").font(.ui(12)).foregroundStyle(Theme.textMuted.color)
                    Spacer()
                    GraphiteSwitch(isOn: onlyInOut) { onlyInOut.toggle() }
                }
            }
            Rectangle().fill(Theme.border.color).frame(height: 1)
            // Pauses left for sound in them, and anything planned from the
            // transcript alone because its sound couldn't be heard.
            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.textMuted.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if current == nil {
                    Text(hasTranscript ? "Listening to the take…" : "Needs a transcript of the take first.")
                        .font(.ui(12))
                        .foregroundStyle(Theme.textFaint.color)
                } else if cuts.isEmpty {
                    Text(hasTranscript ? "No pauses that long." : "Needs a transcript of the take first.")
                        .font(.ui(12))
                        .foregroundStyle(Theme.textFaint.color)
                } else {
                    Text(String(format: "%d %@, %.1f s in all", pauses, pauses == 1 ? "pause" : "pauses", total))
                        .font(.ui(12, .semibold))
                        .foregroundStyle(Theme.text.color)
                }
                Spacer()
                Button {
                    // Planned at its revision: an edit that's landed since
                    // (from the CLI, say) refuses it rather than cutting the
                    // old times out of the newer project.
                    model.apply(PauseTightening.batch(cuts, madeAt: settings.revision))
                    dismiss()
                } label: {
                    Text("Tighten")
                        .font(.ui(12, .bold))
                        .foregroundStyle(Theme.onAmber.color)
                        .padding(.horizontal, 14)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(cuts.isEmpty ? Theme.segmentSelected.color : Theme.amber.color))
                }
                .buttonStyle(.plain)
                .disabled(cuts.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(Theme.raised.color)
        .task(id: settings) { await replan(settings) }
    }

    /// Plans for the current settings once the sliders settle.
    private func replan(_ settings: PauseTightening.Settings) async {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let analysis = model.session.analysis
        // The project at the revision the settings were read at.
        guard model.revision == settings.revision else { return }
        let made = await PauseTightening.plan(
            in: model.project,
            transcript: { analysis.transcript(for: $0) },
            folder: model.session.folder,
            minimum: settings.minimum,
            keep: settings.keep,
            within: settings.within
        )
        guard !Task.isCancelled else { return }
        plan = (settings, made)
    }

    private var hasTranscript: Bool {
        model.project.media.contains { model.session.analysis.transcript(for: $0) != nil }
    }
}

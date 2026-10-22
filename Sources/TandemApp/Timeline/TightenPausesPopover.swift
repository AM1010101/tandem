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
    @State private var plan: (key: String, plan: SoundTightening.Plan)?

    private var key: String { "\(model.revision)/\(minimum)/\(keep)/\(onlyInOut)" }

    var body: some View {
        let current = plan.flatMap { $0.key == key ? $0.plan : nil }
        let cuts = current?.cuts ?? []
        let total = cuts.reduce(0) { $0 + $1.cut.duration.seconds }
        let heard = current?.skipped.filter { $0.reason == .sound || $0.reason == .speech }.count ?? 0
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
            if heard > 0 {
                Text(String(format: "Leaves %d %@ with sound in %@: a breath, another voice or an app.", heard, heard == 1 ? "pause" : "pauses", heard == 1 ? "it" : "them"))
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
                    Text(String(format: "%d %@, %.1f s in all", cuts.count, cuts.count == 1 ? "pause" : "pauses", total))
                        .font(.ui(12, .semibold))
                        .foregroundStyle(Theme.text.color)
                }
                Spacer()
                Button {
                    model.apply(PauseTightening.batch(cuts))
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
        .task(id: key) { await replan() }
    }

    /// Plans for the current settings once the sliders settle.
    private func replan() async {
        let key = key
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let analysis = model.session.analysis
        let made = await PauseTightening.plan(
            in: model.project,
            transcript: { analysis.transcript(for: $0) },
            folder: model.session.folder,
            minimum: Time(seconds: minimum),
            keep: Time(seconds: keep),
            within: onlyInOut ? model.inOutRange : nil
        )
        guard !Task.isCancelled else { return }
        plan = (key, made)
    }

    private var hasTranscript: Bool {
        model.project.media.contains { model.session.analysis.transcript(for: $0) != nil }
    }
}

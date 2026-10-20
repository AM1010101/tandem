import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// What plays once an angle and a mic are synced to the camera (`tandem
/// sync <file>`) and the angle shown over a stretch: the picture switches
/// there and only there, and the mic is the only sound all along, in the
/// viewer, review clips and exports alike (they share this plan).
final class AngleRenderPlanTests: XCTestCase {
    func testTheShownAngleIsThePictureThereAndTheMicIsTheSound() throws {
        var project = Project.standard(name: "Interview")
        project.media = [
            MediaItem(id: "med_cam", path: "wide.mov", kind: .video, role: .camera, takeID: "take_i", takeOffset: t(3),
                      duration: t(120), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_angle", path: "close-up.mov", kind: .video, role: .broll, takeID: "take_i", takeOffset: .zero,
                      duration: t(60), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_mic", path: "mic.wav", kind: .audio, role: .other, takeID: "take_i", takeOffset: .zero,
                      duration: t(60), hasAudio: true)
        ]
        let coordinator = ProjectCoordinator(project: project)
        try coordinator.apply(EditBatch(label: "Build", commands: [
            .placeMedia(mediaIDs: ["med_cam"], at: .zero),
            .placeSynced(mediaID: "med_mic"),
            .placeSynced(mediaID: "med_angle"),
            .showAngle(range: TimeRange(start: t(20), end: t(30)), trackID: "Angle 2")
        ]))
        let plan = RenderPlanner.plan(coordinator.project, format: nil, assets: nil)

        func picture(at seconds: Double) -> [String] {
            let instruction = plan.instructions.first { $0.range.contains(t(seconds)) }
            return (instruction?.stack.flatMap(\.layers) ?? []).compactMap { layer in coordinator.project.clip(layer.clipID)?.mediaID }
        }
        XCTAssertEqual(picture(at: 10), ["med_cam"])
        XCTAssertEqual(picture(at: 25), ["med_cam", "med_angle"], "the close-up over the camera")
        XCTAssertEqual(picture(at: 35), ["med_cam"])

        func sound(at seconds: Double) -> [String] {
            plan.audioSegments.filter { $0.timeline.contains(t(seconds)) }.map(\.mediaID)
        }
        for seconds in [10.0, 25, 35] {
            XCTAssertEqual(sound(at: seconds), ["med_mic"], "at \(seconds) s")
        }
        XCTAssertEqual(sound(at: 80), ["med_cam"], "the camera's own sound after the mic stops")
        let angleAt25 = try XCTUnwrap(plan.videoSegments.first { $0.mediaID == "med_angle" && $0.timeline.contains(t(25)) })
        XCTAssertEqual(angleAt25.sourceStart + (t(25) - angleAt25.timeline.start), t(28), "3 s further into the close-up")
    }
}

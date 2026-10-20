import XCTest
@testable import TandemApp
@testable import TandemCore

/// The Audio tab's Clean up voice: what it changes, and that it has
/// nothing to do on a clip it has cleaned up already.
final class CleanUpVoiceTests: XCTestCase {
    func testItIsolatesTheVoiceAndPutsTheCleanUpFirst() throws {
        var clip = Clip(id: "clip_mic", content: .media(mediaID: "med_mic"), start: .zero, duration: Time(seconds: 10))
        clip.audio = AudioProperties(normalizeTo: -20, effects: [Effect(id: "fx_c", type: "compressor"), Effect(id: "fx_l", type: "limiter")])
        let batch = try XCTUnwrap(InspectorEdits.cleanUpVoice([clip]))
        XCTAssertEqual(batch.label, "Clean up voice")
        XCTAssertEqual(batch.commands.count, 2)
        XCTAssertEqual(batch.commands[0], .updateClip(clipID: "clip_mic", patch: .object(["audio": .object(["voiceIsolation": .number(1)])])))
        guard case .addEffect(let clipID, let effect, let index) = batch.commands[1] else { return XCTFail("\(batch.commands[1])") }
        XCTAssertEqual(clipID, "clip_mic")
        XCTAssertEqual(effect.type, "voiceCleanup")
        XCTAssertEqual(index, 0, "before the compressor and limiter")
    }

    func testACleanedUpClipHasNothingLeftToDo() {
        var clip = Clip(id: "clip_mic", content: .media(mediaID: "med_mic"), start: .zero, duration: Time(seconds: 10))
        clip.audio = AudioProperties(voiceIsolation: 1, effects: [Effect(type: "voiceCleanup", enabled: false)])
        XCTAssertNil(InspectorEdits.cleanUpVoice([clip]), "a clean-up turned off by hand stays off")
        clip.audio?.voiceIsolation = 0.5
        XCTAssertEqual(InspectorEdits.cleanUpVoice([clip])?.commands.count, 1, "only the isolation")
    }
}

import Foundation

extension Editing {
    /// `holdFrame`: the picture `clipID` shows a frame before `range`
    /// starts, held over `range`, so a flash there (a stale frame, the
    /// preview jumping as Mike clicked) is gone. Only this clip is cut, so
    /// its sound and the clips linked to it carry on uncut, and every piece
    /// stays in the clip's link group, so they still move together. The held
    /// piece is a freeze frame; it's the clip's own ID when `range` starts at
    /// the clip's start, otherwise the first ID the batch makes.
    static func holdFrame(_ p: inout Project, clipID: String, range: TimeRange, _ context: inout EditContext) throws {
        let (location, index) = try requireClip(p, clipID)
        let track = p[location]
        try requireUnlocked(track)
        let clip = track.clips[index]
        guard track.kind == .video, let mediaID = clip.mediaID, let item = p.media(mediaID), item.kind == .video, item.hasVideo else {
            throw EditError.invalid("clip \(clipID) isn't part of a video on a video track, so it has no frame to hold")
        }
        guard !range.isEmpty else { throw EditError.invalid("hold a range at least a frame long") }
        guard range.start >= clip.start, range.end <= clip.end else {
            throw EditError.invalid("\(range.start)-\(range.end) isn't inside clip \(clipID) (\(clip.start)-\(clip.end))")
        }
        let frame = p.settings.frameRate.frameDuration
        // The frame on screen a frame before the range: for a clip that's
        // already frozen that's its own frame, and before the clip's start
        // it's the file's frame there, as if the clip started a frame early.
        var held = clip.sourceTime(atTimelineTime: range.start - frame)
        if let limit = p.sourceLimit(for: clip) { held = min(held, limit) }
        held = max(held, .zero)

        var edited = track
        var heldID = clip.id
        var made: [String] = []
        if range.start > clip.start, let right = edited.split(at: range.start, context: &context) {
            heldID = right
            made.append(right)
        }
        if range.end < clip.end, let right = edited.split(at: range.end, context: &context) {
            made.append(right)
        }
        // Splitting gives the pieces after a cut a new link group, which
        // only the linked clips cut there would share. Nothing else is cut,
        // so they stay in the clip's.
        for id in made {
            if let i = edited.index(ofClip: id) { edited.clips[i].linkGroup = clip.linkGroup }
        }
        guard let i = edited.index(ofClip: heldID) else { throw EditError.notFound("clip \(heldID)") }
        edited.clips[i].freezeFrame = true
        edited.clips[i].sourceStart = held
        edited.clips[i].speed = 1
        try checkSource(edited.clips[i], in: p)
        p[location] = edited
    }
}

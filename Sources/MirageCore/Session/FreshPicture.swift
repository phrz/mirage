import Foundation

/// When the whole desktop starts over with a fresh picture (tiny keyframe, climb, lossless blocks; DESIGN §3.3): only
/// when nothing the viewer holds is worth keeping. A large change confined to a region (the Dock's material
/// re-rendering under the pointer, a window animating) is motion or tiles for that region, never a restart: a keyframe
/// whose mask covered 40 % of the display used to restart the whole picture, and right after a restart most tiles are not
/// crisp yet, so the next recovery keyframe's mask was large again (phrz's Dock hover on 949c064: 32 restarts in 14 s,
/// the whole screen dropping to the tiny rung each time).
public enum FreshPictureTrigger: String, Equatable {
    case streamStart = "stream start", resize, tierChange = "tier change", regionChange = "region change", recoveryKeyframe = "recovery keyframe"
    /// A resumed session whose viewer holds no picture (an app relaunched with its saved resume token).
    case viewerEmpty = "viewer holds no picture"
    public var restartsWholePicture: Bool {
        switch self {
        case .streamStart, .resize, .tierChange, .viewerEmpty: return true
        case .regionChange, .recoveryKeyframe: return false
        }
    }
}

/// What a resumed session sends first (DESIGN §4a). The host keeps, per layer, which tiles the viewer holds crisp and
/// the last frame it saw, and normally brings the viewer's kept picture current: a keyframe masked to the tiles it does
/// not hold crisp, plus each layer's diff against that last frame. That is right for a viewer that survived an outage
/// with its picture on screen, and wrong for one that holds nothing: an iOS app relaunched with its saved resume token
/// starts with empty canvases, so the masked keyframe left every tile the host believed crisp grey, and window layers,
/// re-announced with an unchanged diff, stayed empty until the stream size changed. Such a viewer says so
/// (`StreamRequest.holdsPicture == false`) and gets a fresh picture of every layer; the session itself continues (rate
/// controller, tier, ladder rung, sequences, input numbering), so a good path pays no reconnect penalty.
public enum ResumePicture: Equatable {
    /// Bring the viewer's kept picture current (masked keyframe, diffs).
    case bringCurrent
    /// Start every layer over with a fresh picture (tiny keyframe, climb, lossless blocks; windows announced and stilled).
    case fresh(FreshPictureTrigger)
    /// Whether the rate controller survives (only a new size changes what it was tuned for).
    public var keepsController: Bool { if case .fresh(.resize) = self { return false }; return true }

    public static func plan(sizeChanged: Bool, viewerHoldsPicture: Bool?, hasEncoder: Bool) -> ResumePicture {
        if sizeChanged { return .fresh(.resize) }
        if !hasEncoder { return .fresh(.streamStart) }
        if viewerHoldsPicture == false { return .fresh(.viewerEmpty) }
        return .bringCurrent
    }
}

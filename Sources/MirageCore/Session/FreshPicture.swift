import Foundation

/// When the whole desktop starts over with a fresh picture (tiny keyframe, climb, lossless blocks; DESIGN §3.3): only
/// when nothing the viewer holds is worth keeping. A large change confined to a region (the Dock's material
/// re-rendering under the pointer, a window animating) is motion or tiles for that region, never a restart: a keyframe
/// whose mask covered 40 % of the display used to restart the whole picture, and right after a restart most tiles are not
/// crisp yet, so the next recovery keyframe's mask was large again (phrz's Dock hover on 949c064: 32 restarts in 14 s,
/// the whole screen dropping to the tiny rung each time).
public enum FreshPictureTrigger: String, Equatable {
    case streamStart = "stream start", resize, tierChange = "tier change", regionChange = "region change", recoveryKeyframe = "recovery keyframe"
    public var restartsWholePicture: Bool {
        switch self {
        case .streamStart, .resize, .tierChange: return true
        case .regionChange, .recoveryKeyframe: return false
        }
    }
}

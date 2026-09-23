import Foundation

/// Value-only, one-way messages to the full-screen display helper. Game
/// controls and native alerts belong to the launcher, never this protocol.
struct OverlayDisplaySnapshot: Codable, Equatable {
    let cpuLine: String
    let gpuLine: String
    /// Managed `dwrg.exe` PID the two lines describe; 0 while the toolbox has
    /// no live target. The display helper compares it with the real frontmost
    /// application PID instead of trusting any toolbox-side guess.
    let targetPID: Int32
    /// True only once at least one live resource sample backs the two lines,
    /// so a placeholder-only update can never open an empty-looking window.
    let hasLiveData: Bool
}

/// One definition of "the overlay may be on screen", split by ownership so
/// neither side has to guess: the toolbox owns the user's enable intent and
/// data freshness, the display helper owns the real frontmost PID. Turning the
/// overlay off stops the helper (stdin EOF), but updates already in flight
/// still pass the toolbox half, which must not re-present a closed window.
enum OverlayVisibility {
    /// Toolbox half: an eligible snapshot needs the user's intent, a managed
    /// target and at least one live sample.
    static func isSnapshotLive(isEnabledByUser: Bool, hasLiveData: Bool, targetPID: Int32) -> Bool {
        isEnabledByUser && hasLiveData && targetPID != 0
    }
    /// Display-helper half: present only while the real frontmost application
    /// is the managed game. A missing frontmost PID never matches, so data
    /// updates for a background game cannot pull the window back on screen.
    static func shouldPresent(isSnapshotLive: Bool, targetPID: Int32, frontmostPID: Int32?) -> Bool {
        isSnapshotLive && targetPID != 0 && frontmostPID == targetPID
    }
    /// Visibility-gate fixtures: managed game frontmost, another app
    /// frontmost, no frontmost app, missing target, user-closed intent and a
    /// pending first sample. Line text itself is deliberately not mirrored.
    static func fixtureChecks() -> [Bool] {
        let live = isSnapshotLive(isEnabledByUser: true, hasLiveData: true, targetPID: 75512)
        return [
            live,
            shouldPresent(isSnapshotLive: live, targetPID: 75512, frontmostPID: 75512),
            !shouldPresent(isSnapshotLive: live, targetPID: 75512, frontmostPID: 501),
            !shouldPresent(isSnapshotLive: live, targetPID: 75512, frontmostPID: nil),
            !shouldPresent(isSnapshotLive: live, targetPID: 0, frontmostPID: 0),
            !shouldPresent(isSnapshotLive: false, targetPID: 75512, frontmostPID: 75512),
            !isSnapshotLive(isEnabledByUser: true, hasLiveData: true, targetPID: 0),
            !isSnapshotLive(isEnabledByUser: false, hasLiveData: true, targetPID: 75512),
            !isSnapshotLive(isEnabledByUser: true, hasLiveData: false, targetPID: 75512),
        ]
    }
}

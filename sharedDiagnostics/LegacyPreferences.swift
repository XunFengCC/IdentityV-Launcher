import CoreFoundation
import Foundation

/// Copies a deliberately small set of non-secret preferences after the public
/// first-party bundle IDs change. The file-backed product/game state keeps its
/// existing paths; this is only for UserDefaults domains keyed by bundle ID.
enum IdentityVLegacyPreferences {
    private static let marker = "identityVFirstPartyIdentityPreferencesMigratedV1"

    enum ValueKind { case boolean, string }
    struct Rule { let key: String; let kind: ValueKind }

    private static let launcherRules: [Rule] = [
        .init(key: "identityVLauncherHangWarningsEnabled", kind: .boolean),
        .init(key: "idvLoginFollowGameLaunchEnabled", kind: .boolean),
        .init(key: "idvLoginPromptAnswered", kind: .boolean),
        .init(key: "idvLoginCertificateTrustNoticeAcknowledged", kind: .boolean),
        .init(key: "NSWindow Frame identityv-toolbox-main", kind: .string)
    ]
    private static let toolboxRules: [Rule] = [
        .init(key: "NSWindow Frame identityv-toolbox", kind: .string)
    ]

    /// Called before constructing either App's model or SwiftUI window. It
    /// never changes the old domain, Keychain, TCC, or files on disk itself.
    static func migrateForCurrentApp() {
        guard let currentID = Bundle.main.bundleIdentifier else { return }
        let oldID: String
        let rules: [Rule]
        switch currentID {
        case "com.fengyin.identityv.launcher":
            oldID = "com.xunfeng.identityv.launcher"
            rules = launcherRules
        case "com.fengyin.identityv.toolbox":
            oldID = "com.xunfeng.identityv.monitor"
            rules = toolboxRules
        default:
            return
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: marker) else { return }
        let oldValues = defaults.persistentDomain(forName: oldID) ?? [:]
        let newValues = defaults.persistentDomain(forName: currentID) ?? [:]
        for (key, value) in plannedCopies(legacy: oldValues, current: newValues, rules: rules) {
            defaults.set(value, forKey: key)
        }
        // An explicit marker prevents a later user reset from restoring an
        // old setting on each launch. No secret values are logged or exported.
        defaults.set(true, forKey: marker)
    }

    /// Pure planner, so the synthetic contract test never touches real prefs.
    static func plannedCopies(
        legacy: [String: Any], current: [String: Any], rules: [Rule]
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        for rule in rules where current[rule.key] == nil {
            guard let value = legacy[rule.key] else { continue }
            switch rule.kind {
            case .boolean:
                guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { continue }
            case .string:
                guard value is String else { continue }
            }
            result[rule.key] = value
        }
        return result
    }

    static func launcherTestRules() -> [Rule] { launcherRules }
    static func toolboxTestRules() -> [Rule] { toolboxRules }
}

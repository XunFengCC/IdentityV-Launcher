import Foundation

@main
struct LegacyPreferenceMigrationSelfTest {
    static func main() {
        let old: [String: Any] = [
            "idvLoginFollowGameLaunchEnabled": true,
            "idvLoginPromptAnswered": true,
            "identityVLauncherHangWarningsEnabled": "wrong type",
            "NSWindow Frame identityv-toolbox-main": "{{10, 20}, {680, 420}}",
            "privateUnrelatedKey": "must not copy"
        ]
        let current: [String: Any] = ["idvLoginPromptAnswered": false]
        let copied = IdentityVLegacyPreferences.plannedCopies(
            legacy: old, current: current,
            rules: IdentityVLegacyPreferences.launcherTestRules()
        )
        precondition(copied["idvLoginFollowGameLaunchEnabled"] as? Bool == true)
        precondition(copied["NSWindow Frame identityv-toolbox-main"] as? String != nil)
        precondition(copied["idvLoginPromptAnswered"] == nil)
        precondition(copied["identityVLauncherHangWarningsEnabled"] == nil)
        precondition(copied["privateUnrelatedKey"] == nil)
        let toolbox = IdentityVLegacyPreferences.plannedCopies(
            legacy: ["NSWindow Frame identityv-toolbox": "frame", "other": true],
            current: [:], rules: IdentityVLegacyPreferences.toolboxTestRules()
        )
        precondition(toolbox.count == 1)
        precondition(toolbox["NSWindow Frame identityv-toolbox"] as? String == "frame")
        print("Legacy preference migration self-test passed")
    }
}

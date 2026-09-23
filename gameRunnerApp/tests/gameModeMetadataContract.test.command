#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
launcher_plist="$root/../playerLauncherApp/Info.plist"
runner_plist="$root/IdentityV-Mac.app/Contents/Info.plist"

[[ -r "$launcher_plist" && -r "$runner_plist" ]]
/usr/bin/plutil -lint "$launcher_plist" >/dev/null
/usr/bin/plutil -lint "$runner_plist" >/dev/null

# The UI is a launcher, not the gameplay client.  Keep the game category and
# Game Mode opt-in on the embedded runner that owns the Wine game process.
[[ "$(/usr/bin/plutil -extract LSApplicationCategoryType raw -o - "$launcher_plist")" == "public.app-category.utilities" ]]
! /usr/libexec/PlistBuddy -c 'Print :LSSupportsGameMode' "$launcher_plist" >/dev/null 2>&1
! /usr/libexec/PlistBuddy -c 'Print :GCSupportsGameMode' "$launcher_plist" >/dev/null 2>&1

[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw -o - "$runner_plist")" == "第五人格" ]]
[[ "$(/usr/bin/plutil -extract CFBundleName raw -o - "$runner_plist")" == "第五人格" ]]
[[ "$(/usr/bin/plutil -extract LSApplicationCategoryType raw -o - "$runner_plist")" == "public.app-category.games" ]]
[[ "$(/usr/bin/plutil -extract LSSupportsGameMode raw -o - "$runner_plist")" == "true" ]]
[[ "$(/usr/bin/plutil -extract LSUIElement raw -o - "$runner_plist")" == "true" ]]
! /usr/libexec/PlistBuddy -c 'Print :GCSupportsGameMode' "$runner_plist" >/dev/null 2>&1

print -r -- "Game Mode metadata contract self-test passed"

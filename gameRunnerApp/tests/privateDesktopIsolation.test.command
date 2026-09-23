#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h:h}"
RUNNER="$PROJECT_ROOT/gameRunnerApp/IdentityV-Mac.app/Contents/MacOS/launchIdentityVRunner"
TEST_ROOT="$(/usr/bin/mktemp -d /tmp/identityv-private-folders.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
export PREFIX="$TEST_ROOT/prefix"
export LOG_FILE="$TEST_ROOT/isolation.log"
typeset -a FOLDERS
FOLDERS=(Desktop Documents Downloads Pictures Music Videos)
typeset -a MACOS_FOLDERS
MACOS_FOLDERS=(Desktop Documents Downloads Pictures Music Movies)

/bin/mkdir -p "$TEST_ROOT/unrelated" "$TEST_ROOT/relocated-downloads" "$HOME/NotProtected" "$HOME/Videos" "$PREFIX/drive_c/users/crossover/Documents/real-directory"
# A Windows Downloads bridge must still be removed when macOS Downloads itself
# is relocated through a symlink.
/bin/ln -s "$TEST_ROOT/relocated-downloads" "$HOME/Downloads"

for ((i = 1; i <= ${#FOLDERS}; i++)); do
  folder_name="${FOLDERS[i]}"
  mac_folder_name="${MACOS_FOLDERS[i]}"
  /bin/mkdir -p "$HOME/$mac_folder_name/subfolder" "$PREFIX/drive_c/users/crossover/$folder_name/nested" "$PREFIX/drive_c/users/example"
  /usr/bin/touch "$PREFIX/drive_c/users/crossover/$folder_name/ordinary-file"
  /bin/ln -s "$HOME/$mac_folder_name" "$PREFIX/drive_c/users/crossover/$folder_name/Mac $folder_name"
  /bin/ln -s "$HOME/$mac_folder_name/subfolder" "$PREFIX/drive_c/users/crossover/$folder_name/nested/Mac $folder_name Child"
  /bin/ln -s "$HOME/$mac_folder_name" "$PREFIX/drive_c/users/example/$folder_name"
done

/bin/ln -s "$TEST_ROOT/unrelated" "$PREFIX/drive_c/users/crossover/Desktop/Keep Me"
/bin/ln -s "$HOME/NotProtected" "$PREFIX/drive_c/users/crossover/Documents/Keep Nonstandard"
/bin/ln -s "$HOME/Videos" "$PREFIX/drive_c/users/crossover/Videos/Keep Wrong macOS Videos"

function_source="$(/usr/bin/awk '
  /^ensure_private_standard_folders\(\) \{/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$RUNNER")"
[[ -n "$function_source" ]] || { print -u2 -- "cannot locate ensure_private_standard_folders"; exit 1; }
eval "$function_source"
ensure_private_standard_folders

for folder_name in $FOLDERS; do
  [[ -d "$PREFIX/drive_c/users/example/$folder_name" && ! -L "$PREFIX/drive_c/users/example/$folder_name" ]]
  [[ ! -e "$PREFIX/drive_c/users/crossover/$folder_name/Mac $folder_name" ]]
  [[ ! -e "$PREFIX/drive_c/users/crossover/$folder_name/nested/Mac $folder_name Child" ]]
  [[ -f "$PREFIX/drive_c/users/crossover/$folder_name/ordinary-file" ]]
done

[[ -L "$PREFIX/drive_c/users/crossover/Desktop/Keep Me" ]]
[[ "$(/bin/realpath "$PREFIX/drive_c/users/crossover/Desktop/Keep Me")" == "$(/bin/realpath "$TEST_ROOT/unrelated")" ]]
[[ -L "$PREFIX/drive_c/users/crossover/Documents/Keep Nonstandard" ]]
[[ -d "$PREFIX/drive_c/users/crossover/Documents/real-directory" ]]
[[ -L "$PREFIX/drive_c/users/crossover/Videos/Keep Wrong macOS Videos" ]]
/usr/bin/grep -q 'Windows user crossover' "$LOG_FILE"
/usr/bin/grep -q 'Windows user example' "$LOG_FILE"

print -r -- "private standard-folder isolation self-test passed"

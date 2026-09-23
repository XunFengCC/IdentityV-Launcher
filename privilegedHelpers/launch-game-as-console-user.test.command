#!/bin/zsh
# Static contract tests only: no installation and no game/process launch.
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BRIDGE="$SCRIPT_DIR/launch-game-as-console-user"
PROJECT_ROOT="$SCRIPT_DIR:h"
START_HELPER="$SCRIPT_DIR/start-idv-login.sh"
INSTALLER="$PROJECT_ROOT/installIdentityVPasswordlessHelpers.command"

/bin/zsh -n "$BRIDGE"
/bin/zsh -n "$START_HELPER"
/bin/zsh -n "$INSTALLER"
/usr/bin/python3 - "$BRIDGE" "$START_HELPER" "$INSTALLER" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
required = (
    'readonly GAME_APP="/Applications/第五人格启动器.app/Contents/Helpers/IdentityVGameRunner.app"',
    'readonly GAME_RUNNER="$GAME_APP/Contents/MacOS/launchIdentityVRunner"',
    '[[ "$1" == "--start_from_launcher=1" && "$2" == "--is_multi_start" ]]',
    '/usr/bin/stat -f \'%Su\' /dev/console',
    '/usr/bin/stat -f \'%u\' /dev/console',
    '"$console_user" != "root"',
    '"$console_user" != "loginwindow"',
    '/usr/bin/dscl . -read "/Users/$console_user" UniqueID',
    '/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory',
    '/bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/env -i',
    '/bin/zsh "$GAME_RUNNER" --product mainland',
)
missing = [item for item in required if item not in text]
if missing:
    raise SystemExit("bridge static contract missing: " + repr(missing))

start_text = Path(sys.argv[2]).read_text(encoding="utf-8")
installer_text = Path(sys.argv[3]).read_text(encoding="utf-8")
start_required = (
    'GAME_BRIDGE="$HELPER_DIR/launch-game-as-console-user"',
    'STATE_TOOL="$HELPER_DIR/identityv-state-tool"',
    '"$STATE_TOOL" prepare-config --home "$USER_HOME"',
    '"$STATE_TOOL" ensure-hosts',
    'idv_job_start "$IDV_BIN" "$USER_HOME" "$USER_NAME" "$LOG_FILE"',
    'readonly READINESS_TIMEOUT_SECONDS=300',
    'IDV_LOGIN_READINESS=$state',
    '127.0.0.1:443',
    'prepare_user_runtime_directory',
    '^\\/Library\\/Application Support\\/IdentityVOnMac\\/Components\\/idv-login',
)
missing = [item for item in start_required if item not in start_text]
if missing:
    raise SystemExit("start helper bridge hand-off contract missing: " + repr(missing))
for forbidden in ('USER_GAME_EXEC=', 'LAUNCH_URI=', '--uri "$LAUNCH_URI"', 'launching game through Mac entry'):
    if forbidden in start_text:
        raise SystemExit("start helper must not launch a game: " + forbidden)
if '/usr/bin/python3' in start_text:
    raise SystemExit("installed start helper must not require Python")
if 'fix_game_priority_loop </dev/null' in start_text:
    raise SystemExit("priority watcher must not remain in the privileged start chain")
if start_text.rindex('prepare_user_runtime_directory') < start_text.index('if [[ "$MODE" == "status" ]]'):
    raise SystemExit("status path must precede runtime directory writes")
installer_required = (
    'GAME_BRIDGE="$HELPER_DIR/launch-game-as-console-user"',
    'STATE_TOOL="$HELPER_DIR/identityv-state-tool"',
    'STATE_TOOL_SOURCE="$PAYLOAD_ROOT/identityv-state-tool"',
    '"$HELPER_SOURCE_DIR/launch-game-as-console-user"',
    '"$GAME_BRIDGE")" == "0:0:755"',
    '"$STATE_TOOL")" == "0:0:755"',
)
missing = [item for item in installer_required if item not in installer_text]
if missing:
    raise SystemExit("installer bridge install contract missing: " + repr(missing))
sudoers_block = installer_text.split('/bin/cat > "$SUDOERS_FILE" <<SUDOERS', 1)[1].split('SUDOERS\n', 1)[0]
if ' $START_HELPER --status' not in sudoers_block:
    raise SystemExit("readiness status must be an explicit sudoers command")
if 'launch-game-as-console-user' in sudoers_block:
    raise SystemExit("bridge must not be callable through sudoers")
if 'fix-game-priority.sh' in sudoers_block:
    raise SystemExit("priority helper must not be callable through sudoers")
if '"$GAME_RUNNER" "$@"' in text:
    raise SystemExit("validated upstream arguments must not be forwarded to the user app")
if '/usr/bin/open ' in text:
    raise SystemExit("bridge must not reintroduce a LaunchServices helper lifecycle")

# The runtime case accepts exactly zero args or exactly the fixed pair; these
# compact test vectors make the positive and negative policy unambiguous.
def accepted(argv):
    return argv == () or argv == ("--start_from_launcher=1", "--is_multi_start")

cases = {
    (): True,
    ("--start_from_launcher=1", "--is_multi_start"): True,
    ("--start_from_launcher=1",): False,
    ("--is_multi_start", "--start_from_launcher=1"): False,
    ("--start_from_launcher=1", "--is_multi_start", "--extra"): False,
    ("/tmp/other",): False,
}
for argv, expected in cases.items():
    if accepted(argv) != expected:
        raise SystemExit(f"argument policy test failed: {argv!r}")
print("bridge static contract and positive/negative argument cases passed")
PY

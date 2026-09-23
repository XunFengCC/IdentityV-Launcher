#!/bin/zsh
# Test the actual plist generator with unusual paths; never bootstraps a job.
set -euo pipefail
ROOT="${0:A:h}"
source "$ROOT/idv-login-job.sh"
work="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$work"' EXIT
idv_job_write_plist "$work/job.plist" '/Library/Application Support/IdentityVOnMac/Components/idv-login/current/idv-login' '/Users/a & b' 'fixture' '/Users/a & b/Library/Application Support/idv-login/run.log'
/usr/bin/python3 - "$work/job.plist" "$ROOT" <<'PY'
import os,plistlib,subprocess,sys,time
from pathlib import Path
p=plistlib.loads(Path(sys.argv[1]).read_bytes())
root=Path(sys.argv[2])
assert p['Label']=='com.xunfeng.identityv.idv-login'
assert len(p['ProgramArguments'])==1 and p['ProgramArguments'][0].endswith('/current/idv-login')
assert p['EnvironmentVariables']=={'HOME':'/Users/a & b','USER':'fixture','LOGNAME':'fixture','PROGRAMDATA':'/Users/a & b/Library/Application Support','PATH':'/usr/bin:/bin:/usr/sbin:/sbin'}
assert p['StandardInPath']=='/dev/null'
assert p['StandardOutPath']==p['StandardErrorPath']=='/Users/a & b/Library/Application Support/idv-login/run.log'
assert p['RunAtLoad'] is True and p['KeepAlive'] is False and p['Nice']==5
stop=(root/'stop-idv-login.sh').read_text()
assert stop.index('\nidv_job_remove\n') < stop.index('\npids="$(idv_login_pids)"') < stop.index('"$STATE_TOOL" remove-hosts')
start=(root/'start-idv-login.sh').read_text()
assert 'idv_job_start "$IDV_BIN" "$USER_HOME" "$USER_NAME" "$LOG_FILE"' in start
assert 'idv_pid="$!"' not in start
assert 'source "${SELF_PATH:h}/idv-login-job.sh"' in start
print('launchd plist/environment/stop-order contracts passed')
# Exercise the real lock with unprivileged fixture scripts. A parent start
# must be able to call Stop for error cleanup without deadlocking, while an
# unrelated Stop waits until that entire start/cleanup transaction ends.
work=Path(sys.argv[1]).parent.resolve()
common=f'''set -eu
source '{root}/idv-login-job.sh'
SELF_PATH="${{0:A}}"
LOCK_DIR='{work}/lock'
LOCK_HELD=0
trap release_start_lock EXIT
trap 'release_start_lock; exit 143' TERM
acquire_start_lock
'''
(work/'start-idv-login.sh').write_text(common+f'''
touch '{work}/owned'
while [[ ! -f '{work}/release' ]]; do /bin/sleep 0.05; done
ROLE=borrowed /bin/zsh '{work}/stop-idv-login.sh'
print released >> '{work}/events'
''')
(work/'stop-idv-login.sh').write_text(common+f"print -- \"$ROLE\" >> '{work}/events'\n")
children=[]
try:
    first=subprocess.Popen(['/bin/zsh',str(work/'start-idv-login.sh')]); children.append(first)
    deadline=time.monotonic()+3
    while not (work/'owned').exists() and time.monotonic()<deadline: time.sleep(.02)
    assert (work/'owned').exists(), 'start did not acquire lock'
    second=subprocess.Popen(['/bin/zsh',str(work/'stop-idv-login.sh')],env={**os.environ,'ROLE':'external'}); children.append(second)
    time.sleep(.2)
    assert second.poll() is None and not (work/'events').exists(), ('external stop bypassed live start lock',subprocess.check_output(['/bin/ps','-p',str(first.pid),'-o','command='],text=True),str(work),(work/'events').read_text() if (work/'events').exists() else '')
    (work/'release').touch()
    assert first.wait(timeout=4)==0
    assert second.wait(timeout=4)==0
    assert (work/'events').read_text().splitlines()==['borrowed','released','external']
    assert not (work/'lock').exists()
    (work/'lock').mkdir(); (work/'lock'/'pid').write_text('999999999\n')
    subprocess.run(['/bin/zsh',str(work/'stop-idv-login.sh')],env={**os.environ,'ROLE':'recovered'},timeout=3,check=True)
    assert not (work/'lock').exists(), 'stale lock not recovered/released'
finally:
    for child in children:
        if child.poll() is None: child.kill(); child.wait()
print('shared lifecycle lock serialization/borrow/stale recovery passed')
PY

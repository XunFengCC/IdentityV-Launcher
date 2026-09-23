#!/bin/zsh
# Fixture-only readiness tests. They never query real processes, ports or /etc/hosts.
set -euo pipefail

ROOT="${0:A:h}"
HELPER="$ROOT/start-idv-login.sh"
FIXTURE="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$FIXTURE"' EXIT

[[ "$(/bin/zsh "$HELPER" --contract)" == "IDV_LOGIN_STATUS_CONTRACT=7" ]] || {
  print -u2 -- "start helper 未声明预期 status contract。"
  exit 1
}

write_hosts() {
  /usr/bin/printf '%s\n' \
    '127.0.0.1 service.mkey.163.com # identityv-on-mac-compat' \
    '127.0.0.1 sdk-os.mpsdk.easebar.com # identityv-on-mac-compat' \
    '127.0.0.1 mgbsdk.matrix.netease.com # identityv-on-mac-compat' > "$FIXTURE/hosts"
}
write_upstream_hosts() {
  /usr/bin/printf '%s\n' \
    $'127.0.0.1\tservice.mkey.163.com' \
    $'127.0.0.1\tsdk-os.mpsdk.easebar.com' \
    $'127.0.0.1\tmgbsdk.matrix.netease.com' > "$FIXTURE/hosts"
}
write_processes() {
  /usr/bin/printf '%s\n' \
    '410 1 /Library/Application Support/IdentityVOnMac/Components/idv-login/6.2.3/idv-login --uri idvlogin://start?game_id=h55' \
    '411 410 /Library/Application Support/IdentityVOnMac/Components/idv-login/6.2.3/idv-login --uri idvlogin://start?game_id=h55' \
    '412 411 /Library/Application Support/IdentityVOnMac/Components/idv-login/6.2.3/proxy-child' > "$FIXTURE/processes.txt"
}
write_authorizing_processes() {
  write_processes
  /usr/bin/printf '%s\n' \
    '413 411 /usr/bin/security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/idv-login-ca.pem' >> "$FIXTURE/processes.txt"
}
write_unrelated_authorization_processes() {
  write_processes
  /usr/bin/printf '%s\n' \
    '999 1 /usr/bin/security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/unrelated-ca.pem' >> "$FIXTURE/processes.txt"
}
assert_state() {
  local expected="$1" actual
  actual="$(/bin/zsh "$HELPER" --readiness-fixture "$FIXTURE")"
  [[ "$actual" == "IDV_LOGIN_READINESS=$expected" ]] || {
    print -u2 -- "期望 $expected，实际 $actual"
    exit 1
  }
}

write_hosts
write_processes
/usr/bin/printf 'p412\nn127.0.0.1:443\n' > "$FIXTURE/listeners.txt"
assert_state ready

# IDV Login itself rewrites the same three domain-only loopback mappings
# without our comment.  That exact upstream representation is also ready.
write_upstream_hosts
assert_state ready
write_hosts

# A diagnostic shell mentioning the path must never count as an IDV Login
# process merely by substring match.
/usr/bin/printf '%s\n' '999 1 /bin/zsh -c /usr/bin/rg idv-login /Library/Application Support/IdentityVOnMac/Components/idv-login/6.2.3/idv-login' > "$FIXTURE/processes.txt"
assert_state not-running
write_processes

: > "$FIXTURE/listeners.txt"
assert_state starting

/usr/bin/printf 'p999\nn127.0.0.1:443\n' > "$FIXTURE/listeners.txt"
assert_state misconfigured

write_hosts
/usr/bin/printf '%s\n' '127.0.0.1 service.mkey.163.com unrelated.example # identityv-on-mac-compat' >> "$FIXTURE/hosts"
assert_state misconfigured

write_upstream_hosts
/usr/bin/printf '%s\n' '127.0.0.1 service.mkey.163.com # identityv-on-mac-compat' >> "$FIXTURE/hosts"
assert_state misconfigured

write_upstream_hosts
/usr/bin/sed -i '' 's/service.mkey.163.com$/service.mkey.163.com # foreign/' "$FIXTURE/hosts"
assert_state misconfigured

: > "$FIXTURE/processes.txt"
assert_state not-running

# Replay observed first-start transitions without sleeping or touching the
# machine: Hosts cleanup, hot-update restart, CA authorization, then readiness.
SEQUENCE="$FIXTURE/sequence"
mkdir -p "$SEQUENCE"
reset_sequence() { : > "$SEQUENCE/timeline.txt"; }
frame() {
  local elapsed="$1" number="$2"
  mkdir -p "$SEQUENCE/$number"
  cp "$FIXTURE/hosts" "$FIXTURE/processes.txt" "$FIXTURE/listeners.txt" "$SEQUENCE/$number/"
  print -r -- "$elapsed $number" >> "$SEQUENCE/timeline.txt"
}
assert_startup() {
  local expected="$1" actual
  actual="$(/bin/zsh "$HELPER" --startup-sequence-fixture "$SEQUENCE")"
  [[ "$actual" == "IDV_LOGIN_STARTUP=$expected" ]] || {
    print -u2 -- "启动序列期望 $expected，实际 $actual"; exit 1
  }
}
reset_sequence
write_processes
print '127.0.0.1 mgbsdk.matrix.netease.com # identityv-on-mac-compat' > "$FIXTURE/hosts"
: > "$FIXTURE/listeners.txt"
frame 1 1
: > "$FIXTURE/processes.txt"
frame 5 2
write_processes
frame 9 3
frame 180 4
write_upstream_hosts
printf 'p412\nn127.0.0.1:443\n' > "$FIXTURE/listeners.txt"
frame 184 5
assert_startup ready

# Missing mappings never become ready by elapsed time alone.
reset_sequence
: > "$FIXTURE/hosts"
: > "$FIXTURE/listeners.txt"
write_processes
frame 0 1
frame 300 2
assert_startup timeout

# A trust request owned by IDV Login's process tree suspends the 300 s
# readiness budget. It can remain visible for an hour, then readiness gets a
# fresh budget as soon as the managed security process exits.
reset_sequence
: > "$FIXTURE/hosts"
: > "$FIXTURE/listeners.txt"
write_authorizing_processes
frame 0 1
frame 3600 2
write_processes
write_upstream_hosts
printf 'p412\nn127.0.0.1:443\n' > "$FIXTURE/listeners.txt"
frame 3601 3
assert_startup ready

# A matching security command outside the managed process tree is ordinary
# startup work, so it must not suppress the normal readiness deadline.
reset_sequence
: > "$FIXTURE/hosts"
: > "$FIXTURE/listeners.txt"
write_unrelated_authorization_processes
frame 0 1
frame 300 2
assert_startup timeout

# An upstream crash may briefly restart; permanent exit fails after 10s.
reset_sequence
: > "$FIXTURE/processes.txt"
frame 0 1
frame 10 2
assert_startup not-running

# Genuine foreign mappings/listeners remain immediate failures, including
# while mappings are temporarily absent during initialization.
reset_sequence
write_processes
print '192.0.2.1 service.mkey.163.com' > "$FIXTURE/hosts"
frame 1 1
assert_startup misconfigured
reset_sequence
: > "$FIXTURE/hosts"
printf 'p999\nn127.0.0.1:443\n' > "$FIXTURE/listeners.txt"
frame 1 1
assert_startup misconfigured
reset_sequence
printf 'p999\nn*:443\n' > "$FIXTURE/listeners.txt"
frame 1 1
assert_startup misconfigured

# A foreign 443 listener is a hard failure even if a managed certificate
# authorization is simultaneously pending.
reset_sequence
: > "$FIXTURE/hosts"
write_authorizing_processes
printf 'p999\nn127.0.0.1:443\n' > "$FIXTURE/listeners.txt"
frame 1 1
assert_startup misconfigured
print 'IDV Login readiness fixture tests passed.'

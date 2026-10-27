#!/bin/bash
set -euo pipefail
umask 077
action=${1:-}
user_home=${2:-}
user_id=${3:-}
core_source=${4:-}
label=local.private-line.core
old_label=local.codex.private-proxy
daemon=/Library/LaunchDaemons/local.private-line.core.plist
installed_core=/Library/PrivilegedHelperTools/local.private-line.mihomo
expected_hash=2d409b065274ea2f30ad3721c790055d286ebb2adc6091aeabc0e4d4fc333c90
[[ $EUID -eq 0 ]] || { echo 'Administrator authorization required.'; exit 1; }
[[ "$user_id" =~ ^[0-9]+$ && "$user_id" -ge 500 ]] || exit 2
user_name=$(/usr/bin/id -un "$user_id")
actual_home=$(/usr/bin/dscl . -read "/Users/$user_name" NFSHomeDirectory | /usr/bin/sed 's/^NFSHomeDirectory: //')
[[ "$user_home" == "$actual_home" && -d "$user_home" ]] || exit 2
base="$user_home/Library/Application Support/Codex Private Proxy"
old_plist="$user_home/Library/LaunchAgents/$old_label.plist"
[[ -d "$base" && ! -L "$base" && -f "$old_plist" && ! -L "$base/config.yaml" ]] || exit 2

start_old() {
    /bin/launchctl enable "gui/$user_id/$old_label" || true
    /bin/launchctl bootstrap "gui/$user_id" "$old_plist" 2>/dev/null || true
    /bin/launchctl kickstart "gui/$user_id/$old_label" 2>/dev/null || true
}
rollback() {
    /bin/launchctl bootout "system/$label" 2>/dev/null || true
    /bin/rm -f "$daemon"
    if [[ -f "$base/config.activation-backup.yaml" ]]; then
        /bin/cp "$base/config.activation-backup.yaml" "$base/config.yaml"
    fi
    /usr/sbin/chown -R "$user_id:20" "$base"
    /bin/chmod 600 "$base/config.yaml"
    start_old
}

if [[ "$action" == restore ]]; then
    [[ -f "$base/config.before-control-app.yaml" ]] || exit 3
    /bin/launchctl bootout "system/$label" 2>/dev/null || true
    /bin/cp "$base/config.before-control-app.yaml" "$base/config.yaml"
    /usr/sbin/chown -R "$user_id:20" "$base"
    /bin/chmod 600 "$base/config.yaml"
    /bin/rm -f "$daemon" "$installed_core"
    start_old
    echo restored
    exit 0
fi
[[ "$action" == install && -f "$core_source" && ! -L "$core_source" ]] || exit 2
actual_hash=$(/usr/bin/shasum -a 256 "$core_source" | /usr/bin/awk '{print $1}')
[[ "$actual_hash" == "$expected_hash" ]] || { echo 'Bundled core integrity check failed.'; exit 4; }
/usr/bin/codesign --verify --strict "$core_source"
"$core_source" -t -d "$base" -f "$base/config.yaml" >/dev/null 2>&1
/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
/usr/bin/install -o root -g wheel -m 755 "$core_source" "$installed_core"
[[ ! -L "$daemon" ]] || exit 2
/bin/rm -f "$daemon"
/usr/libexec/PlistBuddy -c "Add :Label string $label" "$daemon"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$daemon"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $installed_core" "$daemon"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string -d' "$daemon"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:2 string $base" "$daemon"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:3 string -f' "$daemon"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:4 string $base/config.yaml" "$daemon"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$daemon"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "$daemon"
/usr/libexec/PlistBuddy -c 'Add :ThrottleInterval integer 5' "$daemon"
/usr/libexec/PlistBuddy -c 'Add :Umask integer 63' "$daemon"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string $base/core.log" "$daemon"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $base/core.log" "$daemon"
/usr/sbin/chown root:wheel "$daemon"
/bin/chmod 644 "$daemon"
/usr/bin/plutil -lint "$daemon" >/dev/null
trap 'rollback; exit 1' ERR INT TERM
/bin/launchctl disable "gui/$user_id/$old_label"
/bin/launchctl bootout "gui/$user_id/$old_label" 2>/dev/null || true
/bin/launchctl bootout "system/$label" 2>/dev/null || true
/bin/launchctl bootstrap system "$daemon"
secret=$(/usr/bin/plutil -extract secret raw -o - "$base/config.yaml")
socket="$base/control.sock"
ready=0
for ((attempt=0; attempt<80; attempt++)); do
    status=$(printf 'header = "Authorization: Bearer %s"\n' "$secret" | /usr/bin/curl --config - --noproxy '*' --unix-socket "$socket" --max-time 1 -s -o /dev/null -w '%{http_code}' http://localhost/version || true)
    if [[ "$status" == 200 ]]; then ready=1; break; fi
    /bin/sleep 0.2
done
[[ "$ready" -eq 1 ]]
trap - ERR INT TERM
echo installed

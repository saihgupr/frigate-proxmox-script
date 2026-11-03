#!/usr/bin/env bash
#
# Tests that install.sh hands passwords to the container unchanged, whatever
# characters they contain, and never writes them to the log.
#
# No Proxmox host is needed. install.sh is loaded without running main, and
# `pct` is replaced by a function that records its arguments and stdin.
#
# Run: bash tests/test_password_handling.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A password with every character that breaks shell quoting
PASSWORD=$'it\'s a "test" $HOME `id` \ ;|&'

PASSED=0
FAILED=0
check() {
    local description="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ok    $description"
        PASSED=$((PASSED + 1))
    else
        echo "  FAIL  $description"
        echo "        expected: $(printf '%q' "$expected")"
        echo "        actual:   $(printf '%q' "$actual")"
        FAILED=$((FAILED + 1))
    fi
}

# Load the functions of install.sh without running it
source <(sed 's/^main "\$@"$//' "$ROOT/install.sh") > /dev/null
set +e

# Fake pct: each call appends its arguments (one per line) to calls/N.args,
# and its stdin to calls/N.stdin for the commands that read one
pct() {
    local n
    n=$(find "$WORK/calls" -name '*.args' 2>/dev/null | wc -l)
    mkdir -p "$WORK/calls"
    printf '%s\n' "$@" > "$WORK/calls/$n.args"
    case " $* " in
        *" chpasswd "*|*" smbpasswd "*|*"cat > "*) cat > "$WORK/calls/$n.stdin" ;;
    esac
}

stdin_of() {
    local f
    f=$(grep -lx -- "$1" "$WORK"/calls/*.args 2>/dev/null | head -1)
    [ -n "$f" ] && cat "${f%.args}.stdin"
}

reset() {
    rm -rf "$WORK/calls"
    LOG_FILE="$WORK/install.log"
    : > "$LOG_FILE"
    CT_ID=100
    TEMPLATE_STORAGE=local
    CT_STORAGE=local-lvm
}

echo "Case 1: root password at container creation"
reset; DRY_RUN=false; ROOT_PASSWORD="$PASSWORD"
create_lxc_container > /dev/null
args=$(cat "$WORK"/calls/0.args)
check "--password is followed by the password as one argument" \
    "$PASSWORD" "$(printf '%s\n' "$args" | grep -A1 -x -- '--password' | tail -1)"

echo "Case 2: SSH with its own user"
reset; DRY_RUN=false; ENABLE_SSH=yes; SSH_USER=frigateadmin; SSH_PASSWORD="$PASSWORD"
setup_ssh > /dev/null
check "chpasswd receives user:password" "frigateadmin:$PASSWORD" "$(stdin_of chpasswd)"

echo "Case 3: SSH as root"
reset; DRY_RUN=false; ENABLE_SSH=yes; SSH_USER=root; SSH_PASSWORD="$PASSWORD"
setup_ssh > /dev/null
check "chpasswd receives root:password" "root:$PASSWORD" "$(stdin_of chpasswd)"

echo "Case 4: Samba"
reset; DRY_RUN=false; ENABLE_SAMBA=yes; SAMBA_PASSWORD="$PASSWORD"
setup_samba > /dev/null
check "smbpasswd receives the password twice" "$PASSWORD"$'\n'"$PASSWORD" "$(stdin_of smbpasswd)"

echo "Case 5: dry run"
reset; DRY_RUN=true; ENABLE_SSH=yes; SSH_USER=root; SSH_PASSWORD="$PASSWORD"
setup_ssh > /dev/null
check "the password is not in the log" "no" "$(grep -qF -- "$PASSWORD" "$LOG_FILE" && echo yes || echo no)"

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]

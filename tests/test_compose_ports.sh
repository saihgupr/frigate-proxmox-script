#!/usr/bin/env bash
#
# Tests that the generated compose.yml exposes the go2rtc ports Home Assistant
# needs for streaming (issue #55).
#
# No Proxmox host is needed. install.sh is loaded without running main, and
# `pct` is replaced by a function that captures the generated compose file.
#
# Run: bash tests/test_compose_ports.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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

# Fake pct: capture the compose file it is asked to write
pct() {
    case " $* " in
        *"cat > /opt/frigate/compose.yml"*) cat > "$WORK/compose.yml" ;;
    esac
}

echo "Generated compose.yml exposes go2rtc streaming ports"

DRY_RUN=false
CT_ID=100
ENABLE_IGPU=no
SELECTED_GPU_TYPE=none
DETECTED_CORAL=none
ENABLE_CUSTOM_SSL=no
FRIGATE_PORT=5000
GO2RTC_PORT=1984
AUTH_PORT=8971
FRIGATE_VERSION=stable
SHM_SIZE=512mb
LOG_FILE="$WORK/install.log"
: > "$LOG_FILE"

create_docker_compose > /dev/null

compose=$(cat "$WORK/compose.yml" 2>/dev/null)
check "RTSP port 8554 is published" \
    "yes" "$(grep -qx '      - "8554:8554"' <<< "$compose" && echo yes || echo no)"
check "WebRTC TCP port 8555 is published" \
    "yes" "$(grep -qx '      - "8555:8555/tcp"' <<< "$compose" && echo yes || echo no)"
check "WebRTC UDP port 8555 is published" \
    "yes" "$(grep -qx '      - "8555:8555/udp"' <<< "$compose" && echo yes || echo no)"
check "configured web, go2rtc and auth ports are still published" \
    "3" "$(grep -cE '^      - "(5000:5000|1984:1984|8971:8971)"$' <<< "$compose")"

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]

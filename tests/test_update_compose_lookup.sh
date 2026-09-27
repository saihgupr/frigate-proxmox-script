#!/usr/bin/env bash
#
# Tests how update.sh finds the Frigate compose file inside the container.
#
# No Proxmox host or network is needed. `pct` and `docker` are replaced by small
# fake scripts, and every container path (/opt, /home, /data, ...) is redirected
# into a temporary folder on this machine.
#
# Run: bash tests/test_update_compose_lookup.sh

# ---------------------------------------------------------------------------
# Test cases
#
# Each row is one test.
#
#   description       what the test is about
#   args              extra arguments passed to update.sh
#   label             working_dir reported by `docker inspect frigate`
#   frigate file      compose file that uses the Frigate image
#   unrelated files   compose files for other apps (space separated)
#
# Expected result:
#   - If a Frigate file is given, it must be updated and used for docker compose.
#   - If no Frigate file is given, update.sh must fail.
#   - Unrelated files must never be modified.
# ---------------------------------------------------------------------------
CASES=(
#  description                          | args              | label      | frigate file                     | unrelated files
  "--dir with nonstandard path          | --dir /data/nvr   | -          | /data/nvr/docker-compose.yml     | -"
  "compose.yaml found via docker label  | -                 | /data/cams | /data/cams/compose.yaml          | -"
  "skips unrelated file in common path  | -                 | -          | /home/frigate/docker-compose.yml | /opt/frigate/compose.yml"
  "skips unrelated file in same folder  | --dir /srv/nvr    | -          | /srv/nvr/docker-compose.yml      | /srv/nvr/compose.yml"
  "find fallback skips unrelated file   | -                 | -          | /mnt/storage/nvr/compose.yaml    | /opt/other/compose.yaml"
  "fails when --dir has no Frigate file | --dir /data/other | -          | -                                | /data/other/docker-compose.yml"
  "fails when no Frigate file anywhere  | -                 | -          | -                                | /opt/frigate/compose.yml"
)

FRIGATE_COMPOSE='version: "3.9"
services:
  frigate:
    image: ghcr.io/blakeblackshear/frigate:0.16.0
'

UNRELATED_COMPOSE='version: "3.9"
services:
  web:
    image: nginx:latest
'

NEW_VERSION="0.17.0"

# ---------------------------------------------------------------------------
# Fake pct and docker commands
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
FAKE_BIN="$WORK_DIR/bin"
mkdir -p "$FAKE_BIN"

# Fake pct:
#   pct status / pct snapshot  -> always succeed
#   pct exec <id> -- <cmd>     -> run <cmd> here, with container paths moved under $FAKE_ROOT
cat > "$FAKE_BIN/pct" <<'EOF'
#!/usr/bin/env bash
CONTAINER_DIRS="home opt root srv mnt data"

case "$1" in
    status)   echo "status: running"; exit 0 ;;
    snapshot) exit 0 ;;
esac
shift 3   # drop "exec <id> --"

# Commands whose output update.sh only needs to be plausible
case "$1" in
    df)       echo "Avail"; echo "999999999"; exit 0 ;;
    hostname) echo "10.0.0.2"; exit 0 ;;
esac

# `bash -c '<script>'`: move container paths inside the script text
command=()
if [ "$1" = "bash" ] && [ "$2" = "-c" ]; then
    script="$3"
    for dir in $CONTAINER_DIRS; do
        script="${script// \/$dir/ $FAKE_ROOT/$dir}"
    done
    command=(bash -c "$script")
    shift 3
fi

# macOS sed needs `-i ''` where GNU sed takes `-i`
is_bsd_sed=false
if [ "$1" = "sed" ] && ! sed --version >/dev/null 2>&1; then
    is_bsd_sed=true
fi

# Move every container path argument under $FAKE_ROOT
for arg in "$@"; do
    if [ "$is_bsd_sed" = true ] && [ "$arg" = "-i" ]; then
        command+=(-i "")
        continue
    fi
    for dir in $CONTAINER_DIRS; do
        case "$arg" in
            "/$dir" | "/$dir/"*) arg="$FAKE_ROOT$arg"; break ;;
        esac
    done
    command+=("$arg")
done

exec "${command[@]}"
EOF

# Fake docker:
#   docker inspect  -> prints $DOCKER_LABEL (fails if empty)
#   anything else   -> recorded in $DOCKER_LOG as "<current folder> <arguments>"
cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "inspect" ]; then
    [ -n "$DOCKER_LABEL" ] || exit 1
    echo "$DOCKER_LABEL"
    exit 0
fi
echo "$PWD $*" >> "$DOCKER_LOG"
EOF

chmod +x "$FAKE_BIN/pct" "$FAKE_BIN/docker"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
PASSED=0
FAILED=0

trim() {
    echo "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Turn "-" into an empty value
value_or_empty() {
    if [ "$1" = "-" ]; then echo ""; else echo "$1"; fi
}

# Create a compose file inside the fake container
create_file() {
    local path="$FAKE_ROOT$1"
    local content="$2"
    mkdir -p "$(dirname "$path")"
    printf '%s' "$content" > "$path"
}

# Record the result of one check
check() {
    local description="$1"
    local result="$2"
    if [ "$result" = "ok" ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        CASE_FAILED=true
        echo "    FAIL: $description"
    fi
}

ok_if() {
    if "$@"; then echo "ok"; else echo "fail"; fi
}

file_unchanged()   { [ "$(cat "$FAKE_ROOT$1")" = "$(printf '%s' "$2")" ]; }
file_contains()    { grep -q "$2" "$FAKE_ROOT$1"; }
file_lacks()       { ! grep -q "$2" "$FAKE_ROOT$1"; }
docker_was_run()   { grep -qxF "$FAKE_ROOT$1" "$DOCKER_LOG"; }
docker_never_run() { [ ! -s "$DOCKER_LOG" ]; }

# ---------------------------------------------------------------------------
# Run every case
# ---------------------------------------------------------------------------
case_number=0
for row in "${CASES[@]}"; do
    case_number=$((case_number + 1))

    IFS='|' read -r description args label frigate_file unrelated_files <<< "$row"
    description=$(trim "$description")
    args=$(value_or_empty "$(trim "$args")")
    label=$(value_or_empty "$(trim "$label")")
    frigate_file=$(value_or_empty "$(trim "$frigate_file")")
    unrelated_files=$(value_or_empty "$(trim "$unrelated_files")")

    echo "Case $case_number: $description"

    # Fresh fake container for this case
    FAKE_ROOT="$WORK_DIR/case$case_number"
    DOCKER_LOG="$WORK_DIR/case$case_number.docker.log"
    CASE_FAILED=false
    mkdir -p "$FAKE_ROOT"
    : > "$DOCKER_LOG"

    if [ -n "$frigate_file" ]; then
        create_file "$frigate_file" "$FRIGATE_COMPOSE"
    fi
    for file in $unrelated_files; do
        create_file "$file" "$UNRELATED_COMPOSE"
    done

    # Run update.sh non-interactively: container 100, fixed version, snapshot on (skips the prompt)
    # shellcheck disable=SC2086  # $args must split into separate arguments
    output=$(
        PATH="$FAKE_BIN:$PATH" FAKE_ROOT="$FAKE_ROOT" DOCKER_LOG="$DOCKER_LOG" DOCKER_LABEL="$label" \
            bash "$(dirname "$0")/../update.sh" -i 100 -v "$NEW_VERSION" -s $args 2>&1 < /dev/null
    )
    exit_code=$?

    # Unrelated files must never be touched
    for file in $unrelated_files; do
        check "$file should be unchanged" "$(ok_if file_unchanged "$file" "$UNRELATED_COMPOSE")"
    done

    if [ -z "$frigate_file" ]; then
        # No Frigate file: update.sh must stop before running docker compose
        check "update.sh should fail (exit code was $exit_code)" "$(ok_if [ "$exit_code" -ne 0 ])"
        check "docker compose should not run" "$(ok_if docker_never_run)"
    else
        # Frigate file: it must be updated and used for pull + up
        folder=$(dirname "$frigate_file")
        name=$(basename "$frigate_file")
        check "update.sh should succeed (exit code was $exit_code)" "$(ok_if [ "$exit_code" -eq 0 ])"
        check "$frigate_file should use frigate:$NEW_VERSION" "$(ok_if file_contains "$frigate_file" "frigate:$NEW_VERSION")"
        check "$frigate_file should have no version: line" "$(ok_if file_lacks "$frigate_file" "^version:")"
        check "docker compose pull should run in $folder" "$(ok_if docker_was_run "$folder compose -f $name pull")"
        check "docker compose up should run in $folder" "$(ok_if docker_was_run "$folder compose -f $name up -d")"
    fi

    if [ "$CASE_FAILED" = true ]; then
        echo "    update.sh output:"
        echo "$output" | sed 's/^/      /'
    fi
done

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]

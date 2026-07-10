#!/usr/bin/env bash
###############################################################################
# hdfs_datanode_restart_jmx_controller_v2.sh
#
# NON-INTERACTIVE no-SSH controller for phased HDFS DataNode restart.
#
# Dry-run:
#   ./hdfs_datanode_restart_jmx_controller_v2.sh --env DEV
#
# Real execution:
#   ./hdfs_datanode_restart_jmx_controller_v2.sh --env DEV --execute
#
# Default health check retry:
#   - every 5 minutes
#   - up to 3 hours
#   - override with --timeout MIN and --interval SEC
#
# This script has:
#   - no read command
#   - no curl --user
#   - no interactive credential prompt
#   - no --ambari-url / --ambari-user / --ambari-password arguments
#
# Ambari details are loaded only from same-folder config files:
#   DEV  -> dev_ambari.conf
#   PAT  -> pat_ambari.conf
#   PROD -> prod_ambari.conf
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENVIRONMENT=""
BATCH_SIZE=1
CHECK_INTERVAL_SEC=300
WAIT_TIMEOUT_MIN=180
CURL_INSECURE=false
EXECUTE=false
LOG_DIR="$SCRIPT_DIR/hdfs_jmx_rollout_logs"

DEV_JMX_URL_DEFAULT="https://dev-hdfs.azure.com/jmx"
PAT_JMX_URL_DEFAULT="https://pat-hdfs.azure.com/jmx"
PROD_JMX_URL_DEFAULT="https://prod-hdfs.azure.com/jmx"

AMBARI_COMPONENT="DATANODE"

usage() {
  cat <<USAGE
Usage:
  $0 --env DEV|PAT|PROD [options]

Required:
  --env ENV              DEV, PAT, or PROD

Options:
  --execute              Actually restart DataNodes. Without this, dry-run mode is used.
  --batch-size N         DataNodes per batch. Default: 1
  --interval SEC         Polling interval. Default: 300 seconds / 5 minutes
  --timeout MIN          Wait timeout for health checks. Default: 180 minutes / 3 hours
  --insecure             Use curl -k for HTTPS certificate issues
  --log-dir DIR          Log directory
  --help                 Show help

Not supported:
  --ambari-url
  --ambari-user
  --ambari-password
  --ambari-password-file
  --cluster
  --ambari-cluster
  --yes
  --dry-run

Config files expected in same folder as this script:
  dev_ambari.conf, pat_ambari.conf, prod_ambari.conf
  dev_datanodes.txt, pat_datanodes.txt, prod_datanodes.txt

Examples:
  $0 --env DEV
  $0 --env DEV --execute --insecure
USAGE
}

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*"; }
die() { echo "[$(timestamp)] ERROR: $*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENVIRONMENT="${2:-}"; shift 2 ;;
    --execute) EXECUTE=true; shift ;;
    --batch-size) BATCH_SIZE="${2:-}"; shift 2 ;;
    --interval) CHECK_INTERVAL_SEC="${2:-}"; shift 2 ;;
    --timeout) WAIT_TIMEOUT_MIN="${2:-}"; shift 2 ;;
    --insecure) CURL_INSECURE=true; shift ;;
    --log-dir) LOG_DIR="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --ambari-url|--ambari-user|--ambari-password|--ambari-password-file|--cluster|--ambari-cluster|--yes|-y|--dry-run)
      die "$1 is not supported. Ambari values must be in the env config file."
      ;;
    *) die "Unknown argument: $1. Use --help." ;;
  esac
done

require_command curl
require_command python3
require_command base64

[[ -n "$ENVIRONMENT" ]] || die "--env is required."
ENVIRONMENT="$(echo "$ENVIRONMENT" | tr '[:lower:]' '[:upper:]')"

case "$ENVIRONMENT" in
  DEV)
    AMBARI_CONF_FILE="$SCRIPT_DIR/dev_ambari.conf"
    SERVER_LIST_FILE="$SCRIPT_DIR/dev_datanodes.txt"
    JMX_URL="$DEV_JMX_URL_DEFAULT"
    ;;
  PAT)
    AMBARI_CONF_FILE="$SCRIPT_DIR/pat_ambari.conf"
    SERVER_LIST_FILE="$SCRIPT_DIR/pat_datanodes.txt"
    JMX_URL="$PAT_JMX_URL_DEFAULT"
    ;;
  PROD)
    AMBARI_CONF_FILE="$SCRIPT_DIR/prod_ambari.conf"
    SERVER_LIST_FILE="$SCRIPT_DIR/prod_datanodes.txt"
    JMX_URL="$PROD_JMX_URL_DEFAULT"
    ;;
  *) die "Invalid --env '$ENVIRONMENT'. Must be DEV, PAT, or PROD." ;;
esac

[[ -f "$AMBARI_CONF_FILE" ]] || die "Ambari config file not found: $AMBARI_CONF_FILE"
[[ -f "$SERVER_LIST_FILE" ]] || die "DataNode server list file not found: $SERVER_LIST_FILE"

AMBARI_URL=""
AMBARI_CLUSTER=""
AMBARI_USER=""
AMBARI_PASSWORD=""
AMBARI_AUTH_HEADER=""
JMX_AUTH_HEADER=""
JMX_URL_OVERRIDE=""

# shellcheck disable=SC1090
source "$AMBARI_CONF_FILE"

if [[ -n "${JMX_URL_OVERRIDE:-}" ]]; then
  JMX_URL="$JMX_URL_OVERRIDE"
fi

AMBARI_URL="$(printf "%s" "${AMBARI_URL:-}" | tr -d '\r')"
AMBARI_CLUSTER="$(printf "%s" "${AMBARI_CLUSTER:-}" | tr -d '\r')"
AMBARI_USER="$(printf "%s" "${AMBARI_USER:-}" | tr -d '\r')"
AMBARI_PASSWORD="$(printf "%s" "${AMBARI_PASSWORD:-}" | tr -d '\r')"
AMBARI_AUTH_HEADER="$(printf "%s" "${AMBARI_AUTH_HEADER:-}" | tr -d '\r')"
JMX_AUTH_HEADER="$(printf "%s" "${JMX_AUTH_HEADER:-}" | tr -d '\r')"
JMX_URL="$(printf "%s" "${JMX_URL:-}" | tr -d '\r')"

[[ -n "$AMBARI_URL" ]] || die "AMBARI_URL is missing in $AMBARI_CONF_FILE"
[[ -n "$AMBARI_CLUSTER" ]] || die "AMBARI_CLUSTER is missing in $AMBARI_CONF_FILE"

if [[ -z "$AMBARI_AUTH_HEADER" ]]; then
  [[ -n "$AMBARI_USER" ]] || die "AMBARI_USER is missing in $AMBARI_CONF_FILE"
  [[ -n "$AMBARI_PASSWORD" ]] || die "AMBARI_PASSWORD is missing in $AMBARI_CONF_FILE"
  AMBARI_AUTH_HEADER="Authorization: Basic $(printf "%s:%s" "$AMBARI_USER" "$AMBARI_PASSWORD" | base64 | tr -d '\n\r')"
fi

[[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || die "--batch-size must be a number."
(( BATCH_SIZE >= 1 )) || die "--batch-size must be >= 1."
(( BATCH_SIZE <= 2 )) || die "--batch-size must be 1 or 2 for this safety controller."
[[ "$CHECK_INTERVAL_SEC" =~ ^[0-9]+$ ]] || die "--interval must be a number."
[[ "$WAIT_TIMEOUT_MIN" =~ ^[0-9]+$ ]] || die "--timeout must be a number."

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${ENVIRONMENT}_datanode_restart_$(date +%F_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

RUN_MODE="DRY-RUN"
if [[ "$EXECUTE" == "true" ]]; then
  RUN_MODE="EXECUTE"
fi

curl_common_args() {
  local args=("-sS" "--connect-timeout" "15" "--max-time" "120")
  if [[ "$CURL_INSECURE" == "true" ]]; then
    args+=("-k")
  fi
  printf "%s\n" "${args[@]}"
}

curl_jmx() {
  local args=()
  mapfile -t args < <(curl_common_args)
  if [[ -n "$JMX_AUTH_HEADER" ]]; then
    curl "${args[@]}" -H "$JMX_AUTH_HEADER" "$JMX_URL"
  else
    curl "${args[@]}" "$JMX_URL"
  fi
}

ambari_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local args=()
  mapfile -t args < <(curl_common_args)

  if [[ -n "$data" ]]; then
    curl "${args[@]}" \
      -H "$AMBARI_AUTH_HEADER" \
      -H "X-Requested-By: ambari" \
      -H "Content-Type: application/json" \
      -X "$method" \
      -d "$data" \
      "$AMBARI_URL$endpoint"
  else
    curl "${args[@]}" \
      -H "$AMBARI_AUTH_HEADER" \
      -H "X-Requested-By: ambari" \
      -H "Content-Type: application/json" \
      -X "$method" \
      "$AMBARI_URL$endpoint"
  fi
}

get_jmx_metrics() {
  local tmpfile
  tmpfile="$(mktemp)"
  if ! curl_jmx > "$tmpfile"; then
    rm -f "$tmpfile"
    return 1
  fi

  python3 - "$tmpfile" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"PARSE_ERROR={e}")
    sys.exit(2)

beans = data.get("beans", [])
wanted = {
    "MissingBlocks": 0,
    "MissingReplOneBlocks": 0,
    "CorruptBlocks": 0,
    "UnderReplicatedBlocks": 0,
    "PendingReplicationBlocks": 0,
    "PendingDeletionBlocks": 0,
    "ScheduledReplicationBlocks": 0,
    "NumLiveDataNodes": 0,
    "NumDeadDataNodes": 0,
    "CapacityTotal": 0,
    "CapacityUsed": 0,
    "CapacityRemaining": 0,
    "TotalLoad": 0,
    "BlocksTotal": 0,
}
aliases = {
    "MissingBlocks": ["MissingBlocks"],
    "MissingReplOneBlocks": ["MissingReplOneBlocks"],
    "CorruptBlocks": ["CorruptBlocks", "CorruptReplicaBlocks"],
    "UnderReplicatedBlocks": ["UnderReplicatedBlocks", "UnderReplicatedBlocksCount"],
    "PendingReplicationBlocks": ["PendingReplicationBlocks"],
    "PendingDeletionBlocks": ["PendingDeletionBlocks"],
    "ScheduledReplicationBlocks": ["ScheduledReplicationBlocks"],
    "NumLiveDataNodes": ["NumLiveDataNodes"],
    "NumDeadDataNodes": ["NumDeadDataNodes"],
    "CapacityTotal": ["CapacityTotal"],
    "CapacityUsed": ["CapacityUsed"],
    "CapacityRemaining": ["CapacityRemaining"],
    "TotalLoad": ["TotalLoad"],
    "BlocksTotal": ["BlocksTotal"],
}
for canonical, names in aliases.items():
    found = None
    for bean in beans:
        for name in names:
            if name in bean:
                found = bean.get(name)
                break
        if found is not None:
            break
    if found is not None:
        wanted[canonical] = found
for key, value in wanted.items():
    print(f"{key}={value}")
PY
  local rc=$?
  rm -f "$tmpfile"
  return $rc
}

metric_value() {
  local metrics="$1"
  local key="$2"
  echo "$metrics" | awk -F= -v k="$key" '$1==k {print $2; exit}'
}

normalize_number() {
  local value="${1:-0}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$value"
  else
    echo 0
  fi
}

print_metrics() {
  local metrics="$1"
  echo "$metrics" | egrep "MissingBlocks|MissingReplOneBlocks|CorruptBlocks|UnderReplicatedBlocks|PendingReplicationBlocks|PendingDeletionBlocks|ScheduledReplicationBlocks|NumLiveDataNodes|NumDeadDataNodes|CapacityTotal|CapacityUsed|CapacityRemaining|TotalLoad|BlocksTotal|PARSE_ERROR" || true
}

hdfs_health_gate_from_jmx() {
  local context="$1"
  local timeout_sec elapsed metrics parse_error missing corrupt under dead pending

  timeout_sec=$((WAIT_TIMEOUT_MIN * 60))
  elapsed=0

  log "Checking HDFS JMX health gate with retry: $context"
  log "Health gate timeout=${WAIT_TIMEOUT_MIN} minutes; interval=${CHECK_INTERVAL_SEC} seconds."

  while (( elapsed <= timeout_sec )); do
    metrics="$(get_jmx_metrics)" || die "Unable to get JMX metrics from $JMX_URL"
    print_metrics "$metrics"

    parse_error="$(metric_value "$metrics" "PARSE_ERROR")"
    if [[ -n "${parse_error:-}" ]]; then
      log "JMX parse error: $parse_error"
      log "Sleeping ${CHECK_INTERVAL_SEC}s before retry..."
      sleep "$CHECK_INTERVAL_SEC"
      elapsed=$((elapsed + CHECK_INTERVAL_SEC))
      continue
    fi

    missing="$(normalize_number "$(metric_value "$metrics" "MissingBlocks")")"
    corrupt="$(normalize_number "$(metric_value "$metrics" "CorruptBlocks")")"
    under="$(normalize_number "$(metric_value "$metrics" "UnderReplicatedBlocks")")"
    dead="$(normalize_number "$(metric_value "$metrics" "NumDeadDataNodes")")"
    pending="$(normalize_number "$(metric_value "$metrics" "PendingReplicationBlocks")")"

    if (( missing == 0 && corrupt == 0 && under == 0 && dead == 0 )); then
      log "JMX health gate passed for $context."
      return 0
    fi

    log "HDFS not healthy yet for $context."
    log "Current status: MissingBlocks=$missing CorruptBlocks=$corrupt UnderReplicatedBlocks=$under DeadDataNodes=$dead PendingReplicationBlocks=$pending"
    log "Sleeping ${CHECK_INTERVAL_SEC}s before retry..."
    sleep "$CHECK_INTERVAL_SEC"
    elapsed=$((elapsed + CHECK_INTERVAL_SEC))
  done

  die "Timed out after ${WAIT_TIMEOUT_MIN} minutes waiting for HDFS health gate: $context"
}

wait_until_jmx_healthy() {
  local context="$1"
  local timeout_sec elapsed metrics parse_error missing corrupt under dead pending
  timeout_sec=$((WAIT_TIMEOUT_MIN * 60))
  elapsed=0
  log "Waiting for HDFS JMX health after: $context"

  while (( elapsed <= timeout_sec )); do
    metrics="$(get_jmx_metrics)" || die "Unable to get JMX metrics from $JMX_URL"
    print_metrics "$metrics"

    parse_error="$(metric_value "$metrics" "PARSE_ERROR")"
    if [[ -n "${parse_error:-}" ]]; then
      die "JMX parse error: $parse_error"
    fi

    missing="$(normalize_number "$(metric_value "$metrics" "MissingBlocks")")"
    corrupt="$(normalize_number "$(metric_value "$metrics" "CorruptBlocks")")"
    under="$(normalize_number "$(metric_value "$metrics" "UnderReplicatedBlocks")")"
    dead="$(normalize_number "$(metric_value "$metrics" "NumDeadDataNodes")")"
    pending="$(normalize_number "$(metric_value "$metrics" "PendingReplicationBlocks")")"

    if (( missing > 0 || corrupt > 0 || dead > 0 )); then
      die "Critical JMX status. Missing=$missing Corrupt=$corrupt DeadDataNodes=$dead"
    fi

    if (( under == 0 )); then
      log "HDFS JMX health is healthy after $context."
      return 0
    fi

    log "Still recovering. UnderReplicated=$under PendingReplication=$pending. Sleeping ${CHECK_INTERVAL_SEC}s..."
    sleep "$CHECK_INTERVAL_SEC"
    elapsed=$((elapsed + CHECK_INTERVAL_SEC))
  done
  die "Timed out waiting for HDFS to become healthy after $context."
}

ambari_component_state() {
  local host="$1"
  local endpoint="/api/v1/clusters/${AMBARI_CLUSTER}/hosts/${host}/host_components/${AMBARI_COMPONENT}?fields=HostRoles/state"
  local result
  result="$(ambari_api "GET" "$endpoint" || true)"
  python3 -c 'import json,sys
try:
    data=json.loads(sys.stdin.read())
    print(data.get("HostRoles",{}).get("state","UNKNOWN"))
except Exception:
    print("UNKNOWN")' <<< "$result"
}

ambari_stop_datanode() {
  local host="$1"
  local endpoint="/api/v1/clusters/${AMBARI_CLUSTER}/hosts/${host}/host_components/${AMBARI_COMPONENT}"
  local payload='{"RequestInfo":{"context":"Stop HDFS DataNode via non-interactive JMX controller"},"Body":{"HostRoles":{"state":"INSTALLED"}}}'
  if [[ "$EXECUTE" != "true" ]]; then
    log "[DRY-RUN] Would stop DATANODE on $host using Ambari API."
    return 0
  fi
  log "Stopping DATANODE on $host via Ambari API..."
  ambari_api "PUT" "$endpoint" "$payload" >/dev/null
}

ambari_start_datanode() {
  local host="$1"
  local endpoint="/api/v1/clusters/${AMBARI_CLUSTER}/hosts/${host}/host_components/${AMBARI_COMPONENT}"
  local payload='{"RequestInfo":{"context":"Start HDFS DataNode via non-interactive JMX controller"},"Body":{"HostRoles":{"state":"STARTED"}}}'
  if [[ "$EXECUTE" != "true" ]]; then
    log "[DRY-RUN] Would start DATANODE on $host using Ambari API."
    return 0
  fi
  log "Starting DATANODE on $host via Ambari API..."
  ambari_api "PUT" "$endpoint" "$payload" >/dev/null
}

wait_for_component_state() {
  local host="$1"
  local expected="$2"
  local timeout_sec elapsed state
  timeout_sec=$((WAIT_TIMEOUT_MIN * 60))
  elapsed=0

  if [[ "$EXECUTE" != "true" ]]; then
    log "[DRY-RUN] Would wait for DATANODE on $host to become $expected."
    return 0
  fi

  while (( elapsed <= timeout_sec )); do
    state="$(ambari_component_state "$host")"
    log "Ambari state for $host DATANODE: $state"
    if [[ "$state" == "$expected" ]]; then
      log "$host DATANODE reached $expected."
      return 0
    fi
    sleep "$CHECK_INTERVAL_SEC"
    elapsed=$((elapsed + CHECK_INTERVAL_SEC))
  done
  die "Timed out waiting for $host DATANODE to reach $expected."
}

restart_datanode_via_ambari() {
  local host="$1"
  log "Restart sequence for DATANODE on $host"
  log "Current Ambari state: $(ambari_component_state "$host")"
  ambari_stop_datanode "$host"
  wait_for_component_state "$host" "INSTALLED"
  ambari_start_datanode "$host"
  wait_for_component_state "$host" "STARTED"
  log "DATANODE restart completed on $host"
}

load_servers() {
  grep -v '^[[:space:]]*#' "$SERVER_LIST_FILE" | sed '/^[[:space:]]*$/d'
}

process_batch() {
  local batch_id="$1"
  shift
  local hosts=("$@")
  local host_list
  host_list="$(printf "%s " "${hosts[@]}")"

  log "===================================================================="
  log "Batch $batch_id starting"
  log "Environment: $ENVIRONMENT"
  log "Mode: $RUN_MODE"
  log "JMX URL: $JMX_URL"
  log "Server list: $SERVER_LIST_FILE"
  log "Ambari URL: $AMBARI_URL"
  log "Ambari cluster: $AMBARI_CLUSTER"
  log "Hosts in this batch: $host_list"
  log "===================================================================="

  hdfs_health_gate_from_jmx "before batch $batch_id"

  for host in "${hosts[@]}"; do
    restart_datanode_via_ambari "$host"
  done

  wait_until_jmx_healthy "DataNode restart for batch $batch_id"
  log "Batch $batch_id completed successfully."
}

log "Starting HDFS DataNode restart JMX controller."
log "Script directory=$SCRIPT_DIR"
log "Environment=$ENVIRONMENT"
log "Mode=$RUN_MODE"
log "JMX_URL=$JMX_URL"
log "Server list=$SERVER_LIST_FILE"
log "Ambari config file=$AMBARI_CONF_FILE"
log "Batch size=$BATCH_SIZE"
log "Curl insecure=$CURL_INSECURE"
log "Ambari URL=$AMBARI_URL"
log "Ambari cluster=$AMBARI_CLUSTER"
log "Ambari user=${AMBARI_USER:-AUTH_HEADER_MODE}"
log "Log file=$LOG_FILE"

mapfile -t SERVERS < <(load_servers)
if (( ${#SERVERS[@]} == 0 )); then
  die "No servers found in $SERVER_LIST_FILE"
fi

log "Loaded ${#SERVERS[@]} servers."

hdfs_health_gate_from_jmx "initial startup check"

batch_id=1
batch=()

for host in "${SERVERS[@]}"; do
  batch+=("$host")
  if (( ${#batch[@]} == BATCH_SIZE )); then
    process_batch "$batch_id" "${batch[@]}"
    batch=()
    batch_id=$((batch_id + 1))
  fi
done

if (( ${#batch[@]} > 0 )); then
  process_batch "$batch_id" "${batch[@]}"
fi

log "All batches from $SERVER_LIST_FILE processed."
log "Final JMX health check:"
hdfs_health_gate_from_jmx "final check"
log "Controller completed successfully."

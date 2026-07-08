#!/usr/bin/env bash
###############################################################################
# hdfs_datanode_restart_jmx_controller.sh
#
# No-SSH controller for phased HDFS DataNode restart after Ambari config changes.
#
# Design:
#   - Ambari config/config-group changes are done manually before running.
#   - The script does NOT ask for filesystem name.
#   - The script does NOT perform OS unmount, fstab update, or Azure disk detach.
#   - The script uses NameNode JMX to make sure HDFS is healthy.
#   - The script uses Ambari REST API to restart DATANODE on selected hosts.
#   - The script processes hosts from DEV/PAT/PROD server-list files.
#
# Safety gates:
#   Before each batch:
#     MissingBlocks = 0
#     CorruptBlocks = 0
#     UnderReplicatedBlocks = 0
#     NumDeadDataNodes = 0
#
#   After each DataNode restart:
#     Wait until:
#       MissingBlocks = 0
#       CorruptBlocks = 0
#       UnderReplicatedBlocks = 0
#       NumDeadDataNodes = 0
#
# Requirements:
#   - bash
#   - curl
#   - python3
#   - Ambari API user with permission to stop/start host components
#
# Environments:
#   DEV  JMX default:     https://dev-hdfs.azure.com/jmx
#   PAT  JMX default:     https://pat-hdfs.azure.com/jmx
#   PROD JMX default:     https://prod-hdfs.azure.com/jmx
#
# Ambari URLs and cluster names can be supplied by CLI or env variables:
#   DEV_AMBARI_URL, PAT_AMBARI_URL, PROD_AMBARI_URL
#   DEV_CLUSTER_NAME, PAT_CLUSTER_NAME, PROD_CLUSTER_NAME
###############################################################################

set -u
set -o pipefail

#######################################
# Defaults
#######################################

ENVIRONMENT=""
SERVER_LIST_FILE=""
BATCH_SIZE=1
CHECK_INTERVAL_SEC=60
WAIT_TIMEOUT_MIN=360
CURL_INSECURE=false
DRY_RUN=false
AUTO_YES=false
LOG_DIR="./hdfs_jmx_rollout_logs"

AMBARI_URL=""
AMBARI_CLUSTER=""
AMBARI_USER="${AMBARI_USER:-}"
AMBARI_PASSWORD="${AMBARI_PASSWORD:-}"
AMBARI_PASSWORD_FILE=""

DEV_JMX_URL="${DEV_JMX_URL:-https://dev-hdfs.azure.com/jmx}"
PAT_JMX_URL="${PAT_JMX_URL:-https://pat-hdfs.azure.com/jmx}"
PROD_JMX_URL="${PROD_JMX_URL:-https://prod-hdfs.azure.com/jmx}"

DEV_SERVER_LIST="${DEV_SERVER_LIST:-./dev_datanodes.txt}"
PAT_SERVER_LIST="${PAT_SERVER_LIST:-./pat_datanodes.txt}"
PROD_SERVER_LIST="${PROD_SERVER_LIST:-./prod_datanodes.txt}"

DEV_AMBARI_URL="${DEV_AMBARI_URL:-}"
PAT_AMBARI_URL="${PAT_AMBARI_URL:-}"
PROD_AMBARI_URL="${PROD_AMBARI_URL:-}"

DEV_CLUSTER_NAME="${DEV_CLUSTER_NAME:-}"
PAT_CLUSTER_NAME="${PAT_CLUSTER_NAME:-}"
PROD_CLUSTER_NAME="${PROD_CLUSTER_NAME:-}"

AMBARI_COMPONENT="DATANODE"
AMBARI_SERVICE="HDFS"

#######################################
# Help
#######################################

usage() {
  cat <<'USAGE'
Usage:
  ./hdfs_datanode_restart_jmx_controller.sh --env DEV|PAT|PROD [options]

Required:
  --env ENV                    DEV, PAT, or PROD
  --ambari-url URL             Ambari URL, for example https://dev-ambari.azure.com:8443
                               Can also be set with DEV_AMBARI_URL, PAT_AMBARI_URL, PROD_AMBARI_URL.
  --cluster NAME               Ambari cluster name
                               Can also be set with DEV_CLUSTER_NAME, PAT_CLUSTER_NAME, PROD_CLUSTER_NAME.
  --ambari-user USER           Ambari username, or env AMBARI_USER
  --ambari-password PASS       Ambari password, or env AMBARI_PASSWORD
     OR
  --ambari-password-file FILE  File containing Ambari password

Options:
  --server-list FILE           DataNode host list file
  --batch-size N               DataNodes per batch. Default: 1
  --interval SEC               JMX/Ambari polling interval. Default: 60
  --timeout MIN                Wait timeout after restart. Default: 360
  --insecure                   Use curl -k for HTTPS certificate issues
  --dry-run                    Show what would happen but do not call restart API
  --yes                        Auto-confirm prompts
  --log-dir DIR                Log directory
  --help                       Show help

Examples:
  ./hdfs_datanode_restart_jmx_controller.sh     --env DEV     --ambari-url https://dev-ambari.azure.com:8443     --cluster HDPDEV     --ambari-user admin     --ambari-password-file ./ambari.pass     --server-list ./dev_datanodes.txt     --batch-size 1     --insecure

  AMBARI_USER=admin AMBARI_PASSWORD='secret' \
  ./hdfs_datanode_restart_jmx_controller.sh \
    --env PROD \
    --ambari-url https://prod-ambari.azure.com:8443 \
    --cluster HDPPROD \
    --server-list ./prod_datanodes.txt \
    --batch-size 1

Server list format:
  # one DataNode hostname per line
  dn01.company.com
  dn02.company.com

Important:
  Run this only after Ambari config/config-group was updated manually.
USAGE
}

#######################################
# Logging / utilities
#######################################

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(timestamp)] $*"; }
die() { echo "[$(timestamp)] ERROR: $*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

#######################################
# Parse args
#######################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENVIRONMENT="${2:-}"; shift 2 ;;
    --server-list) SERVER_LIST_FILE="${2:-}"; shift 2 ;;
    --batch-size) BATCH_SIZE="${2:-}"; shift 2 ;;
    --interval) CHECK_INTERVAL_SEC="${2:-}"; shift 2 ;;
    --timeout) WAIT_TIMEOUT_MIN="${2:-}"; shift 2 ;;
    --insecure) CURL_INSECURE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y) AUTO_YES=true; shift ;;
    --log-dir) LOG_DIR="${2:-}"; shift 2 ;;
    --ambari-url) AMBARI_URL="${2:-}"; shift 2 ;;
    --cluster|--ambari-cluster) AMBARI_CLUSTER="${2:-}"; shift 2 ;;
    --ambari-user) AMBARI_USER="${2:-}"; shift 2 ;;
    --ambari-password) AMBARI_PASSWORD="${2:-}"; shift 2 ;;
    --ambari-password-file) AMBARI_PASSWORD_FILE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1. Use --help." ;;
  esac
done

require_command curl
require_command python3

[[ -n "$ENVIRONMENT" ]] || die "--env is required."
ENVIRONMENT="$(echo "$ENVIRONMENT" | tr '[:lower:]' '[:upper:]')"

case "$ENVIRONMENT" in
  DEV)
    JMX_URL="$DEV_JMX_URL"
    [[ -n "$SERVER_LIST_FILE" ]] || SERVER_LIST_FILE="$DEV_SERVER_LIST"
    [[ -n "$AMBARI_URL" ]] || AMBARI_URL="$DEV_AMBARI_URL"
    [[ -n "$AMBARI_CLUSTER" ]] || AMBARI_CLUSTER="$DEV_CLUSTER_NAME"
    ;;
  PAT)
    JMX_URL="$PAT_JMX_URL"
    [[ -n "$SERVER_LIST_FILE" ]] || SERVER_LIST_FILE="$PAT_SERVER_LIST"
    [[ -n "$AMBARI_URL" ]] || AMBARI_URL="$PAT_AMBARI_URL"
    [[ -n "$AMBARI_CLUSTER" ]] || AMBARI_CLUSTER="$PAT_CLUSTER_NAME"
    ;;
  PROD)
    JMX_URL="$PROD_JMX_URL"
    [[ -n "$SERVER_LIST_FILE" ]] || SERVER_LIST_FILE="$PROD_SERVER_LIST"
    [[ -n "$AMBARI_URL" ]] || AMBARI_URL="$PROD_AMBARI_URL"
    [[ -n "$AMBARI_CLUSTER" ]] || AMBARI_CLUSTER="$PROD_CLUSTER_NAME"
    ;;
  *)
    die "Invalid --env '$ENVIRONMENT'. Must be DEV, PAT, or PROD."
    ;;
esac

[[ -f "$SERVER_LIST_FILE" ]] || die "Server list file not found: $SERVER_LIST_FILE"
[[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || die "--batch-size must be a number."
(( BATCH_SIZE >= 1 )) || die "--batch-size must be >= 1."
[[ "$CHECK_INTERVAL_SEC" =~ ^[0-9]+$ ]] || die "--interval must be a number."
[[ "$WAIT_TIMEOUT_MIN" =~ ^[0-9]+$ ]] || die "--timeout must be a number."

[[ -n "$AMBARI_URL" ]] || die "--ambari-url is required, or set ${ENVIRONMENT}_AMBARI_URL."
[[ -n "$AMBARI_CLUSTER" ]] || die "--cluster is required, or set ${ENVIRONMENT}_CLUSTER_NAME."
[[ -n "$AMBARI_USER" ]] || die "--ambari-user is required, or set AMBARI_USER."

if [[ -n "$AMBARI_PASSWORD_FILE" ]]; then
  [[ -f "$AMBARI_PASSWORD_FILE" ]] || die "Password file not found: $AMBARI_PASSWORD_FILE"
  AMBARI_PASSWORD="$(tr -d '\r\n' < "$AMBARI_PASSWORD_FILE")"
fi

[[ -n "$AMBARI_PASSWORD" ]] || die "--ambari-password or --ambari-password-file is required, or set AMBARI_PASSWORD."

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${ENVIRONMENT}_datanode_restart_$(date +%F_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

#######################################
# Curl helpers
#######################################

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
  curl "${args[@]}" "$JMX_URL"
}

ambari_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  local args=()
  mapfile -t args < <(curl_common_args)

  if [[ -n "$data" ]]; then
    curl "${args[@]}"       -u "$AMBARI_USER:$AMBARI_PASSWORD"       -H "X-Requested-By: ambari"       -H "Content-Type: application/json"       -X "$method"       -d "$data"       "$AMBARI_URL$endpoint"
  else
    curl "${args[@]}"       -u "$AMBARI_USER:$AMBARI_PASSWORD"       -H "X-Requested-By: ambari"       -H "Content-Type: application/json"       -X "$method"       "$AMBARI_URL$endpoint"
  fi
}

#######################################
# JMX metrics
#######################################

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

for k, v in wanted.items():
    print(f"{k}={v}")
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
  local metrics parse_error missing corrupt under dead

  log "Checking HDFS JMX health gate: $context"
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

  if (( missing > 0 )); then die "MissingBlocks=$missing. Stop rollout."; fi
  if (( corrupt > 0 )); then die "CorruptBlocks=$corrupt. Stop rollout."; fi
  if (( dead > 0 )); then die "NumDeadDataNodes=$dead. Stop rollout."; fi
  if (( under > 0 )); then die "UnderReplicatedBlocks=$under. Wait until zero before restart/next batch."; fi

  log "JMX health gate passed: Missing=0, Corrupt=0, UnderReplicated=0, DeadDataNodes=0."
}

wait_until_jmx_healthy() {
  local context="$1"
  local timeout_sec elapsed metrics parse_error missing corrupt under dead pending
  timeout_sec=$((WAIT_TIMEOUT_MIN * 60))
  elapsed=0

  log "Waiting for HDFS JMX health after: $context"
  log "Timeout=${WAIT_TIMEOUT_MIN} minutes; interval=${CHECK_INTERVAL_SEC} seconds."

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
      log "HDFS JMX health is healthy. UnderReplicated=0, Missing=0, Corrupt=0, DeadDataNodes=0."
      return 0
    fi

    log "Still recovering. UnderReplicated=$under PendingReplication=$pending. Sleeping ${CHECK_INTERVAL_SEC}s..."
    sleep "$CHECK_INTERVAL_SEC"
    elapsed=$((elapsed + CHECK_INTERVAL_SEC))
  done

  die "Timed out waiting for HDFS to become healthy after $context."
}

#######################################
# Ambari DataNode restart
#######################################

ambari_component_state() {
  local host="$1"
  local endpoint="/api/v1/clusters/${AMBARI_CLUSTER}/hosts/${host}/host_components/${AMBARI_COMPONENT}?fields=HostRoles/state"
  ambari_api "GET" "$endpoint" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("HostRoles",{}).get("state","UNKNOWN"))' 2>/dev/null || echo "UNKNOWN"
}

ambari_stop_datanode() {
  local host="$1"
  local endpoint="/api/v1/clusters/${AMBARI_CLUSTER}/hosts/${host}/host_components/${AMBARI_COMPONENT}"
  local payload='{"RequestInfo":{"context":"Stop HDFS DataNode via disk removal controller"},"Body":{"HostRoles":{"state":"INSTALLED"}}}'

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] Would stop DATANODE on $host using Ambari API."
    return 0
  fi

  log "Stopping DATANODE on $host via Ambari API..."
  ambari_api "PUT" "$endpoint" "$payload" >/tmp/ambari_stop_${host//[^A-Za-z0-9]/_}.json
  cat /tmp/ambari_stop_${host//[^A-Za-z0-9]/_}.json
}

ambari_start_datanode() {
  local host="$1"
  local endpoint="/api/v1/clusters/${AMBARI_CLUSTER}/hosts/${host}/host_components/${AMBARI_COMPONENT}"
  local payload='{"RequestInfo":{"context":"Start HDFS DataNode via disk removal controller"},"Body":{"HostRoles":{"state":"STARTED"}}}'

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] Would start DATANODE on $host using Ambari API."
    return 0
  fi

  log "Starting DATANODE on $host via Ambari API..."
  ambari_api "PUT" "$endpoint" "$payload" >/tmp/ambari_start_${host//[^A-Za-z0-9]/_}.json
  cat /tmp/ambari_start_${host//[^A-Za-z0-9]/_}.json
}

wait_for_component_state() {
  local host="$1"
  local expected="$2"
  local timeout_sec elapsed state

  timeout_sec=$((WAIT_TIMEOUT_MIN * 60))
  elapsed=0

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY-RUN] Would wait for DATANODE on $host to become $expected."
    return 0
  fi

  log "Waiting for DATANODE on $host to reach state=$expected"

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

#######################################
# Batch processing
#######################################

load_servers() {
  grep -v '^[[:space:]]*#' "$SERVER_LIST_FILE" | sed '/^[[:space:]]*$/d'
}

confirm_or_exit() {
  local prompt="$1"
  if [[ "$AUTO_YES" == "true" ]]; then
    log "AUTO_YES=true: $prompt"
    return 0
  fi
  echo
  read -r -p "$prompt Type YES to continue: " answer
  if [[ "$answer" != "YES" ]]; then
    die "Operator did not confirm. Exiting."
  fi
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
  log "JMX URL: $JMX_URL"
  log "Ambari URL: $AMBARI_URL"
  log "Ambari cluster: $AMBARI_CLUSTER"
  log "Hosts in this batch: $host_list"
  log "===================================================================="

  hdfs_health_gate_from_jmx "before batch $batch_id"

  if [[ "$BATCH_SIZE" -gt 1 ]]; then
    confirm_or_exit "Batch $batch_id contains ${#hosts[@]} hosts. Confirm this batch size is approved."
  fi

  confirm_or_exit "HDFS JMX is clean. Proceed with Ambari API DataNode restart for batch $batch_id?"

  for host in "${hosts[@]}"; do
    restart_datanode_via_ambari "$host"
  done

  wait_until_jmx_healthy "DataNode restart for batch $batch_id"

  log "Batch $batch_id completed successfully."
}

#######################################
# Main
#######################################

log "Starting HDFS DataNode restart JMX controller."
log "Environment=$ENVIRONMENT"
log "JMX_URL=$JMX_URL"
log "Server list=$SERVER_LIST_FILE"
log "Batch size=$BATCH_SIZE"
log "Dry run=$DRY_RUN"
log "Curl insecure=$CURL_INSECURE"
log "Ambari URL=$AMBARI_URL"
log "Ambari cluster=$AMBARI_CLUSTER"
log "Ambari user=$AMBARI_USER"
log "Log file=$LOG_FILE"

mapfile -t SERVERS < <(load_servers)

if (( ${#SERVERS[@]} == 0 )); then
  die "No servers found in $SERVER_LIST_FILE"
fi

log "Loaded ${#SERVERS[@]} servers."

if (( BATCH_SIZE > 2 )); then
  echo
  echo "WARNING:"
  echo "  Batch size is $BATCH_SIZE."
  echo "  For replication factor 3 and active Spark jobs, 1-2 DataNodes per batch is safer."
  echo "  For replication factor 2, use 1 preferred and 2 maximum."
  echo
  confirm_or_exit "Do you still want to continue with batch size $BATCH_SIZE?"
fi

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

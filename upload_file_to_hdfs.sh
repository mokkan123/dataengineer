#!/usr/bin/env bash

set -Eeuo pipefail

DEFAULT_LOCAL_DIR="/app5"
DEFAULT_HDFS_DIR="/data"

command -v hdfs >/dev/null 2>&1 || {
  echo "ERROR: The hdfs command is not available in PATH." >&2
  exit 1
}

read -r -p "Enter local file path (example: /app5/test_file_100GB.dat): " LOCAL_FILE

if [[ -z "${LOCAL_FILE}" ]]; then
  echo "ERROR: A local file path is required." >&2
  exit 1
fi

if [[ ! -f "${LOCAL_FILE}" ]]; then
  echo "ERROR: Local file does not exist: ${LOCAL_FILE}" >&2
  exit 1
fi

if [[ ! -r "${LOCAL_FILE}" ]]; then
  echo "ERROR: Local file is not readable: ${LOCAL_FILE}" >&2
  exit 1
fi

read -r -p "Enter HDFS destination directory [${DEFAULT_HDFS_DIR}]: " HDFS_DIR
HDFS_DIR="${HDFS_DIR:-${DEFAULT_HDFS_DIR}}"

if [[ "${HDFS_DIR}" != /* ]]; then
  echo "ERROR: HDFS directory must be an absolute path beginning with /." >&2
  exit 1
fi

HDFS_FILE="${HDFS_DIR%/}/$(basename "${LOCAL_FILE}")"

if hdfs dfs -test -e "${HDFS_FILE}"; then
  echo "ERROR: HDFS destination already exists: ${HDFS_FILE}" >&2
  echo "Remove or rename it before uploading." >&2
  exit 1
fi

echo "Creating HDFS directory if needed: ${HDFS_DIR}"
hdfs dfs -mkdir -p "${HDFS_DIR}"

echo "Uploading ${LOCAL_FILE} to ${HDFS_DIR}/"
hdfs dfs -put "${LOCAL_FILE}" "${HDFS_DIR}/"

echo "Upload completed successfully:"
hdfs dfs -ls -h "${HDFS_FILE}"


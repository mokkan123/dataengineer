#!/usr/bin/env bash

set -Eeuo pipefail

LOCAL_DIR="/app5"
DEFAULT_SIZE_GB="100"

read -r -p "Enter file size in GB [${DEFAULT_SIZE_GB}]: " SIZE_GB
SIZE_GB="${SIZE_GB:-${DEFAULT_SIZE_GB}}"

if [[ ! "${SIZE_GB}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: Enter a positive whole number, such as 100." >&2
  exit 1
fi

DEFAULT_FILE="test_file_${SIZE_GB}GB.dat"
read -r -p "Enter file name [${DEFAULT_FILE}]: " FILE_NAME
FILE_NAME="${FILE_NAME:-${DEFAULT_FILE}}"

if [[ "${FILE_NAME}" == */* || "${FILE_NAME}" == "." || "${FILE_NAME}" == ".." ]]; then
  echo "ERROR: Enter a file name only, without a directory path." >&2
  exit 1
fi

LOCAL_FILE="${LOCAL_DIR}/${FILE_NAME}"

if [[ ! -d "${LOCAL_DIR}" ]]; then
  echo "ERROR: Directory does not exist: ${LOCAL_DIR}" >&2
  exit 1
fi

if [[ ! -w "${LOCAL_DIR}" ]]; then
  echo "ERROR: Directory is not writable: ${LOCAL_DIR}" >&2
  exit 1
fi

if [[ -e "${LOCAL_FILE}" ]]; then
  echo "ERROR: File already exists: ${LOCAL_FILE}" >&2
  exit 1
fi

command -v fallocate >/dev/null 2>&1 || {
  echo "ERROR: The fallocate command is not installed." >&2
  exit 1
}

required_bytes=$((SIZE_GB * 1024 * 1024 * 1024))
available_bytes=$(df --output=avail -B1 "${LOCAL_DIR}" | awk 'NR==2 {print $1}')

if (( available_bytes < required_bytes )); then
  echo "ERROR: Not enough free space in ${LOCAL_DIR}." >&2
  echo "Required: ${SIZE_GB} GiB" >&2
  df -h "${LOCAL_DIR}" >&2
  exit 1
fi

echo "Creating ${SIZE_GB} GiB file: ${LOCAL_FILE}"
fallocate -l "${SIZE_GB}G" "${LOCAL_FILE}"

echo "File created successfully:"
ls -lh "${LOCAL_FILE}"


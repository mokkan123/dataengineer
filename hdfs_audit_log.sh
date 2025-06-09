#!/bin/bash

# Path to the HDFS audit log file
AUDIT_LOG=${1:-/var/log/hadoop/hdfs/hdfs-audit.log}

if [[ ! -f "$AUDIT_LOG" ]]; then
  echo "Audit log not found at: $AUDIT_LOG"
  exit 1
fi

echo "Parsing HDFS audit log: $AUDIT_LOG"
echo "Extracting: user, command, and source directory..."

# Parse the log, extract user, command, and source path
awk -F' ' '
{
  for (i = 1; i <= NF; i++) {
    if ($i ~ /^ugi=/) { split($i, a, "="); user=a[2] }
    if ($i ~ /^cmd=/) { split($i, b, "="); cmd=b[2] }
    if ($i ~ /^src=/) { split($i, c, "="); src=c[2] }
  }
  if (user && cmd && src) {
    print user "\t" cmd "\t" src
    user=cmd=src=""
  }
}' "$AUDIT_LOG" | sort | uniq -c | sort -nr | head -30

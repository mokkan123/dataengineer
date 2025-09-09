#!/usr/bin/env bash
# create_smbcred.sh
# Creates /etc/smbcredentials/myshare.cred with username, password, and domain

set -euo pipefail

# ---------- Variables (EDIT THESE) ----------
SMB_USER="Ananthan"
SMB_PASS="Ananthan"
SMB_DOMAIN="Ananthan.com"
CRED_DIR="/etc/smbcredentials"
CRED_FILE="${CRED_DIR}/myshare.cred"

# ---------- Functions ----------
err(){ echo "ERROR: $*" >&2; exit 1; }
info(){ echo "==> $*"; }

# Must run as root
[[ "${EUID:-$(id -u)}" -eq 0 ]] || err "Please run as root (sudo)."

# ---------- Step 1: Create directory ----------
if [[ ! -d "${CRED_DIR}" ]]; then
  info "Creating directory ${CRED_DIR}"
  mkdir -p "${CRED_DIR}"
fi

# ---------- Step 2: Create credentials file ----------
info "Writing credentials to ${CRED_FILE}"
cat > "${CRED_FILE}" <<EOF
username=${SMB_USER}
password=${SMB_PASS}
domain=${SMB_DOMAIN}
EOF

# ---------- Step 3: Secure the file ----------
chmod 600 "${CRED_FILE}"
info "Credentials file created at ${CRED_FILE} with 600 permissions."

# ---------- Step 4: Show confirmation ----------
info "File contents (password masked):"
grep -v "password=" "${CRED_FILE}" || true
echo "password=********"

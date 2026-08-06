#!/usr/bin/env bash
# =============================================================================
# install-collections.sh - install and VERIFY every Ansible collection this
# project needs, on THIS machine.
#
# Collections must be present on whichever machine actually runs
# ansible-playbook - your workstation, not the remote AWS control node. AAP
# and EDA are configured entirely through REST API calls delegated to
# localhost specifically so ansible.controller and your SSH key never have to
# leave this machine; see the comment at the top of
# ansible/roles/demo_content/tasks/main.yml.
#
# bootstrap.sh and demo_content.sh both call this automatically, right after
# preflight.sh and before anything is built in AWS. Run it by hand to fix or
# verify a collection problem in isolation - it makes no AWS calls and touches
# nothing remote.
#
#   ./scripts/install-collections.sh
# =============================================================================
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# --- 1. workstation tooling + AAP bundle present ------------------------------
bash "${SCRIPT_DIR}/preflight.sh"

# --- 2. install + verify -----------------------------------------------------
install_all_collections

cat <<EOF

$(ok "DONE")  This machine can configure AAP as code.

  ANSIBLE_COLLECTIONS_PATH=${ANSIBLE_COLLECTIONS_PATH}

  Next:
    ./scripts/bootstrap.sh       everything, from nothing
    ./scripts/demo_content.sh    demo content only (needs existing infrastructure)
EOF

#!/usr/bin/env bash
# Verify the operator workstation has the required tooling and that the AAP
# containerized setup bundle is in place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

missing=0
check() {
  if command -v "$1" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$1"
  else
    printf '  MISS  %s\n' "$1"
    missing=1
  fi
}

echo "Checking prerequisites..."
for c in terraform aws ansible-playbook ansible-galaxy ssh ssh-keygen jq curl envsubst openssl tar; do
  check "$c"
done

if [[ "${missing}" -ne 0 ]]; then
  cat >&2 <<'EOF'

Missing tools. Install them, e.g.:
  - terraform      https://developer.hashicorp.com/terraform/install
  - aws (v2)       https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
  - ansible-core   pip install ansible-core   (provides ansible-playbook / ansible-galaxy)
  - jq, curl, gettext(envsubst), openssl, tar, openssh
EOF
  exit 1
fi

# --- AAP containerized setup bundle -----------------------------------------
# Also the source of the ansible.controller collection used to configure AAP,
# so it is required even if you plan to install AAP by hand.
echo
echo "Checking the AAP setup bundle..."
if compgen -G "${ROOT_DIR}/ansible/aap/*.tar.gz" >/dev/null 2>&1; then
  bundle="$(basename "$(compgen -G "${ROOT_DIR}/ansible/aap/*.tar.gz" | head -1)")"
  printf '  ok    %s\n' "${bundle}"
else
  cat >&2 <<EOF
  MISS  no *.tar.gz in ansible/aap/

Download the Ansible Automation Platform 2.6 CONTAINERIZED setup bundle and put
it in ansible/aap/:
  https://developers.redhat.com/products/ansible/download

bootstrap.sh also extracts the ansible.controller collection from this bundle to
configure AAP as code.
EOF
  exit 1
fi

echo
echo "All prerequisites present."

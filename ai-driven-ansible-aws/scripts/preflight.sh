#!/usr/bin/env bash
# Verify the operator workstation has the required tooling.
set -euo pipefail

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
for c in terraform aws ansible-playbook ansible-galaxy ssh ssh-keygen jq curl envsubst; do
  check "$c"
done

if [[ "${missing}" -ne 0 ]]; then
  cat >&2 <<'EOF'

Missing tools. Install them, e.g.:
  - terraform      https://developer.hashicorp.com/terraform/install
  - aws (v2)       https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
  - ansible-core   pip install ansible-core   (provides ansible-playbook / ansible-galaxy)
  - jq, curl, gettext(envsubst), openssh
EOF
  exit 1
fi
echo "All prerequisites present."

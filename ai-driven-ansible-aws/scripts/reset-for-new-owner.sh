#!/usr/bin/env bash
# =============================================================================
# reset-for-new-owner.sh - make a COPIED folder safe to build from.
#
# A folder copy is not a git clone. .gitignore keeps per-operator state out of
# git, so a clone is clean - but a copied folder carries that state with it,
# including terraform/terraform.tfstate, which names live AWS resources in the
# PREVIOUS OWNER'S account.
#
# Running Terraform against inherited state makes Terraform believe it owns
# those resources. Against your credentials that fails confusingly; if you
# happen to share an account, it can modify or destroy a running demo.
#
# So this removes the per-operator state and leaves everything tracked in git
# untouched. Idempotent: safe to run on an already-clean tree.
#
# It does NOT remove ansible/AAP/*.tar.gz - you need the setup bundle, and
# re-downloading it is a multi-MB round trip.
#
# Dry run by default. Pass --yes to actually delete.
#
#   ./scripts/reset-for-new-owner.sh          # show what would be removed
#   ./scripts/reset-for-new-owner.sh --yes    # remove it
#
# See docs/HANDOFF.md.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=0

for arg in "$@"; do
  case "${arg}" in
    -y|--yes) APPLY=1 ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown option: %s (try --help)\n' "${arg}" >&2; exit 1 ;;
  esac
done

blue()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
amber() { printf '\033[1;33m%s\033[0m\n' "$*"; }

# Per-operator state. Each entry is relative to the repo root.
TARGETS=(
  "terraform/terraform.tfstate"
  "terraform/terraform.tfstate.backup"
  "terraform/.terraform"
  "terraform/terraform.tfvars"
  "ansible/inventory.ini"
  "ansible/.known_hosts"
  "ansible/.aap-collections"
)

blue "Repo: ${REPO_ROOT}"
[[ "${APPLY}" -eq 1 ]] || amber "DRY RUN - nothing will be deleted. Re-run with --yes to apply."
printf '\n'

# --- warn loudly if the inherited state describes live infrastructure --------
STATE="${REPO_ROOT}/terraform/terraform.tfstate"
if [[ -f "${STATE}" ]] && command -v python3 >/dev/null 2>&1; then
  n_res="$(python3 -c "
import json,sys
try: print(len(json.load(open('${STATE}')).get('resources',[])))
except Exception: print(0)
" 2>/dev/null || echo 0)"
  if [[ "${n_res}" -gt 0 ]]; then
    amber "NOTE: the inherited terraform.tfstate describes ${n_res} resources."
    amber "      Those belong to whoever built this folder, in THEIR AWS account."
    amber "      Deleting this file does not touch their infrastructure - it only"
    amber "      stops Terraform here from believing it owns them. If that demo is"
    amber "      still running, its owner tears it down with their own copy."
    printf '\n'
  fi
fi

# --- remove ------------------------------------------------------------------
found=0
for rel in "${TARGETS[@]}"; do
  path="${REPO_ROOT}/${rel}"
  [[ -e "${path}" ]] || continue
  found=1
  if [[ -d "${path}" ]]; then
    size="$(du -sh "${path}" 2>/dev/null | cut -f1 || echo '?')"
    printf '  %s  %s/  (%s)\n' "$([[ "${APPLY}" -eq 1 ]] && echo 'removed ' || echo 'would remove')" "${rel}" "${size}"
    [[ "${APPLY}" -eq 1 ]] && rm -rf "${path}"
  else
    printf '  %s  %s\n' "$([[ "${APPLY}" -eq 1 ]] && echo 'removed ' || echo 'would remove')" "${rel}"
    [[ "${APPLY}" -eq 1 ]] && rm -f "${path}"
  fi
done

# .DS_Store anywhere (noise a macOS copy always brings along)
while IFS= read -r ds; do
  found=1
  printf '  %s  %s\n' "$([[ "${APPLY}" -eq 1 ]] && echo 'removed ' || echo 'would remove')" "${ds#"${REPO_ROOT}/"}"
  [[ "${APPLY}" -eq 1 ]] && rm -f "${ds}"
done < <(find "${REPO_ROOT}" -name '.DS_Store' -not -path '*/.git/*' 2>/dev/null)

printf '\n'
if [[ "${found}" -eq 0 ]]; then
  green "Already clean - no per-operator state present. Nothing to do."
elif [[ "${APPLY}" -eq 1 ]]; then
  green "Done. This tree is now safe to build from in your own AWS account."
else
  amber "Nothing deleted. Re-run with --yes to apply."
fi

# --- what is deliberately kept ----------------------------------------------
printf '\nKept on purpose:\n'
if compgen -G "${REPO_ROOT}/ansible/AAP/*.tar.gz" >/dev/null 2>&1; then
  for f in "${REPO_ROOT}"/ansible/AAP/*.tar.gz; do
    printf '  AAP setup bundle: ansible/AAP/%s (%s)\n' "$(basename "${f}")" "$(du -h "${f}" | cut -f1)"
  done
else
  amber "  No AAP setup bundle in ansible/AAP/ - you must download it before building."
  printf '     https://access.redhat.com/downloads/content/480\n'
fi

if [[ "${APPLY}" -eq 1 ]]; then
  cat <<'EOF'

Next:
  1. Read CLAUDE.md and docs/HANDOFF.md
  2. export RHSM_USERNAME="you@example.com"
     read -rs RHSM_PASSWORD && export RHSM_PASSWORD
  3. ./scripts/bootstrap.sh --profile <your-aws-profile> --region us-east-1
EOF
fi

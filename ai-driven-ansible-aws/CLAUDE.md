# CLAUDE.md — project context

Read this first. It is the working context for this repository: what it is, the
invariants you must not break, and the conventions already established. It is
committed to git so it travels with the folder.

Companion documents:

| File | What it holds |
|---|---|
| `docs/HANDOFF.md` | **New owner starts here.** What to delete, what to obtain, first run. |
| `docs/LESSONS-LEARNED.md` | Every defect hit during the build, with root cause and the rule it implies. |
| `docs/DECISIONS.md` | Architecture decisions and why the rejected options were rejected. |
| `docs/SECURITY.md` | The security model in full. |
| `docs/reference-architecture.svg` | The diagram. Customer-presentable. |
| `README.md` | User-facing guide: quick start, run book, troubleshooting. |

---

## 1. What this is

A production-quality Infrastructure-as-Code reproduction of Red Hat's public
**"Introduction to AI-Driven Ansible Automation"** RHPDS/showroom lab, built to run
in *our own* AWS account instead of RHPDS. Purpose: a partner-side Solution
Architect demo asset we control, can extend, and can run on demand without an
RHPDS reservation.

Demo narrative in one line: **Apache breaks → Filebeat/Kafka detect it →
Event-Driven Ansible reacts → an AI model explains the fault and drafts a fix → a
human approves → a playbook is generated, committed to Git and applied → Apache
serves again.**

Content origin: adapted from the public `ansible-tmm/aiops-summitlab` repo. Our
playbooks are versioned in `ansible/roles/demo_content/files/repo/` and pushed into
Gitea on every run.

## 2. Shape of the repo

```
terraform/                  VPC, subnet, SGs, KMS, IAM, 2x EC2, EIPs
ansible/
  site.yml                  9 roles, every one tagged
  group_vars/all.yml        the single source of tunables; secrets via env lookups
  roles/
    common                  RHSM registration, base packages     [base]
    target                  httpd + Filebeat                     [target]
    control_base            podman, firewalld                    [services]
    kafka gitea mattermost  Quadlet containers                   [services]
    ollama                  local CPU inference + model pulls    [ai]
    aap                     AAP 2.6 containerized install        [aap]
      tasks/subscription.yml  entitlement attach                 [aap, subscription]
    demo_content            all AAP/EDA/Gitea/MM configuration   [demo_content]
      files/repo/           <-- the demo playbooks pushed to Gitea
scripts/
  bootstrap.sh              everything, from nothing. 30-50 min.
  infra_only.sh            Terraform only, prompts for no secrets
  demo_content.sh          demo content only. Minutes. Use this to iterate.
  attach-subscription.sh   fix an entitlement without reinstalling AAP
  set-ai-endpoint.sh       repoint at OpenShift AI / RHEL AI later
  cleanup.sh               terraform destroy
  preflight.sh             workstation tooling + AAP bundle check
  collect-secrets.sh       sourced; hidden-input prompts
  lib/common.sh            shared shell library — read this before editing scripts
docs/
```

**Three entrypoints, one library.** Every script sources `scripts/lib/common.sh`.
Put shared behaviour there, never duplicated in two scripts.

## 3. Non-negotiable invariants

Break any of these and the build regresses in a way that is hard to see. They are
each here because something went wrong.

### Security

1. **Secrets are prompted with hidden input, held in the process environment only.**
   Never written to disk, never echoed, never passed on a command line, never
   placed in Terraform state or variables.
2. **`no_log: true` on every task whose module arguments contain a secret.**
3. **Integration secrets live in AAP encrypted credentials**, injected as extra_vars
   by a custom credential type — never in a job template's own `extra_vars`.
4. **Ingress is scoped to the operator's `/32`, never `0.0.0.0/0`.** `detect_ingress_cidr`
   resolves it. The inference port is firewalld-only and appears in no security group.
5. **Never print subscription pool IDs.** They identify the account. Names and node
   counts only.
6. **Do not ask the user for their Red Hat credentials to use on their behalf.** The
   automation authenticates with credentials the operator supplies at runtime; that
   is the whole design.

### Correctness

7. **Addresses inside the VPC must be private.** An EIP is not routable from inside
   the VPC. `aap_controller_host` is public (for your browser);
   `aap_controller_host_internal` is private (for EDA, Filebeat, anything in-VPC).
   Getting this wrong produces a connection timeout that looks like a firewall bug.
8. **The gateway serves the controller under `/api/controller/v2/`**, not `/api/v2/`.
   EDA's controller URL is *discovered* by probing, not guessed — see
   `demo_content/tasks/eda.yml`.
9. **Numeric JSON fields must be cast.** Ansible's Jinja returns strings by default and
   the model server unmarshals strictly. Build request bodies as a single dict
   expression with `| int` / `| float`, never as YAML key/value pairs.
10. **Rulebook activations are immutable.** To change one: disable → delete → poll
    until the count is 0 → create. EDA deletes asynchronously.
11. **Workflows that receive `ansible_eda` vars need `ask_variables_on_launch: true`**
    on the workflow *and* on the runtime patch, or the launch is silently rejected.
12. **`demo_content` implies the `ai` tag.** demo_content writes model IDs into an AAP
    credential; if the endpoint serving those models is not reconciled in the same
    run, the credential advertises a model that was never pulled. Both `bootstrap.sh`
    and `demo_content.sh` expand this automatically — preserve that.
13. **One trigger rule in the rulebook.** A second matching rule double-launches the
    workflow.
14. **Never trust `uri`'s `changed` for POST** — it is not set. Re-query and select by
    name instead.

### Conventions

15. **Idempotent, always.** Re-running any script converges; it never creates a
    duplicate server or a second copy of an AAP object. Prefer create-or-PATCH.
16. **Fail at the real cause, early.** Do not warn and continue when a later stage is
    guaranteed to fail. The subscription check is the canonical example: it hard-fails
    before the 20-minute install rather than after it.
17. **Comments explain *why*, not *what*.** The code says what. Nearly every comment in
    this repo exists because a specific thing went wrong; keep them.
18. **`ansible.controller` comes from the local AAP setup bundle**, extracted by
    `ensure_aap_collections`. This deliberately avoids needing an Automation Hub
    token. `ansible.eda` is *not* in the bundle, which is why EDA is configured
    through the raw REST API.

## 4. How to work on this

**Iterating on demo content** — never re-run `bootstrap.sh` for this:

```bash
./scripts/demo_content.sh --profile <aws-profile> --region us-east-1
```

**Editing the demo playbooks** — they live in
`ansible/roles/demo_content/files/repo/playbooks/`. Edit there, then run
`demo_content.sh`, which pushes them to Gitea and re-syncs the AAP project. Do not
edit them in the Gitea UI: the next run overwrites them.

**Before committing:**

```bash
ansible-lint ansible/                     # YAML + Ansible correctness
shellcheck scripts/*.sh scripts/lib/*.sh  # shell correctness
terraform -chdir=terraform validate && terraform -chdir=terraform fmt -check
python3 -c "import xml.dom.minidom as m; m.parse('docs/reference-architecture.svg')"
```

**If you edit the SVG:** XML comments cannot contain `--`. Use `=` for separator
rules. Validate as above, and render it to PNG and *look at it* — layout defects
(overflowing text, arrows striking through labels) are invisible to structural
checks.

## 5. State: what is yours and what is the machine's

A folder copy carries files that git does not. These are **per-operator** and must
not be inherited:

| Path | Why it must not travel |
|---|---|
| `terraform/terraform.tfstate{,.backup}` | Names live AWS resources in *someone else's* account. Inheriting it makes Terraform believe it owns them. |
| `terraform/.terraform/` | Host-specific provider binaries. |
| `ansible/inventory.ini` | Rendered from Terraform outputs; contains the previous owner's public IPs. |
| `ansible/.known_hosts` | Previous host keys. Causes verification failures. |
| `ansible/.aap-collections/` | Extracted from the bundle; large and reproducible. |
| `~/.ssh/aiops_ansible_demo{,.pub}` | Outside the repo, but it is the operator's key. Not shared. |

All are `.gitignore`d, so a `git clone` is clean. A **folder copy is not** —
`docs/HANDOFF.md` covers the reset, and `scripts/reset-for-new-owner.sh` performs it.

For the record: `terraform.tfstate` in this project contains **no secrets** — the
only `password`/`token` matches are AWS attribute *names* (`get_password_data`,
`http_tokens`). It still must not travel, for the ownership reason above.

## 6. Known-unverified paths

Be honest about these; do not present them as tested.

- **Ansible Lightspeed `saas` mode.** `lightspeed_mode` defaults to `local` for a
  reason. The hosted generation endpoint path is undocumented and the token needs a
  live seat entitlement. A lapsed token fails *at the generation step*, mid-demo.
  Verify entitlement before switching.
- **Subscription identifier field.** The attach code sends the ID as `pool_id`,
  `subscription_id` *and* `id`, because which one the API returns has varied by
  release. This was inferred from an error message, not confirmed against a live
  response. If attach fails, `./scripts/attach-subscription.sh --list` prints the
  actual field names.
- **OpenShift AI / RHEL AI as the backend.** The swap is a variable change and the
  code path is the same OpenAI-compatible `/v1/chat/completions`, but it has not been
  run end to end against either product from this repo.

## 7. Security incident on record

A live Ansible Lightspeed API key was pasted into a chat transcript during
development and must be treated as compromised. It was to be revoked and rotated.
**Do not paste replacement secrets anywhere** — the tooling reads every secret from
an environment variable precisely so that it never needs to be shown.

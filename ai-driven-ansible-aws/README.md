# AI-Driven Ansible Automation — AWS IaC

Terraform + Ansible to stand up the Red Hat
[Introduction to AI-Driven Ansible Automation](https://rhpds.github.io/showroom-ai-driven-ansible-automation/modules/index.html)
demo in your own AWS account, with secure, runtime-only secret handling.

The upstream lab is normally delivered pre-built by the Red Hat Demo Platform
(demo.redhat.com). This project reproduces the environment described in that
lab as reusable Infrastructure as Code so you can run it in your own account.

## Architecture

Two RHEL 10 nodes in a dedicated VPC (public subnet, internet gateway):

- **control** (`m6i.2xlarge`) — Ansible Automation Platform 2.6 (containerized,
  all-in-one incl. EDA), plus Kafka (KRaft), Gitea and Mattermost as Podman
  Quadlet services. Also runs a local CPU inference endpoint unless you supply an
  external one.
- **target** (`t3.medium`) — the RHEL webserver running `httpd` with Filebeat
  shipping Apache logs to Kafka on the control node. This is the service that
  "fails" and is auto-remediated.

```
        operator (your IP /32 only)
                 │  22 / 443 / 488 / 8065              22 / 80
                 ▼                                         ▼
      ┌────────────────────────┐   Kafka 9092    ┌─────────────────────┐
      │  control  (private SG) │◀────────────────│  target (private SG)│
      │  AAP + EDA             │                 │  httpd + Filebeat   │
      │  Kafka / Gitea / MM    │───── SSH 22 ───▶│  (managed by AAP)   │
      └────────────────────────┘   run job templ └─────────────────────┘
                 │
                 └──▶ AI inference: local CPU endpoint, or your own
                      OpenShift AI / RHEL AI / MaaS endpoint
```

Security defaults: default-deny security groups scoped to your workstation IP
(never `0.0.0.0/0`), IMDSv2 enforced, EBS encrypted with a customer-managed KMS
key, least-privilege instance role (optional SSM Session Manager, nothing
else), and Terraform state that contains **no credentials**.

Two documented demo trade-offs: Gitea and Mattermost are served over plain HTTP,
and Mattermost has open signups enabled so its first admin can be created
non-interactively. Both are only reachable from your `/32`. See
[docs/SECURITY.md](docs/SECURITY.md) for the full model and what to change before
using this beyond a personal demo.

## Repository layout

```
ai-driven-ansible-aws/
├── README.md
├── .gitignore
├── docs/
│   └── SECURITY.md              # secret-handling model + hardening notes
├── terraform/                   # AWS infrastructure (no secrets in state)
│   ├── versions.tf providers.tf variables.tf main.tf
│   ├── security_groups.tf iam.tf kms.tf ec2.tf outputs.tf
│   └── terraform.tfvars.example
├── ansible/                     # software stack configuration
│   ├── ansible.cfg requirements.yml site.yml unregister.yml
│   ├── update-ai-endpoint.yml   # repoint the AI credential (no AAP reinstall)
│   ├── inventory.ini.tmpl       # rendered at runtime from TF outputs
│   ├── group_vars/all.yml       # non-secret config; secrets via env lookups
│   ├── aap/                     # put the AAP 2.6 setup bundle here (gitignored)
│   └── roles/
│       ├── common target control_base kafka gitea mattermost aap
│       ├── ollama               # local CPU inference endpoint
│       └── demo_content/        # Gitea content + AAP/EDA config as code
│           └── files/repo/      # the playbooks + rulebook pushed to Gitea
└── scripts/
    ├── bootstrap.sh             # 1. everything: infrastructure + full config
    ├── infra_only.sh            # 2. infrastructure only (Terraform)
    ├── demo_content.sh          # 3. demo content only (the fast path)
    ├── set-ai-endpoint.sh       # repoint the demo at a real model endpoint
    ├── cleanup.sh               # unregister + destroy
    ├── preflight.sh             # tool + AAP bundle checks
    ├── collect-secrets.sh       # hidden-input secret prompts (sourced)
    └── lib/common.sh            # shared plumbing for the three entrypoints
```

## Prerequisites

On your workstation: `terraform` (>=1.5), `aws` CLI v2, `ansible-core`
(provides `ansible-playbook`/`ansible-galaxy`), plus `jq`, `curl`, `envsubst`
(gettext), `openssl`, `tar`, and OpenSSH. Run `scripts/preflight.sh` to check —
it also verifies the AAP setup bundle is present. On macOS also
`pip install passlib` (Ansible needs it to hash the lab-user password; Linux uses
the system `crypt`).

Before you run, have ready:

- **AWS access via SSO or a named profile** — `aws sso login --profile <p>`
  (or exported temporary STS creds). No AWS keys are ever entered into this
  tooling.
- **A Red Hat account whose subscription includes Ansible Automation Platform**
  — your Red Hat username and password. The free
  [Red Hat Developer Subscription for Individuals](https://developers.redhat.com/products/ansible/overview)
  covers this. The same credentials are used for RHSM and `registry.redhat.io`.
  Nothing is needed at install time beyond these; attach the subscription in the
  AAP UI on first login (Username/password, not a manifest).
- **The AAP 2.6 containerized setup bundle** in `ansible/aap/` — download
  `ansible-automation-platform-containerized-setup-2.6-*.tar.gz` from
  <https://developers.redhat.com/products/ansible/download>. `bootstrap.sh` also
  extracts `ansible.controller` from it, so no Automation Hub token is required.
- *(Optional)* an **OpenAI-compatible model endpoint** — OpenShift AI Model
  Serving, RHEL AI, or Red Hat MaaS. Leave it blank and the demo deploys a local
  CPU endpoint instead. See [AI inference](#ai-inference).
- *(Optional)* an **Ansible Lightspeed** token. Without one, remediation
  playbooks are generated by the model endpoint above — same demo narrative.

## The three scripts

| Script | Does | Takes | Use when |
|---|---|---|---|
| **`bootstrap.sh`** | Terraform **+** full `site.yml` (RHSM, services, AAP install, demo content) | **30–50 min** | First build, from nothing |
| **`infra_only.sh`** | Terraform only — no software, no secrets prompted | **3–5 min** | You want the boxes up before configuring, or to converge drift |
| **`demo_content.sh`** | Gitea content + AAP/EDA objects only | **2–5 min** | **Iterating on the demo.** Changed a playbook, rulebook, job template or workflow |

`demo_content.sh` is the one you'll use most. It runs `site.yml --tags
demo_content`, which skips the AAP containerized install — the 20–40 minute part
— and re-applies just the demo: pushes the repo content to Gitea, and recreates
the credentials, inventory, projects, 10 job templates, both workflows and the
EDA activation. It doesn't ask for your Red Hat credentials or a vault password,
because that stage only talks to services that are already installed.

All three are idempotent. Re-running converges rather than duplicating.

## Quick start

```bash
cd ai-driven-ansible-aws

# 1. Authenticate to AWS (SSO example)
aws sso login --profile my-sso-profile

# 2. Full build. Prompts for your Red Hat login and a vault password (hidden
#    input). Ingress is auto-restricted to your public IP /32.
./scripts/bootstrap.sh --profile my-sso-profile --region us-east-1
```

That runs preflight, validates AWS creds, generates a local SSH keypair (if
needed), collects secrets, `terraform apply`, renders the Ansible inventory from
the outputs, waits for SSH, installs collections, and runs `site.yml`. The AAP
containerized install alone can take 20–40+ minutes.

Then iterate without paying that cost again:

```bash
# Edit ansible/roles/demo_content/files/repo/... or the AAP objects, then:
./scripts/demo_content.sh --profile my-sso-profile
```

Or bring up infrastructure separately first:

```bash
./scripts/infra_only.sh --profile my-sso-profile          # or --plan to preview
./scripts/bootstrap.sh  --profile my-sso-profile          # configure it
```

What you are prompted for:

| Prompt | Required? | Notes |
|---|---|---|
| Red Hat username | **Yes** | Used for both RHSM and `registry.redhat.io` |
| Red Hat password | **Yes** | Hidden input |
| Vault password | No | Enter to auto-generate |
| Red Hat AI model endpoint URL | No | Enter to use the local CPU endpoint |
| Red Hat AI model id | No | Only asked if you gave an endpoint |
| Red Hat AI model API key | No | Only asked if you gave an endpoint |
| Ansible Lightspeed API key | No | Enter to generate playbooks with the model endpoint |

Only the two Red Hat credentials are required — press Enter through the rest and
you get a complete, working demo with local CPU inference.

Anything already exported is used and **not** prompted for, so repeat and
non-interactive runs never block:

```bash
AI_MODEL_ENDPOINT="https://<model>-<ns>.apps.<cluster>/v1" \
AI_MODEL_ID="granite-3.1-8b-instruct" \
AI_MODEL_API_KEY="<token>" \
  ./scripts/bootstrap.sh --profile my-sso-profile
```

Skipped them and got the details later? Use
[`scripts/set-ai-endpoint.sh`](#switching-to-your-own-endpoint-later) — no
AAP reinstall.

`demo_content.sh` prompts only for the optional AI and Lightspeed values —
never the Red Hat credentials or the vault password.

### Running individual stages

`site.yml` is tagged, so any stage can be run alone:

| Tag | Stage |
|---|---|
| `base` | RHSM registration and base packages |
| `target` | httpd + Filebeat on the target node |
| `services` | Kafka, Gitea, Mattermost containers |
| `ai` | local CPU inference endpoint |
| `aap` | the AAP containerized install (the slow one) |
| `subscription` | attach the AAP subscription only (seconds) |
| `demo_content` | Gitea content + AAP/EDA configuration |

```bash
./scripts/bootstrap.sh --profile my-sso-profile --tags services
./scripts/demo_content.sh --profile my-sso-profile --check     # dry run
./scripts/demo_content.sh --profile my-sso-profile -- --start-at-task "Create the workflows"
```

`demo_content` is deliberately a single tag rather than one per stage: the stages
share facts (the Gitea API token minted first is consumed by the AAP credential
and EDA stages), so running them in isolation would fail on undefined variables.

## Accessing the environment

`bootstrap.sh` prints the URLs at the end (also `terraform -chdir=terraform
output`):

| System      | URL                          | Login                              |
|-------------|------------------------------|------------------------------------|
| AAP         | `https://<control-ip>`       | `admin` / `redhat`                 |
| Gitea       | `http://<control-ip>:488`    | `lab-user` / `redhat`              |
| Mattermost  | `http://<control-ip>:8065`   | `ansibleadmin` / `ansibleredhat`   |
| Webserver   | `http://<target-ip>`         | —                                  |

Two easy-to-hit gotchas:

- AAP uses a **self-signed certificate**, so expect a browser warning.
- Gitea is **plain HTTP** on port 488 — use `http://<control-ip>:488`, not
  `https://`. An `ERR_SSL_PROTOCOL_ERROR` here means the scheme is wrong.

Passwords are set as lab defaults (`redhat` / `ansibleredhat`) and are not
prompted. Override before running with `LAB_USER_PASSWORD`, `AAP_ADMIN_PASSWORD`,
or `MM_ADMIN_PASSWORD` if you prefer.

**The AAP subscription is attached automatically.** `bootstrap.sh` does it right
after installing AAP, using the Red Hat credentials you already supplied — no
manifest export, no UI step. It picks the pool with the most managed-node
capacity.

If your account has no AAP pool the attach is skipped with a warning, and you can
either attach it in the UI (choose **Username/password**, enter your Red Hat
login) or re-run just that stage once the entitlement exists:

```bash
./scripts/bootstrap.sh --profile my-sso-profile --tags subscription   # seconds
```

Why it matters: without a subscription the controller accepts inventories and
groups but rejects `POST /hosts/` with HTTP 403, because **hosts** are what
consume entitlements. `demo_content.sh` checks this up front and stops before
creating anything.

## Running the demo

The demo content is built for you. `demo_content_enabled` defaults to `true`, so
after `bootstrap.sh` finishes you have 10 job templates, both workflows, the
inventory, all credentials, two Gitea repos, and a live EDA rulebook activation.

| Step | Action | What to watch |
|---|---|---|
| 1 | Launch **❌ Break Apache** | Inserts `InvalidDirectiveHere` into `httpd.conf`; the restart fails by design |
| 2 | Automation Decisions → Rulebook Activations | Filebeat → Kafka → EDA matches the event |
| 3 | *(automatic)* **AI Insights and Lightspeed prompt generation** | Logs collected, AI writes an RCA, Mattermost gets both, a survey is prepared |
| 4 | Read Mattermost **#town-square** | The incident logs and the AI root cause analysis — the "enriched ticket" moment |
| 5 | Launch **Remediation Workflow** | Review the AI-authored prompt in the survey, then finish. This is the human-in-the-loop checkpoint |
| 6 | Check Gitea `lightspeed-playbooks` | The AI-generated playbook, committed as the audit trail |
| 7 | Launch **🔧✅ Execute HTTPD Remediation** with limit `target-node` | The fix is applied |
| 8 | Visit `http://<target-ip>` | Serving again |

Reset between runs with **✅ Restore Apache**.

The two-workflow split is the point, not an accident: the first runs unattended
and stops at a reviewable prompt, the second is launched by a human who has seen
what the AI proposed. That boundary is where a change window or approval gate
belongs in production.

### AI inference

Every demo playbook talks plain OpenAI `/v1/chat/completions`, so the inference
backend is a variable, not a code change. Two options:

**Local CPU (default).** Ollama on the control node serving
`granite3.1-dense:2b`. No extra infrastructure, no cost, inference stays in your
VPC — but expect 30–90 seconds per call, so narrate while it thinks. Good for
building and rehearsing the demo.

**Your own model endpoint.** Anything OpenAI-compatible: OpenShift AI Model
Serving, RHEL AI, Red Hat AI Inference Server, or Red Hat MaaS.

You do **not** need this up front. Build the environment now with the local
endpoint, and switch whenever your endpoint is ready — see below.

#### Switching to your own endpoint later

Do **not** re-run `bootstrap.sh` just for this; it would re-run the AAP
containerized installer (20–40 minutes) to change one credential. Instead:

```bash
./scripts/set-ai-endpoint.sh
```

It prompts for the URL and token, **lists the model ids the endpoint actually
serves** so you pick from a menu rather than guessing, verifies a real chat
completion works, and then updates the AAP credential in place. Takes seconds and
touches nothing else. Every AI job template reads that credential, so there is
nothing further to change.

Non-interactive equivalent:

```bash
AI_MODEL_ENDPOINT="https://<model>-<ns>.apps.<cluster>/v1" \
AI_MODEL_ID="granite-3.1-8b-instruct" \
AI_MODEL_API_KEY="<token>" \
  ./scripts/set-ai-endpoint.sh
```

Or set the same three variables before a fresh `bootstrap.sh` run, which skips
the local Ollama role entirely.

**For OpenShift AI Model Serving:** use the deployed model's *inference endpoint*
with `/v1` appended, and a token from the ServiceAccount you granted access. The
model id must match what the endpoint reports — a mismatch is the most common
cause of the demo failing at the AI step, which is why the script checks it for
you:

```bash
curl -sSk https://<your-route>/v1/models -H "Authorization: Bearer $TOKEN" | jq '.data[].id'
```

Also confirm the route is reachable from the AWS VPC — if the cluster is
elsewhere, network path is the next thing to sort out.

### Ansible Lightspeed

The upstream lab calls the hosted playbook-generation API, which needs a
Lightspeed / watsonx Code Assistant seat entitlement. This build points that step
at the same model endpoint instead, so the narrative is identical with no external
entitlement.

To use the real service, verify your entitlement first:

```bash
curl -sS -X POST https://c.ai.ansible.redhat.com/api/v0/ai/generations/ \
  -H "Authorization: Bearer $LIGHTSPEED_TOKEN" -H "Content-Type: application/json" \
  -d '{"text":"remove the line containing InvalidDirectiveHere from /etc/httpd/conf/httpd.conf and restart httpd"}'
```

A playbook in the response means you are entitled — set `lightspeed_mode: saas` in
`ansible/roles/demo_content/defaults/main.yml` and supply the token. A 401/403
means no seat, and the default `local` mode is the right call.

Quantized models occasionally emit YAML that will not parse. The generator fails
loudly by default so you can see it. For a high-stakes live demo, set
`allow_fallback_playbook: true` to substitute a known-good playbook instead.

### Demo content is versioned here

The playbooks and rulebook live in
`ansible/roles/demo_content/files/repo/` and are pushed to Gitea on every run.
Adapted from the public
[`ansible-tmm/aiops-summitlab`](https://github.com/ansible-tmm/aiops-summitlab)
repo. See
[`ansible/roles/demo_content/README.md`](ansible/roles/demo_content/README.md)
for what gets created and why.

**The edit loop:** change a file under `files/repo/`, or a job template in
`tasks/aap_job_templates.yml`, then:

```bash
./scripts/demo_content.sh --profile my-sso-profile
```

Committing directly in Gitea works for a quick experiment but is overwritten on
the next run — make lasting changes in `files/repo/`.

## Cost

Two on-demand instances (an `m6i.2xlarge` + a `t3.medium`), two EIPs, EBS, and a
KMS key. Roughly **US$0.50–0.60/hour** in `us-east-1` while running — dominated
by the control node. Destroy it when you are done.

If you point the demo at an external model endpoint, that endpoint's cost is
separate and not included here.

## Cleanup

```bash
./scripts/cleanup.sh --profile my-sso-profile
```

This unregisters the nodes from Red Hat Subscription Management (so you don't
leak entitlements), then `terraform destroy`s everything and removes the
generated inventory. Add `--delete-ssh-key` to also remove the local keypair.

## Troubleshooting

- **AAP install fails** — it is version/entitlement sensitive. Confirm your
  subscription includes AAP 2.6 and that the setup bundle in `ansible/aap/`
  matches. Check `/tmp/aap_install.log` on the control node. You can set
  `aap_install_enabled: false` in `ansible/group_vars/all.yml` to build
  everything else, then install AAP by hand.
- **`You don't have permission to POST to .../hosts/ (HTTP 403)`** — this is a
  **subscription** limit, not RBAC. Hosts consume entitlements, which is why the
  inventory and group are created successfully and only the host fails.
  `bootstrap.sh` now attaches the subscription automatically after installing
  AAP; if that could not find a pool, attach it by hand — open
  `https://<control-ip>`, choose **Username/password**, enter your Red Hat login
  — then re-run `./scripts/demo_content.sh`. `demo_content.sh` also checks the
  subscription up front and stops with this guidance before creating anything.
- **Demo content stage fails elsewhere** — the rescue block prints the failing
  task and message, and tailors its advice to the cause. The stage is safely
  re-runnable and leaves the platform untouched when it fails.
- **`ansible.controller` not found** — `bootstrap.sh` extracts it from the setup
  bundle in `ansible/aap/`. Confirm the tarball is there, then re-run. Delete
  `ansible/.aap-collections/` to force re-extraction.
- **EDA activation restart-loops on `.../api/v2/config/`** — `ansible-rulebook`
  cannot use the controller API. Two distinct causes, and the log tells you which:
  - `Connection timeout` → wrong *address*. AWS does not route traffic to an
    instance's own Elastic IP from inside the VPC, so it must be the private one.
  - `404 Not Found` → wrong *port*. That is the AAP gateway, which serves the
    controller under `/api/controller/v2/`; `ansible-rulebook` hardcodes
    `/api/v2/config/`, so it needs the controller's own listener (normally
    `:8443`).

  The demo content stage probes the control node for a URL that actually answers
  `/api/v2/config/` and patches the credential on every run, so re-running
  `./scripts/demo_content.sh` fixes both. Override discovery with
  `eda_controller_url` in `ansible/group_vars/all.yml` if your topology differs.
- **EDA activation not running for another reason** — the demo content stage now
  fetches the activation's own log and names the likely cause. Otherwise check
  Automation Decisions in the UI. Next most common: Kafka unreachable — confirm
  `podman ps` shows `kafka` and that `<control-private-ip>:9092` is listening.
- **Mattermost user creation fails with `api.user.create_user.no_open_server`
  (HTTP 403)** — Mattermost 9+ disables open signups, which blocks the
  unauthenticated first-user bootstrap. The Quadlet unit sets
  `MM_TEAMSETTINGS_ENABLEOPENSERVER`, so a 403 means the container is running with
  stale configuration. On the control node:
  `sudo podman rm -f mattermost`, then re-run `bootstrap.sh`. Removing the
  container rather than just restarting it also clears a half-initialised database
  left by a failed run.
- **Mattermost gets no messages** — the webhook is created at bootstrap. Confirm
  an "Environment ready" smoke-test message exists in `#town-square`; if not,
  re-run the demo content stage.
- **AI step fails with a model error** — `AI_MODEL_ID` does not match what the
  endpoint serves. Check with
  `curl -sSk <endpoint>/v1/models -H "Authorization: Bearer $TOKEN"`, or just run
  `scripts/set-ai-endpoint.sh`, which lists the valid ids for you.
- **AI step is slow or times out** — local CPU inference takes 30–90s per call and
  the playbook allows 600s. `podman logs ollama` on the control node shows whether
  the model loaded; the first run pulls several GB. Point at a real endpoint if you
  need it fast.
- **Generated playbook rejected as invalid YAML** — small quantized models
  sometimes emit prose or broken YAML. The generator fails loudly on purpose. Set
  `allow_fallback_playbook: true` for a guaranteed-green live demo.
- **No RHEL AMI found** — pass an explicit `TF_VAR_rhel_ami_id`, or run
  Terraform with a region where Red Hat publishes RHEL 10 GP3 AMIs.
- **SSH not ready** — new instances take a minute; the script retries. Confirm
  your public IP hasn't changed (re-run with `--ingress-cidr`).
- **`demo_content.sh` says no infrastructure found** — it refuses to run against
  nothing. Build with `infra_only.sh` or `bootstrap.sh` first. It reads the
  Terraform state, so run it from the same checkout that created the environment.
- **`demo_content.sh` fails waiting for the AAP gateway API** — AAP is not up.
  That script does not install AAP; run `bootstrap.sh` (or
  `bootstrap.sh --tags aap`) once first.
- **Re-running** — Terraform, Ansible and the demo content stage are all
  idempotent; re-run to converge. Two things are deliberately recreated each run:
  the Gitea API token (so AAP always holds a known value) and the EDA rulebook
  activation (activations are immutable once running).

## Disclaimer

Community tooling, not an official Red Hat distribution of the lab. Review
[docs/SECURITY.md](docs/SECURITY.md) before using beyond a personal demo.

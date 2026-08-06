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
  all-in-one incl. EDA), plus Kafka (KRaft), Gitea, Mattermost and **Ollama** as
  Podman Quadlet services. Ollama serves two small models over an
  OpenAI-compatible API and is skipped entirely if you supply your own endpoint.
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
                 └──▶ AI inference (port 11434, private only):
                      Ollama + 2 models by default, or your own
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
| Red Hat AI model endpoint URL | No | Enter to use the built-in local endpoint |
| Red Hat AI model id | No | Only asked if you gave an endpoint |
| Red Hat AI model API key | No | Only asked if you gave an endpoint |
| Model id for code generation | No | Only asked if you gave an endpoint; Enter reuses the model above |
| Ansible Lightspeed API key | No | Enter to generate playbooks with the model endpoint |

Only the two Red Hat credentials are required — press Enter through the rest and
you get a complete, working demo running entirely on models the IaC deploys for
you. See [AI models used when you supply nothing](#ai-models-used-when-you-supply-nothing).

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

| Tag | Stage | Roughly |
|---|---|---|
| `base` | RHSM registration and base packages | 2 min |
| `target` | httpd + Filebeat on the target node | 2 min |
| `services` | Kafka, Gitea, Mattermost containers | 5 min |
| `ai` | local inference endpoint + model pulls | 5 min (first run) |
| `aap` | the AAP containerized install | **20–40 min** |
| `subscription` | attach the AAP subscription only | seconds |
| `demo_content` | Gitea content + AAP/EDA configuration | 2–5 min |

```bash
./scripts/bootstrap.sh --profile my-sso-profile --tags services
./scripts/bootstrap.sh --profile my-sso-profile --tags subscription   # attach only
./scripts/demo_content.sh --profile my-sso-profile --check            # dry run
./scripts/demo_content.sh --profile my-sso-profile -- --start-at-task "Create the workflows"
```

Two deliberate behaviours:

- **`demo_content` implies `ai`.** Selecting `demo_content` automatically adds
  `ai`, in both `bootstrap.sh --tags` and `demo_content.sh`. The demo content
  writes model ids into AAP's AI credential, so the endpoint serving those models
  has to be reconciled in the same run — otherwise the credential advertises a
  model nothing pulled, and the demo fails later with `model 'x' not found`.
- **`demo_content` is one tag, not one per stage.** Its stages share facts (the
  Gitea API token minted first is consumed by the AAP credential and EDA stages),
  so running them in isolation would fail on undefined variables.

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

You launch **three** things by hand. Everything else is a workflow node.

| Step | Launch | Type | What to watch |
|---|---|---|---|
| 1 | **❌ Break Apache** | Job template | Inserts `InvalidDirectiveHere` into `httpd.conf`; the restart fails by design |
| 2 | *(nothing)* | — | Automation Decisions → Rulebook Activations shows Filebeat → Kafka → EDA matching the event |
| 3 | *(nothing — automatic)* | Workflow | **AI Insights and Lightspeed prompt generation** runs itself: logs collected, AI writes an RCA, Mattermost gets both, the survey is prepared |
| 4 | *(nothing)* | — | Read Mattermost **#town-square** — incident logs and the AI root cause analysis. The "enriched ticket" moment |
| 5 | **Remediation Workflow** | **Workflow job template** | Survey shows a known-good prompt plus the one **the AI wrote**. Copy the AI's over if you're happy with it, then Next → Finish. This review is the human-in-the-loop checkpoint |
| 6 | *(nothing)* | — | Gitea `lightspeed-playbooks` now holds the AI-generated playbook — the audit trail |
| 7 | **🔧✅ Execute HTTPD Remediation** with Limit `target-node` | Job template | The fix is applied |
| 8 | *(nothing)* | — | `http://<target-ip>` is serving again |

Reset between runs with **✅ Restore Apache** (job template).

**Do not launch these seven directly — they are workflow nodes:**

- `⚙️ Apache Service Status Check`
- `🤖 RHEL AI: Analyze Incident`
- `📣 Notify via Mattermost`
- `⚙️ Build Ansible Lightspeed Job Template`
- `🧠 Lightspeed Remediation Playbook Generator`
- `🧾 Commit Fix to Gitea`
- `⚙️ Build HTTPD Remediation Template`

They read artifacts from the nodes before them, so on their own they fail with a
clear message — e.g. *"No prompt supplied. Launch the Remediation Workflow and
complete the survey, which provides lightspeed_prompt."*

In step 5, pick the row whose **Type** column reads *Workflow job template*.
`Remediation Workflow` sorts just after `📣 Notify via Mattermost` in the
alphabetical Templates list, so it may be below the fold.

The two-workflow split is the point, not an accident: the first runs unattended
and stops at a reviewable prompt, the second is launched by a human who has seen
what the AI proposed. That boundary is where a change window or approval gate
belongs in production.

## Demo run book

A presenter's script: what to check first, what to click, what to say, and how long
each step takes. Total run time **8–12 minutes**, most of it waiting on CPU
inference.

### Before you present — 5-minute pre-flight

Run these once, before the audience is watching. Each is a place the demo can be
silently broken.

```bash
# 1. Environment converged and demo content current
./scripts/demo_content.sh --profile my-sso-profile

# 2. Apache is HEALTHY to start from (the trigger needs a running service)
#    Launch "✅ Restore Apache" in AAP, or:
curl -sSf http://<target-ip> >/dev/null && echo "webserver OK"

# 3. Both models are pulled and warm
ssh -i ~/.ssh/aiops_ansible_demo ec2-user@<control-ip> \
  'sudo podman exec ollama ollama list'
```

Then confirm in the AAP UI:

| Check | Where | Must show |
|---|---|---|
| Rulebook activation | Automation Decisions → Rulebook Activations | `Web App` = **Running** |
| Subscription | Settings → Subscription | attached, node capacity free |
| Templates | Automation Execution → Templates | 10 job templates + 2 workflows |

**If the activation is not `Running`, nothing will trigger.** That is the single
most common reason a rehearsed demo does nothing.

Finally, tidy the stage:

- Delete any old `Environment ready` posts from Mattermost `#town-square` so the
  channel is empty when you start.
- Open five browser tabs in this order — you will move left to right:
  1. AAP → Automation Execution → **Templates**
  2. AAP → Automation Decisions → **Rulebook Activations**
  3. AAP → Automation Execution → **Jobs**
  4. **Mattermost** `#town-square`
  5. **Gitea** → `lab-user/lightspeed-playbooks`
- Have a sixth tab on `http://<target-ip>` showing the working web page.

### The run

**Step 1 — Break it.** *(Tab 1 · ~30s)*

Launch **❌ Break Apache**.

> "This inserts an invalid directive into httpd.conf and restarts Apache. Nothing
> about the rest of this demo is scripted — from here on, the platform reacts."

Switch to tab 6 and refresh: the site is down.

**Step 2 — Detection.** *(Tab 2 · ~15s)*

Open the `Web App` activation's log.

> "Filebeat shipped the httpd error log to Kafka. Event-Driven Ansible was already
> watching that topic, matched the shutdown event, and launched a workflow. No
> polling, no cron, no human."

**Step 3 — Enrichment runs itself.** *(Tab 3 · 2–4 min)*

**Launch nothing.** Watch `AI Insights and Lightspeed prompt generation` appear and
work through four nodes.

> "Four things happen without us. It checks the service state, sends the logs to a
> Granite model for analysis, posts the result to chat, and then builds the next
> piece of automation."

The AI node is the slow one — 30–90 seconds per call, two calls. Fill it by
explaining that inference is running on the control node's CPU inside the VPC, and
that in production this would be RHEL AI or OpenShift AI on a GPU.

**Step 4 — The payoff.** *(Tab 4 · ~1 min)*

Mattermost `#town-square` now has two posts: the raw incident logs, and the
AI-written root cause analysis.

> "This is the moment worth paying attention to. Mattermost is standing in for
> ServiceNow. A ticket now exists with the logs attached *and* a root cause
> analysis — before any engineer has opened it. That is the difference between an
> alert and an actionable ticket."

**Step 5 — Human in the loop.** *(Tab 1 · ~1 min)*

Launch **Remediation Workflow** — the row whose **Type** is *Workflow job template*.

The survey has two boxes: a known-good prompt, and **the prompt the AI wrote from
your actual failure**. Read the AI's version aloud, then copy it into the required
field and click **Next → Finish**.

> "Here is the control point. The AI proposed a fix; a human reads it before
> anything is generated. In your environment this is where a change window or an
> approval gate goes. This is why it's two workflows and not one."

**Step 6 — Automation writes automation.** *(Tab 3 → Tab 5 · 1–2 min)*

Watch the four remediation nodes run, then switch to Gitea.

> "The model generated a playbook, it was committed to Git, the project synced, and
> a new job template was created to run it. The fix is a reviewable commit — not
> something a machine applied behind your back."

Open the commit and show the YAML.

**Step 7 — Apply it.** *(Tab 1 · ~30s)*

Launch **🔧✅ Execute HTTPD Remediation** with **Limit** = `target-node`.

> "Note this is still deliberate and scoped. The limit means it touches one host."

**Step 8 — Close the loop.** *(Tab 6 · ~10s)*

Refresh the web page. It serves again.

> "Detection, enrichment, root cause analysis, generated remediation, an audit
> trail in Git, and a human decision point — start to finish in about ten minutes."

### Reset between runs

Launch **✅ Restore Apache**. It removes the bad directive, validates the config,
restarts the service and confirms the site responds. Takes about 20 seconds.

For a fully clean second run, also:

- delete the new posts in Mattermost `#town-square`
- optionally delete `🔧✅ Execute HTTPD Remediation`, so step 6 visibly creates it

### If it stalls mid-demo

| Symptom | Most likely cause | Quick move |
|---|---|---|
| Nothing happens after step 1 | Activation not `Running` | Say you'll trigger manually; launch the enrichment workflow directly |
| AI node runs > 3 min | Cold model | Wait — it will finish. Talk about CPU vs GPU inference |
| Step 6 fails on generation | Model emitted unusable YAML | Relaunch the workflow; accept the pre-filled known-good prompt instead of the AI's |
| Any workflow node fails | — | The job's output names the cause; every failure path in this build prints a specific next step |

Before a high-stakes run, set `allow_fallback_playbook: true` on
`🧠 Lightspeed Remediation Playbook Generator`. Generation is non-deterministic, and
that flag substitutes a known-good playbook rather than failing in front of people.

### Timing summary

| Step | Time | You do |
|---|---|---|
| 1 Break Apache | 30s | Launch |
| 2 EDA detection | 15s | Watch |
| 3 Enrichment workflow | 2–4 min | Watch + narrate |
| 4 Mattermost RCA | 1 min | Read aloud |
| 5 Remediation Workflow + survey | 1 min | Review, copy, launch |
| 6 Generate, commit, sync | 1–2 min | Watch, show Git |
| 7 Execute remediation | 30s | Launch with limit |
| 8 Verify | 10s | Refresh |
| **Total** | **8–12 min** | |

## The role of AI in this demo

AI is **not** what detects the failure and **not** what applies the fix. Detection
is Filebeat, Kafka and Event-Driven Ansible. Execution is an ordinary Ansible
playbook run by Automation Controller. Those parts are deterministic, and the demo
is better for it.

AI does exactly three things, at three points in the chain:

| # | Job template | What the model is asked | What comes back | Where it goes |
|---|---|---|---|---|
| 1 | `🤖 RHEL AI: Analyze Incident` | *"A service is failing on host X. Based on these logs, give one concise fix instruction."* `max_tokens: 120`, `temperature: 0` | `ai_fix_instruction` — one or two sentences | Becomes the pre-filled prompt a human reviews |
| 2 | `🤖 RHEL AI: Analyze Incident` | *"Analyse these logs and write a root cause analysis."* `max_tokens: 600`, `temperature: 0.3` | `ai_rca_text` — a paragraph of prose | Posted to Mattermost as the enriched ticket |
| 3 | `🧠 Lightspeed Remediation Playbook Generator` | *"Write an Ansible Playbook for this task: &lt;reviewed prompt&gt;"* `max_tokens: 700`, `temperature: 0` | `generated_playbook` — YAML | Sanitised, committed to Gitea, then run |

Calls 1 and 2 run unattended in the enrichment workflow. Call 3 only happens
**after a human has read and approved** the prompt from call 1 — that survey is the
governance boundary, and it is why the demo is split into two workflows rather than
one.

What the model actually receives is narrow and mechanical: the output of
`journalctl -u httpd -n 20`, plus a fixed instruction. It is not given credentials,
inventory, or access to anything. And its YAML output is never trusted blindly —
`commit_to_gitea` forces `hosts: all` and `become: true` before committing, so the
model cannot choose its own blast radius, and the fix lands as a reviewable Git
commit before anyone runs it.

Everything is plain OpenAI `/v1/chat/completions`, so the inference backend is
configuration rather than code. You do **not** need an endpoint to start.

## Default AI: what runs when you give no OpenShift AI details

Leave the endpoint prompts blank and the IaC deploys a complete, self-contained
inference stack for you. Nothing external is required — no OpenShift AI, no RHEL AI,
no API keys, no GPU, no accounts.

**What gets deployed.** `Ollama` as a Podman Quadlet service on the control node,
listening on port `11434` and exposing an OpenAI-compatible API. It serves two
models, both pulled and warmed automatically at deploy time:

| Serves | Model | Size | Variable | Used by |
|---|---|---|---|---|
| Calls 1 & 2 — RCA and fix instruction | `granite3.1-dense:2b` | ~1.6 GB | `ollama_model` | `🤖 RHEL AI: Analyze Incident` |
| Call 3 — playbook generation | `qwen2.5-coder:3b` | ~1.9 GB | `ollama_codegen_model` | `🧠 Lightspeed Remediation Playbook Generator` |

**How the job templates reach it.** They don't hardcode anything. `demo_content`
writes the endpoint URL, the model ids and a token into an AAP custom credential
(`Demo AI Endpoint`), which injects them as extra variables at job run time. The
URL uses the control node's **private** address, so inference traffic never leaves
the VPC — and the port is opened in firewalld only, never in a security group.

```
🤖 RHEL AI: Analyze Incident            🧠 Lightspeed Remediation Playbook Generator
        │                                             │
        │  POST /v1/chat/completions                  │  POST /v1/chat/completions
        │  model: granite3.1-dense:2b                 │  model: qwen2.5-coder:3b
        ▼                                             ▼
   ┌──────────────────────────────────────────────────────────┐
   │  Ollama  ·  http://<control-private-ip>:11434/v1         │
   │  Podman Quadlet on the control node · CPU · private only │
   └──────────────────────────────────────────────────────────┘
```

**Why two models rather than one.** Summarising logs into prose and emitting valid
YAML are different jobs. A 2B general **chat** model writes a perfectly good RCA but
routinely wraps generated YAML in prose, which surfaces mid-demo as *"the model did
not return a usable Ansible Playbook"*. A small **code** model is both faster on CPU
and far more reliable at structured output. The generator is deliberately tolerant —
it strips markdown fences, drops prose preambles, and wraps a bare task list or a
lone play into a valid playbook — but no parser can fix output that was never YAML.

**What to expect in the room.** CPU inference, so 30–90 seconds per call; narrate
while it thinks. Both models stay resident (`OLLAMA_MAX_LOADED_MODELS=2`) and are
warmed at deploy time, so neither step pays a cold start or an eviction reload
mid-demo.

**Cost:** nothing beyond the control node you are already paying for.

**Honesty about the story.** In the upstream Red Hat lab this endpoint is RHEL AI
serving Granite. Ollama is a stand-in with an identical API contract, which is what
makes the swap a variable change. If you are presenting this, it is fair to say
"a Granite-family model on an OpenAI-compatible endpoint" — and worth saying that
in production this would be RHEL AI, OpenShift AI Model Serving, or Red Hat AI
Inference Server, all of which this same code targets unchanged.

**Changing the local models** while staying fully local — in
`ansible/group_vars/all.yml`:

```yaml
ollama_model: "granite3.1-dense:8b"      # better RCA, slower on CPU
ollama_codegen_model: "granite-code:8b"  # on-brand IBM code model, slower
```

Then `./scripts/demo_content.sh --profile <p>` pulls and switches to them. The
stage verifies the endpoint actually serves whatever you configure before it writes
the credential, so a typo fails immediately instead of mid-demo.

### Using your own endpoint instead

Anything OpenAI-compatible: **OpenShift AI Model Serving**, RHEL AI, Red Hat AI
Inference Server, or Red Hat MaaS. Setting an endpoint skips the local Ollama role
entirely — no models are pulled and nothing runs on the control node.

On a real serving stack one capable model handles both jobs, so the two-model split
disappears: leave the code-generation model blank and it reuses your main model.
The split is a concession to CPU inference, not the recommended production shape.

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
AI_CODEGEN_MODEL_ID="" \
  ./scripts/set-ai-endpoint.sh          # blank codegen = reuse AI_MODEL_ID
```

Or set the same variables before a fresh `bootstrap.sh` run, which skips the local
Ollama role entirely.

| Variable | Purpose |
|---|---|
| `AI_MODEL_ENDPOINT` | OpenAI-compatible base URL, must end in `/v1` |
| `AI_MODEL_ID` | Model id exactly as `/v1/models` reports it |
| `AI_MODEL_API_KEY` | Bearer token |
| `AI_CODEGEN_MODEL_ID` | Optional second model for playbook generation; blank reuses `AI_MODEL_ID` |
| `AI_BACKEND` | `ollama` (default) or `external`; set automatically when an endpoint is given |

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

### Guaranteed-green live demos

Generation is non-deterministic, which is a risk in front of an audience. Set
`allow_fallback_playbook: true` on the
`🧠 Lightspeed Remediation Playbook Generator` job template and unusable output is
replaced with a known-good playbook instead of failing the run. Off by default so
problems stay visible while you build.

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

**Inference costs nothing extra** with the defaults: both models run on the control
node's CPU, so there is no GPU instance and no external API billing. The trade-off
is latency — 30–90 seconds per AI call. If you point the demo at an external
endpoint, that endpoint's cost is separate and not counted here.

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
- **Activation is running, the rule fires, but no workflow starts** — check the
  activation log for
  `Variables ansible_eda are not allowed on launch`. `ansible-rulebook` passes the
  matched event as an `ansible_eda` extra variable, so the workflow needs
  **Prompt on Launch → Extra Variables** (`ask_variables_on_launch: true`). The
  IaC sets this on both workflows; re-run `./scripts/demo_content.sh` if a
  workflow predates it. Symptom: Apache breaks but nothing happens afterwards.
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
- **`model 'x' not found` (HTTP 404) from the AI endpoint** — the model is not
  pulled. `demo_content.sh` runs `--tags demo_content,ai` so the local endpoint is
  reconciled in the same pass, and the stage now verifies the endpoint actually
  serves every configured model *before* creating any AAP object. If you hit it,
  pull it directly:
  `sudo podman exec ollama ollama pull <model>` on the control node, or
  `./scripts/bootstrap.sh --tags ai`.
- **`cannot unmarshal string into Go struct field ... max_tokens of type int`** —
  a numeric request field was sent as a JSON string. Ollama is written in Go and
  unmarshals strictly; OpenAI and vLLM coerce silently, so this only shows up
  against Ollama. The demo playbooks build their request bodies as a single Jinja
  expression specifically to preserve numeric types — if you add a field, do the
  same rather than writing `max_tokens: "{{ n | int }}"`, which templates to the
  string `"120"`.
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

# Decision record

Why this is built the way it is. Each entry names the alternatives that were
considered and rejected, so a future maintainer can tell a deliberate choice from an
accident — and can reopen a decision knowing what it was weighed against.

Status key: **Settled** (do not relitigate without new information) ·
**Provisional** (chosen on incomplete information) · **Reverted**.

---

## D1. Reproduce the RHPDS lab in our own AWS account — Settled

**Alternative:** just book the RHPDS lab.

RHPDS gives you the lab as Red Hat ships it. It does not let you extend it, keep it
running, or demo without a reservation. As a partner-side asset we want to modify the
narrative, swap the AI backend for whatever a given customer runs, and control the
lifecycle. The cost is that we own the build.

---

## D2. AAP 2.6 **containerized**, Growth / all-in-one topology — Settled

**Alternatives:** RPM install; OpenShift-based AAP.

Containerized is the current install path and the one a customer will most likely be
adopting. All-in-one on a single `m6i.2xlarge` keeps the demo to two EC2 instances.
Component ports: Gateway `:443`, Controller `:8443`, Hub `:8444`, EDA `:8445`.

Consequence worth remembering: the gateway fronts everything, so the controller API
lives at `/api/controller/v2/` — the cause of the 404 in LESSONS-LEARNED A2.

---

## D3. Take `ansible.controller` from the **local AAP setup bundle** — Settled

**Alternative:** install it from Automation Hub with a token.

An Automation Hub token is another credential to obtain, rotate and explain, and it
would become a hard prerequisite for a peer running this. The setup bundle is already
downloaded (it is required for the install), and it contains the collection.
`ensure_aap_collections` extracts it.

**Direct consequence:** `ansible.eda` is *not* in the bundle. That is precisely why
EDA is configured through the raw REST API (D4) rather than with a collection.

---

## D4. Configure EDA through the **raw REST API** — Settled, reluctantly

Follows from D3. It costs us the create-or-update semantics a collection would give
for free, which is why `demo_content/tasks/eda.yml` hand-rolls: controller URL
discovery, create-or-PATCH for credentials and projects, and the
disable → delete → poll → create dance for activations (LESSONS-LEARNED B2).

Revisit if `ansible.eda` ever ships in the bundle.

---

## D5. **OpenAI-compatible `/v1/chat/completions`** as the only AI interface — Settled

This is the highest-leverage decision in the repo. Every AI call in every playbook
speaks that one protocol. Consequences:

- Swapping the backend is a **variable change, not a code change**.
- Ollama locally, Red Hat OpenShift AI Model Serving, RHEL AI, Red Hat AI Inference
  Server, or a Models-as-a-Service endpoint are all drop-in.
- It is also the honest architectural story to tell a customer: *your* inference,
  wherever it runs, on-prem or sovereign.

---

## D6. Local **CPU** inference by default — Settled

**Alternatives:** require an endpoint up front; require a GPU.

The demo must build with **no AI details supplied at all**, because that is how it
gets picked up and tried. Ollama on the control node's CPU needs nothing from the
operator. It is slow, and that is an acceptable trade for zero prerequisites.

`scripts/set-ai-endpoint.sh` repoints it later without a rebuild.

---

## D7. **Two models**, chat + code — Settled

`granite3.1-dense:2b` (~1.6 GB) for root-cause analysis and the one-line fix
instruction; `qwen2.5-coder:3b` (~1.9 GB) for playbook generation.

The split exists **only** to work around small CPU-hosted models: a 2B chat model
will not reliably emit clean YAML (LESSONS-LEARNED D3). A capable endpoint does both
jobs with one model, which is why `AI_CODEGEN_MODEL_ID` defaults to "same as
`AI_MODEL_ID`" when you supply your own endpoint.

Requires `OLLAMA_MAX_LOADED_MODELS=2`, and both models are warmed.

---

## D8. Lightspeed defaults to **`local`**, never auto-switches — Settled

The Lightspeed API token is collected and stored if offered, but `lightspeed_mode`
stays `local` even when a token is present.

**Why not switch automatically:** a token whose seat entitlement has lapsed fails *at
the generation step* — the most damaging possible place, in front of a customer. So
it is opt-in after you have verified the entitlement.

Also honest: the hosted generation endpoint path is undocumented and this path is
**unverified** (see CLAUDE.md §6). Two distinct products get confused here —
Lightspeed (watsonx Code Assistant, needs a seat) is not RHEL AI (self-hosted vLLM).
The README has a table distinguishing them.

---

## D9. **Human-in-the-loop** before any generated code runs — Settled

An operator reads the AI-authored prompt in a survey on the Remediation Workflow and
approves or edits it. Nothing is generated until they do, and the generated playbook
is committed to Gitea before it is applied.

This is a **design principle, not a demo convenience**. It is also the answer to the
question every customer asks — "would you actually run this in production?" The
diagram states it as a first-class box for that reason. Related invariants: generated
playbooks are forced to `hosts: all` + `become: true` before commit, so the model
cannot choose its own blast radius; and the apply step runs with an explicit `--limit`.

---

## D10. **Three entrypoints** over one flag-driven script — Settled

`infra_only.sh` (no secrets prompted) · `demo_content.sh` (minutes, for iterating) ·
`bootstrap.sh` (everything, 30–50 min).

Driven by the actual workflow: you build the infrastructure once and then iterate on
demo content dozens of times. A single script with flags made the common case carry
the cost of the rare one. Shared behaviour lives in `scripts/lib/common.sh` so the
three cannot drift.

---

## D11. Attach the subscription **in code**, and hard-fail if it does not — Settled

Originally this warned and continued. That guaranteed a failure ~20 minutes later at
`POST /hosts/`, with the cause buried far behind (LESSONS-LEARNED C1).

Now: attach automatically while the Red Hat credentials are already in hand, and
**hard-fail** if the licence is still absent *and* `demo_content_enabled` is true. If
you have deliberately set `demo_content_enabled: false`, it warns instead — AAP is
usable unlicensed for everything except hosts.

`aap_subscription_pool_name` defaults to `Partner`. Pool IDs are never printed.

---

## D12. Kafka + Filebeat for detection, not a polling check — Settled

Filebeat ships `/var/log/httpd/*_log` to a single-node KRaft Kafka on the control
node; the EDA rulebook watches the topic. **No polling and no cron** — which is the
whole point of the event-driven story, and worth saying out loud during the demo.

The rulebook has exactly **one** throttled trigger rule on `"shutting down"`. A
second matching rule double-launches the workflow.

Note the subtlety in `httpd_break.yml`: Apache must be **running** before the invalid
directive is inserted, so that the "caught SIGTERM, shutting down" line is actually
emitted and reaches Kafka. Breaking a stopped service produces no event.

---

## D13. Gitea as the audit trail — Settled

**Alternative:** GitHub/GitLab.

Self-contained, no external account, no outbound dependency, and it makes the point
that every AI-authored fix lands as a reviewable commit before anything runs. Two
repos: `aiops-demo` (the demo content) and `lightspeed-playbooks` (generated
remediations). Mattermost stands in for an ITSM tool the same way.

---

## D14. Reverted: GPU node + Red Hat AI Inference Server — Reverted

Built then removed at the user's request ("I will check if I have OpenShift AI in
AWS"): an optional `g6.2xlarge`, an `nvidia_gpu` role (driver, container toolkit,
CDI), an `rhaiis` role serving Granite FP8 on `:8000`, plus an `ai_backend` switch,
HF token handling and a GPU quota preflight.

**Why it is recorded here:** if OpenShift AI turns out to be unavailable and a
GPU-backed local endpoint is wanted again, this was working and the git history has
it. The `ai_backend` variable survives in `group_vars/all.yml` as the seam it would
plug into. Do not rebuild it from scratch without looking.

---

## D15. Secrets in the **process environment only** — Settled

Prompted with hidden input, exported for the current process, never written to disk,
echoed, committed, or placed in Terraform state. `no_log: true` on every task whose
arguments contain one. Integration secrets end up in **AAP encrypted credentials**
via custom credential types with `injectors.extra_vars` — never in a job template's
`extra_vars`, where they would be visible in the UI and the API.

Four custom credential types: `Demo AI Endpoint` (including `ai_codegen_model_id`),
`Demo Gitea`, `Demo Mattermost`, `Demo Lightspeed`.

`scrub_secrets`/`trap_scrub` in `lib/common.sh` unsets them on any exit path.

Full model: `docs/SECURITY.md`.

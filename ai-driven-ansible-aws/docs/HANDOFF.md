# Handoff — you just received this folder

You are standing up **your own** environment in **your own** AWS account. You are not
inheriting the previous owner's infrastructure.

Work through this file top to bottom. It should take about 15 minutes of your
attention, then 30–50 minutes of waiting.

---

## Step 0 — the one thing that can go badly wrong

A **folder copy** is not the same as a **git clone**.

`.gitignore` keeps per-operator state out of git, so a clone is clean. But a copied
folder carries that state with it — including `terraform/terraform.tfstate`, which
names live AWS resources **in the previous owner's account**.

If you run Terraform against inherited state, Terraform believes it owns those
resources. It will try to reconcile them, and against your credentials that fails in
confusing ways — or, if you happen to share an account, it can modify or destroy
someone else's running demo.

**So, before anything else:**

```bash
cd ai-driven-ansible-aws
./scripts/reset-for-new-owner.sh          # shows what it would remove
./scripts/reset-for-new-owner.sh --yes    # removes it
```

It removes, if present:

| Path | Why |
|---|---|
| `terraform/terraform.tfstate`, `.backup` | Names the previous owner's live resources |
| `terraform/.terraform/` | Host-specific provider binaries |
| `terraform/terraform.tfvars` | Previous owner's variable values |
| `ansible/inventory.ini` | Rendered from their Terraform outputs; their public IPs |
| `ansible/.known_hosts` | Their host keys — causes SSH verification failures |
| `ansible/.aap-collections/` | Extracted from the bundle; large, reproducible |
| `**/.DS_Store` | Noise |

It does **not** touch `ansible/AAP/*.tar.gz` (you need the bundle — see Step 2) or
anything tracked in git.

For the record: this project's `terraform.tfstate` contains **no secrets** — the only
`password`/`token` matches are AWS attribute *names*. The reason to delete it is
resource ownership, not credential exposure.

**If the folder came to you as a git clone or a fresh archive**, run the script
anyway. It is idempotent and reports "already clean".

---

## Step 1 — read these, in this order

1. **`CLAUDE.md`** — project context, the invariants, and what is unverified. If you
   use an AI assistant, it loads this automatically; read it yourself regardless.
2. **`docs/LESSONS-LEARNED.md`** — 20 defects already solved. Skim it now; you will
   come back to it the first time something fails.
3. **`README.md`** — the user-facing guide: quick start, demo run book, troubleshooting.
4. **`docs/DECISIONS.md`** — read when you want to *change* something, so you know
   what a choice was weighed against.
5. **`docs/reference-architecture.svg`** — the picture. Customer-presentable as-is.

---

## Step 2 — what you must obtain yourself

| Thing | Where | Notes |
|---|---|---|
| **AWS account + CLI access** | your own | An SSO profile is fine; pass `--profile`. Needs EC2, VPC, KMS, IAM. |
| **Red Hat account** | yours | Used for RHSM registration *and* `registry.redhat.io`. Same credentials for both. |
| **An AAP subscription** | your Red Hat account | Any AAP entitlement. No AAP pool? The free [Red Hat Developer Subscription for Individuals](https://developers.redhat.com/products/ansible/overview) includes one. |
| **AAP containerized setup bundle** | [Red Hat downloads](https://access.redhat.com/downloads/content/480) | Place in `ansible/AAP/`. Currently pinned to `ansible-automation-platform-containerized-setup-2.6-11.tar.gz`. `preflight.sh` checks for it. |
| **Workstation tooling** | — | `terraform`, `ansible-core`, `aws` CLI, `jq`, `python3`. `preflight.sh` verifies. |

You do **not** need: an Automation Hub token (see DECISIONS D3), an AI endpoint, a
GPU, or an Ansible Lightspeed seat. All optional.

> The bundle may already be present in the folder you received — it is ~3.6 MB and,
> because of a `.gitignore` case mismatch that has since been corrected, it was
> committed to git. Check `ls ansible/AAP/`. Re-download if the version has moved on.

---

## Step 3 — build it

```bash
export RHSM_USERNAME="you@example.com"
read -rs RHSM_PASSWORD && export RHSM_PASSWORD

./scripts/bootstrap.sh --profile <your-aws-profile> --region us-east-1
```

Every prompt comes **before** the long-running work, so once it starts it is
unattended. Add `-y` to skip prompts entirely (requires the two exports above).

Expect **30–50 minutes**, dominated by the AAP install. Defaults you should know:

| | |
|---|---|
| Resource prefix | `aiops-ansible-demo` (prompted; `-y` takes the default) |
| Ingress | your public IP `/32`, auto-detected |
| Region | `us-east-1` |
| AAP admin | `admin` / `redhat` |
| Gitea | `lab-user` / `redhat` |
| Mattermost | `ansibleadmin` / `ansibleredhat` |

Override the passwords by exporting `AAP_ADMIN_PASSWORD`, `LAB_USER_PASSWORD`,
`MM_ADMIN_PASSWORD` before running.

**Iterating afterwards** — never re-run `bootstrap.sh` for demo changes:

```bash
./scripts/demo_content.sh --profile <your-aws-profile>   # minutes, not 40
```

**Tearing down** — do this every time you finish. Two EC2 instances plus EIPs are not
free:

```bash
./scripts/cleanup.sh --profile <your-aws-profile>
```

---

## Step 4 — confirm you got the same state

After `bootstrap.sh` completes, you should have:

- **2 EC2 instances** — control (`m6i.2xlarge`), target (`t3.medium`)
- **AAP reachable** at `https://<control-ip>`, with a subscription attached
- **10 job templates, 2 workflows, 6 credentials, 4 custom credential types**
- **1 EDA rulebook activation**, running, watching the Kafka topic
- **2 Gitea repos** — `aiops-demo`, `lightspeed-playbooks`
- **Mattermost** with the `aiops` team and an incoming webhook on `#town-square`
- **2 Ollama models pulled** — `granite3.1-dense:2b`, `qwen2.5-coder:3b`

Then run the demo end to end once, alone, before you run it for anyone else. The
**Demo run book** section of `README.md` is the script — including which four
templates you launch by hand and which seven you must *not* (that distinction caused
a real failure; see LESSONS-LEARNED F1).

---

## Step 5 — before you demo to a customer

- **Run it end to end the day before.** Not the hour before.
- **Know the reset.** The run book has a reset procedure and a mid-demo recovery path.
  Read both.
- **Know what is unverified** — CLAUDE.md §6. Do not claim the Lightspeed SaaS path or
  an OpenShift AI backend works from this repo; neither has been run end to end.
- **The AI is advisory.** If someone asks whether you would run this in production,
  the answer is in the human-in-the-loop checkpoint and the Git audit trail, not in
  the model quality. Lead with that.
- **Local inference is slow.** On CPU, the RCA step takes a while. Either narrate it,
  or point the demo at a real endpoint with `scripts/set-ai-endpoint.sh`.

---

## Security expectations for you as the new owner

Non-negotiable — the full model is in `docs/SECURITY.md`:

1. **Never commit a secret.** Everything is read from environment variables so that no
   secret ever needs to be written down or shown. A Lightspeed key was once pasted
   into a chat transcript during development and had to be treated as compromised —
   do not repeat it.
2. **Never widen ingress to `0.0.0.0/0`.** It is scoped to your `/32` automatically.
   If you need a colleague in, add their `/32`.
3. **Never print subscription pool IDs.** They identify the account.
4. **Rotate the demo passwords** if this environment will live longer than a demo.
   They are deliberately weak lab defaults.

---

## If it fails

1. `README.md` → **Troubleshooting**.
2. `docs/LESSONS-LEARNED.md` — search the error text. Twenty failure modes are
   documented there with root causes; the odds are good.
3. Useful one-shots:

```bash
./scripts/attach-subscription.sh --list      # entitlement problems; prints pool fields
./scripts/demo_content.sh                    # re-converge all AAP/EDA/Gitea config
./scripts/set-ai-endpoint.sh                 # repoint the AI without a rebuild
```

Two failure modes worth knowing before you hit them, because both *look* like
something else:

- **`403` on creating an inventory host** is a **subscription** problem, not
  permissions. Hosts consume entitlements.
- **EDA activation times out** — something is using a public IP where it needs a
  private one. Nothing inside the VPC can reach an Elastic IP.

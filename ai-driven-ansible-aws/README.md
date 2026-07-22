# AI-Driven Ansible Automation — AWS IaC

Terraform + Ansible to stand up the Red Hat
[Introduction to AI-Driven Ansible Automation](https://rhpds.github.io/showroom-ai-driven-ansible-automation/modules/index.html)
demo in your own AWS account, with secure, runtime-only secret handling.

The upstream lab is normally delivered pre-built by the Red Hat Demo Platform
(demo.redhat.com). This project reproduces the environment described in that
lab as reusable Infrastructure as Code so you can run it in your own account.

## Architecture

Two RHEL 9 nodes in a dedicated VPC (public subnet, internet gateway):

- **control** (`m6i.2xlarge`) — Ansible Automation Platform 2.5 (containerized,
  all-in-one incl. EDA), plus Kafka (KRaft), Gitea, and Mattermost as Podman
  Quadlet services.
- **target** (`t3.medium`) — the RHEL webserver running `httpd` with Filebeat
  shipping Apache logs to Kafka on the control node. This is the service that
  "fails" and is auto-remediated.

```
        operator (your IP /32 only)
                 │  22 / 443 / 488 / 8065              22 / 80
                 ▼                                         ▼
      ┌────────────────────────┐   Kafka 9092    ┌────────────────────┐
      │  control  (private SG) │◀────────────────│  target (private SG)│
      │  AAP + EDA             │                 │  httpd + Filebeat    │
      │  Kafka / Gitea / MM    │───── SSH 22 ────▶│  (managed by AAP)    │
      └────────────────────────┘   run job templ └────────────────────┘
```

Security defaults: default-deny security groups scoped to your workstation IP
(never `0.0.0.0/0`), IMDSv2 enforced, EBS encrypted with a customer-managed KMS
key, least-privilege instance role (optional SSM Session Manager, nothing
else), and Terraform state that contains **no credentials**. See
[docs/SECURITY.md](docs/SECURITY.md).

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
│   ├── inventory.ini.tmpl       # rendered at runtime from TF outputs
│   ├── group_vars/all.yml       # non-secret config; secrets via env lookups
│   └── roles/ common target control_base kafka gitea mattermost aap demo_content
└── scripts/
    ├── bootstrap.sh             # orchestrator (provision + configure)
    ├── collect-secrets.sh       # hidden-input secret prompts (sourced)
    ├── preflight.sh             # tool checks
    └── cleanup.sh               # unregister + destroy
```

## Prerequisites

On your workstation: `terraform` (>=1.5), `aws` CLI v2, `ansible-core`
(provides `ansible-playbook`/`ansible-galaxy`), plus `jq`, `curl`, `envsubst`
(gettext), and OpenSSH. Run `scripts/preflight.sh` to check. On macOS control
nodes also `pip install passlib` (Ansible needs it to hash the lab-user
password; Linux uses the system `crypt`).

Before you run, have ready:

- **AWS access via SSO or a named profile** — `aws sso login --profile <p>`
  (or exported temporary STS creds). No AWS keys are ever entered into this
  tooling.
- **A Red Hat subscription that includes Ansible Automation Platform 2.5** and
  either an **activation key + org ID** (recommended) or username/password.
- A **registry.redhat.io service account** (username + token) for pulling AAP
  container images. Create one at <https://access.redhat.com/terms-based-registry/>.
- *(Optional)* an **Ansible Lightspeed** API key and a **Red Hat AI** model
  serving endpoint + key for the inference steps. Without these, the platform
  still builds; the AI wiring is left as documented hooks.

## Quick start

```bash
cd ai-driven-ansible-aws

# 1. Authenticate to AWS (SSO example)
aws sso login --profile my-sso-profile

# 2. Provision + configure. Prompts for Red Hat / app secrets at the start,
#    with hidden input. Ingress is auto-restricted to your public IP /32.
./scripts/bootstrap.sh --profile my-sso-profile --region us-east-1
```

That single command runs preflight, validates AWS creds, generates a local SSH
keypair (if needed), securely collects secrets, `terraform apply`, renders the
Ansible inventory from the outputs, waits for SSH, installs collections, and
runs `site.yml`. The AAP containerized install alone can take 20–40+ minutes.

Provision infrastructure only (no secrets, no config):

```bash
./scripts/bootstrap.sh --profile my-sso-profile --skip-ansible
```

## Accessing the environment

`bootstrap.sh` prints the URLs at the end (also `terraform -chdir=terraform
output`):

| System      | URL                          | Login                              |
|-------------|------------------------------|------------------------------------|
| AAP         | `https://<control-ip>`       | `lab-user` / *(password you set)*  |
| Gitea       | `http://<control-ip>:488`    | `lab-user` / *(password you set)*  |
| Mattermost  | `http://<control-ip>:8065`   | `ansibleadmin@ansible.com` / *set* |
| Webserver   | `http://<target-ip>`         | —                                  |

AAP uses a self-signed certificate by default, so expect a browser warning.

## Demo content (the AI workflow itself)

The infrastructure and platform are fully automated. The demo's *content* — the
specific AAP job templates, workflows, EDA rulebook, and AI prompts — is
proprietary to the Red Hat Demo Platform and is **not** shipped here. It is
scaffolded as documented hooks in `ansible/roles/demo_content` (disabled by
default). To wire it up, supply your own content repo and enable the role — see
[`ansible/roles/demo_content/README.md`](ansible/roles/demo_content/README.md).

## Cost

Two on-demand instances (an `m6i.2xlarge` + a `t3.medium`), two EIPs, EBS, and a
KMS key. Roughly **US$0.50–0.60/hour** in `us-east-1` while running — dominated
by the control node. Destroy it when you are done.

## Cleanup

```bash
./scripts/cleanup.sh --profile my-sso-profile
```

This unregisters the nodes from Red Hat Subscription Management (so you don't
leak entitlements), then `terraform destroy`s everything and removes the
generated inventory. Add `--delete-ssh-key` to also remove the local keypair.

## Troubleshooting

- **AAP install fails** — it is version/entitlement sensitive. Confirm your
  subscription includes AAP 2.5 and that the repo/package resolve on your RHEL
  9 minor. Check `~lab-user/aap_install*.log` on the control node. You can set
  `aap_install_enabled: false` in `ansible/group_vars/all.yml` to build
  everything else, then install AAP by hand.
- **No RHEL AMI found** — pass an explicit `TF_VAR_rhel_ami_id`, or run
  Terraform with a region where Red Hat publishes RHEL 9 GP3 AMIs.
- **SSH not ready** — new instances take a minute; the script retries. Confirm
  your public IP hasn't changed (re-run with `--ingress-cidr`).
- **Re-running** — both Terraform and Ansible are idempotent; re-run
  `bootstrap.sh` to converge.

## Disclaimer

Community tooling, not an official Red Hat distribution of the lab. Review
[docs/SECURITY.md](docs/SECURITY.md) before using beyond a personal demo.

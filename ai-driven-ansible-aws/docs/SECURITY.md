# Security model

## Credential handling

**AWS.** Authentication uses your active credential chain only — AWS SSO, a
named CLI profile, or exported temporary STS credentials. The scripts never
prompt for, echo, or store an AWS access key or secret. `bootstrap.sh` and
`cleanup.sh` verify access with `aws sts get-caller-identity` and stop with
instructions if none is active. Recommended: `aws sso login --profile <p>` or
`assume-role` producing short-lived credentials.

**Red Hat and application secrets.** Collected at runtime by
`scripts/collect-secrets.sh` using hidden input (`read -rs`, confirmed where it
matters). They are:

- **exported to the process environment only** — never written to any file;
- **read by Ansible via env lookups** declared in `ansible/group_vars/all.yml`
  (e.g. `lookup('ansible.builtin.env', 'AAP_ADMIN_PASSWORD')`), so they are
  **not** passed as `-e` command-line args (which would show in `ps`/history);
- **scrubbed on exit** — `bootstrap.sh` traps `EXIT/INT/TERM` and `unset`s them;
- **marked `no_log: true`** on every task that consumes them, so they never
  appear in Ansible output or logs.

No credential, token, password, or API key is hardcoded anywhere in this repo.
The only secret-like value that touches disk on your workstation is the SSH
**private** key (mode `0600`, generated locally); only its **public** half is
ever sent to AWS.

## Terraform state contains no credentials

By design, Terraform only ever receives non-secret inputs: region, the ingress
CIDR, and your **public** SSH key. `user_data` is secret-free (it only installs
python3 and sets the hostname). Therefore `terraform.tfstate` holds no
passwords, tokens, or private keys.

Still recommended for team use: enable the encrypted, locked S3 backend stubbed
in `terraform/versions.tf` (`encrypt = true` + a DynamoDB lock table), and
restrict access to the state bucket.

## Secrets that necessarily live on the instances

A running demo must hold some secrets on the control node for the services to
function — the AAP admin/database passwords (in the containerized installer
inventory it writes) and any Lightspeed/AI keys you configure into AAP. These
are mitigated, not eliminated:

- written **mode `0600`, root/lab-user-owned**;
- on **EBS volumes encrypted at rest** with a customer-managed KMS key
  (`aws_kms_key.ebs`, rotation enabled);
- reachable only through **default-deny security groups** scoped to your IP;
- for anything beyond a demo, store operational secrets in **AAP's own
  credential store** / an external vault rather than plaintext inventory.

This is the one place secrets are persisted server-side; it is called out here
so the trade-off is explicit. The containerized-installer inventory it renders
is also covered by `.gitignore` patterns and lives only on the control node.

## Network & host hardening

- **Security groups**: default-deny. Operator ingress (22/443/488/8065 on
  control; 22/80 on target) is limited to `allowed_ingress_cidrs`
  (auto-detected as your `/32`). A Terraform validation rule **rejects
  `0.0.0.0/0`**. Inter-node paths (Kafka 9092; control→target SSH/HTTP) use
  security-group references, not IP ranges.
- **IMDSv2 enforced** (`http_tokens = required`) with hop limit 1, mitigating
  SSRF-based credential theft from instance metadata.
- **EBS encryption** on every root volume via the customer-managed CMK.
- **Least-privilege IAM**: the instance role grants only the AWS-managed
  `AmazonSSMManagedInstanceCore` (optional, for keyless Session Manager access)
  — no S3, no secrets, no broad EC2/IAM permissions.
- **SSH host keys**: `accept-new` (trust-on-first-use) via `ansible.cfg`, so
  freshly provisioned hosts are recorded then verified, avoiding blind
  `StrictHostKeyChecking=no`.

## Demo content configuration (`demo_content` role)

This stage creates the Gitea repos and configures AAP and EDA. Its secret
handling:

- **Where the calls originate.** Gitea and Mattermost are configured over
  `127.0.0.1` on the control node, so the Gitea API token and the Mattermost
  session token never traverse the network. The AAP and EDA API calls are
  `delegate_to: localhost` — the workstation is the only place that holds the
  `ansible.controller` collection and the target's SSH private key.
- **Secrets land in AAP's encrypted credential store, not in playbooks.** The
  AI endpoint key, Gitea token and Mattermost webhook are held in three custom
  credential types and injected as extra vars at job run time. They are
  encrypted at rest, masked in job output, and rotatable without editing any
  playbook. The target's SSH private key is read from the workstation and pushed
  straight into a Machine credential; it is never written to the repo, the
  rendered inventory, or Terraform state.
- **`no_log` coverage.** Every task whose module arguments contain a password,
  token, key or webhook URL sets `no_log: true`. Because the EDA REST calls carry
  basic-auth in their arguments, all of them are `no_log`; each mutating call is
  therefore paired with a follow-up task that surfaces only the HTTP status and
  response body, so API errors remain diagnosable without leaking credentials.
- **One deliberate exception.** The AAP admin password is passed to the
  `ansible.controller` modules through block-level `environment:`
  (`CONTROLLER_PASSWORD`), which is the collection's documented mechanism. Env
  values are not included in task results or `invocation.module_args`; they are
  visible only at `-vvvv`. Avoid running the demo content stage at that
  verbosity in a shared terminal or CI log.
- **Gitea token scope and rotation.** The token minted for AAP is scoped to
  `write:repository` only, and is deleted and re-minted on every run so the value
  stored in AAP is always current.
- **Gitea and Mattermost remain HTTP** on their host ports, reachable only from
  your `/32`. Acceptable for a demo; see below before going further.

## Mattermost open signups

Mattermost 9+ disables open signups by default, which blocks the unauthenticated
"create the first user" API call this build relies on to bootstrap its admin. The
Quadlet unit therefore sets `MM_TEAMSETTINGS_ENABLEOPENSERVER=true`
(`mattermost_allow_open_signup`), and the password policy is relaxed so a short
lab password is accepted.

Both are demo conveniences with bounded exposure — port 8065 is only reachable
from `allowed_ingress_cidrs` (your `/32`), never the internet. Do not carry this
pattern into anything shared: create the first admin out of band (`mmctl` in local
mode against the container's socket), leave `EnableOpenServer` false, and keep the
default password policy.

## AI inference

- **The local CPU endpoint is not exposed.** Ollama's port is opened in firewalld
  only so AAP's rootless execution environments can reach it over the control
  node's private address; no security group rule publishes it, so it is
  unreachable from outside the VPC.
- **External endpoints.** When you point the demo at OpenShift AI Model Serving,
  RHEL AI or MaaS, the endpoint URL and its bearer token are stored in AAP's
  encrypted credential store and injected as extra vars at job run time — masked
  in job output and never written to the repo or the inventory. Prefer an endpoint
  reachable privately (VPC peering, PrivateLink, or an internal route) over one
  published to the internet, and scope the token to the single model.
- **What leaves your environment.** The demo sends real log excerpts from the
  target host to whichever endpoint you configure. With the local endpoint or an
  in-cluster OpenShift AI model, that data never leaves your infrastructure. With
  a hosted service, treat those logs as data shared with a third party.

## Recommended hardening beyond this demo

- Put the nodes in private subnets behind a bastion / SSM-only access and drop
  public IPs.
- Terminate TLS for Gitea/Mattermost (this build serves them over HTTP on their
  host ports) and use a trusted certificate for AAP.
- Use SCA + activation keys scoped to the minimum products required.
- Rotate the demo SSH key and destroy the environment when finished
  (`scripts/cleanup.sh`).

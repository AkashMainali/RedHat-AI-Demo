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

## Recommended hardening beyond this demo

- Put the nodes in private subnets behind a bastion / SSM-only access and drop
  public IPs.
- Terminate TLS for Gitea/Mattermost (this build serves them over HTTP on their
  host ports) and use a trusted certificate for AAP.
- Use SCA + activation keys scoped to the minimum products required.
- Rotate the demo SSH key and destroy the environment when finished
  (`scripts/cleanup.sh`).

# `demo_content` — the demo, as code

Everything the AI-driven Ansible automation demo needs, built idempotently from
this role. Enabled by default (`demo_content_enabled: true`).

Content is adapted from the public Red Hat Demo Platform lab
[`ansible-tmm/aiops-summitlab`](https://github.com/ansible-tmm/aiops-summitlab),
so the published showroom modules can be followed verbatim.

## What it creates

| Stage | File | Resources |
|---|---|---|
| Gitea | `tasks/gitea.yml` | `aiops-demo` + `lightspeed-playbooks` repos, a scoped API token, all demo content pushed via the contents API, and a placeholder so the second project can sync before the first AI run |
| Mattermost | `tasks/mattermost.yml` | `Automators` team, Town Square membership, incoming webhooks enabled, the `AAP AIOps` webhook |
| AAP credentials | `tasks/aap_credentials.yml` | 3 custom credential types + 6 credentials (machine, SCM, AAP, AI, Gitea, Mattermost) |
| AAP inventory & projects | `tasks/aap_inventory_projects.yml` | `lab-inventory` with the target host, `AI-EDA` and `Lightspeed-Playbooks` projects |
| AAP job templates | `tasks/aap_job_templates.yml` | All 10 job templates, named exactly as the lab |
| AAP workflows | `tasks/aap_workflows.yml` | Both workflows, fully wired |
| EDA | `tasks/eda.yml` | Project, AAP + SCM credentials, and the `Web App` rulebook activation on Kafka |

## Design decisions worth knowing

**Where each API call runs.** Gitea and Mattermost are configured over
`127.0.0.1` on the control node, so their tokens never cross the network. The
AAP and EDA calls are `delegate_to: localhost` — the operator's workstation is
the only place that has both the `ansible.controller` collection and the target's
SSH private key.

**No Automation Hub token needed.** `ansible.controller` ships inside the AAP
containerized setup bundle already in `ansible/aap/`. `bootstrap.sh` extracts it
to `ansible/.aap-collections/` and prepends that to `ANSIBLE_COLLECTIONS_PATH`.
EDA is configured through its REST API instead, because the bundle does not
include `ansible.eda`.

**Configuration lives in credentials, not playbooks.** Endpoints, tokens and
webhook URLs are injected as extra vars by three custom credential types, so
they are encrypted at rest in AAP, hidden in job output, and rotatable without
editing any playbook. Every task touching them sets `no_log: true`.

**Private addressing.** AAP reaches Kafka, Gitea, Mattermost and the AI endpoint
over the control node's private IP, and the target over its private IP. Public
IPs are used only by your browser and the delegated API calls.

**Emoji job template names.** Defined once in `defaults/main.yml` and injected
into the two templates that create other templates. Never retyped — a
variation-selector mismatch between two files would be a genuinely nasty bug to
track down.

## Re-running

Safe. Repos, credentials, templates and workflows converge. Two exceptions,
both deliberate:

- the Gitea API token is deleted and re-minted each run, so the value stored in
  AAP is always one this run knows;
- the EDA rulebook activation is deleted and recreated, because activations are
  immutable once running.

## Editing the demo content

Edit under `files/repo/` and re-run `bootstrap.sh`. Committing directly in Gitea
works for quick experiments but will be overwritten on the next run.

## Skipping this stage

Set `demo_content_enabled: false` in `ansible/group_vars/all.yml` to build the
infrastructure and platform only. The role fails soft with actionable guidance
if AAP has no subscription attached yet, which is the most common first-run
problem — attach one in the UI and re-run.

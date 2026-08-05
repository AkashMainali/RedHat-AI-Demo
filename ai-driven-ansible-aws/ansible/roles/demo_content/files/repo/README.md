# AI-Driven Ansible Automation — demo content

This repository is created and populated automatically by the
`ai-driven-ansible-aws` IaC. It is the SCM source for the **AI-EDA** project in
Ansible Automation Platform and for the EDA rulebook activation.

Content is adapted from the public Red Hat Demo Platform lab
[`ansible-tmm/aiops-summitlab`](https://github.com/ansible-tmm/aiops-summitlab),
with three changes so it runs outside RHPDS on the default execution
environment:

| Change | Reason |
|---|---|
| AI calls use `/v1/chat/completions` | Universally supported by Ollama, vLLM, RHEL AI, OpenShift AI and MaaS. The lab used the legacy `/v1/completions`. |
| Mattermost via `ansible.builtin.uri` webhook | Avoids needing `community.general` in the execution environment. |
| Git writes via the Gitea contents API | Avoids needing `ansible.scm`, a git binary, or SSH keys inside the EE. |

No endpoint, token, or password is hardcoded. Everything arrives as extra vars
injected by AAP custom credentials.

## Flow

```
Break Apache  ──▶ Filebeat ──▶ Kafka ──▶ EDA rulebook
                                            │
                        ┌───────────────────▼────────────────────┐
                        │  Enrichment workflow                   │
                        │  1. systemd_check_status                │
                        │  2. ai_analyze_incident   (RCA + prompt) │
                        │  3. notify_mattermost                   │
                        │  4. build_lightspeed_job_template       │
                        └───────────────────┬────────────────────┘
                                            │  ◀── human reviews the prompt
                        ┌───────────────────▼────────────────────┐
                        │  Remediation workflow                  │
                        │  1. generate_remediation_playbook       │
                        │  2. commit_to_gitea                     │
                        │  3. Project sync (Lightspeed-Playbooks) │
                        │  4. build_httpd_remediation_template    │
                        └───────────────────┬────────────────────┘
                                            │  ◀── operator launches with --limit
                                   Execute HTTPD Remediation
```

## Files

| Path | Role in the demo |
|---|---|
| `playbooks/httpd_break.yml` | Creates the incident |
| `playbooks/httpd_fix.yml` | Resets Apache between demo runs |
| `playbooks/systemd_check_status.yml` | Collects journal logs, builds the AI prompts |
| `playbooks/ai_analyze_incident.yml` | Calls the model for a fix instruction and an RCA |
| `playbooks/notify_mattermost.yml` | Posts logs + RCA to the chat channel |
| `playbooks/build_lightspeed_job_template.yml` | Turns the AI prompt into a reviewable survey |
| `playbooks/generate_remediation_playbook.yml` | Generates the fix playbook |
| `playbooks/commit_to_gitea.yml` | Commits the fix, normalising `hosts`/`become` |
| `playbooks/build_httpd_remediation_template.yml` | Creates the job template that applies the fix |
| `rulebooks/web_app.yml` | EDA rulebook watching the Kafka topic |

## Artifacts passed between nodes

Workflow nodes communicate with `set_stats`:

| Artifact | Produced by | Consumed by |
|---|---|---|
| `incident_service`, `incident_host`, `incident_summary` | `systemd_check_status` | `notify_mattermost` |
| `fix_prompt`, `rca_prompt` | `systemd_check_status` | `ai_analyze_incident` |
| `ai_fix_instruction`, `ai_rca_text` | `ai_analyze_incident` | `notify_mattermost`, `build_lightspeed_job_template` |
| `generated_playbook`, `generated_by` | `generate_remediation_playbook` | `commit_to_gitea` |

## Editing this content

Commit here and the AAP projects pick it up on next sync (both are
`update_on_launch`). Re-running the environment's `bootstrap.sh` re-pushes the
IaC copy and will overwrite local edits — make lasting changes in
`ansible/roles/demo_content/files/repo/` in the IaC repo instead.

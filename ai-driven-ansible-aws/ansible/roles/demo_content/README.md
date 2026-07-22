# demo_content role — hooks for the AAP/EDA demo objects

This role is a **wiring point**, disabled by default. The infrastructure and
platform (AAP, EDA, Kafka, Gitea, Mattermost, httpd, Filebeat) are fully built
by the other roles. What lives here is the demo's *content*, which is
proprietary to the Red Hat Demo Platform and therefore **not shipped**:

- the three AAP **job templates** (log enrichment, remediation, execute HTTPD fix)
- the two **workflows** that chain them
- the **EDA rulebook** that consumes the Kafka `httpd-events` topic
- the exact **AI prompts** and the Red Hat AI / Lightspeed **credentials**

## Enabling

1. Put your copy of the playbooks/rulebooks in a Git repo and set
   `demo_content_git_url` in `group_vars/all.yml`.
2. Install the AAP config collections (from Red Hat Automation Hub):
   `awx.awx` (or `ansible.controller`), `ansible.eda`, `infra.aap_configuration`.
3. Set `demo_content_enabled: true`.
4. Implement the resource-creation tasks in `tasks/main.yml` where indicated.

## Inputs already available to you

| Purpose            | Variable / source                                   |
|--------------------|-----------------------------------------------------|
| AAP admin password | `aap_admin_password` (env `AAP_ADMIN_PASSWORD`)     |
| AAP URL            | `https://{{ control_public_ip }}`                   |
| Kafka bootstrap    | `{{ control_private_ip }}:{{ kafka_port }}`         |
| Kafka topic        | `{{ kafka_topic }}`                                 |
| Gitea repo         | `remediation` on `http://{{ control_public_ip }}:488` |
| Lightspeed API key | `lightspeed_api_key` (env `LIGHTSPEED_API_KEY`)     |
| Red Hat AI endpoint| `ai_model_endpoint` / `ai_model_api_key`            |

All credential-bearing tasks must set `no_log: true`.

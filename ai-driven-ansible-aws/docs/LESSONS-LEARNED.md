# Lessons learned

Every defect that cost real time during this build, with its root cause and the
general rule it implies. This is the most valuable file in the repo for anyone
extending it: each entry is a trap already sprung, and several of the fixes look
arbitrary until you know what they are defending against.

Format: **symptom** → what it actually was → what fixed it → **the rule**.

---

## A. Networking and addressing

### A1. EDA: `Connection timeout to https://<public-ip>/api/v2/config/`

The EDA credential pointed at the control node's **Elastic IP**. An EIP is not
routable from inside the VPC — traffic to it from a VM in the same VPC does not
hairpin back. So EDA, running on the control node, could not reach the controller
that was on the same host.

**Fix:** introduced `aap_controller_host_internal` (private address) alongside
`aap_controller_host` (public, for browsers). Corrected the `Demo AAP` credential,
which had the same flaw, and added a PATCH so existing environments self-correct on
re-run.

> **Rule:** anything inside the VPC talks over **private** addresses. Public
> addresses are for the operator's browser only. This bug presents as a firewall or
> security-group problem and will send you looking in the wrong place.

### A2. EDA: `404 /api/v2/config/`

The AAP **gateway** serves the controller under `/api/controller/v2/`, not
`/api/v2/`. My first fix was a second guess at the URL; that was the wrong instinct.

**Fix:** replaced guessing with **discovery** — probe `https://<priv>:8443`,
`https://<priv>`, and `:8013` for whichever answers `/api/v2/config/`, and use that.

> **Rule:** when a URL depends on topology you do not control, probe for it. Two
> guesses in a row means you are guessing.

---

## B. Ordering and lifecycle

### B1. `ansible-vault: command not found`

The `aap` role invoked `ansible-vault` roughly ten tasks *before* it installed
`ansible-core`. Worse, the role's `rescue` block blamed **registry credentials**, so
the error message actively misdirected.

**Fix:** reordered to validate → install `ansible-core` + archive tools → locate
`ansible-vault` (and use the resolved absolute path) → hostname/`/etc/hosts` → vault
file → tarball → installer → subscription. Added plaintext cleanup. Rewrote the
rescue to report the *actual* failing task.

> **Rule:** a `rescue` block that guesses at causes is worse than no rescue. Report
> the failing task name first, and only then interpret.

### B2. `activation with this name already exists` — on a delete-then-create

EDA deletes rulebook activations **asynchronously**. The create fired before the
delete had landed.

**Fix:** disable → delete → **poll until the count is 0** → create.

> **Rule:** never assume a REST delete is synchronous. Poll for absence.

### B3. `403 PATCH /api/controller/v2/credential_types/33/`

AAP refuses to modify a credential type that has credentials attached — and reports
it as **403**, not 400, so it reads as a permissions problem. My rescue block then
misclassified it as an auth failure because the message contained the word
"credential".

**Fix:** added schema-drift migration — detect a changed field list, delete the
dependent credentials first, then update the type. Declared each field list once in
`set_fact` and reused it for both definition and drift detection so the two cannot
diverge.

> **Rule:** classify failures by **failing task name first**, then by message text.
> Text matching alone misdiagnoses; at one point my own error message containing
> "403" and "/hosts/" caused the handler to misdiagnose itself.

---

## C. Licensing and entitlement

### C1. `403 POST /api/controller/v2/hosts/` — which is not an RBAC error

**Hosts** are what consume AAP entitlements. Without an attached subscription the
controller happily accepts inventories and groups, then rejects `POST /hosts/` with
403. The failure therefore surfaces several steps into demo content and looks like a
permissions problem.

**Fix:** automatic subscription attach in `aap/tasks/subscription.yml`, plus an
up-front subscription pre-check in `demo_content` so it stops early with actionable
guidance.

> **Rule:** know which API objects consume entitlements. A 403 on a write is not
> automatically about permissions.

### C2. Pool selection silently produced nothing — "attach → not attempted"

Two bugs stacked:

1. **Response shape.** The pools endpoint has returned both a bare JSON array and an
   object wrapping the array in `results`, across versions. I assumed one.
2. **String sort.** `instance_count` comes back as a *string*, so "largest pool"
   sorted lexicographically — `"99" > "500"`. I proved this with a test before
   believing it.

**Fix:** normalise both shapes; cast `instance_count` to `int` before ordering; print
the pools (names and node counts only) so a silent selection failure is visible.

> **Rule:** print the intermediate selection. A silent wrong choice is far more
> expensive than a noisy one.

### C3. `400 {"error":"No subscription ID provided."}`

The pool objects did not carry `pool_id`, so the attach POSTed `null`.

**Fix:** detect the identifier across `pool_id` / `subscription_id` / `id` and send
it under **all three** names — versions that read only one ignore the rest.
`attach-subscription.sh --list` now also prints the pool objects' actual field names
as a diagnostic.

> **Rule:** still unconfirmed against a live response (see `CLAUDE.md` §6). When you
> infer a fix from an error message, say so and ship the diagnostic that would
> confirm it.

---

## D. Talking to a model server

### D1. `cannot unmarshal string into Go struct field ChatCompletionRequest.max_tokens of type int`

Ansible's Jinja returns **strings** by default. Ollama is written in Go and
unmarshals strictly, so `max_tokens: "120"` is a type error.

**Fix:** build the whole request body as a single Jinja dict expression so numeric
types survive:

```yaml
body: >-
  {{ { 'model': _model,
       'messages': [ {'role':'system','content':_system_fix},
                     {'role':'user','content':fix_prompt} ],
       'max_tokens': ai_fix_max_tokens | default(120) | int,
       'temperature': 0.0 | float } }}
```

Then swept the repo for every other numeric field.

> **Rule:** any JSON body with numbers gets built as one dict expression with
> explicit casts. Never as YAML key/value pairs.

### D2. `the JSON object must be str, bytes or bytearray, not dict`

`lookup('template')` had **already parsed** the JSON — `convert_data` behaviour
varies by Ansible version — so the subsequent `from_json` received a dict.

**Fix:** replaced both survey JSON templates with **native YAML dicts** and deleted
the `.j2` files.

> **Rule:** do not round-trip data through a template just to build a structure
> Ansible can express natively.

### D3. "the model did not return a usable Ansible Playbook"

`granite3.1-dense:2b` is a small **chat** model. Asking it to emit clean YAML was
asking the wrong tool.

**Fix:** a two-model split — `granite3.1-dense:2b` for chat/RCA, `qwen2.5-coder:3b`
for code generation. Plus a far more tolerant parser (strips fences, drops prose
preambles, wraps a bare task list or single play), tested against six real output
shapes; a few-shot prompt; and diagnostics that distinguish "chat model used for
code" from "model genuinely failed".

> **Rule:** on CPU-hosted inference, match the model to the job. And parse model
> output defensively — it is text, not an API.

### D4. `model 'qwen2.5-coder:3b' not found`

`demo_content.sh` ran without the `ai` tag, so the second model was never pulled —
while the AAP credential already advertised it. Configuration and reality diverged
silently.

**Fix:** `--tags demo_content` now auto-expands to `demo_content,ai` in *both*
`demo_content.sh` and `bootstrap.sh`; added a model-availability guard up front, set
`OLLAMA_MAX_LOADED_MODELS=2`, and warm both models.

> **Rule:** if stage A declares what stage B must provide, they belong in the same
> run. Enforce it in code, not in documentation.

---

## E. API idioms

### E1. `No first item, sequence was empty` — Mattermost webhook

Two mistakes in one task: it relied on `uri`'s `changed` flag (**not set for POST**),
and the fallback searched the *pre-creation* list, which is empty on a fresh
environment.

**Fix:** list → create → **re-list** → select by `display_name`. Gated the smoke test
on `not (_mm_hook_new.skipped | default(false))`.

> **Rule:** after a POST, re-query and select by a stable attribute. Never infer
> success from `changed`.

### E2. `Variables ansible_eda are not allowed on launch`

Both workflows lacked `ask_variables_on_launch: true`. This was the reason "Break
Apache" appeared to do nothing at all — the rulebook fired, the launch was rejected,
and nothing surfaced in the UI.

**Fix:** set it on both workflows and in the runtime patch.

> **Rule:** an event-driven chain fails *silently* by default. Verify each hop
> produced its effect; do not infer it from the absence of an error.

### E3. `args: "{{ some_dict }}"` is unsafe

Produced a warning and unpredictable argument expansion.

**Fix:** `module_defaults` (or a block-level `environment:`) instead. Note that
`module_defaults` group naming is version-sensitive — `demo_content/tasks/main.yml`
uses a block-level `environment:` with `CONTROLLER_HOST` / `CONTROLLER_USERNAME` /
`CONTROLLER_PASSWORD` / `CONTROLLER_VERIFY_SSL` for exactly that reason.

---

## F. Documentation and demo delivery

### F1. The operator launched a workflow *node* directly → "No prompt supplied"

Not a code defect — a **docs** defect. The run book did not distinguish the four
templates you launch by hand from the seven that only ever run as workflow nodes.

**Fix:** rewrote the run book to separate them explicitly and to name the **Type**
column so the reader can tell a workflow from a job template in the UI.

> **Rule:** if the environment lets someone do the wrong thing, the run book must
> name the wrong thing. "Do not launch these" is real content.

---

## G. Diagrams

### G1. SVG invalid XML at line 84

**XML comments cannot contain `--`.** My dashed section separators
(`<!-- ---- SECTION ---- -->`) were illegal. Twenty-two comments affected.

**Fix:** use `=` for separator rules.

### G2. Layout defects invisible to structural checks

XML parsed, element counts were right — and the render had legend text running past
the canvas edge, arrows striking through labels, and text wider than its container.

**Fix:** rebuilt at 1800×1280 with measured text widths (≈0.52 × font-size per
character), rerouted the arrows through the gaps between boxes, and added an
automated containment audit.

### G3. My own overflow audit produced 50+ false positives

It ignored the `y` coordinate, so it compared the title against the operator box.

**Fix:** require **both** x and y containment, and select the smallest enclosing box
by area. Then it reported cleanly.

> **Rule:** render it and *look at it*. And when a checker reports dozens of
> failures, suspect the checker first.

---

## H. Process lessons, from direct feedback

These came from Akash telling me I had got it wrong. They are worth more than the
technical ones.

1. **"Why is it asking me for input like this — I thought we reverted it?"** (asked
   three times) — I had wrongly stripped the AI/Lightspeed prompts while reverting an
   unrelated change. Restored as *optional*. **Reverting a feature is not the same as
   deleting its interface.**

2. **"I want to run complete, I don't want to run separately."** — `bootstrap.sh` was
   warning and continuing past a failure that made a later stage certain to fail.
   Changed to hard-fail at the real cause. **One command should either complete or
   stop at the actual problem.**

3. **"I just want to run demo_content.sh right now."** — I had handed off to a second
   script. Made `demo_content.sh` self-heal the subscription inline instead.
   **Do not make the user orchestrate your scripts.**

4. **"I don't want bootstrap.sh to prompt anything when it is running."** — Added
   `-y/--yes` and moved every prompt to *before* `tf_apply`/`run_site`, so a long run
   is genuinely unattended. **Collect all input up front; never block a 40-minute run
   on a question.**

5. **"Do not implement, just give me demo suggestions first."** — Ask before
   building. Respect the review step.

6. **"Can you use my credentials and log in for me?"** — Declined. The automation
   authenticates with credentials the operator supplies at runtime; taking someone's
   Red Hat login is not a shortcut worth having.

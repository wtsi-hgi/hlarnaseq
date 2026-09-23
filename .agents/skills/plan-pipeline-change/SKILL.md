---
name: plan-pipeline-change
description: Create a small, reviewable one-iteration plan for hlarnaseq. Use for features, fixes, refactors, module additions, parameter changes, docs updates, or test work. Saves artifacts/1_plan.md and stops for human approval.
---

# Plan Pipeline Change Skill

Use this skill when the user asks to plan any change to `hlarnaseq`, or when implementation is requested but no approved plan exists. This is the default for any pipeline change request, whether or not the user says the word "plan".

Skip this skill only when the user explicitly asks to bypass the plan/approval step for this change (e.g. "make this change directly", "skip the plan", "no plan needed"). In that case go straight to `implement-nfcore-nextflow`, but still keep the change small, still validate afterward, still don't commit, and say plainly that the plan step was skipped because the human asked for a direct change. See `AGENTS.md` § "Bypassing the plan/approve cycle" for the exact bar for what counts as explicit.

## Workflow

1. Read the user request and restate the target behavior.
2. Read `AGENTS.md` and enforce repository constraints.
3. Inspect the relevant pipeline files before planning. Common files include:
   - `main.nf`
   - `workflows/hlarnaseq.nf`
   - `nextflow.config`
   - `nextflow_schema.json`
   - `assets/schema_input.json`
   - `conf/test.config`
   - `tests/default.nf.test`
   - `modules.json`
   - `docs/usage.md`
   - `docs/output.md`
4. Check whether an existing nf-core module or subworkflow should be used before proposing custom process code.
5. If you need to clarify anything, ask questions.
6. Produce a minimal one-iteration plan using `references/plan-template.md`.
7. Save the complete proposed plan to `artifacts/1_plan.md`.
8. Keep scope tight:
   - list in-scope and out-of-scope items;
   - avoid broad rewrites unless explicitly requested;
   - keep the expected review under about 30 minutes.
9. Include coordinated file updates for any changed behavior:
   - parameters: `nextflow.config`, `nextflow_schema.json`, docs, tests;
   - sample sheet columns: `assets/schema_input.json`, docs, tests;
   - outputs: module/workflow emits, `docs/output.md`, nf-test snapshots;
   - tools: module metadata, active-Conda dependency assumptions, `CITATIONS.md`, versions.
10. Include validation commands with pass criteria and note likely blockers.
11. Stop and request human approval. Do not implement.

## Dependency and Container Policy

- Every runtime tool must come from the declaration of the process that uses it:
  an `environment.yml` feeding a `conda` directive, paired with a matching pinned
  `container` directive. Never plan a step that takes a tool from the environment
  Nextflow was launched in, from `$PATH`, or via `conda run -n <env>`.
- A plan that adds or changes a process must say which `environment.yml` provides
  each tool it calls, and at which pinned version.
- Plan custom Python and R scripts under `bin/`; they run against the
  interpreters their calling module declares.
- Prefer a module-local `${moduleDir}/environment.yml`. The shared
  `containers/datatools/` environment exists only for modules running this
  repository's own small `bin/` scripts over the same interpreters; read
  `containers/datatools/README.md` before planning an addition to it.
- Container creation, packaging, pulls, and containerized execution profiles may
  be planned. A tool with no Bioconda package needs a module-local `Dockerfile`
  plus a `scripts/build_image_*.sh`, as several modules already have.
- When adding a tool, document the pinned version, the image it resolves to under
  each profile, versions reporting, and citation impact.
- Large out-of-band **reference data** (`--hlala_graph_dir`,
  `--arcashla_reference_dir`, `--hibag_model`, `--hlapm_repo`) is the one
  legitimate operator-prepared input. It is data, not tools; each needs a helper
  script under `scripts/` that builds it inside the pipeline's own pinned image.

## Output

Return the completed plan sections in the same order as `references/plan-template.md`.

At the end, add:

`Approval needed: Please confirm this plan is approved. I will not implement until you approve.`

Persist the same content to `artifacts/1_plan.md` before finishing.

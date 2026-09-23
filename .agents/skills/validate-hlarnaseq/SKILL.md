---
name: validate-hlarnaseq
description: Validate hlarnaseq changes by running available nf-core, nf-test, and pre-commit checks; review plan compliance; and write artifacts/3_validate.md with findings and residual risks.
---

# Validate HLARNASeq Skill

Use this skill when asked to validate, review, or quality-check an implementation.

## Workflow

1. Read `AGENTS.md`.
2. Read `artifacts/1_plan.md` and `artifacts/2_implement.md` when present.
3. Create `artifacts/` if it does not exist.
4. Run `.agents/skills/validate-hlarnaseq/scripts/validate.sh` unless the user requests narrower validation.
   - Run the Nextflow testdata smoke check locally via `./pipeline_testdata_run.sh` (defaults to `-profile singularity`; override with `PROFILE=<profile>` or pass `-profile <profile>` through as an argument).
5. Review changed files against the approved plan.
6. Check for nf-core pipeline risks:
   - invalid channel contracts;
   - missing `emit` outputs;
   - missing or inconsistent versions reporting;
   - unvalidated parameters;
   - sample sheet schema/docs drift;
   - missing docs for new outputs;
   - missing tool citations;
   - active-Conda dependency gaps;
   - tests or snapshots that do not cover new behavior.
7. Save the validation report to `artifacts/3_validate.md`.
8. Report findings first, ordered by severity, with file and line references.
9. If no findings are found, state that explicitly and list residual risks.

## Required Report Sections

- Status summary
- Checks run
- Blocked checks
- Findings
- Plan compliance
- Residual risks
- Recommended next step

## Severity Guidance

- High: likely runtime failure, incorrect scientific result, invalid schema, broken test profile, a process missing its `conda`/`container` declaration or calling a tool that declaration does not provide.
- Medium: user-facing docs/schema drift, incomplete validation of changed workflow behavior, missing citations or versions for new tools.
- Low: maintainability issues, narrow docs gaps, minor style issues that do not affect execution.

## Conda and Container Policy

- Before validation, verify the **launcher** tools `nextflow`, `nf-test` and `nf-core` are available. These are the only tools expected from an environment rather than from a module's own declaration.
- If they are unavailable, put the launcher environment on `PATH` for the command: `export PATH="$HOME/miniforge3/envs/nf-core/bin:$PATH"; ...`.
- Every pipeline tool must come from its process's `conda`/`container` declaration. A `command not found` from inside a task is a **finding** — a wrong or missing `environment.yml`/`container`, or a run without a container profile — never something to fix by installing on the host or falling back to the launcher environment.
- Check that every process touched by the diff still declares both a `conda` and a `container` directive, that its `environment.yml` pins match what the script actually calls, and that a changed shared image had its tag bumped in `scripts/build_image_*.sh` and in **every** consuming module.
- Run `docker info` (and `singularity --version` / `apptainer --version` when relevant) and containerized `nextflow run` profiles — they are permitted and preferred when the runtime is available.
- If a container runtime or image is genuinely unavailable, record that as a blocked check with residual risk, not a policy skip.
- For pipeline smoke validation, run `./pipeline_testdata_run.sh` locally; it defaults to `-profile singularity` and clones `HLApm` into the run directory on first use.

# Sanger HPC deployment

An [Environment Modules](https://modules.readthedocs.io/) deployment of
wtsi-hgi/hlarnaseq for an LSF cluster. After `module load hlarnaseq/1.0` a user
gets four commands and needs to know nothing about Nextflow profiles:

| Command                                  | What it does                                                                      |
| ---------------------------------------- | --------------------------------------------------------------------------------- |
| `hlarnaseq [args...]`                    | Runs the pipeline in the foreground with `-profile singularity,sanger`            |
| `hlarnaseq-bsub [args...]`               | Submits the Nextflow **head process** to LSF; the pipeline then submits its tasks |
| `hlarnaseq-build-image <target>`         | Builds the four container images that are not published to a registry             |
| `hlarnaseq-build-reference <kind> <dir>` | Builds a large out-of-band reference dataset                                      |

Arguments are passed through to `nextflow run` unchanged. There are no site
defaults for `--gtf`, `--arcashla_reference_dir`, `--hibag_model` or
`--hlala_graph_dir`: users supply their own, as on a bare `nextflow run`.

Adapted from the [yascp](https://github.com/wtsi-hgi/yascp) v2.0 deploy scripts.

## Layout

```
scripts/sanger_hpc_deploy_scripts/
├── README.md                      this file
├── site.env.example               the ONE file a deployer edits (copy to site.env)
├── lib/common.sh                  shared logic, sourced by every wrapper
├── module_executables/            everything the modulefile puts on PATH
│   ├── hlarnaseq
│   ├── hlarnaseq-bsub
│   ├── hlarnaseq-build-image
│   ├── hlarnaseq-build-reference
│   └── help.info
├── sanger_module_files/1.0        modulefile template
└── tests/modulefile_smoke.sh      evaluates the modulefile's Tcl without Modules
```

`hlarnaseq-bsub` is a wrapper around `hlarnaseq`: it builds a log directory, wraps
that command in one `bsub` submission, and does nothing else. There is no separate
job script, so there is no second code path that can drift from the foreground one.

The wrappers are **location-independent**: each resolves the pipeline from its
own path (`../..` from this directory), so a git checkout, a versioned
`/software/...` install and a scratch copy all work with no edits. The one
consequence is that this directory cannot be moved out of the repository — the
whole repository is the deployable unit.

## Installing

```bash
# 1. Install the pipeline repository at a versioned path.
git clone https://github.com/wtsi-hgi/hlarnaseq /software/.../hlarnaseq/v1.0
cd /software/.../hlarnaseq/v1.0

# 2. Set site values (optional but recommended).
cd scripts/sanger_hpc_deploy_scripts
cp site.env.example site.env
$EDITOR site.env          # container cache, default queue, head-job memory

# 3. Build the four local images. NEEDS DOCKER - see below.
module_executables/hlarnaseq-build-image all

# 4. Install the modulefile and edit its two marked lines.
cp sanger_module_files/1.0 /software/modulefiles/hlarnaseq/1.0
$EDITOR /software/modulefiles/hlarnaseq/1.0
#   - set install <the path from step 1>
#   - uncomment the singularity and nextflow `module load` lines
tests/modulefile_smoke.sh /software/modulefiles/hlarnaseq/1.0   # check the Tcl

# 5. Check it.
module load hlarnaseq/1.0
hlarnaseq -v
DRY_RUN=1 hlarnaseq --outdir /tmp/x
```

`site.env` is not tracked by git, so a `git pull` in the install tree never
clobbers your site values. Precedence is: the user's own environment beats
`site.env`, which beats the built-in defaults — so a user can always override
the container cache or the queue without a deployer's help.

### Checking the modulefile before you install it

```bash
tests/modulefile_smoke.sh
```

Evaluates the modulefile's Tcl and runs `ModulesHelp` with the Modules commands
stubbed, so Tcl errors surface here rather than on a user's first `module help`.
Worth running after **any** edit to `sanger_module_files/*`, because a mistake in
`ModulesHelp` is invisible to review and to `module load` — that proc runs only for
`module help`. In particular, a Tcl proc does not see top-level variables unless it
declares them, so a variable added to the help text must also be added to the proc's
`global` line.

It does not check Modules-specific behaviour (`module-info version`, `prepend-path`,
the module hierarchy); `module help <name>` and `module load <name>` on the cluster
remain the real test.

### Nextflow version

This pipeline's manifest requires **Nextflow >= 25.04.0**. yascp's modulefile
loads `HGI/common/nextflow/24.10.4`, which is too old; point the modulefile at a
25.04+ module or the pipeline refuses to start.

## The four local images

`ARCASHLA_GENOTYPE`, `HLAPM_BUILD_REF`, `HLAPM_QUANTIFY_READS` and the shared
data-tools image (used by thirteen modules) are **not published to any registry**.
The modules reference them by path — `${projectDir}/containers/datatools/datatools.sif`
and `${moduleDir}/*.sif` — so the `.sif` files must physically sit inside the
install tree Nextflow runs from, and `*.sif` is in `.gitignore`, so a fresh
clone never carries them.

> **Known limitation.** `hlarnaseq-build-image` requires Docker: the underlying
> `scripts/build_image_*.sh` build with `docker build` and convert via
> `docker-daemon://`. A cluster node with Singularity alone cannot run them, and
> will stop with `ERROR: docker is required to build this image`.
>
> Until the images are published to a registry, a Singularity-only install needs
> the four `.sif` files produced on a machine that does have Docker and then
> copied into the install tree at:
>
> ```
> containers/datatools/datatools.sif
> modules/local/arcashla/genotype/arcashla-genotype.sif
> modules/local/hlapm/build_ref/hlapm-build-ref.sif
> modules/local/hlapm/quantify_reads/hlapm-quantify-reads.sif
> ```
>
> Publishing them to a registry is the real fix and is tracked separately.

Every other image the pipeline uses (STAR, Subread, samtools, HLA-LA, HIBAG,
validatefastq) is a public Biocontainers/Galaxy-depot/Wave image that Nextflow
pulls into `NXF_SINGULARITY_CACHEDIR`. Those need no build step at all.

## Why `-profile singularity,sanger`

Two profiles, and the order matters:

- `singularity` (from this repo's `nextflow.config`) enables the container
  engine. A profile is mandatory here — every process declares its own
  `conda`/`container` and takes nothing from the launching environment, so a
  run without one fails fast instead of silently using host tools.
- `sanger` comes from [nf-core/configs](https://github.com/nf-core/configs) and
  supplies the LSF executor, `perJobMemLimit`, a submit rate limit, farm22 queue
  selection by `task.time`/`task.memory`, and
  `--bind /lustre --bind /nfs --bind /data --bind /software`.

`sanger` does **not** enable Singularity itself, which is why both are needed.
It is consumed from nf-core/configs rather than vendored into this repo, so it
tracks upstream changes to the cluster automatically — but note it is fetched
over the network at startup unless `NXF_OFFLINE` is set.

## Notes for maintainers

`lib/common.sh` is the only place that knows where the pipeline lives, which
site values exist, which `NXF_*` variables a run needs, and how the `nextflow
run` command line is assembled. yascp duplicates all of that across ten
near-identical scripts, which is how they drifted apart; keep new wrappers thin.

Deliberate departures from the yascp scripts:

- **Nextflow runs in the foreground of the LSF job.** yascp backgrounds it with
  `&` inside the job script, so the script exits immediately and the head
  process is orphaned — `bjobs` and `bkill` then no longer describe the run.
- **No separate job script.** yascp pairs each `bsub_*.sh` with a
  `nohup_start_nextflow_lsf*.sh`; here `hlarnaseq-bsub` submits `hlarnaseq`
  directly. What makes that work is handing `bsub` a single already-quoted
  command string: `bsub` concatenates its trailing words and the job re-parses
  them through a shell, so passing argv as separate words would lose the quoting
  on any argument containing whitespace. `hlarnaseq_print_cmd` does the quoting,
  the job's shell undoes it, and the submitted string is saved to
  `hlarnaseq-run-logs/<timestamp>/command`.
- **No `rm -f *.log`** in the user's working directory. Logs go to a timestamped
  `hlarnaseq-run-logs/<timestamp>/` instead of being deleted and clobbered.
- **No interactive prompt** for the container cache: it would hang under `bsub`
  and in any script.
- **No `ts`/moreutils dependency** for log timestamping, and no `/dev/tcp` usage
  pings.
- **No `--nf_ci_loc`** — not a parameter of this pipeline; nf-schema would flag
  it as unrecognised.
- **No `-resume` injected automatically.** Silently resuming a run the user
  thought was fresh is a worse surprise than typing the flag.
- **`$install/bin` is not added to `PATH`.** Those scripts are staged into tasks
  by Nextflow and run under each module's declared interpreter; putting them on
  a user `PATH` would invite the launch-environment dependency this pipeline is
  built to avoid.

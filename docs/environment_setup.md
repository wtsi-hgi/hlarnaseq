# wtsi-hgi/hlarnaseq: environments and containers

**Every tool this pipeline runs is declared by the process that runs it** — an
`environment.yml` feeding that module's `conda` directive, paired with a matching
pinned `container` directive, resolved by Nextflow under `-profile conda`,
`docker`, `singularity` or `apptainer`. All 17 processes under `modules/local/`
and all vendored `modules/nf-core/` modules follow this pattern. **No pipeline
step takes a tool from the environment you launch Nextflow in**, and running with
none of those profiles makes each step fail fast with a message naming them
rather than silently using whatever is on the host `PATH`.

There are no `conda run -n <env>` call sites left in the pipeline, so no
environment _name_ matters at runtime.

## What you have to set up

### 1. A launcher environment

One environment, and nothing in the pipeline depends on it:

| Environment | File                                      | Used by                                                    | Needed for |
| ----------- | ----------------------------------------- | ---------------------------------------------------------- | ---------- |
| `nf-core`   | [`envs/nf-core.yml`](../envs/nf-core.yml) | Nextflow, nf-core and nf-test themselves; `testdata-make/` | Always     |

```bash
conda env create -f envs/nf-core.yml
# or: mamba env create -f envs/nf-core.yml - much faster if you have mamba installed
conda activate nf-core
```

It is an operator-prepared precondition, and the only one of its kind. It carries
no interpreters or libraries for the pipeline: those come from each module's own
declaration. `samtools` is listed only because the `testdata-make/` fixture
scripts invoke it directly.

### 2. Four locally built container images

Most modules resolve to public Biocontainers/Galaxy-depot/Wave images that
Nextflow pulls for you. Four do not — they are built on your machine and found in
your local Docker image store (or, for Singularity/Apptainer, as a local `.sif`
the `container` directive references by path). Run each once before your first
containerized run:

| Script                                  | Provides                                                   | Image                                             |
| --------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------- |
| `scripts/build_image_arcashla.sh`       | `ARCASHLA_GENOTYPE`                                        | `quay.io/hlarnaseq/arcashla-genotype:0.6.0`       |
| `scripts/build_image_hlapm.sh`          | `HLAPM_BUILD_REF`                                          | `quay.io/hlarnaseq/hlapm-build-ref:38faa60`       |
| `scripts/build_image_hlapm_quantify.sh` | `HLAPM_QUANTIFY_READS`                                     | `quay.io/hlarnaseq/hlapm-quantify-reads:py2.7.15` |
| `scripts/build_image_datatools.sh`      | the eleven `bin/`-script and inline-shell modules (shared) | `quay.io/hlarnaseq/datatools:1.1`                 |

Notes:

- These tags are **not published to any registry**. A fresh clone on another
  machine cannot run `-profile docker` until these four scripts have been run.
  Publishing them is planned but not done.
- `scripts/build_image_hlapm.sh` bakes HLApm in at a pinned commit (it has no
  Conda package) and needs network access to `github.com` at build time.
  `scripts/build_image_hlapm_quantify.sh` needs PyPI and `github.com` for the
  legacy Python 2.7 stack with `pybam` pinned by commit.
- All four document their override variables under `--help`. A fully
  containerized run needs all four built once.

### 3. Two out-of-band reference data inputs

These are **data, not tools**, which is why they are prepared separately. Each has
a helper script that builds it inside the same pinned image the pipeline itself
runs, and neither is created by the pipeline:

- `scripts/build_arcashla_reference.sh <dir>` → `--arcashla_reference_dir`
  (~15 GB of scratch on `<dir>`'s own filesystem under Singularity/Apptainer, plus
  network access to `github.com`; run `scripts/build_image_arcashla.sh` first).
  See [usage docs](usage.md#arcashla-genotyping-environment).
- `scripts/build_reference_hlala.sh <dir>` → `--hlala_graph_dir` (~2.25 GB
  download, ~29 GB on disk, a few hours, up to 40 GB of RAM; no image-build step
  needed, the `hla-la:1.0.4` image is public). It fetches and indexes a
  _published_ PRG graph and cannot construct one from scratch. Indexing means both
  `HLA-LA --action prepareGraph` and `bwa index` over the graph's
  `extendedReferenceGenome.fa` — the latter because HLA-LA would otherwise build
  it inside every concurrent `HLALA_TYPING` task, all writing to the same shared
  files. See [usage docs](usage.md#preparing-the-hla-la-graph).
- Both are idempotent and document their override variables under `--help`.

`--hibag_model` (SNP-array path) and, under `-profile conda` only, `--hlapm_repo`
are the other two data-style inputs; see
[usage docs](usage.md#the-hibag-model) and [usage docs](usage.md#hlapm-container).

## Where each module's dependencies are declared

Most modules own their environment file at `${moduleDir}/environment.yml`. Eleven
share one, because they run this repository's own small `bin/` scripts over the
same interpreters — or a few lines of shell — rather than a bioinformatics tool of
their own: `HLA_CONSENSUS`, `HLAPM_PREPARE_INPUT`, `ARCASHLA_COMBINE`,
`HLAPM_SUMMARIZE_READCOUNTS`, `HLA_READCOUNT_RECONCILE_DIFF`,
`COUNTS_COMMONREF_HLA_REFORMAT`, `HLALA_COMBINE`, `HIBAG_COMBINE`,
`HLAPM_COMBINE_GTF`, `HLAPM_LIST_STAR_TARGETS` and `HLAPM_RESOLVE_SAMPLE_ALLELES`
all point at
[`containers/datatools/environment.yml`](../containers/datatools/environment.yml).
See [`containers/datatools/README.md`](../containers/datatools/README.md) for why
that one is shared and how to extend it.

`HLAPM_BUILD_REF` is a partial exception in one respect: HLApm itself is an
unpackaged git repository, so Conda cannot install it. The module's container
image bakes it in at a pinned commit, and running under `-profile conda` still
requires a checkout passed with `--hlapm_repo`, which is otherwise an optional
override.

Per-module detail lives in the usage docs:
[RNA samplesheet input](usage.md#rna-samplesheet-input),
[arcasHLA genotyping environment](usage.md#arcashla-genotyping-environment),
[WGS samplesheet input](usage.md#wgs-samplesheet-input),
[HIBAG dependency](usage.md#hibag-dependency),
[HLApm container](usage.md#hlapm-container),
[HLApm read-quantification container](usage.md#hlapm-read-quantification-container),
[shared data-tools container](usage.md#shared-data-tools-container), and
[HLApm STAR index](usage.md#hlapm-star-index).

## How this came about

Historical, for context only — none of these environments exists any more, and
nothing below describes current setup.

- The pipeline used to expect several operator-prepared Conda environments and to
  shell out to them with `conda run -n <env>`. They were retired one module at a
  time.
- `HLAPM_BUILD_REF` retired the `hlapm` environment; its R dependencies moved to
  `modules/local/hlapm/build_ref/environment.yml`.
- `HLAPM_QUANTIFY_READS` and `HLAPM_SUMMARIZE_READCOUNTS` together retired
  `hlapm-quantify`, which held two unrelated halves: a legacy Python 2 stack (now
  `modules/local/hlapm/quantify_reads/environment.yml` and its own image) and an R
  stack (now part of the shared data-tools image). `HLA_CONSENSUS`,
  `HLAPM_PREPARE_INPUT` and `ARCASHLA_COMBINE` moved at the same time, off the
  `nf-core` environment's Python/R packages — which is why that file is now
  launcher-only.
- `ARCASHLA_EXTRACT` and `HIBAG_PREDICT` moved before them, taking `samtools` and
  `bioconductor-hibag` off the `nf-core` environment.
- The last seven — `HLA_READCOUNT_RECONCILE_DIFF`,
  `COUNTS_COMMONREF_HLA_REFORMAT`, `HLALA_COMBINE`, `HIBAG_COMBINE`,
  `HLAPM_COMBINE_GTF`, `HLAPM_LIST_STAR_TARGETS` and
  `HLAPM_RESOLVE_SAMPLE_ALLELES` — had no `conda`/`container` directives at all
  and resolved tools from the host `PATH`. They moved onto the shared data-tools
  environment, which gained `samtools` at that point (`datatools:1.0` →
  `:1.1`). That completed the transition.

See `CHANGELOG.md` for the full record.

# `datatools` shared container

The python3 + R environment behind this pipeline's own `bin/` analysis scripts,
and the declared environment for its small inline-shell data-shuffling steps.
Build it with [`scripts/build_image_datatools.sh`](../../scripts/build_image_datatools.sh).

## Why this one is not module-local

Every other environment in this repository lives next to the single module that
uses it, and each module's `conda` directive points at `${moduleDir}/environment.yml`.
This one is shared by thirteen modules:

| Module                          | Script                                 | Uses                                    |
| ------------------------------- | -------------------------------------- | --------------------------------------- |
| `HLA_CONSENSUS`                 | `bin/call_hla_consensus.py`            | python3, pandas                         |
| `HLAPM_PREPARE_INPUT`           | `bin/consensus_to_hlapm.py`            | python3 (stdlib only)                   |
| `ARCASHLA_COMBINE`              | `bin/combine_arcashla_genotypes.R`     | jsonlite, dplyr, tibble, stringr, purrr |
| `HLAPM_SUMMARIZE_READCOUNTS`    | `bin/summarize_hla_readcounts.R`       | dplyr, tidyr                            |
| `HLA_READCOUNT_RECONCILE_DIFF`  | `bin/reconcile_hla_readcounts.py`      | python3, pandas                         |
| `GTF_HLA_GENE_ID_CHECK`         | `bin/check_gtf_hla_gene_ids.py`        | python3 (stdlib only)                   |
| `COMBINE_FINAL_COUNTS_PATCH`    | `bin/combine_final_counts.py`          | python3 (stdlib only)                   |
| `COUNTS_COMMONREF_HLA_REFORMAT` | `bin/reformat_rnaseq_featurecounts.py` | samtools, python3 (stdlib only)         |
| `HLALA_COMBINE`                 | inline shell                           | bash, coreutils, awk                    |
| `HIBAG_COMBINE`                 | inline shell                           | bash, coreutils, awk                    |
| `HLAPM_COMBINE_GTF`             | inline shell                           | bash, coreutils, grep                   |
| `HLAPM_LIST_STAR_TARGETS`       | inline shell                           | bash, coreutils, findutils              |
| `HLAPM_RESOLVE_SAMPLE_ALLELES`  | inline shell                           | bash, coreutils                         |

These are small data transformations over the same two interpreters and a POSIX
shell, with overlapping package lists. Thirteen module-local copies would give
slightly smaller `-profile conda` environments, at the cost of thirteen specs
that must be kept in step with each other and with one image - exactly the drift
this repository avoids elsewhere by deriving `conda` and `container` from a
single file. So all thirteen point their `conda` directive at
`${projectDir}/containers/datatools/environment.yml` and their `container`
directive at the image built from it.

This is a deliberate deviation from the nf-core module layout, not an oversight.
A module that needs a tool of its own - rather than these shared interpreters -
should still get its own module-local `environment.yml`, as
`HLAPM_BUILD_REF`, `ARCASHLA_GENOTYPE`, `HLAPM_QUANTIFY_READS` and
`HIBAG_PREDICT` all do.

### The shell-only consumers

The five inline-shell modules take nothing from the conda environment: `bash`,
coreutils, `awk`, `findutils` and `grep` come from the image's Debian base under
`-profile docker/singularity`, and from the host under `-profile conda` - the
same arrangement nf-core's own pure-shell modules rely on. They point here so
that they declare _some_ reproducible environment instead of none at all, which
is what they had before. The `Dockerfile` asserts at build time that bash
associative arrays, process substitution, `sha256sum` and `find` are present, so
a future base-image change fails the build rather than the pipeline.

### The samtools exception

`COUNTS_COMMONREF_HLA_REFORMAT` needs `samtools` _and_ `python3` in one
environment - a combination with no prebuilt public image - so `samtools` and
`htslib` live here despite the "Adding a package" rule below. The alternative, a
fourth module-local `Dockerfile` for a single `samtools view` call, was judged
the worse trade. The pin (1.24) is deliberately identical to `ARCASHLA_EXTRACT`'s
and the vendored nf-core `SAMTOOLS_SORT`'s, so the pipeline can never run more
than one samtools version.

## Adding a package

Add it to `environment.yml`, pinned, then rebuild and bump the image tag
(`IMAGE_TAG` in `scripts/build_image_datatools.sh`, and the `container`
directive in each of the thirteen modules - they must agree). Bump the tag
whenever the environment changes, so an image and a tag always mean the same
contents; operators build this image locally, and a moved tag with an unchanged
name is indistinguishable from a stale build.

Prefer adding a package here only if it serves a `bin/` script of this kind. A
module wrapping a real bioinformatics tool belongs in its own module-local
environment, where its pins can move independently of everything else. The one
standing exception is `samtools`/`htslib`; see "The samtools exception" above.

## Versions

Pinned to the versions this pipeline's existing published results were produced
with, so containerization changes no output. `r-tidyr` is the one exception - it
had no build for the pinned `r-base`, so it necessarily moved; see the note in
`environment.yml`.

# nf-core/hlarnaseq: Usage

## :warning: Please read this documentation on the nf-core website: [https://nf-co.re/hlarnaseq/usage](https://nf-co.re/hlarnaseq/usage)

> _Documentation of pipeline parameters is generated automatically from the pipeline schema and can no longer be found in markdown files._

## Introduction

<!-- TODO nf-core: Add documentation about anything specific to running your pipeline. For general topics, please point to (and add to) the main nf-core website. -->

## Dependencies and profiles

**Every tool this pipeline runs is declared by the process that runs it**, following the standard nf-core pattern: an `environment.yml` feeding the module's `conda` directive, paired with a matching pinned `container` directive. Nothing is taken from the environment you launch Nextflow in — you need `nextflow` itself on your `PATH`, and nothing else.

That means **a profile is required**. Pick one:

```bash
-profile singularity   # or: docker, apptainer, conda
```

Running with none of them leaves every step unprovisioned; each fails fast with a message naming the profiles rather than silently using whatever happens to be on the host. `singularity`/`docker` are recommended; `-profile conda` works and is exercised, but has not been verified as thoroughly across systems.

Two things still come from outside the pipeline, and neither is a tool:

- **Reference data** — `--hlala_graph_dir`, `--arcashla_reference_dir`, `--hibag_model` and (under `-profile conda`) `--hlapm_repo`. Each is prepared once, out of band, by a helper script under [`scripts/`](../scripts/) that runs inside the same pinned image the pipeline itself uses. They are too large, too slow, or too licence-encumbered to build inside a task.
- **Four container images that are currently built locally.** `ARCASHLA_GENOTYPE`, `HLAPM_BUILD_REF`, `HLAPM_QUANTIFY_READS` and the shared data-tools image resolve to `quay.io/hlarnaseq/...` tags that are **not published to any registry** — they are built on your machine by `scripts/build_image_*.sh` and found in the local Docker image store (or, for Singularity/Apptainer, as a local `.sif` referenced by path). Run those four scripts once before your first containerized run:

  ```bash
  scripts/build_image_arcashla.sh
  scripts/build_image_hlapm.sh
  scripts/build_image_hlapm_quantify.sh
  scripts/build_image_datatools.sh
  ```

  Every other image (STAR, Subread, samtools, HLA-LA, HIBAG, validatefastq) is a public Biocontainers/Galaxy-depot/Wave image that Nextflow pulls for you. Publishing the four local ones to a registry is planned; until then a fresh clone needs these builds. On a cluster install that provides the `hlarnaseq` module, `hlarnaseq-build-image all` runs all four against the installed pipeline — see [Running on an LSF cluster](#running-on-an-lsf-cluster-sanger-module).

See [`docs/environment_setup.md`](environment_setup.md) for the full per-module breakdown.

## RNA samplesheet input

Provide the required RNA manifest with `--rna_samples` and the region to extract with `--hla_region`:

```bash
--rna_samples '[path to RNA samplesheet]' \
--hla_region 'chr6:28500000-33400000'
```

The CSV header must exactly match the following five columns:

```csv title="rna_samples.csv"
rna_id,bam,bai,unpaired_r1,unpaired_r2
RNA_SAMPLE_1,/path/to/RNA_SAMPLE_1.bam,/path/to/RNA_SAMPLE_1.bam.bai,/path/to/RNA_SAMPLE_1.unpaired_1.fastq.gz,/path/to/RNA_SAMPLE_1.unpaired_2.fastq.gz
```

| Column        | Description                                                                                           |
| ------------- | ----------------------------------------------------------------------------------------------------- |
| `rna_id`      | Unique RNA sample identifier without spaces.                                                          |
| `bam`         | Coordinate-sorted RNA-seq BAM containing aligned reads; must end in `.bam`.                           |
| `bai`         | Index for `bam`; must end in `.bai`.                                                                  |
| `unpaired_r1` | Gzip-compressed read-1 FASTQ to combine with BAM-derived MHC reads; must end in `.fq.gz`/`.fastq.gz`. |
| `unpaired_r2` | Gzip-compressed read-2 FASTQ to combine with BAM-derived MHC reads; must end in `.fq.gz`/`.fastq.gz`. |

All columns are mandatory and each `rna_id` may occur only once. Relative file paths are resolved from the samplesheet directory, launch directory, or pipeline project directory. The extraction is paired-end only.

`--hla_region` is passed unchanged to samtools. The user must choose coordinates and chromosome notation that match every BAM header: the pipeline does not translate `6` to `chr6`, or vice versa.

For each sample, the pipeline extracts complete pairs overlapping this region, excludes secondary and supplementary alignments, and combines the recovered mates with the supplied FASTQs. An [example RNA samplesheet](../assets/rna_samples.csv) is included.

Each extracted read pair is checked with [validatefastq](https://github.com/biopet/validatefastq) before it is made available to downstream arcasHLA steps. A non-zero validator exit status or a reported `ERROR` stops the pipeline; the pipeline does not attempt to repair, reorder, or skip invalid pairs. Successful per-sample validation logs are written beneath `arcashla/validation/`.

`ARCASHLA_VALIDATE_FASTQ` provisions the validator itself, via its own module `environment.yml`/`conda` directive (`bioconda::biopet-validatefastq=0.1.1`) paired with the matching pinned Biocontainers image, resolved automatically under `-profile conda`/`docker`/`singularity`/`apptainer`. Note that the packaged executable is named `biopet-validatefastq` (there is no plain `validatefastq` alias); running the pipeline with no container/Conda profile at all leaves the module unprovisioned and it will fail fast saying so.

Once a sample's extracted reads pass validation, the pipeline runs `arcasHLA genotype` on them, requesting the genes listed in `--arcashla_genes` (a broad default gene list is provided). Per-sample results are written to `arcashla/genotype/<rna_id>.genotype.json` (+ `.log`).

### arcasHLA genotyping environment

`ARCASHLA_GENOTYPE` provisions arcasHLA itself via its own module `environment.yml`/`conda` directive (`arcas-hla=0.6.0`, `kallisto=0.44.0` - later kallisto versions are incompatible with this arcasHLA version's `kallisto pseudo` output parsing), resolved automatically by Nextflow under `-profile conda` and, from the image built by `scripts/build_image_arcashla.sh`, under the container profiles.

arcasHLA has no option to point `genotype` at an external reference database at runtime; the reference used is always whichever one exists inside its own install. Rather than have the pipeline build this reference itself (it clones the ~4GB [ANHIG/IMGTHLA](https://github.com/ANHIG/IMGTHLA) database - too slow and network-dependent to do inside every container build or as a first-task surprise), it is prepared once, out of band, and pointed to with a required **`--arcashla_reference_dir`** parameter - the same pattern as `--hlala_graph_dir` for HLA-LA above. `ARCASHLA_GENOTYPE` takes the directory as a staged process input and symlinks it into place as its own `dat/ref` at the start of every task; the symlink swap is fast and atomic, so it's redone unconditionally on every task with no locking or "first use" logic.

Because the reference is a real process input rather than a path pasted into the task script, Nextflow resolves it and hands it to the container engine itself (`singularity.autoMounts`, or a Docker volume). It can therefore live on **any filesystem the executor can read** - including behind a symlink onto a separate mount - with no `SINGULARITY_BIND`, no `singularity.runOptions`, and no bind flags of your own. The pipeline also checks at launch that the directory actually contains a built reference (`hla.idx` and `hla.p.json`) rather than merely existing, so a half-finished build fails immediately with a clear message instead of surfacing later as an arcasHLA `FileNotFoundError` on `dat/ref/hla.p.json`.

Build the reference once with:

```bash
scripts/build_image_arcashla.sh              # build the container image, once
scripts/build_arcashla_reference.sh /path/to/arcashla_reference   # build the reference into it, once
```

`build_arcashla_reference.sh` runs inside the same container image the pipeline itself uses (so the reference matches the exact pinned `arcas-hla=0.6.0`/`kallisto=0.44.0` versions). It does not just run plain `arcasHLA reference`: as of IMGT/HLA's Release 3.56.0, its large files (including the `hla.dat` this arcasHLA version expects as a plain file) are distributed as separate `.zip` downloads rather than checked into git, which arcasHLA 0.6.0 doesn't know how to handle. Instead, the script clones IMGT/HLA itself and checks out a pinned pre-3.56.0 commit (**IMGT/HLA version 3.52.0** by default, tag `v3.52.0-alpha`, pinned by commit SHA; override with `IMGTHLA_COMMIT`), then runs `arcasHLA reference --rebuild` against that pinned checkout. This also pins the exact HLA database version used, rather than depending on whatever the upstream default branch contains when the script happens to be run. It checks that a real `hla.idx` file was actually produced before finishing (arcasHLA can otherwise fail partway without a clear error).

Version 3.52.0 is the default because it is the IPD-IMGT/HLA version HLApm uses, so arcasHLA's genotype calls and the personalized reference HLApm builds from them share one allele nomenclature. It is not reachable via `arcasHLA reference --version`, whose built-in version-to-commit mapping stops at 3.46.0 - checking the commit out directly, as this script does, is what makes any pre-3.56.0 version available. **If you built a reference with an earlier version of this script, which defaulted to 3.46.0, re-run it to pick up 3.52.0**: the pipeline does not inspect or validate the database version of the directory you pass to `--arcashla_reference_dir`.

Then run the pipeline with:

```bash
--arcashla_reference_dir /path/to/arcashla_reference
```

The build needs roughly **15 GB of free space** and network access to `github.com`. It runs under Docker if that image is loaded, otherwise Singularity/Apptainer against the local `.sif`; `RUNTIME=docker|singularity|apptainer` forces one. Under Singularity/Apptainer all of that space is used on the output directory's own filesystem - a `.sif` is read-only at execution time, so the IMGT/HLA checkout cannot live inside the image the way it does in a Docker container's writable layer, and the script instead mounts a writable scratch directory over the image's arcasHLA `dat/` directory. That scratch directory defaults to a temporary `<output-dir>.build.XXXXXX` sibling, removed when the script exits; set `DAT_WORK_DIR` to put it on a different (larger) filesystem, in which case it is left in place. The free-space check runs before the download and can be adjusted with `REQUIRED_GB`. See `scripts/build_arcashla_reference.sh --help` for all override variables.

Under `-profile docker`/`-profile singularity`/`-profile apptainer`, `ARCASHLA_GENOTYPE` uses a container image built from `modules/local/arcashla/genotype/Dockerfile` (just the pinned packages - no reference baked in, for the same reason it isn't built automatically above). Build it once before running with a container profile:

```bash
scripts/build_image_arcashla.sh
```

This builds and tags the Docker image as `quay.io/hlarnaseq/arcashla-genotype:0.6.0`, matching `nextflow.config`'s `docker.registry`/`singularity.registry = 'quay.io'` default so `-profile docker` finds it locally with no registry push needed. It also converts that same image into a local `modules/local/arcashla/genotype/arcashla-genotype.sif` (when `singularity`/`apptainer` is available) for `-profile singularity`/`apptainer`: Singularity/Apptainer has no access to Docker's local image store, and a bare image name is not a filesystem path, so without this `.sif` file Nextflow would otherwise try (and fail) to pull the image from `quay.io` over the network. See `scripts/build_image_arcashla.sh --help` for details and override variables.

## WGS samplesheet input

Optionally provide WGS BAM inputs with `--wgs_samples`:

```bash
--wgs_samples '[path to WGS samplesheet file]'
```

The WGS samplesheet must be a comma-separated file with exactly these columns:

```csv title="wgs_samples.csv"
WGS_sample_id,WGS_BAM_path,WGS_BAI_path
NA12878,testdata-make/hlarnases-testdata/wgs/NA12878.chr6_hla.GRCh38.bam,testdata-make/hlarnases-testdata/wgs/NA12878.chr6_hla.GRCh38.bam.bai
```

| Column          | Description                                                                                                          |
| --------------- | -------------------------------------------------------------------------------------------------------------------- |
| `WGS_sample_id` | WGS sample identifier. This entry is mandatory and cannot contain spaces.                                            |
| `WGS_BAM_path`  | Path to the WGS BAM file. This entry is mandatory and must end in `.bam`.                                            |
| `WGS_BAI_path`  | Path to the WGS BAI index. This entry is mandatory and must be named `<BAM file name>.bai` (i.e. end in `.bam.bai`). |

Each row is validated and loaded as a separate WGS sample channel entry. Relative BAM and BAI paths are resolved from the directory containing the WGS samplesheet, the launch directory, or the pipeline project directory. An [example WGS samplesheet](../assets/wgs_samples.csv) has been provided with the pipeline.

The index must be named exactly `<BAM file name>.bai` (for example `NA12878.bam` + `NA12878.bam.bai`), not `<BAM base name>.bai`: HLA-LA resolves a BAM's index by appending `.bai` to the BAM path, and will not find an index named otherwise. This is enforced by [`assets/schema_wgs_samples.json`](../assets/schema_wgs_samples.json), so a mismatch fails at samplesheet validation rather than deep inside HLA-LA.

When `--wgs_samples` is provided, the pipeline runs HLA-LA once per WGS BAM and combines the reported G-group allele calls into `hlala/HLA-LA_combined.tsv`.
HLA-LA itself (and the samtools/bwa/picard tooling it shells out to) is provisioned by the `HLALA_TYPING` module's own `environment.yml`/`conda` directive and matching pinned `container` (`hla-la=1.0.4`), resolved automatically by Nextflow under `-profile conda`/`docker`/`singularity`/`apptainer`. The image is public, so nothing has to be built locally for it - only the graph below is prepared out of band.

The prepared HLA-LA **graph**, however, remains a required, separately-prepared input: the pipeline never downloads, builds, or packages HLA-LA graph data (the `hlala/preparegraph` step is deliberately not wired in), the same pattern as `--arcashla_reference_dir` for arcasHLA above.
Provide the **parent** directory containing the prepared graph with `--hlala_graph_dir`, and the **graph directory's own name** with `--hlala_graph` (defaults to `PRG_MHC_GRCh38_withIMGT`) - i.e. the graph the pipeline uses is `<hlala_graph_dir>/<hlala_graph>`.

```bash
nextflow run nf-core/hlarnaseq \
    --rna_samples ./rna_samples.csv \
    --hla_region chr6:28500000-33400000 \
    --wgs_samples ./wgs_samples.csv \
    --hlala_graph_dir /path/to/HLA-LA/graphs \
    --outdir ./results
```

### Preparing the HLA-LA graph

Prepare the graph once, out of band, with:

```bash
scripts/build_reference_hlala.sh /path/to/HLA-LA/graphs
```

This downloads the published PRG graph package (`PRG_MHC_GRCh38_withIMGT`, ~2.25 GB), verifies its md5, extracts it, and then indexes it twice over, inside the same pinned `hla-la:1.0.4` container image `HLALA_TYPING` itself runs - so the graph is indexed by the exact build that will later consume it:

1. `HLA-LA --action prepareGraph`, which produces `serializedGRAPH`; and
2. `bwa index` over `extendedReferenceGenome/extendedReferenceGenome.fa`.

Unlike arcasHLA's image, this one is public (Biocontainers/Galaxy depot), so there is no companion image-build script: the container is pulled on first use. Docker is used when its daemon is reachable, otherwise Singularity/Apptainer. That image already ships the `bwa` step 2 needs, so nothing extra has to be installed.

**Step 2 is not optional, even though `prepareGraph` does not do it.** The published tarball ships `mapping_PRGonly/referenceGenome.fa` pre-indexed but `extendedReferenceGenome/` with the FASTA alone, and HLA-LA copes by building that bwa index lazily, the first time it maps reads against the extended reference genome - writing it back into the graph directory, next to the FASTA. The pipeline hands `HLALA_TYPING` one shared graph directory for every WGS sample, so with an unindexed graph all the concurrent per-sample tasks find the index missing, all launch the same `bwa index` against the same paths, and they overwrite each other's partial output: all but (at most) one sample fails, hours into the run. Building the index once, up front, removes the race. The pipeline also refuses to start a `--wgs_samples` run against a graph that lacks it, naming this script in the error, rather than letting the race happen.

Budget for it before starting:

- **~29 GB on disk** for the extracted and fully indexed graph (`serializedGRAPH` alone is ~5.5 GB, and the bwa index adds ~5.1 GB on top of the 3 GB extended reference FASTA), plus the 2.25 GB tarball. The script checks free space on the target filesystem up front (override the floor with `REQUIRED_GB`) rather than failing hours in.
- **A few hours** for `prepareGraph`, and per HLA-LA's own README it "might take up to 40G of memory". The script warns if the machine has less than 40 GB of RAM but still proceeds. `bwa index` adds roughly another hour and is not memory-hungry.

Re-running the script is free: if the graph is already fully indexed - `<output-dir>/<graph>/serializedGRAPH` non-empty **and** the extended reference FASTA's `.sa`/`.ann`/`.bwt` all present - it reports the graph as already built and exits without downloading, extracting, or indexing anything, and that check runs _before_ the download.

Each indexing step is skipped independently when its own output is already in place, so **a graph prepared before this pipeline built the bwa index is repaired by simply re-running the script on the same directory**: it adds the missing index and neither re-downloads the package nor re-runs the multi-hour `prepareGraph`. An interrupted run that already extracted the package likewise resumes at indexing instead of re-downloading.

**To force a full rebuild, delete the graph directory and re-run**; that is deliberately the only supported way, so there is no "force" flag that could half-overwrite an existing graph. `GRAPH_NAME`, `GRAPH_URL`, `GRAPH_MD5`, `TARBALL` (use an already-downloaded copy), `IMAGE_TAG`, `SIF_PATH`, and `REQUIRED_GB` are all overridable - see `scripts/build_reference_hlala.sh --help`.

On success the script prints the exact parameters to pass:

```bash
--hlala_graph_dir /path/to/HLA-LA/graphs --hlala_graph PRG_MHC_GRCh38_withIMGT
```

**Limitation: the script fetches and indexes a _published_ graph; it cannot construct one from scratch.** This is not an unfinished feature - building a PRG graph for a newer IMGT/HLA release or for custom loci is not scriptable outside the tool author's own environment. HLA-LA's own `src/Update graphs.txt` documents that workflow as Perl scripts run on the author's Windows laptop, plus the separate older MHC-PRG v1 binary (not shipped in the bioconda `hla-la` package), hardcoded cluster paths, and input files that were never distributed. A newer graph is an upstream request to the HLA-LA authors. The `GRAPH_NAME`/`GRAPH_URL`/`GRAPH_MD5` overrides exist so other _published_ graph packages, an offline mirror, or a future move of the download host work without editing the script.

### Requirement: `--outdir` and the Nextflow work directory must share a filesystem

**When `--wgs_samples` is used, `--outdir` and the Nextflow work directory (`-w`, default `./work`) must be on the same filesystem.** This is a hard requirement, not a recommendation.

HLA-LA's per-sample output directory is published with `mode: 'link'` (hard links) rather than the pipeline's usual `copy` - see the `HLALA_TYPING` entry in `conf/modules.config`. The `HLALA_TYPING` module declares its per-sample output directory as an output alongside individual files inside it, which makes publishing all-or-nothing (Nextflow offers only the directory to `publishDir`, never the nested paths), and publishing everything by copy would duplicate HLA-LA's multi-gigabyte intermediates (`extraction*.bam`, `remapped_with_a.bam`, `R_{1,2,U}.fastq`) for every WGS sample. Hard links make that free.

Hard links cannot cross filesystems, and **Nextflow does not fall back to copying**: if `--outdir` is on a different filesystem than the work directory, the run aborts with

```
Failed to publish file: /path/to/work/xx/xxxxxx/<sample_id>; to: /path/to/outdir/hlala/<sample_id> [link]
```

This is easy to hit on HPC, where the normal layout is `--outdir` on shared/project storage and `-w` on fast local scratch. Either put both on the same filesystem, or override the publishing mode in a custom config passed with `-c`:

```groovy title="hlala_copy.config"
process {
    withName: 'HLALA_TYPING' {
        publishDir = [
            path: { "${params.outdir}/hlala" },
            mode: 'copy'
        ]
    }
}
```

Be aware that this reintroduces the multi-gigabyte-per-sample duplication that `'link'` exists to avoid. `'symlink'`/`'rellink'` are cheaper alternatives, but the published results then break as soon as the work directory is cleaned.

## SNP-array samplesheet input (HIBAG)

HIBAG is the alternative to HLA-LA for the genotype-side HLA calls. Instead of typing HLA from WGS alignments, it _imputes_ HLA alleles from GWAS SNP genotypes, so its input is microarray data in PLINK binary format:

```bash
--array_samples '[path to SNP-array samplesheet file]' --hibag_model '[path to a pre-fit HIBAG model .RData]'
```

**`--array_samples` and `--wgs_samples` are mutually exclusive.** Both fill the same genotype-side input to the consensus step, so the pipeline fails fast if given both rather than silently picking one.

The SNP-array samplesheet must be a comma-separated file with exactly these columns:

```csv title="array_samples.csv"
array_sample_id,array_bed_path,array_bim_path,array_fam_path
NA12878_omniexpress,testdata-make/hlarnases-testdata/array/NA12878.omniexpress.xMHC.hg19.bed,testdata-make/hlarnases-testdata/array/NA12878.omniexpress.xMHC.hg19.bim,testdata-make/hlarnases-testdata/array/NA12878.omniexpress.xMHC.hg19.fam
```

| Column            | Description                                                                               |
| ----------------- | ----------------------------------------------------------------------------------------- |
| `array_sample_id` | Label for the PLINK **dataset**. Mandatory, cannot contain spaces. See the warning below. |
| `array_bed_path`  | Path to the PLINK `.bed` genotype file. Mandatory, must end in `.bed`.                    |
| `array_bim_path`  | Path to the matching `.bim` variant file. Mandatory, must end in `.bim`.                  |
| `array_fam_path`  | Path to the matching `.fam` sample file. Mandatory, must end in `.fam`.                   |

Relative paths are resolved from the directory containing the samplesheet, the launch directory, or the pipeline project directory, as for the other samplesheets. An [example SNP-array samplesheet](../assets/array_samples.csv) is provided with the pipeline.

### :warning: A row is one PLINK dataset, not one sample

This is the one place where the SNP-array samplesheet behaves differently from the RNA and WGS ones. A PLINK fileset can hold many samples, and HIBAG imputes all of them in a single call, so:

- `array_sample_id` is only a **label** for the dataset. It is used for task tags and output filenames, and nothing else.
- The sample IDs that reach the consensus step come from the **IID column of the `.fam` file**.

It is therefore the `.fam` IIDs - not `array_sample_id` - that must match the `wgs_sample_id` values in `--sample_key`. If they do not match, the affected individuals simply produce no consensus rows rather than raising an error, so check this first if consensus output looks empty.

### The HIBAG model

`--hibag_model` is **mandatory** whenever `--array_samples` is given, and the pipeline fails fast if it is missing or does not exist.

The file must be an `.RData` holding either a single `hlaAttrBagObj` or a named list of them, one per HLA locus - the shape the published HIBAG per-platform models use. Pick a model built for your array platform and genome assembly; the pipeline never trains one. By default every locus in the model file is predicted; restrict that with `--hibag_loci 'A,B,C'`.

Set `--hibag_assembly` (`hg18`/`hg19`/`hg38`, default `hg19`) to the assembly of your **genotypes**, and make sure the model was built on the same one.

### :warning: If HIBAG reports that no SNPs match

The most common failure is a model whose SNP coordinates do not line up with your array manifest. HIBAG's own error for this is a bare `There is no overlapping of SNPs!`, so the pipeline checks the overlap first and fails with something you can act on:

```text
HLA-A: none of the model's 266 SNPs match the array data under --match-type 'RefSNP+Position'.
    SNPs found under each criterion:
      Position         0 of 266 model SNPs
      Pos+Allele       0 of 266 model SNPs
      RefSNP+Position  0 of 266 model SNPs
      RefSNP           264 of 266 model SNPs
    Try --match-type with one of: RefSNP.
```

Set `--hibag_match_type` to whichever criterion the message says will work. The default is the strict `RefSNP+Position`, which is correct when the model and the genotypes were built against the same manifest and assembly. `RefSNP` matches on rsID alone and is the usual fix for a coordinate offset. If _no_ criterion matches anything, the model and the data are on different assemblies, or the array does not cover the xMHC.

`--hibag_min_prob` (default `0`, i.e. no filtering) drops calls whose posterior probability falls below the threshold. The default matches the HLA-LA path, which applies no confidence filter either.

### :warning: Partial SNP overlap is rejected, not warned about

HIBAG does **not** fail when only some of a model's SNPs are found. It returns confident-looking alleles computed from whatever matched, and they can simply be wrong. Observed against a published model whose rsIDs had gone stale: at 13 of 273 matched SNPs it reported a homozygous `C*07:01`/`C*07:01`, where the same data and model at 271 of 273 gave the correct `C*01:02`/`C*07:01`.

`--hibag_min_matched_snps` (default `0.5`) therefore fails the run when fewer than that fraction of a locus's model SNPs are found, with the same diagnostic table as the zero-overlap error. The per-locus matched fraction is logged for every run and recorded in `<array_sample_id>.hibag_posterior.tsv` as `n_model_snps` / `n_matched_snps`.

Set it to `0` to disable the check, only if you accept unreliable calls.

### Getting a multi-locus model

The model bundled with the HIBAG R package covers **HLA-A only**, so a run using it reports one locus. For the test data, `testdata-make/11-download-hibag-model` fetches a published model covering A, B, C, DRB1, DQA1, DQB1 and DPB1:

```bash
testdata-make/11-download-hibag-model
```

These are the "HLARES" parameter estimates of Zheng et al. (2014), built from SNP markers common to the Illumina 1M Duo, OmniQuad, OmniExpress, 660K and 550K platforms. Four ancestries are published (`HIBAG_ANCESTRY`: European, Asian, Hispanic, African) in hg18 and hg19 (`HIBAG_MODEL_ASSEMBLY`); European/hg19 is the default and is the right one for NA12878.

They carry accurate hg19 positions but 2012-era rsIDs, many of which have since been merged or retired, so they need `--hibag_match_type Pos+Allele` — rsID matching finds only a few percent of each model's SNPs. `pipeline_testdata_run.sh` sets this for you.

### HIBAG dependency

`HIBAG_PREDICT` follows the standard nf-core pattern: its dependency is declared once in [`modules/local/hibag/predict/environment.yml`](../modules/local/hibag/predict/environment.yml) (`bioconda::bioconductor-hibag=1.42.0`), which feeds both the module's `conda` directive and a matching pinned Biocontainers/Galaxy-depot `container` directive. Run the SNP-array path with one of `-profile conda`, `-profile docker`, `-profile singularity` or `-profile apptainer` and Nextflow provisions HIBAG for you.

Running with none of those profiles fails at this step with an explicit message naming the profiles to use, rather than silently imputing with whatever version happens to be on the host.

The pin is 1.42.0 rather than the newer 1.46.0 because 1.42.0 is the most recent release for which the Galaxy depot publishes a Singularity image, so a single version covers all four profiles.

### Preparing SNP-array test data

`testdata-make/10-prepare-na12878-array-hibag` downloads the NA12878 / GM12878 Illumina HumanOmniExpress-24 v1.0 array data from GEO and converts it to the PLINK genotypes this step consumes. See [`testdata-make/README.md`](../testdata-make/README.md) for what the conversion does and its limitations.

## RNA/WGS sample key input

`--sample_key` is a required top-level parameter. It maps RNA samples to their matched WGS sample (when one exists) for HLA consensus calling:

```bash
--sample_key '[path to sample key file]'
```

The sample key must be a comma-separated file with exactly these columns:

```csv title="sample_key.csv"
rnaseq_sample_id,wgs_sample_id
RNA_SAMPLE_1,WGS_SAMPLE_1
```

| Column             | Description                                                               |
| ------------------ | ------------------------------------------------------------------------- |
| `rnaseq_sample_id` | RNA sample identifier; must match a `rna_id` from `--rna_samples`.        |
| `wgs_sample_id`    | WGS sample identifier; must match a `WGS_sample_id` from `--wgs_samples`. |

One row per RNA sample that has a matched WGS sample. An RNA sample simply absent from this file (or, when `--wgs_samples` is not provided at all, every RNA sample) is treated as having no WGS pairing: it is reported under a synthetic `RNA_ONLY:<rna_id>` group instead of being matched to a WGS sample. A `--sample_key` file with zero data rows is valid and simply routes every RNA sample through the `RNA_ONLY:<rna_id>` fallback.

`HLA_CONSENSUS` always runs; there is no separate flag to enable it, and no way to skip it (`--rna_samples` and `--sample_key` are both required). `--wgs_samples` is optional and only affects whether WGS-derived alleles are available to blend into the consensus call for matched individuals - it does not affect whether `HLA_CONSENSUS` (or the downstream HLApm/STAR steps) run at all. When `--wgs_samples` is not provided, `HLA_CONSENSUS` combines the arcasHLA RNA genotype calls with an empty HLA-LA input, so every group falls back to `RNA_ONLY:<rna_id>` and the consensus call is RNA-only.

Two further optional parameters let you drop specific samples from consensus calling without editing the RNA/WGS/HLA-LA inputs themselves:

- `--rna_excluded_samples`: path to a plain-text file listing RNA sample IDs (one per line) to exclude.
- `--wgs_excluded_samples`: path to a plain-text file listing WGS sample IDs (one per line) to exclude.

`--hla_consensus_truncate_fields` (default `2`) controls how many colon-separated fields of each HLA allele are kept when comparing RNA and WGS calls (e.g. `02:07:01` truncated to 2 fields becomes `02:07`).

## HLApm personalized HLA reference

`HLAPM` runs whenever `HLA_CONSENSUS` runs, which is always, regardless of whether `--wgs_samples` is also provided; there is no separate flag to enable it. It converts the `hla_consensus.rna_wgs_hla_consensus.tsv` consensus calls into one per-individual HLA allele-list TSV, then builds a personalized FASTA+GTF reference per allele, per individual, using [HLApm](https://github.com/davenportlab/HLApm)'s `bulkRNA_build_personalized_HLA_ref()` function. It does not run HLApm's own downstream STAR-index/mapping/allele-assignment stages, and single-cell mode is out of scope; instead, the pipeline runs its own STAR indexing step immediately afterwards (see below).

`--hlapm_allowed_loci` (default `A,B,C,DRB1,DQA1,DQB1,DPA1,DPB1,DOA,DOB,G,E,F`) is a comma-separated allow-list of HLA loci (without the `HLA-` prefix) to include when building the HLApm input. `HLA_CONSENSUS` output loci not in this list (e.g. `HLA-DRB3`, `HLA-H`, `HLA-J`, `HLA-K`, `HLA-L`) are silently omitted from the per-individual HLApm input TSVs; no separate audit/log file is written for excluded loci. This default is restricted to the loci HLApm's own per-allele locus regex can reliably parse — passing other loci through can crash the underlying R script.

### HLApm container

`HLAPM_BUILD_REF` follows the standard nf-core pattern for its R dependencies: they are declared once in [`modules/local/hlapm/build_ref/environment.yml`](../modules/local/hlapm/build_ref/environment.yml) (`r-base`, `data.table`, `dplyr`, `stringr`, `seqinr`, `Biostrings`, `rtracklayer`, `DECIPHER`, `bedtools`), which feeds both the module's `conda` directive and the image its `container` directive points at. Build that image once with `scripts/build_image_hlapm.sh`; nothing has to be created by hand for the R side.

HLApm itself is different. It is an unpackaged lab git repository rather than a Conda package, so it cannot be installed from `environment.yml` and reaches the module one of two ways:

- **Container profiles** (`-profile docker`/`singularity`/`apptainer`) — the image bakes in HLApm at pinned commit `38faa6087bbd827ccab969d947f8df101e95d688`, including its bundled `data/references/` files. Build it once before running:

  ```bash
  scripts/build_image_hlapm.sh
  ```

  This builds and tags the Docker image as `quay.io/hlarnaseq/hlapm-build-ref:38faa60`, matching `nextflow.config`'s `docker.registry`/`singularity.registry = 'quay.io'` default so `-profile docker` finds it locally with no registry push needed, and converts that same image into a local `modules/local/hlapm/build_ref/hlapm-build-ref.sif` (when `singularity`/`apptainer` is available) for `-profile singularity`/`apptainer`, for the same reason described for arcasHLA above. The build needs network access to `github.com` (for the HLApm clone) and to the Conda channels. Override the baked-in HLApm version with `HLAPM_COMMIT=<sha>` — see `scripts/build_image_hlapm.sh --help`.

- **`-profile conda`, or no profile at all** — `--hlapm_repo` is **mandatory**, and the pipeline fails fast at launch with a clear error if it is missing or does not exist, rather than failing partway through the run:

  ```bash
  --hlapm_repo '[path to a local HLApm checkout]'
  ```

  It must point to a local, pre-cloned checkout of [davenportlab/HLApm](https://github.com/davenportlab/HLApm), including its bundled `data/references/` files. The pipeline never clones or fetches HLApm at runtime; the checkout must already exist at this path before the pipeline runs.

Under a container profile `--hlapm_repo` remains available but **optional**: passing it overrides the baked-in checkout with your own (e.g. a patched or newer HLApm) without rebuilding the image. The override is staged into the task as an input, so it is mounted into the container automatically — no manual bind-mount options are needed. Either way, `versions.yml` reports which HLApm commit was actually used: the pinned commit from the image, or the override checkout's `git rev-parse HEAD`.

### HLApm STAR index

Immediately after `HLAPM` builds the personalized FASTA+GTF references, the pipeline builds a STAR genome index for every allele reference that actually exists under `hlapm/personalized_ref/out/<individual_ID>/*.fa` - the set of alleles indexed is discovered by scanning that output tree directly, not from the HLApm input TSV or the consensus calls, since HLApm can emit reference files for alleles not listed in its own input. Before indexing, allele references are deduplicated by a content hash (sha256 of FASTA+GTF): the same allele often recurs across multiple individuals, and hashing content (rather than trusting the allele name) avoids ever silently merging two different sequences that happen to share a name. See [output docs](output.md#hlapm-star-index) for the resulting `hlapm/star_index/` and `hlapm/star_index_targets/` layout, including how to look up which shared index applies to a given individual/allele via `sample_alleles.csv`.

This step reuses the [nf-core/modules `STAR_GENOMEGENERATE`](https://github.com/nf-core/modules/tree/master/modules/nf-core/star/genomegenerate) module unmodified, pinned to **STAR 2.7.11b** - the same version used by [nf-core/rnaseq](https://nf-co.re/rnaseq/) to build this pipeline's own RNA-seq test data. Like every other step, STAR comes from the module's own `environment.yml`/`container` pair (see [Dependencies and profiles](#dependencies-and-profiles)) - here a public Biocontainers image, so nothing has to be built locally for it:

```bash
-profile singularity
```

`docker` and `apptainer` work the same way. `-profile conda` also works - Nextflow auto-creates an isolated environment from the module's pinned `environment.yml` (`bioconda::star=2.7.11b`) at run time instead of pulling a container - but it has not been verified as thoroughly on all systems, so `singularity`/`docker` is recommended.

### HLApm STAR alignment

Immediately after the STAR indexes are built, the pipeline aligns each RNA sample's arcasHLA MHC-extracted reads (`ARCASHLA`'s `.mhc_1.fq.gz`/`.mhc_2.fq.gz`, not the full/raw RNA fastqs) against every one of that sample's personalized allele indexes. This produces one alignment job per `(RNA sample, allele)` pair: a sample with 3 personalized alleles gets 3 separate STAR alignments, each reusing the same read pair against a different single-allele index.

`sample_alleles.csv`'s `sample` column is keyed by `HLA_CONSENSUS`'s grouping id (the WGS individual ID for WGS-backed individuals, or a synthetic `RNA_ONLY:<rna_id>` token otherwise) - not directly by RNA sample id. Before alignment, the pipeline resolves this back to real RNA sample ids using `--sample_key`: a WGS individual matched to more than one RNA sample in `--sample_key` has its full allele set aligned separately against each of those RNA samples' own reads (broadcast, not collapsed to one). This resolved mapping is published as `hlapm/star_align/rna_sample_alleles.csv` - see [output docs](output.md#hlapm-star-alignment) for its columns and for the alignment output layout.

This step reuses the [nf-core/modules `STAR_ALIGN`](https://github.com/nf-core/modules/tree/master/modules/nf-core/star/align) module unmodified, pinned to the same **STAR 2.7.11b** version used for indexing above, and continues the same container/Conda exception described there (`-profile singularity`/`docker`/`conda`).

### HLApm read quantification

Immediately after alignment, each per-`(RNA sample, allele)` coordinate-sorted BAM (`STAR_ALIGN`'s own output, above) is additionally queryname-sorted with [nf-core/modules `SAMTOOLS_SORT`](https://github.com/nf-core/modules/tree/master/modules/nf-core/samtools/sort) (`samtools sort -n`); `STAR_ALIGN`'s coordinate-sorted BAM is unchanged and continues to be published as before. Once every distinct allele's GTF (from HLApm STAR index, above) has been concatenated into one cohort-wide `combined.gtf` (comment lines stripped), the pipeline runs the legacy, unmodified Python 2.7 `make_a_table_210804_allHLAgenes.py` script once per RNA sample, over that sample's full set of per-allele queryname-sorted BAMs plus the combined GTF. For each read, this script assigns it to a gene by minimum summed-mate edit distance across every candidate allele/gene it overlaps, producing `<rna_id>.edit_distance.tsv` (one row per read, with a `unique`/`best`/`ambiguous` confidence label) plus a `<rna_id>.stat.txt` run-statistics log. See [output docs](output.md#hlapm-read-quantification) for the resulting `hlapm/quantify/` layout.

Immediately after `make_a_table_210804_allHLAgenes.py` writes `<rna_id>.edit_distance.tsv`, the pipeline runs a new `HLAPM_SUMMARIZE_READCOUNTS` step over that same table, using a new `bin/summarize_hla_readcounts.R` script (adapted from `davenportlab/HLApm_farm_pipeline`'s summarization script). For each RNA sample, it keeps only non-`ambiguous` reads whose winning-gene edit distance is at or below `--hlapm_quantify_max_edit_distance` (default `16`, matching the source script's hardcoded threshold), then counts the surviving reads per gene, producing `<rna_id>.HLA_gene_summary.tsv` (columns: `gene_name`, `n_reads_mapping`). This closes the "stops at the per-read table" gap left open by the earlier iteration; it runs from the [shared data-tools container](#shared-data-tools-container) rather than alongside `make_a_table_210804_allHLAgenes.py`'s Python 2 environment (see below).

`--hlapm_quantify_max_edit_distance` (default `16`) is passed straight through to this step as the maximum summed-mate edit distance (NM) a read may have and still count toward its assigned gene's read count.

Per-allele-level read counts, a cross-sample combined gene-count table, and comparison against `featureCounts` ground truth remain out of scope for this iteration.

#### HLApm read-quantification container

`HLAPM_QUANTIFY_READS` provisions its own dependencies from
[`modules/local/hlapm/quantify_reads/environment.yml`](../modules/local/hlapm/quantify_reads/environment.yml),
which feeds both the module's `conda` directive and the image its `container` directive points at. Build that image once with `scripts/build_image_hlapm_quantify.sh`; nothing has to be created by hand.

`make_a_table_210804_allHLAgenes.py` is unmodified legacy code, so this environment is a deliberately frozen **Python 2.7.15** (the newest Python 2 conda-forge ships) plus:

- `pybam`, pinned by commit `846d98603905c57c31bf7b9abaf2eb8c89899e60` - it is a GitHub-only package with no releases, tags or PyPI presence, so a commit SHA is the only reproducible handle on a version;
- `intervaltree` 3.1.0. The script prefers `quicksect` and falls back to `intervaltree`; `quicksect` is deliberately **not** installed, so the script keeps taking the `intervaltree` branch that every result this pipeline has produced so far came from.

Python 2 has been end of life since 2020 and receives no security updates. Freezing it inside a container, rather than asking operators to maintain a Python 2 environment, is precisely the point of this image; porting the script to Python 3 is the real fix and is a separate, much larger piece of work.

Build the image once before running with a container profile:

```bash
scripts/build_image_hlapm_quantify.sh
```

This builds and tags the Docker image as `quay.io/hlarnaseq/hlapm-quantify-reads:py2.7.15`, matching `nextflow.config`'s `docker.registry`/`singularity.registry = 'quay.io'` default so `-profile docker` finds it locally with no registry push needed, and converts it into a local `modules/local/hlapm/quantify_reads/hlapm-quantify-reads.sif` for `-profile singularity`/`apptainer`. The build needs network access to the Conda channels, PyPI and `github.com`. Override the pinned pybam commit with `PYBAM_COMMIT=<sha>` - see `scripts/build_image_hlapm_quantify.sh --help`, and note that `-profile conda` reads the pin from `environment.yml`, so change both to keep those two paths in step.

Under `-profile conda` the same `environment.yml` is used, which means Conda needs PyPI and `github.com` access the first time it creates that environment - `pybam` and `intervaltree` are `pip:` entries, outside Conda's solver.

#### Shared data-tools container

Thirteen modules do not wrap a bioinformatics tool at all - they run this repository's own small analysis scripts from `bin/`, or a few lines of inline shell:

| Module                          | Script                                                                   |
| ------------------------------- | ------------------------------------------------------------------------ |
| `HLA_CONSENSUS`                 | `call_hla_consensus.py` (python3, pandas)                                |
| `HLAPM_PREPARE_INPUT`           | `consensus_to_hlapm.py` (python3)                                        |
| `ARCASHLA_COMBINE`              | `combine_arcashla_genotypes.R` (jsonlite, dplyr, tibble, stringr, purrr) |
| `HLAPM_SUMMARIZE_READCOUNTS`    | `summarize_hla_readcounts.R` (dplyr, tidyr)                              |
| `HLA_READCOUNT_RECONCILE_DIFF`  | `reconcile_hla_readcounts.py` (python3, pandas)                          |
| `GTF_HLA_GENE_ID_CHECK`         | `check_gtf_hla_gene_ids.py` (python3)                                    |
| `COMBINE_FINAL_COUNTS_PATCH`    | `combine_final_counts.py` (python3)                                      |
| `COUNTS_COMMONREF_HLA_REFORMAT` | `reformat_rnaseq_featurecounts.py` (python3) + `samtools`                |
| `HLALA_COMBINE`                 | inline shell (bash, coreutils, awk)                                      |
| `HIBAG_COMBINE`                 | inline shell (bash, coreutils, awk)                                      |
| `HLAPM_COMBINE_GTF`             | inline shell (bash, coreutils, grep)                                     |
| `HLAPM_LIST_STAR_TARGETS`       | inline shell (bash, coreutils, findutils)                                |
| `HLAPM_RESOLVE_SAMPLE_ALLELES`  | inline shell (bash, coreutils)                                           |

All thirteen share one environment, [`containers/datatools/environment.yml`](../containers/datatools/environment.yml), and one image built from it. Unlike every other environment file here it is not module-local, because thirteen near-identical copies of an overlapping package list would drift apart; see [`containers/datatools/README.md`](../containers/datatools/README.md).

`COUNTS_COMMONREF_HLA_REFORMAT` is why that environment also carries `samtools` (pinned to **1.24**, the same version `ARCASHLA_EXTRACT` and the vendored `SAMTOOLS_SORT` use, so the pipeline never runs two samtools versions): it needs `samtools` and `python3` together, and no prebuilt public image pairs them. The five inline-shell modules add nothing to the environment - `bash`, coreutils, `awk`, `findutils` and `grep` come from the image's base OS under a container profile and from the host under `-profile conda` - but they point at it so they declare a reproducible environment rather than none at all.

Build it once before running with a container profile:

```bash
scripts/build_image_datatools.sh
```

This builds `quay.io/hlarnaseq/datatools:1.1` and the local `containers/datatools/datatools.sif`, following the same local-image pattern as the other images described above. Under `-profile conda`, Nextflow creates the one environment and all thirteen modules share it.

> [!IMPORTANT]
> The image tag moved from `:1.0` to `:1.1` when `samtools` was added. If you built the image before that, **rebuild it** - a run under `-profile docker` will otherwise fail to find `quay.io/hlarnaseq/datatools:1.1` in the local image store, and `-profile singularity`/`apptainer` will silently use a stale `.sif` with no `samtools`.

Package versions are pinned to those the pipeline's existing published results were produced with, so containerizing these steps changes no output. Running any of these thirteen modules with no `-profile conda`/`docker`/`singularity`/`apptainer` now fails fast with a message naming those profiles, instead of silently using whichever `python3`/`Rscript`/`samtools` happens to be on the host `PATH` - the same trade already made for `ARCASHLA_EXTRACT`, `HIBAG_PREDICT` and `HLAPM_BUILD_REF`.

## GTF HLA gene-id uniqueness check

> [!IMPORTANT]
> This check rejects **stock GENCODE**. A run with an unmodified
> `gencode.v50.primary_assembly.annotation.gtf.gz` fails, by design, within seconds of starting. You must supply a corrected GTF - see [Fixing a rejected GTF](#fixing-a-rejected-gtf) below. There is no opt-out parameter and no lenient mode, and because RNA-seq HLA quantification is the pipeline's only mode (`--rna_samples` and `--gtf` are both required), there is no WGS-only or typing-only run to fall back on in the meantime.

Before any counting or reconciliation result is produced, a new `GTF_HLA_GENE_ID_CHECK` process (`bin/check_gtf_hla_gene_ids.py`) makes one streaming pass over `--gtf` and refuses to continue unless its HLA-region annotation carries a strict one-to-one `gene_name` <-> `gene_id` mapping. It runs on every launchable run, is submitted in the first scheduling wave alongside MHC extraction, takes seconds even on a whole-genome GTF, and publishes a small provenance table (`gtf_hla_gene_id_check/hla_region_gene_id_map.tsv`, see [output docs](output.md#gtf-hla-gene-id-uniqueness-check)).

### What is checked, and over which genes

Only `feature_type == "gene"` rows are considered, so a gene with many `transcript`/`exon` rows is never mistaken for a duplicate. The genes **in scope** are the union of two sets - matching the two different ways a gene name reaches the [HLA read-count reconciliation diff table](#hla-read-count-reconciliation-diff-table) below:

1. every gene overlapping `--hla_region` (the same samtools region string `ARCASHLA_EXTRACT` slices each BAM with, so this is exactly the set of non-HLA gene names the reconciliation can see); **union**
2. every gene whose name starts with `HLA-`, wherever it sits in the file (the personalized-reference gene names, which come from HLApm rather than from the region slice, so definition 1 alone would miss them).

For each in-scope gene name, **distinct `gene_id`s are counted across the whole GTF**, not just inside the region - the same thing `bin/reconcile_hla_readcounts.py` does when it resolves a name - so an off-region second annotation of an in-region gene name is an offender too. Both directions fail:

- a `gene_name` carrying more than one distinct `gene_id` (`status=duplicated_gene_name`);
- a `gene_id` carrying more than one distinct in-scope `gene_name` (`status=duplicated_gene_id`).

Because scope definition 1 is keyed off `--hla_region`, narrowing `--hla_region` narrows what is checked. That is deliberate - it keeps the check aligned with the region the pipeline actually analyses - but it does mean the two parameters have to be chosen together.

A GTF with **no** gene overlapping `--hla_region` is a non-fatal warning, not a failure: `-profile test`'s tiny `placeholder.gtf` legitimately has none. On a real whole-genome GTF that warning almost always means a contig-notation mismatch (`chr6` vs `6`) between `--hla_region` and the GTF, and is worth acting on.

### The failure message

The process exits `1` and, because `conf/modules.config` gives it `errorStrategy = 'terminate'`, the run aborts immediately rather than waiting for already-running tasks. **Every** offending pair is printed to stderr - uncapped - because a failed Nextflow task publishes nothing, so that message is the only copy of the list you get without going into the task work directory:

```
ERROR: --gtf has a non-unique gene_name <-> gene_id mapping in the HLA region
       (6 offending gene names, HLA region = chr6:28500000-33400000).
  HLA-DRB6   ENSG00000290878.2, ENSG00000229391.8    duplicated_gene_name
  HLA-H      ENSG00000310469.1, ENSG00000206341.7    duplicated_gene_name
  HLA-L      ENSG00000291097.2, ENSG00000243753.8    duplicated_gene_name
  HLA-V      ENSG00000290710.2, ENSG00000181126.14   duplicated_gene_name
  POLR1HASP  ENSG00000293508.2, ENSG00000204623.12   duplicated_gene_name
  Y_RNA      ENSG00000200344.1, ENSG00000252254.1, ... (758 ids)
Fix --gtf (drop or rename the duplicate gene rows) and re-run. ...
Full table: hla_region_gene_id_map.tsv ...
```

That is the **actual** verdict on `gencode.v50.primary_assembly.annotation.gtf.gz` with the default `--hla_region`: 476 gene names in scope (476 in-region, 39 `HLA-`-prefixed), 6 of them offenders. Note the last two: this check is not HLA-specific within the region, so the non-HLA `POLR1HASP` and `Y_RNA` fail it too. `Y_RNA` is the extreme case - that one name is reused 758 times genome-wide (7 of them inside the MHC), and because the message is uncapped, all 758 ids really are printed on that one line. Truncating it was rejected deliberately: a failed task publishes nothing, so this is the only complete copy of the list, and the `--report` table in the task work directory is the readable form.

An exit status of `127` instead means the process got no environment at all (no `-profile conda`/`docker`/`singularity`/`apptainer`), not that your GTF is bad - see [Dependencies and profiles](#dependencies-and-profiles). An exit status of `2` means `--hla_region` could not be parsed as `contig[:start[-end]]`.

### Fixing a rejected GTF

Most offending rows in a real GENCODE GTF are annotation-duplication artifacts: two near-identical, overlapping `gene` rows for one locus, each with its own `gene_id` (the four HLA pseudogenes and `POLR1HASP` above are all of this kind). Either id is a defensible choice of "the" gene id, but the pipeline cannot pick one for you without silently attributing read counts to an arbitrary id. So the fix is to make the file unambiguous, then re-run:

- **drop** the redundant `gene` row (and its `transcript`/`exon` children) for each offending `gene_name`, keeping the annotation you consider canonical - usually the one with the longer span or the non-`_2`-suffixed `gene_name` in your source; or
- **rename** one of the two `gene_name`s so the pair no longer collides (e.g. `HLA-H` and `HLA-H_dup`). Note that a renamed `HLA-`-prefixed gene stays in scope by definition 2 above, and that HLApm gene names must still match, so renaming is the better option only for genes the personalized reference does not carry.

A `gene_name` that is **reused genome-wide** rather than duplicated at one locus (`Y_RNA`, and in other annotation sources names like `SNORD*` or `5_8S_rRNA`) needs the second approach, applied only to the copies inside the region: give each in-region `gene` row its own unique name (`Y_RNA_MHC_1`, `Y_RNA_MHC_2`, ...). Once no in-region row carries the shared name, that name is out of scope entirely - by definition 1, only in-region genes are checked - so its hundreds of out-of-region copies stop mattering, and the renamed in-region genes each map to one id. Do **not** try to collapse the out-of-region copies; they are genuinely different genes that happen to share a symbol.

Both fixes can be applied mechanically from a small, reviewable patch file rather than by hand - see [Patching a rejected GTF](#patching-a-rejected-gtf) below, which includes a ready-made patch for GENCODE v50.

Re-run the check on its own, without launching the pipeline, to iterate quickly:

```bash
singularity exec containers/datatools/datatools.sif \
  bin/check_gtf_hla_gene_ids.py \
    --gtf /path/to/annotation.gtf.gz \
    --hla-region chr6:28500000-33400000 \
    --report hla_region_gene_id_map.tsv
```

The report lists every in-scope gene name with its `gene_ids`, `n_gene_ids`, `in_region`, `hla_prefixed` and `status`, so `awk -F'\t' '$6 != "unique"'` over it is the full worklist.

### Patching a rejected GTF

`scripts/patch_gtf_gene_ids.py` performs both fixes above from a small patch file, so a corrected GTF is reproducible from a reviewable, version-controlled record of what was changed and why, rather than from an ad hoc `awk` invocation nobody kept. It is an operator tool run out of band, like the other `scripts/` helpers: no process runs it, and it changes no pipeline behaviour. It reads the GTF plain or gzipped and writes the patched GTF to **stdout**, with an action summary on stderr.

The patch is a two-column TSV whose second column is optional per row. `#` comments, blank lines, and a `gene_id`/`new_gene_name` header row are ignored.

| Column | Meaning                                                                                                                                     |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| 1      | `gene_id`, matched exactly against the row's `gene_id` attribute - **version suffix included** (`ENSG00000206341.7`, not `ENSG00000206341`) |
| 2      | `new_gene_name`. Present: **rename** that gene. Absent, empty, or whitespace-only: **remove** it.                                           |

Each action reaches the whole gene, not just its `gene` row. Every `transcript`, `exon`, `CDS`, `UTR` and codon row carries the same `gene_id`, so a removed gene disappears completely and a renamed gene is renamed on all of its rows - which is what makes the fix effective downstream, since featureCounts reads `exon` rows and would otherwise keep counting under the old name. A rename rewrites the `gene_name "..."` token and nothing else, leaving every other attribute, their order, and the row's whitespace untouched.

**Genes you do not list are never touched.** Nothing is inferred from `gene_name`, so an unlisted gene that merely shares a symbol with a listed one comes through byte for byte - that is what makes the `Y_RNA` case safe to patch: naming the 7 in-region `gene_id`s cannot disturb the 751 copies elsewhere in the genome. A `gene_id` listed in the patch but **absent** from the GTF is a hard error (exit `3`) rather than a silent no-op, and the whole patch is resolved against the GTF before the first output byte, so a stale patch or the wrong `--gtf` leaves stdout empty instead of a truncated file that looks usable. Exit `2` means an input could not be used at all - the patch file is malformed (bad row, duplicate `gene_id`) or a file could not be read. Because stdout is a whole GTF, the script behaves like any other Unix filter when its reader goes away: piping into `head`, or into a `gzip` that dies, ends quietly with `141` rather than a traceback.

`gencodev50.mapping_patch.tsv` in the repository root is a worked example: the complete, rename-only patch that makes stock `gencode.v50.primary_assembly.annotation.gtf.gz` pass this check under the default `--hla_region`, with its provenance and the reasoning behind each primary-id choice in its comment preamble.

```bash
singularity exec containers/datatools/datatools.sif \
  scripts/patch_gtf_gene_ids.py \
    --gtf gencode.v50.primary_assembly.annotation.gtf.gz \
    --patch gencodev50.mapping_patch.tsv \
  | gzip > gencode.v50.hla-patched.gtf.gz

# confirm, then use the result as --gtf
singularity exec containers/datatools/datatools.sif \
  bin/check_gtf_hla_gene_ids.py \
    --gtf gencode.v50.hla-patched.gtf.gz \
    --hla-region chr6:28500000-33400000 \
    --report hla_region_gene_id_map.tsv
```

Two things the script deliberately does not do. It does not rewrite attributes derived from the old symbol, notably GENCODE's `transcript_name "HLA-H-201"`, which keeps the old name after a rename; nothing in this pipeline reads them, so this is cosmetic residue rather than a correctness problem. And it will not stop you removing a gene the personalized reference still expects - the caution in [Fixing a rejected GTF](#fixing-a-rejected-gtf) applies unchanged, so prefer renaming for `HLA-`-prefixed genes HLApm carries. The stderr summary prints each patched gene's current `gene_name` alongside its action for exactly this reason.

### Why this is stricter than it used to be

An earlier iteration deliberately made this ambiguity _non_-fatal, resolving it softly inside `bin/reconcile_hla_readcounts.py` (see `CHANGELOG.md`, the "484 ambiguous gene names in GENCODE v50" entry). That is now reversed for HLA-region genes: neither soft resolution produces a usable `gene_id` for the planned count-matrix patching step - the HLA rule picks an arbitrary first id, and the non-HLA rule emits a semicolon-joined id string that is not a `gene_id` at all - so ambiguity is rejected up front instead. The soft handling itself stays in place as defence in depth for names outside this check's scope, and for the `missing_gene_name` case, which remains a soft fail.

## Whole-genome common-reference gene counts

Independent of `--sample_key`/HLApm, the pipeline also runs [nf-core/modules `SUBREAD_FEATURECOUNTS`](https://github.com/nf-core/modules/tree/master/modules/nf-core/subread/featurecounts) once per RNA sample, directly against that sample's original, full whole-genome, coordinate-sorted BAM (`--rna_samples`'s `bam`/`bai` columns) - not the arcasHLA MHC-extracted reads or HLApm personalized references used above. This reproduces, in-pipeline, the "original count matrix" half of the legacy prototype's `featureCounts` step, producing a per-sample whole-genome gene-count table without depending on an externally supplied count matrix file.

`--gtf` is **mandatory**, like `--rna_samples` and `--sample_key` themselves: nf-schema rejects a run that omits it with `Missing required parameter(s): gtf`, and rejects a path that does not exist, before any task starts.

```bash
--gtf '[path to a whole-genome reference GTF]'
```

`--rnaseq_strandedness` (default `reverse`) sets the RNA-seq library strandedness passed to featureCounts (`-s`); allowed values are `unstranded`, `forward`, or `reverse`. This is a single pipeline-wide value, not a per-sample `--rna_samples` column - a future cohort needing per-sample strandedness would require revisiting this as a samplesheet column.

This step reuses the `SUBREAD_FEATURECOUNTS` module unmodified, pinned to **Subread 2.1.1**. As with `STAR_GENOMEGENERATE`/`STAR_ALIGN` above, Subread/featureCounts comes from the module's own `environment.yml`/`container` pair - a public Biocontainers image, nothing to build locally:

```bash
-profile singularity
```

`docker` and `apptainer` work the same way, and `-profile conda` builds the module's pinned `environment.yml` (`bioconda::subread=2.1.1`) instead - with the same "less thoroughly verified" caveat noted for STAR above.

See [output docs](output.md#whole-genome-common-reference-gene-counts) for the resulting `counts_commonref/` layout. These whole-genome counts are published unpatched, for provenance: they are patched with `HLAPM_STAR_QUANTIFY`'s HLA-specific counts downstream, via the per-gene reconciliation diff produced by [HLA read-count reconciliation diff table](#hla-read-count-reconciliation-diff-table) and then applied by [Final combined gene counts](#final-combined-gene-counts), both below.

## HLA-region per-read featureCounts reconciliation input

Independent of `--sample_key`/HLApm, the pipeline also produces a per-read gene-assignment table for the HLA-region-restricted subset of each RNA sample's original BAM - the second of the four steps making up the "hijack original count matrix" roadmap item. Unlike [Whole-genome common-reference gene counts](#whole-genome-common-reference-gene-counts) above (which is independent of/parallel to `ARCASHLA`), this step runs _after_ `ARCASHLA`, because it reuses `ARCASHLA_EXTRACT`'s own intermediate HLA-region BAM (`arcashla/extracted/<rna_id>.mhc.namesort.bam`, see [output docs](output.md#arcashla-read-extraction-and-validation)) rather than extracting the HLA region a second time from scratch. No new region-extraction dependency is introduced by this step.

`SUBREAD_FEATURECOUNTS` (aliased `SUBREAD_FEATURECOUNTS_HLA`, a second invocation of the same vendored module used above) runs with `-R BAM` against that intermediate BAM and the same cohort-wide `--gtf` reference already used above - no separate HLA-only GTF is built or required. This module has been patched (`nf-core modules patch subread/featurecounts`) to additionally capture the `-R BAM` per-read reannotated BAM as a declared output (previously an unexposed side effect of `-R BAM`); the patch also fixes an unrelated, pre-existing version-reporting defect (see `CHANGELOG.md`). The reannotated BAM is then converted to plain text with `samtools view`, filtered to `Assigned`-status lines, and reformatted into a `read_name`, `direction`, `gene_name`, `edit_distance` TSV by a new `bin/reformat_rnaseq_featurecounts.py` script. Both steps run inside `COUNTS_COMMONREF_HLA_REFORMAT`, which provisions its own `samtools` and `python3` from the [shared data-tools container](#shared-data-tools-container) - they are no longer expected on the host `$PATH`. (`SUBREAD_FEATURECOUNTS_HLA` itself continues the same container/`-profile conda` exception as `SUBREAD_FEATURECOUNTS` above.)

`reformat_rnaseq_featurecounts.py` translates each read's assigned `gene_id` (featureCounts' `XT` tag) back to a `gene_name` via the same `--gtf`, which is the mirror image of the reconciliation's lookup below - and it fails the same way, for the same reason. A `gene_id` that carries reads here but has more than one distinct `gene_name` in `--gtf` (the `duplicated_gene_id` direction the [GTF HLA gene-id uniqueness check](#gtf-hla-gene-id-uniqueness-check) also rejects) fails the task with exit status 1 and prints the offending ids and all of their names, rather than silently adopting whichever name appeared last in the file and attributing the reads to the wrong gene. As below, the failure is scoped to consumption: only a `gene_id` actually carried by an assigned read is checked, so a duplicated `gene_id` elsewhere in `--gtf` does not fail the run. A `gene_id` with no `gene_name` at all is unaffected and still stands in for its own name.

See [output docs](output.md#hla-region-per-read-featurecounts-reconciliation-input) for the resulting `counts_commonref_hla/` layout. This step itself stops at producing the per-read table; reconciling it against `HLAPM_STAR_QUANTIFY`'s HLA-specific `edit_distance.tsv` is described immediately below, and the final splice into `counts_commonref`'s whole-genome table (the "hijack" step itself) in [Final combined gene counts](#final-combined-gene-counts) after that.

## HLA read-count reconciliation diff table

Whenever an RNA sample has both a `counts_commonref_hla` read-gene-assignment table (above) and a personalized-HLA `edit_distance.tsv` ([HLApm read quantification](#hlapm-read-quantification), above) - i.e. only samples resolved through `--sample_key`/HLApm to at least one personalized allele - the pipeline reconciles the two into a per-gene diff table, via a new `HLA_READCOUNT_RECONCILE` subworkflow (`HLA_READCOUNT_RECONCILE_DIFF` module) and a new `bin/reconcile_hla_readcounts.py` script. This is iteration 3 of the "hijack original count matrix" roadmap item: it adapts `artifacts/scripts/compare-hla-rnaseq-readcounts.py`'s read-pair reconciliation logic (kept-vs-dropped classification) to these two real pipeline tables. Samples not resolved to any personalized-HLA allele simply get no diff table - an expected inner-join outcome, not an error.

For every personalized-HLA read pair (after the existing `ambiguous`/`--hlapm_quantify_max_edit_distance` filtering, reusing the same threshold `HLAPM_SUMMARIZE_READCOUNTS` above uses), it is kept as HLA if the local `counts_commonref_hla` table has no matching read pair (`missing_fc`), if `counts_commonref_hla` also assigned it to an HLA gene (`both_hla`), or if `counts_commonref_hla` assigned it to a non-HLA gene but the personalized-reference edit distance is equal to or better (`reassigned_to_hla`); otherwise it is dropped in favor of the better non-HLA `counts_commonref_hla` assignment. Every post-filter personalized-HLA gene gets a row in the output - including a gene whose every read pair was dropped, with a reconciled count of `0` rather than a silently missing row (a gap fixed relative to the prototype script). A non-HLA gene only gets a row when it lost at least one read pair to HLA.

Every gene name in the output (HLA and non-HLA alike) is resolved to a `gene_id` via the whole-genome `--gtf` (unlike the separate `artifacts/scripts/hijack-original-featurecounts.py` prototype's own gene-mapping helper, which only resolves `HLA-`-prefixed names). That resolution has to produce exactly one `gene_id` per row, because the row is an input to the future count-matrix patching step, so:

- A `gene_name` absent from `--gtf` resolves to the literal string `NA`, and the run continues - a personalized-reference-only or renamed gene symbol legitimately missing from the whole-genome GTF is plausible. It is recorded in a dedicated, always-produced `<rna_id>.gene_id_resolution_warnings.tsv` file (see [output docs](output.md#hla-read-count-reconciliation-diff-table) for its full column schema), alongside a batched stderr summary.
- A `gene_name` that maps to more than one distinct `gene_id` in `--gtf` **fails the task** (exit status 1), printing every offending name and all of its candidate ids to stderr. The pipeline does not pick one id, and does not join them: either would put a value the patching step cannot use into a published table. Earlier versions resolved this softly (first id for an HLA row, semicolon-joined ids for a non-HLA row, recorded as `ambiguous_gene_id` in the warnings file); that policy is gone.

**You do not need a globally de-duplicated `--gtf`.** This is the important half, because ambiguous gene names are normal: GENCODE v50's primary assembly has 484 of them, each a near-identical/overlapping-gene-row annotation-duplication artifact, and only 4 are HLA genes (`HLA-H`, `HLA-L`, `HLA-V`, `HLA-DRB6`). A `--gtf` corrected for the HLA region still contains the other 480, and that is expected and fine. The failure above is triggered by ambiguity that is **actually consumed**, not by ambiguity that merely exists:

- only a `gene_name` that takes a row in the diff table has its `gene_id` looked up at all - i.e. a post-filter personalized-HLA gene, or a non-HLA gene that actually lost at least one read pair to HLA;
- a gene that is ambiguous in `--gtf` but takes no row - an off-region gene, or even a gene with its own featureCounts read pairs that lost none of them to HLA - is never looked up, never reported, and never fails the run.

In practice the failure should be unreachable: the [GTF HLA gene-id uniqueness check](#gtf-hla-gene-id-uniqueness-check) rejects a `--gtf` that is ambiguous over any gene overlapping `--hla_region` or any `HLA-`-prefixed gene name before this step runs, which covers every name this reconciliation can produce from a real HLA-region BAM (including all 4 GENCODE v50 HLA offenders). Reaching the error message therefore means a name got here from outside that check's scope - a GTF whose ambiguity lives only in non-`gene` feature rows, a `--gtf` replaced mid-run, or a genuinely off-region gene reaching the output - each of which is worth stopping for rather than silently resolving. The fix in every case is to drop or rename the duplicate `gene` rows for the names the error lists; nothing else in the GTF needs touching.

This reconciliation - and the `gene_id` lookup above - operates entirely at `gene_name` granularity, never `gene_id`: the per-read `gene_id` featureCounts originally assigned (via its `XT` tag) is already discarded upstream, when [`bin/reformat_rnaseq_featurecounts.py`](#hla-region-per-read-featurecounts-reconciliation-input) converts it to `gene_name` (above) - `counts_commonref_hla`'s own per-read table never carries `gene_id` at all, so this step has no per-read `gene_id` left to work with even for a non-HLA row. This is not just an incidental data-loss inconvenience: featureCounts assigns each mate of a read pair independently, based on that mate's own overlap, so for two overlapping gene annotations that happen to share one `gene_name` (exactly the kind of annotation-duplication artifact described above - `POLR1HASP`'s two `gene_id`s are one real example: a large lncRNA locus with a smaller pseudogene entirely nested inside its span), a read pair's R1 and R2 mates can each be assigned a _different_ specific `gene_id` by featureCounts while still agreeing on `gene_name`. There is therefore no single, unambiguous `gene_id` to attribute a whole read pair to even in principle, which is why a non-HLA row's `original_fc_count`/`diff` (or an HLA row's `personalized_count`, which HLApm never associates with any whole-genome `gene_id` at all) is never split out per individual `gene_id` - the single-`gene_id`-per-`gene_name` lookup above (or a hard failure when that name has no single id) is the full extent of this step's `gene_id` resolution.

See [output docs](output.md#hla-read-count-reconciliation-diff-table) for the resulting `hla_readcount_reconcile/` layout and full column schema. This step produces only the per-sample diff table; applying it to `counts_commonref`'s whole-genome table (the final "hijack" splice) is the next section.

## Final combined gene counts

Whenever an RNA sample has both a whole-genome `counts_commonref` gene-count table ([Whole-genome common-reference gene counts](#whole-genome-common-reference-gene-counts), above) and an `hla_readcount_reconcile` diff table (immediately above) - i.e. only samples resolved through `--sample_key`/HLApm to at least one personalized allele - the pipeline patches the former with the latter, via a new `COMBINE_FINAL_COUNTS` subworkflow (`COMBINE_FINAL_COUNTS_PATCH` module) and a new `bin/combine_final_counts.py` script. This is iteration 4, the last, of the "hijack original count matrix" roadmap item, and adapts `artifacts/scripts/hijack-original-featurecounts.py`. Samples not resolved to any personalized-HLA allele get no final table at all - an expected inner-join outcome, and deliberately preferred to publishing an unpatched copy of the whole-genome table under a "final" name.

The patch is a straight `gene_id` join:

- a `category: hla` diff row **replaces** that `gene_id`'s count with the personalized-reference count (`personalized_count`);
- a `category: non_hla` diff row **adjusts** that `gene_id`'s count by the (negative) `diff`;
- every other gene keeps its original whole-genome count.

Row order and the row key set of the output are exactly `counts_commonref`'s, so per-sample columns stay joinable into a cohort matrix; every row, patched HLA rows included, is keyed by `gene_id`. The script also does the raw-table conversion itself: `counts_commonref`'s published table is featureCounts' native 7-column output (`Geneid`, `Chr`, `Start`, `End`, `Strand`, `Length`, plus one count column), and the final table is a two-column projection of it. See [output docs](output.md#final-combined-gene-counts) for the resulting `combine_final_counts/` layout and the change log's full column schema.

**No `--gtf` is needed for this step**, unlike the prototype script it replaces. That script keyed its HLA replacements by `gene_name` and so re-derived a `gene_name` -> `gene_id` mapping itself, with an HLA-only, "first seen wins" helper. Here the diff table already carries a resolved, unambiguous `gene_id` for both categories (see above) and the whole-genome table is keyed by `gene_id` (featureCounts' `-g gene_id`), so a third, independent gene-name resolution path would only reintroduce the loose behaviour the [GTF HLA gene-id uniqueness check](#gtf-hla-gene-id-uniqueness-check) and the reconciliation's own strict lookup were added to remove.

### Missing is soft, wrong is fatal

- A diff row whose `gene_id` is the literal `NA` is **skipped**, and the run continues. This is the reconciliation's deliberate soft-fail for a gene name absent from `--gtf`, and a real cohort hits it (`HLA-DRB3`: reconciled to read pairs, no `gene_id`). Failing here would reject runs the upstream step intentionally accepts. Every such gene is recorded in `<rna_id>.final_counts.change_log.tsv` as `unapplied_missing_gene_id` and warned about on stderr, so nothing is lost silently - but **its read pairs do not reach the final table**, so a cohort's final counts under-count exactly those HLA genes missing from `--gtf`. The fix is upstream: annotate the gene in `--gtf` (`bin/patch_gtf_gene_ids.py` can rename or remove genes out of band), not here.
- A diff row whose `gene_id` is **not** `NA` but is absent from the whole-genome table **fails the task** (exit status 1). Both tables are built from the same `--gtf`, so this can only mean the two counting steps saw different annotation.
- A resulting count **below zero fails the task** (exit status 1). A `non_hla` `diff` is computed against the HLA-region-restricted featureCounts run while the count being patched comes from the whole-genome run, so the two are not arithmetically guaranteed to fit. A negative count is never a publishable number.

Both fatal classes are collected across the whole table before either is allowed to fail, and every offender is printed to stderr uncapped, so one run gives you the complete list. Nothing is written on failure.

### Counts are read pairs, and that is asserted

The final table counts **read pairs** (fragments), not reads. The reconciled personalized-HLA counts are read pairs by construction, so the whole-genome table has to be counted the same way for the two to be comparable - and in this pipeline it always is, since `conf/modules.config` passes `--countReadPairs` to `SUBREAD_FEATURECOUNTS` and every RNA sample is treated as paired-end (so featureCounts also gets `-p`).

Rather than offer the prototype's `--fc-is-paired` switch and its x2 read-pairs-to-reads rescale, the script **asserts** that unit: it parses the `# Program:...Command:` line featureCounts writes into its own output and fails the task (exit status 1) unless that command line shows both `--countReadPairs` and `-p`. If the line is absent or unparsable, it fails too - the assumption cannot be verified, and silently assuming it is what would halve or double every HLA count. There is no CLI switch and no parameter, so the unit cannot be overridden into being wrong. A future `ext.args` edit that drops `--countReadPairs` therefore becomes a run failure with an actionable message rather than a silent rescale; any such edit needs this step reconsidered anyway.

Merging these per-sample columns into a single cross-sample count **matrix** remains out of scope.

## Running on an LSF cluster (Sanger module)

If your cluster provides this pipeline as an [Environment Modules](https://modules.readthedocs.io/) module, you do not need to assemble a `nextflow run` command or remember which profiles to combine:

```bash
module load hlarnaseq/1.0

hlarnaseq-bsub -params-file my_run.yml --outdir results   # head process on LSF
hlarnaseq      -params-file my_run.yml --outdir results   # head process in this shell
```

Both commands pass every argument straight through to `nextflow run` and default to `-profile singularity,sanger`, so everything in the rest of this document applies unchanged. `hlarnaseq -h` lists the module's commands, and `hlarnaseq -v` reports which install, branch and commit you are about to run.

`hlarnaseq-bsub` submits only the **Nextflow head process**. The pipeline then submits each task as its own LSF job through the `sanger` profile's executor, so that one job is small and long-lived rather than being the work itself. Its logs go to `./hlarnaseq-run-logs/<timestamp>/`, and `QUEUE=long hlarnaseq-bsub ...` overrides the queue.

Two commands cover the one-off preparation described elsewhere in this document — the [four locally built images](#dependencies-and-profiles) and the large out-of-band reference datasets:

```bash
hlarnaseq-build-image all                              # needs Docker; see the deployment README
hlarnaseq-build-reference arcashla /lustre/.../ref      # --arcashla_reference_dir
hlarnaseq-build-reference hlala    /lustre/.../graphs   # --hlala_graph_dir
```

Neither is submitted to LSF for you. The reference builds in particular are slow and want a lot of disk and memory, so take an interactive job rather than running them on a login node — `hlarnaseq-build-reference -h` gives a `bsub -Is` line to start from.

`-resume` is **not** added for you by either run command: pass it explicitly to continue a previous run in the same directory.

To set this deployment up, or to understand what it does and does not handle, see [`scripts/sanger_hpc_deploy_scripts/README.md`](../scripts/sanger_hpc_deploy_scripts/README.md).

## Running the pipeline

The typical command for running the pipeline is as follows:

```bash
nextflow run nf-core/hlarnaseq \
    --rna_samples ./rna_samples.csv \
    --sample_key ./rna_wgs_key.csv \
    --hla_region chr6:28500000-33400000 \
    --gtf /path/to/annotation.gtf \
    --arcashla_reference_dir /path/to/arcashla_reference \
    --outdir ./results
```

All five of those input parameters, plus `--outdir`, are required: RNA-seq HLA quantification is the pipeline's purpose, so there is no RNA-less or typing-only mode. A run missing any of them stops immediately with nf-schema's `Missing required parameter(s): ...`. Genotype-side typing (`--wgs_samples` with HLA-LA, or `--array_samples` with HIBAG) stays optional.

Every step provisions its own tools. All eighteen processes under `modules/local/` declare a `conda` directive backed by an `environment.yml` and a matching pinned `container`, as do all vendored `modules/nf-core/` modules — MHC extraction (samtools), read-pair validation and arcasHLA genotyping included. No pipeline step falls back to whatever happens to be on the host `$PATH`; running with none of `-profile conda`/`docker`/`singularity`/`apptainer` fails with an explicit message naming the missing tool. See [Dependencies and profiles](#dependencies-and-profiles).

> [!NOTE]
> `-profile test`'s bundled RNA fixture is deliberately tiny and does not carry real HLA allele signal, so arcasHLA genotypes it as empty. Since `HLA_CONSENSUS`, `HLAPM`, and STAR indexing/alignment now always run, a real (non-stub) `-profile test` run will fail once it reaches `HLA_CONSENSUS`/`HLAPM` with no allele calls to consense. At this development stage, `-profile test` is validated with `-stub-run` (`nextflow run . -profile test -stub-run --outdir <OUTDIR>`), which proves process/channel wiring without needing real tool output. A real, non-stub `-profile test` run is not expected to succeed yet.

Note that the pipeline will create the following files in your working directory:

```bash
work                # Directory containing the nextflow working files
<OUTDIR>            # Finished results in specified location (defined with --outdir)
.nextflow_log       # Log file from Nextflow
# Other nextflow hidden files, eg. history of pipeline runs and old logs.
```

If you wish to repeatedly use the same parameters for multiple runs, rather than specifying each flag in the command, you can specify these in a params file.

Pipeline settings can be provided in a `yaml` or `json` file via `-params-file <file>`.

> [!WARNING]
> Do not use `-c <file>` to specify parameters as this will result in errors. Custom config files specified with `-c` must only be used for [tuning process resource specifications](https://nf-co.re/docs/usage/configuration#tuning-workflow-resources), other infrastructural tweaks (such as output directories), or module arguments (args).

The above pipeline run specified with a params file in yaml format:

```bash
nextflow run nf-core/hlarnaseq -profile docker -params-file params.yaml
```

with:

```yaml title="params.yaml"
rna_samples: './rna_samples.csv'
hla_region: 'chr6:28500000-33400000'
outdir: './results/'
genome: 'GRCh38'
<...>
```

You can also generate such `YAML`/`JSON` files via [nf-core/launch](https://nf-co.re/launch).

### Updating the pipeline

When you run the above command, Nextflow automatically pulls the pipeline code from GitHub and stores it as a cached version. When running the pipeline after this, it will always use the cached version if available - even if the pipeline has been updated since. To make sure that you're running the latest version of the pipeline, make sure that you regularly update the cached version of the pipeline:

```bash
nextflow pull nf-core/hlarnaseq
```

### Reproducibility

It is a good idea to specify the pipeline version when running the pipeline on your data. This ensures that a specific version of the pipeline code and software are used when you run your pipeline. If you keep using the same tag, you'll be running the same version of the pipeline, even if there have been changes to the code since.

First, go to the [nf-core/hlarnaseq releases page](https://github.com/nf-core/hlarnaseq/releases) and find the latest pipeline version - numeric only (eg. `1.3.1`). Then specify this when running the pipeline with `-r` (one hyphen) - eg. `-r 1.3.1`. Of course, you can switch to another version by changing the number after the `-r` flag.

This version number will be logged in reports when you run the pipeline, so that you'll know what you used when you look back in the future.

To further assist in reproducibility, you can use share and reuse [parameter files](#running-the-pipeline) to repeat pipeline runs with the same settings without having to write out a command with every single parameter.

> [!TIP]
> If you wish to share such profile (such as upload as supplementary material for academic publications), make sure to NOT include cluster specific paths to files, nor institutional specific profiles.

## Core Nextflow arguments

> [!NOTE]
> These options are part of Nextflow and use a _single_ hyphen (pipeline parameters use a double-hyphen)

### `-profile`

Use this parameter to choose a configuration profile. Profiles can give configuration presets for different compute environments.

Several generic profiles are bundled with the pipeline which instruct the pipeline to use software packaged using different methods (Docker, Singularity, Podman, Shifter, Charliecloud, Apptainer, Conda) - see below.

> [!IMPORTANT]
> We highly recommend the use of Docker or Singularity containers for full pipeline reproducibility, however when this is not possible, Conda is also supported.

The pipeline also dynamically loads configurations from [https://github.com/nf-core/configs](https://github.com/nf-core/configs) when it runs, making multiple config profiles for various institutional clusters available at run time. For more information and to check if your system is supported, please see the [nf-core/configs documentation](https://github.com/nf-core/configs#documentation).

Note that multiple profiles can be loaded, for example: `-profile test,docker` - the order of arguments is important!
They are loaded in sequence, so later profiles can overwrite earlier profiles.

If `-profile` is not specified, the pipeline will run locally and expect all software to be installed and available on the `PATH`. This is _not_ recommended, since it can lead to different results on different machines dependent on the computer environment.

- `test`
  - A profile with a complete configuration for automated testing
  - Includes links to test data so needs no other parameters
- `docker`
  - A generic configuration profile to be used with [Docker](https://docker.com/)
- `singularity`
  - A generic configuration profile to be used with [Singularity](https://sylabs.io/docs/)
- `podman`
  - A generic configuration profile to be used with [Podman](https://podman.io/)
- `shifter`
  - A generic configuration profile to be used with [Shifter](https://nersc.gitlab.io/development/shifter/how-to-use/)
- `charliecloud`
  - A generic configuration profile to be used with [Charliecloud](https://charliecloud.io/)
- `apptainer`
  - A generic configuration profile to be used with [Apptainer](https://apptainer.org/)
- `wave`
  - A generic configuration profile to enable [Wave](https://seqera.io/wave/) containers. Use together with one of the above (requires Nextflow ` 24.03.0-edge` or later).
- `conda`
  - A generic configuration profile to be used with [Conda](https://conda.io/docs/). Please only use Conda as a last resort i.e. when it's not possible to run the pipeline with Docker, Singularity, Podman, Shifter, Charliecloud, or Apptainer.

### `-resume`

Specify this when restarting a pipeline. Nextflow will use cached results from any pipeline steps where the inputs are the same, continuing from where it got to previously. For input to be considered the same, not only the names must be identical but the files' contents as well. For more info about this parameter, see [this blog post](https://www.nextflow.io/blog/2019/demystifying-nextflow-resume.html).

You can also supply a run name to resume a specific run: `-resume [run-name]`. Use the `nextflow log` command to show previous run names.

### `-c`

Specify the path to a specific config file (this is a core Nextflow command). See the [nf-core website documentation](https://nf-co.re/usage/configuration) for more information.

## Custom configuration

### Resource requests

Whilst the default requirements set within the pipeline will hopefully work for most people and with most input data, you may find that you want to customise the compute resources that the pipeline requests. Each step in the pipeline has a default set of requirements for number of CPUs, memory and time. For most of the pipeline steps, if the job exits with any of the error codes specified [here](https://github.com/nf-core/rnaseq/blob/4c27ef5610c87db00c3c5a3eed10b1d161abf575/conf/base.config#L18) it will automatically be resubmitted with higher resources request (2 x original, then 3 x original). If it still fails after the third attempt then the pipeline execution is stopped.

To change the resource requests, please see the [max resources](https://nf-co.re/docs/usage/configuration#max-resources) and [tuning workflow resources](https://nf-co.re/docs/usage/configuration#tuning-workflow-resources) section of the nf-core website.

### Custom Containers

In some cases, you may wish to change the container or conda environment used by a pipeline steps for a particular tool. By default, nf-core pipelines use containers and software from the [biocontainers](https://biocontainers.pro/) or [bioconda](https://bioconda.github.io/) projects. However, in some cases the pipeline specified version maybe out of date.

To use a different container from the default container or conda environment specified in a pipeline, please see the [updating tool versions](https://nf-co.re/docs/usage/configuration#updating-tool-versions) section of the nf-core website.

### Custom Tool Arguments

A pipeline might not always support every possible argument or option of a particular tool used in pipeline. Fortunately, nf-core pipelines provide some freedom to users to insert additional parameters that the pipeline does not include by default.

To learn how to provide additional arguments to a particular tool of the pipeline, please see the [customising tool arguments](https://nf-co.re/docs/usage/configuration#customising-tool-arguments) section of the nf-core website.

### nf-core/configs

In most cases, you will only need to create a custom config as a one-off but if you and others within your organisation are likely to be running nf-core pipelines regularly and need to use the same settings regularly it may be a good idea to request that your custom config file is uploaded to the `nf-core/configs` git repository. Before you do this please can you test that the config file works with your pipeline of choice using the `-c` parameter. You can then create a pull request to the `nf-core/configs` repository with the addition of your config file, associated documentation file (see examples in [`nf-core/configs/docs`](https://github.com/nf-core/configs/tree/master/docs)), and amending [`nfcore_custom.config`](https://github.com/nf-core/configs/blob/master/nfcore_custom.config) to include your custom profile.

See the main [Nextflow documentation](https://www.nextflow.io/docs/latest/config.html) for more information about creating your own configuration files.

If you have any questions or issues please send us a message on [Slack](https://nf-co.re/join/slack) on the [`#configs` channel](https://nfcore.slack.com/channels/configs).

## Running in the background

Nextflow handles job submissions and supervises the running jobs. The Nextflow process must run until the pipeline is finished.

The Nextflow `-bg` flag launches Nextflow in the background, detached from your terminal so that the workflow does not stop if you log out of your session. The logs are saved to a file.

Alternatively, you can use `screen` / `tmux` or similar tool to create a detached session which you can log back into at a later time.
Some HPC setups also allow you to run nextflow within a cluster job submitted your job scheduler (from where it submits more jobs).

## Nextflow memory requirements

In some cases, the Nextflow Java virtual machines can start to request a large amount of memory.
We recommend adding the following line to your environment to limit this (typically in `~/.bashrc` or `~./bash_profile`):

```bash
NXF_OPTS='-Xms1g -Xmx4g'
```

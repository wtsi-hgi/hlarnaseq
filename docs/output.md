# nf-core/hlarnaseq: Output

## Introduction

This document describes the output produced by the pipeline.

The directories listed below will be created in the results directory after the pipeline has finished. All paths are relative to the top-level results directory.

<!-- TODO nf-core: Write this documentation describing your workflow's output -->

## Pipeline overview

The pipeline is built using [Nextflow](https://www.nextflow.io/) and processes data using the following steps:

- [arcasHLA read extraction and validation](#arcashla-read-extraction-and-validation) - Prepare and validate paired RNA reads for arcasHLA genotyping
- [arcasHLA genotyping](#arcashla-genotyping) - HLA genotyping from validated RNA-seq reads
- [HLA-LA](#hla-la) - HLA typing from WGS BAM inputs
- [HLA consensus](#hla-consensus) - RNA/WGS HLA consensus calling
- [HLA personalized reference (HLApm)](#hla-personalized-reference-hlapm) - Personalized HLA reference building from consensus alleles
- [HLApm STAR index](#hlapm-star-index) - Deduplicated STAR genome indexing of personalized HLA allele references
- [HLApm STAR alignment](#hlapm-star-alignment) - STAR alignment of RNA reads against personalized per-sample-per-allele indexes
- [HLApm read quantification](#hlapm-read-quantification) - Queryname-sorted BAMs, cohort-wide combined GTF, per-read edit-distance/gene-assignment tables, and per-gene read-count summaries
- [GTF HLA gene-id uniqueness check](#gtf-hla-gene-id-uniqueness-check) - Fail-fast validation that `--gtf`'s HLA-region annotation has a one-to-one `gene_name` <-> `gene_id` mapping
- [Whole-genome common-reference gene counts](#whole-genome-common-reference-gene-counts) - Per-sample whole-genome featureCounts gene-count tables from each RNA sample's original BAM
- [HLA-region per-read featureCounts reconciliation input](#hla-region-per-read-featurecounts-reconciliation-input) - Per-read, per-sample gene assignment table from the HLA-region-restricted subset of each RNA sample's original BAM
- [HLA read-count reconciliation diff table](#hla-read-count-reconciliation-diff-table) - Per-sample, per-gene diff table reconciling the HLA-region featureCounts table against the personalized-HLA per-read quantification
- [Pipeline information](#pipeline-information) - Report metrics generated during the workflow execution

### arcasHLA read extraction and validation

<details markdown="1">
<summary>Output files</summary>

- `arcashla/extracted/`
  - `<rna_id>.mhc_1.fq.gz`: supplied read-1 FASTQ combined with complete BAM read pairs overlapping `--hla_region`.
  - `<rna_id>.mhc_2.fq.gz`: supplied read-2 FASTQ combined with complete BAM read pairs overlapping `--hla_region`.
  - `<rna_id>.mhc.namesort.bam`: the HLA-region-restricted, primary-alignment-only (secondary/supplementary excluded), name-sorted BAM slice of that sample's original BAM that `<rna_id>.mhc_1/2.fq.gz` are themselves derived from (before FASTQ conversion and merging with the supplied `unpaired_r1`/`unpaired_r2` reads). Published as a side effect of this file already being produced internally; it is also consumed directly by [HLA-region per-read featureCounts reconciliation input](#hla-region-per-read-featurecounts-reconciliation-input), below.
- `arcashla/validation/`
  - `<rna_id>.validatefastq.log`: pairing-validation report for the extracted FASTQ files.

</details>

The extracted files are concatenated gzip streams and are accepted by standard gzip-aware FASTQ readers. They are forwarded only after `validatefastq` confirms the mates have consistent names, order, and record structure. A validator command failure or reported `ERROR` stops the pipeline.

### arcasHLA genotyping

<details markdown="1">
<summary>Output files</summary>

- `arcashla/genotype/`
  - `<rna_id>.genotype.json`: arcasHLA genotype calls for the sample.
  - `<rna_id>.genotype.log`: arcasHLA genotype run log for the sample.
- `arcashla/`
  - `arcasHLA_combined.csv`: Combined arcasHLA genotype calls across all RNA samples, in long format with one row per HLA gene per sample and columns `HLA_gene,allele1_rna,allele2_rna,rna_sample_id`, covering a fixed list of 21 `HLA-*` genes (genes not reported for a sample are padded with `NA` alleles).

</details>

`arcasHLA genotype` runs on each sample's validated, extracted read pair, requesting the genes listed in `--arcashla_genes`. This step provisions arcasHLA itself via its own `environment.yml`/`conda` and `container` directives (see [usage docs](usage.md#arcashla-genotyping-environment) for details); its reference (IMGT/HLA + kallisto index) is a required, separately-prepared input (`--arcashla_reference_dir`, built with `scripts/build_arcashla_reference.sh`), staged as a process input so container engines bind-mount it automatically - the same pattern as `--hlala_graph_dir` for HLA-LA below.

### HLA-LA

<details markdown="1">
<summary>Output files</summary>

- `hlala/`
  - `HLA-LA_combined.tsv`: Combined HLA-LA G-group allele calls across all WGS samples, tab-separated with columns `sample_id`, `Locus`, `HLA_allele` (one allele per row, extracted from columns 1 and 3 of each sample's `R1_bestguess_G.txt`).
  - `<sample_id>/`: HLA-LA's complete per-sample output directory, published in full (see the note on hard links below):
    - `hla/`: the typing results, including `R1_bestguess_G.txt` (the G-group best guess file the combined TSV is built from), `R1_bestguess.txt`, and HLA-LA's full supporting output (`R1_pileup_*.txt`, `R1_PP_*_pairs.txt`, `R1_readIDs_*.txt`, `R1_columnIncompatibilities_*.txt`, `R1_parameters.txt`, `histogram_matchesPerRead.txt`, `summaryStatistics.txt`).
    - `reads_per_level.txt`: read counts per graph level.
    - `extraction.bam`, `extraction.bam.bai`, `extraction_mapped.bam`, `extraction_unmapped.bam`, `remapped_with_a.bam`, `remapped_with_a.bam.bai`, `R_1.fastq`, `R_2.fastq`, `R_U.fastq`: HLA-LA's own intermediates. These are large (multiple gigabytes per sample on real WGS BAMs) and are reproducible from the input BAM, so they are not usually of interest - they appear here only because publishing this directory is all-or-nothing, as explained below.

</details>

HLA-LA runs only when `--wgs_samples` is provided.
The combined CSV preserves the WGS sample identifiers from the `WGS_sample_id` column and extracts allele calls from column 3 of each `R1_bestguess_G.txt` after the header.

**The per-sample `hlala/<sample_id>/` directory is published as hard links, not copies, and this imposes a hard requirement: `--outdir` and the Nextflow work directory must be on the same filesystem.** If they are not, the run aborts with `Failed to publish file: ... [link]` - Nextflow does not fall back to copying. See [usage docs](usage.md#requirement---outdir-and-the-nextflow-work-directory-must-share-a-filesystem) for the reasoning, the HPC caveat, and the custom-config workaround.

The short version: the `HLALA_TYPING` module declares each per-sample output directory as an output _and_ individual files nested inside it, and Nextflow (verified on 26.04.4) then offers only the enclosing directory to `publishDir`, never the nested paths - so publishing from this process is all-or-nothing, with no way to keep just the typing results without patching the module. Publishing everything by copy would duplicate the multi-gigabyte intermediates for every WGS sample, so `mode: 'link'` is used instead: hard links cost no additional disk space, and (unlike symlinks) the published files remain valid real files after the work directory is deleted. See the `HLALA_TYPING` entry in `conf/modules.config`.

Two files published by earlier versions of this pipeline are gone: `<sample_id>/hla.tar.gz` (the `hla/` directory is published unarchived instead) and `<sample_id>/hlala.log` (HLA-LA's stdout is no longer redirected to a file; it is captured in the task's `.command.out` under the work directory).

### HIBAG (SNP-array HLA imputation)

<details markdown="1">
<summary>Output files</summary>

- `hibag/`
  - `HIBAG_combined.tsv`: Combined HIBAG allele calls across all SNP-array datasets, tab-separated with columns `sample_id`, `Locus`, `HLA_allele` (one allele per row). **This is the same format `hlala/HLA-LA_combined.tsv` uses**, so the consensus step consumes either interchangeably.
  - `<array_sample_id>.hibag_calls.tsv`: The same three columns for one PLINK dataset, before combining.
  - `<array_sample_id>.hibag_posterior.tsv`: Per-call diagnostics - `sample_id`, `locus`, `allele1`, `allele2`, `prob` (posterior probability), `matching`, `n_model_snps`, `n_matched_snps`. Not consumed by the pipeline; use it to judge call confidence and how much of the model matched your array. A low `n_matched_snps / n_model_snps` ratio is the strongest signal that a call should not be trusted, which is why `--hibag_min_matched_snps` fails the run below a threshold rather than letting it through.

</details>

HIBAG runs only when `--array_samples` is provided, and is mutually exclusive with HLA-LA. It replaces HLA-LA as the genotype-side caller, imputing HLA alleles from SNP-array genotypes rather than typing them from WGS alignments.

Note that `sample_id` comes from the **`.fam` IID column** of each PLINK dataset, not from the samplesheet's `array_sample_id`. See [usage docs](usage.md#warning-a-row-is-one-plink-dataset-not-one-sample).

Allele resolution differs between the two callers - HLA-LA reports G-groups (`A*01:01:01G`), HIBAG reports two fields (`A*01:01`) - but `--hla_consensus_truncate_fields` (default `2`) collapses both to the same resolution before consensus calling, so the two paths are directly comparable downstream.

### HLA consensus

<details markdown="1">
<summary>Output files</summary>

- `hla_consensus/`
  - `hla_consensus.rna_wgs_rna-hla_with_consensus.tsv`: one row per (RNA sample, HLA gene), with columns `WGS_sample_ID`, `RNA_sample_ID`, `HLA_gene`, `consensus_alleles`, `consensus_level`, `consensus_labels`, `RNA_alleles`, `WGS_alleles`. `WGS_sample_ID` is the matched WGS sample ID from `--sample_key`, or a synthetic `RNA_ONLY:<RNA_sample_ID>` group when the RNA sample is absent from the key. Rows with an empty consensus call are dropped.
  - `hla_consensus.rna_wgs_hla_consensus.tsv`: one row per (WGS group, HLA gene), with columns `WGS_sample_ID`, `HLA_gene`, `consensus_level`, `consensus_labels`, `consensus_alleles`. This is the deduplicated consensus call per WGS group/gene (RNA replicates collapsed).

</details>

`HLA_CONSENSUS` always runs (`--rna_samples` and `--sample_key` are both required top-level parameters, and there is no dedicated boolean flag), regardless of whether `--wgs_samples` is also provided. It combines the `arcashla/arcasHLA_combined.csv` RNA genotype calls with the `hlala/HLA-LA_combined.tsv` WGS genotype calls (or a header-only placeholder when `--wgs_samples` is not provided) via the RNA/WGS mapping supplied with `--sample_key`, and applies a decision tree (`consensus_level` 1-4, `consensus_labels`) to call a consensus HLA allele set per WGS group and gene, preferring WGS calls when RNA and WGS agree or partially agree, and falling back to RNA-only consensus (`RNA_ONLY:<rna_id>` groups) when no matched WGS sample, no WGS genotype, or no WGS data at all exists. `--hla_consensus_truncate_fields` controls the HLA resolution used for comparison (default 2 fields, e.g. `02:07`). `--rna_excluded_samples`/`--wgs_excluded_samples` optionally drop specific samples from consensus calling.

### HLA personalized reference (HLApm)

<details markdown="1">
<summary>Output files</summary>

- `hlapm/input/`
  - `<WGS_sample_ID>.tsv`: per-individual, 2-column HLApm input (`individual_ID`, `HLA_allele`), derived from `hla_consensus.rna_wgs_hla_consensus.tsv`. Loci outside `--hlapm_allowed_loci` simply do not appear in this file; no separate audit file is produced.
- `hlapm/personalized_ref/out/`
  - `<individual_ID>/<allele>.fa`, `<individual_ID>/<allele>.gtf`: HLApm's native personalized-reference output layout (one FASTA and one GTF per allele per individual), published as-is.

</details>

`HLAPM` runs whenever `HLA_CONSENSUS` runs, which is always; there is no separate flag to enable it, and it runs regardless of whether `--wgs_samples` is also provided. Under a container profile HLApm comes from the module's own image; without one (`-profile conda`, or no profile) `--hlapm_repo` is mandatory and the pipeline fails fast at launch if it is missing or does not exist. It first converts the `hla_consensus.rna_wgs_hla_consensus.tsv` consensus calls into one per-individual HLA allele-list TSV per WGS group (including synthetic `RNA_ONLY:<rna_id>` groups), filtered by the `--hlapm_allowed_loci` allow-list, then builds a personalized FASTA+GTF reference per allele, per individual, using [HLApm](https://github.com/davenportlab/HLApm)'s `bulkRNA_build_personalized_HLA_ref()` function (see [usage docs](usage.md#hlapm-container) for how HLApm and its R dependencies are provisioned). This iteration stops at reference building; HLApm's downstream STAR-index/mapping/allele-assignment stages and single-cell mode are out of scope.

### HLApm STAR index

<details markdown="1">
<summary>Output files</summary>

- `hlapm/star_index_targets/`
  - `unique_alleles.csv`: one row per distinct allele reference (`allele_key`, `representative_name`, `fasta`, `gtf`), discovered by scanning the actual `hlapm/personalized_ref/out/<individual_ID>/*.fa`/`*.gtf` files on disk (not any consensus/HLApm-input TSV) and deduplicated by a content hash (sha256) of each allele's FASTA+GTF. `allele_key` is `<representative_name>__<8-character hash prefix>`.
  - `sample_alleles.csv`: one row per original `(individual_ID, allele)` occurrence (`sample`, `allele`, `allele_key`), mapping every individual's allele back to the shared `allele_key` it was indexed under. Use this file to find which `hlapm/star_index/<allele_key>/` directory applies to a given individual/allele - there is no per-individual STAR index directory.
- `hlapm/star_index/`
  - `<allele_key>/star/`: STAR genome index (`Genome`, `SA`, `SAindex`, etc.) for one distinct allele reference, built with `STAR --runMode genomeGenerate --sjdbOverhang 100`. Shared across every individual whose allele has that exact FASTA+GTF content, so a recurring allele (e.g. a common population allele) is indexed only once regardless of how many individuals carry it.

</details>

STAR indexing runs immediately after `HLAPM` builds the personalized references, deduplicating allele references by content (not by name) before indexing: HLApm's personalized-reference building does not explicitly guarantee that the same named allele call (e.g. `A*01:136`) is always byte-identical across individuals, so trusting name equality alone would risk silently indexing two different sequences as one. Indexing itself reuses the [nf-core/modules `STAR_GENOMEGENERATE`](https://github.com/nf-core/modules/tree/master/modules/nf-core/star/genomegenerate) module unmodified, pinned to STAR 2.7.11b (the version used by [nf-core/rnaseq](https://nf-co.re/rnaseq/) to build this pipeline's RNA-seq test data). Like every other step, STAR comes from the module's own declaration: run the pipeline with `-profile singularity` (or `docker`/`conda`) so Nextflow can resolve STAR from the module's pinned container or `environment.yml` (see [usage docs](usage.md) for details). Aligning reads against these indexes is the next step, described immediately below.

### HLApm STAR alignment

<details markdown="1">
<summary>Output files</summary>

- `hlapm/star_align/`
  - `rna_sample_alleles.csv`: one row per resolved `(rna_id, sample, allele, allele_key)` alignment target (`rna_id,sample,allele,allele_key`) - `sample` keeps the original `HLA_CONSENSUS` grouping id (WGS individual ID, or `RNA_ONLY:<rna_id>`) alongside the real RNA sample id it was resolved to via `--sample_key`, for traceability. This is the human-facing summary of exactly which personalized alleles are (or were) aligned for each RNA sample.
  - `<rna_id>/<allele_key>/`: STAR alignment output for one `(RNA sample, allele)` pair, produced with `STAR --outSAMtype BAM SortedByCoordinate`:
    - `<rna_id>.<allele_key>.sortedByCoord.out.bam`: coordinate-sorted alignment of that RNA sample's arcasHLA MHC-extracted reads against that single allele's STAR index.
    - `<rna_id>.<allele_key>.Log.final.out`, `.Log.out`, `.Log.progress.out`: STAR's standard log outputs.

</details>

For every RNA sample that has one or more personalized HLA allele references, the pipeline aligns that sample's arcasHLA MHC-extracted reads (`ARCASHLA`'s `.mhc_1.fq.gz`/`.mhc_2.fq.gz`, not the full/raw RNA fastqs) against every one of its allele-specific STAR indexes: one alignment job per `(RNA sample, allele)` pair, so a sample with N personalized alleles produces N separate alignments that each reuse the same read pair against a different single-allele index.

`hlapm/star_index_targets/sample_alleles.csv`'s `sample` column is keyed by `HLA_CONSENSUS`'s grouping id (the WGS individual ID for WGS-backed individuals, or a synthetic `RNA_ONLY:<rna_id>` token otherwise), not directly by RNA sample id. Before alignment, this is resolved back to real RNA sample ids using `--sample_key`: `RNA_ONLY:<rna_id>` rows resolve by prefix-stripping alone, while WGS-individual rows broadcast-join against every RNA sample `--sample_key` matches to that individual - a WGS individual matched to more than one RNA sample has its full allele set aligned separately against each of those RNA samples' own reads, rather than collapsed to one. The resolved mapping is published as `rna_sample_alleles.csv` above.

This step reuses the [nf-core/modules `STAR_ALIGN`](https://github.com/nf-core/modules/tree/master/modules/nf-core/star/align) module unmodified, pinned to the same STAR 2.7.11b version used for indexing, and continues the same container/Conda exception described above. This iteration stops at producing per-sample-per-allele BAMs; reconciling alignments across candidate alleles into a single per-locus call remains out of scope. Read quantification from these BAMs, including gene-level read counts, is described immediately below (see [HLApm read quantification](#hlapm-read-quantification)).

### HLApm read quantification

<details markdown="1">
<summary>Output files</summary>

- `hlapm/star_align/<rna_id>/<allele_key>/`
  - `<rna_id>.<allele_key>.queryname.bam`: the same alignment as `<rna_id>.<allele_key>.sortedByCoord.out.bam` above, additionally sorted by read name (`samtools sort -n`) rather than coordinate. The coordinate-sorted BAM is unaffected and continues to be published as before.
- `hlapm/quantify/`
  - `combined.gtf`: every distinct allele's GTF (from `hlapm/star_index/<allele_key>/`) concatenated into one cohort-wide file, with comment lines stripped. Built once per pipeline run, not once per RNA sample.
  - `<rna_id>/<rna_id>.edit_distance.tsv`: one row per read observed across that sample's full set of per-allele queryname-sorted BAMs, with columns `read_name`, `gene_name_confidence` (`unique`/`best`/`ambiguous`), `gene_name`, followed by one column per input BAM holding that read's summed-mates edit distance (NM) when it belongs to the winning gene, else `NA`.
  - `<rna_id>/<rna_id>.stat.txt`: run-statistics log (redirected stderr) for that sample's quantification run.
  - `<rna_id>/<rna_id>.HLA_gene_summary.tsv`: per-gene read count derived from `<rna_id>.edit_distance.tsv`, with columns `gene_name` and `n_reads_mapping` (the number of non-`ambiguous` reads assigned to that gene with a winning-gene edit distance at or below `--hlapm_quantify_max_edit_distance`).

</details>

For every RNA sample, the pipeline queryname-sorts each of that sample's per-allele coordinate-sorted BAMs (`STAR_ALIGN`'s output, above) using the [nf-core/modules `SAMTOOLS_SORT`](https://github.com/nf-core/modules/tree/master/modules/nf-core/samtools/sort) module (`samtools sort -n`), then runs the legacy, unmodified Python 2.7 `make_a_table_210804_allHLAgenes.py` script once per RNA sample, over that sample's full set of queryname-sorted per-allele BAMs plus the cohort-wide `combined.gtf`. The script assigns each read to a gene by minimum summed-mate edit distance across every candidate allele/gene it overlaps, producing the per-read `edit_distance.tsv` table above. It runs from the module's own frozen Python 2.7 container (see [usage docs](usage.md#hlapm-read-quantification-container) for details).

A new `HLAPM_SUMMARIZE_READCOUNTS` step then turns that per-read table into the per-gene `<rna_id>.HLA_gene_summary.tsv` read-count summary described above, using a new `bin/summarize_hla_readcounts.R` script (adapted from `davenportlab/HLApm_farm_pipeline`'s summarization script), run from the [shared data-tools container](usage.md#shared-data-tools-container). Per-allele-level read counts, a cross-sample combined gene-count table, and comparison against `featureCounts` ground truth remain out of scope for this iteration.

### GTF HLA gene-id uniqueness check

<details markdown="1">
<summary>Output files</summary>

- `gtf_hla_gene_id_check/`
  - `hla_region_gene_id_map.tsv`: one run-level provenance table (a few hundred rows for a real whole-genome GTF), listing every gene name this check considered in scope, sorted by `gene_name`. Columns:
    - `gene_name`: the in-scope gene name.
    - `gene_ids`: every distinct `gene_id` carrying that `gene_name` anywhere in `--gtf` (not just inside `--hla_region`), semicolon-joined in first-appearance-in-file order.
    - `n_gene_ids`: the number of ids in the previous column - `1` on a GTF the pipeline accepts.
    - `in_region`: `yes` when at least one of that name's `gene` rows overlaps `--hla_region`.
    - `hla_prefixed`: `yes` when the name starts with `HLA-` (a name can be in scope by either or both criteria).
    - `status`: `unique`, `duplicated_gene_name` (more than one `gene_id` for this name) or `duplicated_gene_id` (this name's `gene_id` is shared with another in-scope name). Anything other than `unique` fails the run, so a published table contains only `unique` rows.

</details>

Produced on **every** run, before any counting or reconciliation output exists: `GTF_HLA_GENE_ID_CHECK` (`bin/check_gtf_hla_gene_ids.py`) streams `--gtf` once, `feature_type == "gene"` rows only, and rejects a GTF whose HLA-region annotation does not carry a one-to-one `gene_name` <-> `gene_id` mapping. Scope is the union of "genes overlapping `--hla_region`" and "gene names starting with `HLA-`". **Note that a failed run publishes nothing here** - a rejected GTF's offender list appears only in the Nextflow error report/`.command.err`, which is why that message is uncapped. Stock GENCODE v50 is rejected; see [usage docs](usage.md#gtf-hla-gene-id-uniqueness-check) for the full scope definition, the failure message and how to fix a GTF.

### Whole-genome common-reference gene counts

<details markdown="1">
<summary>Output files</summary>

- `counts_commonref/<rna_id>/`
  - `<rna_id>.featureCounts.tsv`: featureCounts gene-count table for that RNA sample, produced by running featureCounts (`--countReadPairs -g gene_id`) directly against that sample's original, full whole-genome, coordinate-sorted BAM (`--rna_samples`'s `bam` column) and the whole-genome reference GTF supplied with `--gtf`.
  - `<rna_id>.featureCounts.tsv.summary`: featureCounts' own per-sample assignment summary log.

</details>

For every RNA sample, independent of `--sample_key`/HLApm, the pipeline runs the [nf-core/modules `SUBREAD_FEATURECOUNTS`](https://github.com/nf-core/modules/tree/master/modules/nf-core/subread/featurecounts) module unmodified, pinned to Subread 2.1.1, once per sample against that sample's own original BAM plus the single, cohort-wide `--gtf` reference. `--rnaseq_strandedness` (default `reverse`, pipeline-wide rather than per-sample) is merged into each sample's metadata immediately beforehand. This whole-genome table itself is **not yet patched** with `HLAPM_STAR_QUANTIFY`'s HLA-specific gene counts - that final splice ("hijack original count matrix") remains a future iteration; the per-gene reconciliation diff feeding it is now produced, see [HLA read-count reconciliation diff table](#hla-read-count-reconciliation-diff-table) below. See [usage docs](usage.md#whole-genome-common-reference-gene-counts) for the container/`-profile conda` dependency this step introduces.

### HLA-region per-read featureCounts reconciliation input

<details markdown="1">
<summary>Output files</summary>

- `counts_commonref_hla/<rna_id>/`
  - `<rna_id>.rnaseq_featurecounts.tsv`: one row per HLA-region read assigned to a gene, with columns `read_name`, `direction` (`R1`/`R2`/`NA`), `gene_name`, `edit_distance`. This is an **intermediate artifact** for the reconciliation step below ("hijack original count matrix"), not a final HLA gene-count table.
  - `<rna_id>.featureCounts.tsv.summary`: featureCounts' own per-sample assignment summary log for this step's `-R BAM` run.

</details>

For every RNA sample, independent of `--sample_key`/HLApm, the pipeline runs `SUBREAD_FEATURECOUNTS` a second time (aliased as `SUBREAD_FEATURECOUNTS_HLA`) with `-R BAM`, directly against `arcashla/extracted/<rna_id>.mhc.namesort.bam` above (the HLA-region-restricted subset of that sample's original BAM, reused from `ARCASHLA_EXTRACT` rather than re-extracted) plus the same cohort-wide `--gtf` reference used above - no separate HLA-only GTF is built. The reannotated per-read BAM this produces is converted to plain text with `samtools view`, filtered to `Assigned`-status lines, and reformatted by a new `bin/reformat_rnaseq_featurecounts.py` script into the per-read TSV documented above. Reconciling this table against `HLAPM_STAR_QUANTIFY`'s HLA-specific `edit_distance.tsv` (above) is described immediately below; the final splice into `counts_commonref`'s whole-genome table remains out of scope for this iteration - see [usage docs](usage.md#hla-region-per-read-featurecounts-reconciliation-input).

### HLA read-count reconciliation diff table

<details markdown="1">
<summary>Output files</summary>

- `hla_readcount_reconcile/<rna_id>/`
  - `<rna_id>.hla_readcount_reconcile.tsv`: one row per gene involved in the reconciliation, with columns `gene_id`, `gene_name`, `category` (`hla`/`non_hla`), `original_fc_count`, `personalized_count`, `diff`. Produced only for RNA samples that have **both** a `counts_commonref_hla` read-gene-assignment table (above) and a personalized-HLA `edit_distance.tsv` (i.e. only samples resolved through `--sample_key`/HLApm to at least one personalized allele) - for every other RNA sample, no file is produced.
    - Every HLA gene present in the personalized-HLA results (after the existing `ambiguous`/edit-distance filtering) gets exactly one `category: hla` row, including genes whose every read pair was ultimately dropped (`personalized_count` of `0`, not an absent row). `original_fc_count` is that gene's valid-read-pair count in the local, HLA-region-restricted `counts_commonref_hla` table; `personalized_count` is the reconciled personalized-reference read-pair count (kept via `missing_fc`, `both_hla`, or reassigned from a worse non-HLA `counts_commonref_hla` assignment); `diff` is `personalized_count - original_fc_count`.
    - A `category: non_hla` row is emitted **only** for a non-HLA gene that lost at least one read pair to an HLA gene in this reconciliation (`diff` != 0) - an untouched non-HLA gene never gets a row. `personalized_count` is the literal string `NA` for these rows (there is no personalized-reference quantification for a non-HLA gene); `diff` is the negative count of read pairs reassigned away from it.
    - `gene_id` is resolved from `gene_name` via the whole-genome `--gtf`, using a soft, category-aware policy that never fails the run - see [usage docs](usage.md#hla-read-count-reconciliation-diff-table) for the full rationale. A `gene_name` absent from `--gtf` resolves to the literal string `NA`. A `gene_name` that ambiguously maps to more than one distinct `gene_id` in `--gtf` resolves to the first-appearing `gene_id` for a `category: hla` row, or to **every** candidate `gene_id`, semicolon-joined in first-appearance order (e.g. `ENSG00000236397.3;ENSG00000308415.1`), for a `category: non_hla` row.
    - `original_fc_count`/`personalized_count`/`diff` are never split out per individual `gene_id` when a `gene_name` is ambiguous - this table reconciles at `gene_name` granularity throughout, because the upstream `counts_commonref_hla` per-read table (above) never carries `gene_id` at all, and because featureCounts can assign a read pair's R1/R2 mates to two _different_ specific `gene_id`s that share one `gene_name` (e.g. `POLR1HASP`) - see [usage docs](usage.md#hla-read-count-reconciliation-diff-table) for the full rationale.
  - `<rna_id>.gene_id_resolution_warnings.tsv`: always produced alongside the diff table above (header-only when there is nothing to report), recording every `gene_name` in that sample's diff table whose `gene_id` did not come from a normal, unambiguous `--gtf` lookup. One row per such `gene_name`, with columns:
    - `gene_name`: the gene name being resolved.
    - `category`: `hla`/`non_hla`, matching the diff table's own `category` column.
    - `reason`: `ambiguous_gene_id` (more than one distinct `gene_id` found for this name in `--gtf`) or `missing_gene_name` (name absent from `--gtf` entirely). `ambiguous_gene_id` is now effectively unreachable for HLA-region genes: the [GTF HLA gene-id uniqueness check](#gtf-hla-gene-id-uniqueness-check) rejects such a `--gtf` before this step runs, over exactly the set of names this table can report. It remains in the schema as defence in depth for a name outside that check's scope; `missing_gene_name` is unaffected and still a soft fail.
    - `gene_ids`: every candidate `gene_id` found for this name in `--gtf`, semicolon-joined in first-appearance order; empty when `reason` is `missing_gene_name`.
    - `resolution`: `first_id_used` (HLA-category ambiguity, resolved to the first-appearing id), `all_ids_joined` (non-HLA-category ambiguity, resolved to every candidate id joined), or `na_placeholder` (missing name, resolved to `NA`).
    - `resolved_gene_id`: the exact value written into that gene name's row's `gene_id` field in `<rna_id>.hla_readcount_reconcile.tsv`.

</details>

Whenever an RNA sample has both a `counts_commonref_hla` read-gene-assignment table and a personalized-HLA `edit_distance.tsv`, the pipeline reconciles the two: for every personalized-HLA read pair, it is kept as HLA if `counts_commonref_hla` has no matching read pair (`missing_fc`), if `counts_commonref_hla` also assigned it to an HLA gene (`both_hla`), or if `counts_commonref_hla` assigned it to a non-HLA gene but the personalized-reference edit distance is equal to or better than that assignment's (reassigned to HLA); otherwise it is dropped in favor of the better non-HLA `counts_commonref_hla` assignment. This adapts the read-pair reconciliation logic of a prototype script (`artifacts/scripts/compare-hla-rnaseq-readcounts.py`) via a new `bin/reconcile_hla_readcounts.py` script and a new `HLA_READCOUNT_RECONCILE` subworkflow/`HLA_READCOUNT_RECONCILE_DIFF` module, reusing the same `--hlapm_quantify_max_edit_distance` threshold (default `16`) already used by `HLAPM_SUMMARIZE_READCOUNTS` above. This is iteration 3 of the "hijack original count matrix" roadmap item: it produces only the per-sample diff table; merging/patching `counts_commonref`'s whole-genome table using this diff table remains a future iteration - see [usage docs](usage.md#hla-read-count-reconciliation-diff-table).

### Pipeline information

<details markdown="1">
<summary>Output files</summary>

- `pipeline_info/`
  - Reports generated by Nextflow: `execution_report.html`, `execution_timeline.html`, `execution_trace.txt` and `pipeline_dag.dot`/`pipeline_dag.svg`.
  - Reports generated by the pipeline: `pipeline_report.html`, `pipeline_report.txt` and `software_versions.yml`. The `pipeline_report*` files will only be present if the `--email` / `--email_on_fail` parameter's are used when running the pipeline.
  - Reformatted samplesheet files used as input to the pipeline: `samplesheet.valid.csv`.
  - Parameters used by the pipeline run: `params.json`.

</details>

[Nextflow](https://www.nextflow.io/docs/latest/tracing.html) provides excellent functionality for generating various reports relevant to the running and execution of the pipeline. This will allow you to troubleshoot errors with the running of the pipeline, and also provide you with other information such as launch commands, run times and resource usage.

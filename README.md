<h1>
  HLARNASeq
</h1>

<!-- Commented due to the early stage of development
[![run with conda](http://img.shields.io/badge/run%20with-conda-3EB049?labelColor=000000&logo=anaconda)](https://docs.conda.io/en/latest/)
[![run with docker](https://img.shields.io/badge/run%20with-docker-0db7ed?labelColor=000000&logo=docker)](https://www.docker.com/)
[![run with singularity](https://img.shields.io/badge/run%20with-singularity-1d355c.svg?labelColor=000000)](https://sylabs.io/docs/)
-->

## Introduction

**HLARNASeq** is a bioinformatics pipeline that
precisely qualifies human HLA genes expression from RNASeq data
by using personalized reference genomes.

The pipeline can use results of [NF-Core RNASeq](https://nf-co.re/rnaseq/latest) pipeline as input.

### Pipeline scheme

<!-- TODO nf-core: Include a figure that guides the user through the major workflow steps. Many nf-core
     workflows use the "tube map" design for that. See https://nf-co.re/docs/guidelines/graphic_design/workflow_diagrams#examples for examples.   -->

- Check up front that `--gtf`'s HLA-region annotation has a one-to-one `gene_name` <-> `gene_id` mapping, and stop immediately if it does not (stock GENCODE is rejected - see [usage docs](docs/usage.md#gtf-hla-gene-id-uniqueness-check))
- Extract MHC region and unmapped reads from RNASeq data
- Validate the extracted paired FASTQ files before arcasHLA analysis
- Call HLA reference alleles from RNASeq data with arcasHLA
- (Optional) Call HLA reference alleles from WGS/WES data with HLA-LA, **or** impute them from SNP-array data with HIBAG (the two are mutually exclusive)
- Call HLA allele consensus on RNASeq and WGS/WES data
- Map RNASeq data to personalized references
- Extract HLA genes counts
- Hijack original count matrix

## Usage

> [!NOTE]
> If you are new to Nextflow and nf-core, please refer to [this page](https://nf-co.re/docs/usage/installation) on how to set-up Nextflow. Make sure to [test your setup](https://nf-co.re/docs/usage/introduction#how-to-run-a-pipeline) with `-profile test -stub-run` before running the workflow on actual data. At this early development stage, `-profile test`'s bundled fixture is deliberately tiny and does not carry real HLA allele signal, so it is only validated in `-stub-run` mode (a process/channel wiring smoke test); a real, non-stub `-profile test` run is not expected to succeed yet.

Provide an RNA samplesheet with the exact columns `rna_id,bam,bai,unpaired_r1,unpaired_r2`. The requested HLA region is passed to samtools unchanged, so its chromosome notation must match the BAM headers.

RNA-seq HLA quantification is what the pipeline does, so `--rna_samples`, `--sample_key`, `--hla_region`, `--gtf` and `--arcashla_reference_dir` are all required; a run that omits any of them stops immediately at parameter validation. A `--sample_key` with a header only is valid and routes every RNA sample through the `RNA_ONLY:<rna_id>` consensus fallback.

```bash
nextflow run wtsi-hgi/hlarnaseq \
   -profile singularity \
   --rna_samples rna_samples.csv \
   --sample_key rna_wgs_key.csv \
   --hla_region chr6:28500000-33400000 \
   --gtf /path/to/annotation.gtf \
   --arcashla_reference_dir /path/to/arcashla_reference \
   --outdir <OUTDIR>
```

> [!IMPORTANT]
> A profile is required. Every tool this pipeline runs is declared by the process that runs it — an `environment.yml` feeding a `conda` directive, paired with a matching pinned `container` — so nothing is taken from the environment you launch Nextflow in. Use `-profile singularity`, `docker`, `apptainer` or `conda`; with none of them, every step fails fast saying so.
>
> Most images are public and pulled for you, but **four are currently built locally** and need `scripts/build_image_{arcashla,hlapm,hlapm_quantify,datatools}.sh` run once before your first containerized run. See [Dependencies and profiles](docs/usage.md#dependencies-and-profiles).

> [!WARNING]
> Please provide pipeline parameters via the CLI or Nextflow `-params-file` option.
> Custom config files including those provided by the `-c` Nextflow option
> can be used to provide any configuration _**except for parameters**_;
> see [docs](https://nf-co.re/docs/usage/getting_started/configuration#custom-configuration-files).

The genotype-side HLA calls are optional and come from one of two sources. Use `--wgs_samples` to type them from WGS with HLA-LA, or `--array_samples` together with `--hibag_model` to impute them from SNP-array (PLINK) data with HIBAG:

```bash
nextflow run wtsi-hgi/hlarnaseq \
   -profile singularity \
   --rna_samples rna_samples.csv \
   --sample_key rna_wgs_key.csv \
   --hla_region chr6:28500000-33400000 \
   --gtf /path/to/annotation.gtf \
   --arcashla_reference_dir /path/to/arcashla_reference \
   --array_samples array_samples.csv \
   --hibag_model /path/to/HIBAG_model.RData \
   --outdir <OUTDIR>
```

Both produce the same combined allele table, so the consensus step and everything after it are unchanged either way. See the [usage documentation](docs/usage.md#snp-array-samplesheet-input-hibag) for the SNP-array samplesheet layout and the HIBAG model requirements.

For more details and further functionality, please refer to the [usage documentation](https://nf-co.re/hlarnaseq/usage)
and the [parameter documentation](https://nf-co.re/hlarnaseq/parameters).

## Pipeline output

To see the results of an example test run with a full size dataset refer to the [results](https://nf-co.re/hlarnaseq/results) tab on the nf-core website pipeline page.
For more details about the output files and reports, please refer to the
[output documentation](https://nf-co.re/hlarnaseq/output).

## Credits

nf-core/hlarnaseq pipeline was written by Gennadii Zakharov,
following the approach developed by
[Davenport Group](https://www.sanger.ac.uk/group/davenport-group/),
[Wellcome Sanger Institute](https://www.sanger.ac.uk).

<!--
We thank the following people for their extensive assistance in the development of this pipeline:

 TODO nf-core: If applicable, make list of people who have also contributed -->

## Contributions and Support

If you would like to contribute to this pipeline, please see the [contributing guidelines](.github/CONTRIBUTING.md).

<!--
For further information or help, don't hesitate to get in touch on the [Slack `#hlarnaseq` channel](https://nfcore.slack.com/channels/hlarnaseq)
(you can join with [this invite](https://nf-co.re/join/slack)).
-->

## Citations

<!-- TODO nf-core: Add citation for pipeline after first release. Uncomment lines below and update Zenodo doi and badge at the top of this file. -->
<!-- If you use nf-core/hlarnaseq for your analysis, please cite it using the following doi: [10.5281/zenodo.XXXXXX](https://doi.org/10.5281/zenodo.XXXXXX) -->

<!-- TODO nf-core: Add bibliography of tools and data used in your pipeline -->

An extensive list of references for the tools used by the pipeline can be found in the [`CITATIONS.md`](CITATIONS.md) file.

This pipeline uses code and infrastructure developed and maintained by the [nf-core](https://nf-co.re) initative, and reused here under the [MIT license](https://github.com/nf-core/tools/blob/master/LICENSE).

> The nf-core framework for community-curated bioinformatics pipelines.
>
> Philip Ewels, Alexander Peltzer, Sven Fillinger, Harshil Patel, Johannes Alneberg, Andreas Wilm, Maxime Ulysse Garcia, Paolo Di Tommaso & Sven Nahnsen.
>
> Nat Biotechnol. 2020 Feb 13. doi: 10.1038/s41587-020-0439-x.

[![Nextflow](https://img.shields.io/badge/version-%E2%89%A525.04.0-green?style=flat&logo=nextflow&logoColor=white&color=%230DC09D&link=https%3A%2F%2Fnextflow.io)](https://www.nextflow.io/)
[![nf-core template version](https://img.shields.io/badge/nf--core_template-3.5.2-green?style=flat&logo=nfcore&logoColor=white&color=%2324B064&link=https%3A%2F%2Fnf-co.re)](https://github.com/nf-core/tools/releases/tag/3.5.2)

<!--
In addition, references of tools and data used in this pipeline are as follows:
-->

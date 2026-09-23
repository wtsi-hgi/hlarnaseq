/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { paramsSummaryMap       } from 'plugin/nf-schema'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_wtsihgi_hlarnaseq_pipeline'
include { HLALA                  } from '../subworkflows/local/hlala'
include { HIBAG                  } from '../subworkflows/local/hibag'
include { ARCASHLA                } from '../subworkflows/local/arcashla'
include { HLA_CONSENSUS          } from '../modules/local/hla_consensus'
include { HLAPM                  } from '../subworkflows/local/hlapm'
include { HLAPM_STAR_INDEX       } from '../subworkflows/local/hlapm_star_index'
include { HLAPM_STAR_ALIGN       } from '../subworkflows/local/hlapm_star_align'
include { HLAPM_STAR_QUANTIFY    } from '../subworkflows/local/hlapm_star_quantify'
include { COUNTS_COMMONREF       } from '../subworkflows/local/counts_commonref'
include { COUNTS_COMMONREF_HLA   } from '../subworkflows/local/counts_commonref_hla'
include { HLA_READCOUNT_RECONCILE } from '../subworkflows/local/hla_readcount_reconcile'
include { COMBINE_FINAL_COUNTS   } from '../subworkflows/local/combine_final_counts'
include { GTF_HLA_GENE_ID_CHECK  } from '../modules/local/gtf_hla_gene_id_check'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow HLARNASEQ {

    take:
    ch_rna_samplesheet   // channel: RNA samplesheet read in from --rna_samples
    ch_wgs_samplesheet   // channel: WGS samplesheet read in from --wgs_samples
    ch_array_samplesheet // channel: SNP-array samplesheet read in from --array_samples
    ch_sample_key        // channel: RNA/WGS sample key read in from --sample_key
    main:

    ch_versions = channel.empty()
    // Only genuinely optional channels need an empty placeholder here: HIBAG
    // runs only under --array_samples. Everything else below is unconditional,
    // because RNA analysis is what this pipeline is for - --rna_samples,
    // --sample_key, --gtf and --arcashla_reference_dir are all required
    // parameters (see nextflow_schema.json), so nf-schema rejects a run that
    // omits any of them before any of this code executes.
    ch_hibag_calls = channel.empty()
    ch_hibag_posterior = channel.empty()

    // Passed down as a value channel so ARCASHLA_GENOTYPE stages the
    // prepared reference directory as a real process input - which is what
    // makes Nextflow bind its real path into the container - and reuses it
    // for every sample instead of consuming it on the first one.
    ch_arcashla_reference = Channel.value(file(params.arcashla_reference_dir, checkIfExists: true))
    ARCASHLA(ch_rna_samplesheet, ch_arcashla_reference)
    ch_versions = ch_versions.mix(ARCASHLA.out.versions)
    ch_arcashla_reads = ARCASHLA.out.reads
    ch_arcashla_validation_logs = ARCASHLA.out.validation_logs
    ch_arcashla_genotypes = ARCASHLA.out.genotypes
    ch_arcashla_genotype_logs = ARCASHLA.out.genotype_logs
    ch_arcashla_combined_genotype = ARCASHLA.out.combined_genotype

    // Runs on the sample's original whole-genome BAM (--rna_samples'
    // bam/bai columns), independent of --sample_key/HLApm - iteration 1
    // of "hijack original count matrix" (see docs/output.md).
    // SUBREAD_FEATURECOUNTS reports its own version via the topic-based
    // versions channel (like STAR_ALIGN/STAR_GENOMEGENERATE/SAMTOOLS_SORT
    // elsewhere in this pipeline), collected automatically below -
    // COUNTS_COMMONREF has no other module and so emits no versions
    // channel of its own to mix in here.
    ch_gtf = Channel.value(file(params.gtf, checkIfExists: true))

    // Fail fast on a --gtf whose HLA-region annotation does not carry a
    // one-to-one gene_name <-> gene_id mapping, before any counting or
    // reconciliation result is produced. Called at the very front of the
    // workflow body so it is submitted in the first scheduling wave and
    // completes in seconds; conf/modules.config gives it
    // errorStrategy 'terminate' so a bad GTF aborts the run at once instead
    // of letting an hours-long ARCASHLA_GENOTYPE/STAR task finish first
    // (conf/base.config's default 'finish'). RNA analysis is unconditional -
    // --rna_samples and --gtf are both required parameters - so this check
    // runs on every launchable run and there is no configuration that skips
    // it. See docs/usage.md#gtf-hla-gene-id-uniqueness-check for why
    // ambiguity is rejected here rather than resolved softly downstream.
    GTF_HLA_GENE_ID_CHECK(ch_gtf)
    ch_versions = ch_versions.mix(GTF_HLA_GENE_ID_CHECK.out.versions)
    ch_gtf_hla_gene_id_report = GTF_HLA_GENE_ID_CHECK.out.report

    // Report-gated view of the same GTF, for the one consumer whose output
    // actually depends on gene_name -> gene_id resolution
    // (HLA_READCOUNT_RECONCILE, below): combining rather than re-emitting the
    // GTF from the check avoids staging a multi-GB file as a process output,
    // and .first() restores value-channel (broadcast) semantics so the
    // per-sample consumer can reuse it. COUNTS_COMMONREF and
    // COUNTS_COMMONREF_HLA keep the plain ch_gtf: both run featureCounts with
    // `-g gene_id` (conf/modules.config), so name ambiguity cannot affect
    // their output.
    ch_gtf_checked = ch_gtf
        .combine(ch_gtf_hla_gene_id_report)
        .map { gtf, _report -> gtf }
        .first()

    COUNTS_COMMONREF(ch_rna_samplesheet, ch_gtf)
    ch_counts_commonref_gene_counts = COUNTS_COMMONREF.out.gene_counts
    ch_counts_commonref_summary = COUNTS_COMMONREF.out.summary

    // Iteration 2 of "hijack original count matrix" (see docs/output.md):
    // per-read featureCounts reconciliation input, run once per RNA
    // sample against the HLA-region-restricted subset of that sample's
    // original/common-reference BAM. Unlike COUNTS_COMMONREF above
    // (deliberately independent of/parallel to ARCASHLA), this step
    // consumes ARCASHLA_EXTRACT's own intermediate HLA-region BAM
    // (ARCASHLA.out.hla_region_bam), so it must run after ARCASHLA - an
    // intentional, necessary ordering dependency introduced by reusing
    // that intermediate rather than re-extracting the HLA region again.
    COUNTS_COMMONREF_HLA(ARCASHLA.out.hla_region_bam, ch_gtf)
    ch_versions = ch_versions.mix(COUNTS_COMMONREF_HLA.out.versions)
    ch_counts_commonref_hla_read_gene_assignments = COUNTS_COMMONREF_HLA.out.read_gene_assignments

    // Genotype-side HLA calls in the `sample_id/Locus/HLA_allele` contract.
    // Filled by HLA-LA (from WGS) or by HIBAG (from SNP arrays) - the two are
    // mutually exclusive - or left as the header-only placeholder when
    // neither input is given. The name is historical: HLALA_COMBINE defined
    // this format, and HIBAG_COMBINE reproduces it exactly.
    if (params.wgs_samples) {
        HLALA(ch_wgs_samplesheet)
        ch_versions = ch_versions.mix(HLALA.out.versions)
        ch_hlala_combined = HLALA.out.combined_csv
    } else if (params.array_samples) {
        HIBAG(ch_array_samplesheet)
        ch_versions = ch_versions.mix(HIBAG.out.versions)
        ch_hlala_combined = HIBAG.out.combined_csv
        ch_hibag_calls = HIBAG.out.calls
        ch_hibag_posterior = HIBAG.out.posterior
    } else {
        ch_hlala_combined = Channel.fromPath("${projectDir}/assets/NO_WGS_HLALA_COMBINED.tsv")
    }

    ch_rna_excluded_samples = params.rna_excluded_samples
        ? Channel.fromPath(params.rna_excluded_samples)
        : Channel.fromPath("${projectDir}/assets/NO_FILE")
    ch_wgs_excluded_samples = params.wgs_excluded_samples
        ? Channel.fromPath(params.wgs_excluded_samples)
        : Channel.fromPath("${projectDir}/assets/NO_FILE")

    HLA_CONSENSUS(
        ch_arcashla_combined_genotype,
        ch_hlala_combined,
        ch_sample_key,
        ch_rna_excluded_samples,
        ch_wgs_excluded_samples
    )
    ch_versions = ch_versions.mix(HLA_CONSENSUS.out.versions)
    ch_hla_consensus_summary = HLA_CONSENSUS.out.summary
    ch_hla_consensus_key = HLA_CONSENSUS.out.consensus

    HLAPM(ch_hla_consensus_key)
    ch_versions = ch_versions.mix(HLAPM.out.versions)
    ch_hlapm_personalized_ref = HLAPM.out.personalized_ref

    HLAPM_STAR_INDEX(ch_hlapm_personalized_ref)
    ch_versions = ch_versions.mix(HLAPM_STAR_INDEX.out.versions)
    ch_hlapm_star_index = HLAPM_STAR_INDEX.out.index
    ch_hlapm_star_index_gtf = HLAPM_STAR_INDEX.out.gtf
    ch_hlapm_star_index_sample_alleles = HLAPM_STAR_INDEX.out.sample_alleles

    HLAPM_STAR_ALIGN(
        ch_hlapm_star_index_sample_alleles,
        ch_hlapm_star_index,
        ch_hlapm_star_index_gtf,
        ch_arcashla_reads,
        ch_sample_key
    )
    ch_versions = ch_versions.mix(HLAPM_STAR_ALIGN.out.versions)
    ch_hlapm_star_align_bam = HLAPM_STAR_ALIGN.out.bam_sorted
    ch_hlapm_star_align_log_final = HLAPM_STAR_ALIGN.out.log_final
    ch_hlapm_star_align_rna_sample_alleles = HLAPM_STAR_ALIGN.out.rna_sample_alleles

    HLAPM_STAR_QUANTIFY(ch_hlapm_star_align_bam, ch_hlapm_star_index_gtf)
    ch_versions = ch_versions.mix(HLAPM_STAR_QUANTIFY.out.versions)
    ch_hlapm_edit_distance = HLAPM_STAR_QUANTIFY.out.edit_distance
    ch_hlapm_gene_summary = HLAPM_STAR_QUANTIFY.out.gene_summary

    // Iteration 3 of "hijack original count matrix" (see docs/output.md):
    // reconciles iteration 2's local, HLA-region-restricted featureCounts
    // read-gene-assignment table (ch_counts_commonref_hla_read_gene_assignments,
    // produced by COUNTS_COMMONREF_HLA above) against this sample's own
    // personalized-HLA per-read quantification (ch_hlapm_edit_distance, just
    // produced above), emitting a per-sample diff table. Both required inputs
    // are available by this point in the workflow. Only RNA samples resolved
    // through --sample_key/HLApm to at least one personalized allele - i.e.
    // present in ch_hlapm_edit_distance - get a diff table (inner join on
    // rna_id, performed inside HLA_READCOUNT_RECONCILE itself).
    // ch_gtf_checked, not ch_gtf: this is the step whose gene_id resolution
    // the new GTF_HLA_GENE_ID_CHECK protects, so the dependency edge makes it
    // structurally impossible to produce a diff table from an unchecked GTF
    // (same file, same value-channel shape - only an added ordering edge).
    HLA_READCOUNT_RECONCILE(ch_counts_commonref_hla_read_gene_assignments, ch_hlapm_edit_distance, ch_gtf_checked)
    ch_versions = ch_versions.mix(HLA_READCOUNT_RECONCILE.out.versions)
    ch_hla_readcount_diff = HLA_READCOUNT_RECONCILE.out.read_count_diff
    ch_hla_readcount_diff_warnings = HLA_READCOUNT_RECONCILE.out.gene_id_resolution_warnings

    // Iteration 4 - the last - of "hijack original count matrix" (see
    // docs/output.md): patches COUNTS_COMMONREF's whole-genome featureCounts
    // table (ch_counts_commonref_gene_counts, produced above) with the
    // per-sample reconciliation diff table just produced
    // (ch_hla_readcount_diff), emitting the final two-column gene_id/count
    // table plus a change log. No --gtf input: the diff table already carries
    // a resolved, unambiguous gene_id for both categories and the
    // featureCounts table is keyed by gene_id (`-g gene_id`, see
    // conf/modules.config), so the patch is an exact gene_id join - see
    // bin/combine_final_counts.py's header for why re-deriving a
    // gene_name <-> gene_id mapping here is deliberately avoided. Only RNA
    // samples present in BOTH channels get a final table (inner join on
    // rna_id, performed inside COMBINE_FINAL_COUNTS itself); a sample not
    // resolved to any personalized allele gets no output rather than an
    // unpatched table published under a "final" name.
    COMBINE_FINAL_COUNTS(ch_counts_commonref_gene_counts, ch_hla_readcount_diff)
    ch_versions = ch_versions.mix(COMBINE_FINAL_COUNTS.out.versions)
    ch_combine_final_counts = COMBINE_FINAL_COUNTS.out.final_counts
    ch_combine_final_counts_change_log = COMBINE_FINAL_COUNTS.out.change_log

    //
    // Collate and save software versions
    //
    def topic_versions = Channel.topic("versions")
        .distinct()
        .branch { entry ->
            versions_file: entry instanceof Path
            versions_tuple: true
        }

    def topic_versions_string = topic_versions.versions_tuple
        .map { process, tool, version ->
            [ process[process.lastIndexOf(':')+1..-1], "  ${tool}: ${version}" ]
        }
        .groupTuple(by:0)
        .map { process, tool_versions ->
            tool_versions.unique().sort()
            "${process}:\n${tool_versions.join('\n')}"
        }

    softwareVersionsToYAML(ch_versions.mix(topic_versions.versions_file))
        .mix(topic_versions_string)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'wtsihgi_'  +  'hlarnaseq_software_'  + 'versions.yml',
            sort: true,
            newLine: true
        ).set { ch_collated_versions }


    emit:
    versions       = ch_versions                 // channel: [ path(versions.yml) ]
    hlala_combined = ch_hlala_combined           // channel: [ path(HLA-LA_combined.tsv | HIBAG_combined.tsv) ]
    hibag_calls    = ch_hibag_calls              // channel: [ val(meta), path(*.hibag_calls.tsv) ]
    hibag_posterior = ch_hibag_posterior         // channel: [ val(meta), path(*.hibag_posterior.tsv) ]
    arcashla_reads = ch_arcashla_reads           // channel: [ val(meta), [ path(read1), path(read2) ] ]
    arcashla_validation_logs = ch_arcashla_validation_logs // channel: [ val(meta), path(validatefastq.log) ]
    arcashla_genotypes = ch_arcashla_genotypes   // channel: [ val(meta), path(genotype.json) ]
    arcashla_genotype_logs = ch_arcashla_genotype_logs // channel: [ val(meta), path(genotype.log) ]
    arcashla_combined_genotype = ch_arcashla_combined_genotype // channel: [ path(arcasHLA_combined.csv) ]
    hla_consensus_summary = ch_hla_consensus_summary // channel: [ path(hla_consensus.rna_wgs_rna-hla_with_consensus.tsv) ]
    hla_consensus_key = ch_hla_consensus_key // channel: [ path(hla_consensus.rna_wgs_hla_consensus.tsv) ]
    hlapm_personalized_ref = ch_hlapm_personalized_ref // channel: [ path("out") ]
    hlapm_star_index = ch_hlapm_star_index // channel: [ val(meta), path("star") ], meta.id == allele_key
    hlapm_star_index_gtf = ch_hlapm_star_index_gtf // channel: [ val(meta), path(gtf) ], meta.id == allele_key
    hlapm_star_index_sample_alleles = ch_hlapm_star_index_sample_alleles // channel: [ path("sample_alleles.csv") ]
    hlapm_star_align_bam = ch_hlapm_star_align_bam // channel: [ val(meta), path("*.sortedByCoord.out.bam") ]
    hlapm_star_align_log_final = ch_hlapm_star_align_log_final // channel: [ val(meta), path("*.Log.final.out") ]
    hlapm_star_align_rna_sample_alleles = ch_hlapm_star_align_rna_sample_alleles // channel: [ path("rna_sample_alleles.csv") ]
    hlapm_edit_distance = ch_hlapm_edit_distance // channel: [ val(meta), path("*.edit_distance.tsv") ], meta.id == rna_id
    hlapm_gene_summary = ch_hlapm_gene_summary // channel: [ val(meta), path("*.HLA_gene_summary.tsv") ], meta.id == rna_id
    gtf_hla_gene_id_report = ch_gtf_hla_gene_id_report // channel: [ path("hla_region_gene_id_map.tsv") ]
    counts_commonref_gene_counts = ch_counts_commonref_gene_counts // channel: [ val(meta), path("*featureCounts.tsv") ], meta.id == rna_id
    counts_commonref_summary = ch_counts_commonref_summary // channel: [ val(meta), path("*featureCounts.tsv.summary") ], meta.id == rna_id
    counts_commonref_hla_read_gene_assignments = ch_counts_commonref_hla_read_gene_assignments // channel: [ val(meta), path("*.rnaseq_featurecounts.tsv") ], meta.id == rna_id
    hla_readcount_diff = ch_hla_readcount_diff // channel: [ val(meta), path("*.hla_readcount_reconcile.tsv") ], meta.id == rna_id, only for samples present in both counts_commonref_hla_read_gene_assignments and hlapm_edit_distance
    hla_readcount_diff_warnings = ch_hla_readcount_diff_warnings // channel: [ val(meta), path("*.gene_id_resolution_warnings.tsv") ], meta.id == rna_id, only for samples present in both counts_commonref_hla_read_gene_assignments and hlapm_edit_distance
    combine_final_counts = ch_combine_final_counts // channel: [ val(meta), path("*.final_counts.tsv") ], meta.id == rna_id, only for samples present in both counts_commonref_gene_counts and hla_readcount_diff
    combine_final_counts_change_log = ch_combine_final_counts_change_log // channel: [ val(meta), path("*.final_counts.change_log.tsv") ], meta.id == rna_id, only for samples present in both counts_commonref_gene_counts and hla_readcount_diff

}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

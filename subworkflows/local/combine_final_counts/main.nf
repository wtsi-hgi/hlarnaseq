include { COMBINE_FINAL_COUNTS_PATCH } from '../../../modules/local/combine_final_counts'

workflow COMBINE_FINAL_COUNTS {

    take:
    ch_gene_counts     // channel: [ val(meta), path("*featureCounts.tsv") ], meta.id == rna_id, from COUNTS_COMMONREF.out.gene_counts (meta also carries single_end/strandedness)
    ch_read_count_diff // channel: [ val(meta), path("*.hla_readcount_reconcile.tsv") ], meta.id == rna_id, from HLA_READCOUNT_RECONCILE.out.read_count_diff (meta is [id:] only)

    main:

    // Both inputs are guaranteed at most one row per rna_id
    // (SUBREAD_FEATURECOUNTS and HLA_READCOUNT_RECONCILE_DIFF each run once
    // per RNA sample), so a plain `.join()` - mirroring
    // HLA_READCOUNT_RECONCILE's own join - is both sufficient and exactly the
    // desired "only patch samples that have both tables" semantics: an RNA
    // sample with a whole-genome count table but NO diff table (not resolved
    // through --sample_key/HLApm to any personalized allele) is silently
    // dropped here and gets no final_counts.tsv at all, rather than having an
    // unpatched copy of its whole-genome table published under a "final"
    // name. That is an expected inner-join outcome, not an error, and it is
    // consistent with the same sample already getting no
    // hla_readcount_reconcile/ directory.
    //
    // The reverse case cannot occur: ch_read_count_diff is itself already
    // inner-joined against the same --rna_samples samplesheet that produced
    // ch_gene_counts, so a diff table without a whole-genome table is not
    // reachable.
    ch_fc_by_id = ch_gene_counts.map { meta, tsv -> [ meta.id, tsv ] }
    ch_diff_by_id = ch_read_count_diff.map { meta, tsv -> [ meta.id, tsv ] }

    // Reconstructs a clean [id: rna_id] meta, discarding the fc side's extra
    // single_end/strandedness keys (not meaningful to this step).
    ch_joined = ch_fc_by_id
        .join(ch_diff_by_id)
        .map { rna_id, fc_tsv, diff_tsv -> [ [ id: rna_id ], fc_tsv, diff_tsv ] }

    COMBINE_FINAL_COUNTS_PATCH(ch_joined)

    ch_versions = COMBINE_FINAL_COUNTS_PATCH.out.versions

    emit:
    final_counts = COMBINE_FINAL_COUNTS_PATCH.out.final_counts // channel: [ val(meta), path("*.final_counts.tsv") ], meta.id == rna_id
    change_log   = COMBINE_FINAL_COUNTS_PATCH.out.change_log   // channel: [ val(meta), path("*.final_counts.change_log.tsv") ], meta.id == rna_id
    versions     = ch_versions                                 // channel: [ path(versions.yml) ]
}

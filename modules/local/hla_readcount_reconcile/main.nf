process HLA_READCOUNT_RECONCILE_DIFF {
    // Named _DIFF, not HLA_READCOUNT_RECONCILE, even though this is the only
    // process in this module/directory: the wrapping subworkflow of the
    // same feature is itself named HLA_READCOUNT_RECONCILE (see
    // subworkflows/local/hla_readcount_reconcile/main.nf), and Nextflow
    // does not allow a workflow and an `include`d process to share one
    // symbol name in the same script ("`X` is already included"). Matches
    // this repository's existing COUNTS_COMMONREF_HLA_REFORMAT /
    // COUNTS_COMMONREF_HLA precedent of giving the wrapped process its own,
    // more specific name distinct from the subworkflow that calls it.
    tag "${meta.id}"
    label 'process_single'

    // Shared python3 + R environment, not module-local: see
    // containers/datatools/README.md. bin/reconcile_hla_readcounts.py needs
    // python3 and pandas, both of which that environment already pins.
    conda "${projectDir}/containers/datatools/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        "${projectDir}/containers/datatools/datatools.sif" :
        'quay.io/hlarnaseq/datatools:1.1' }"

    // No module-level publishDir here (matches COUNTS_COMMONREF_HLA_REFORMAT's
    // own precedent): this process's publish path varies per sample
    // (${meta.id}), which requires a closure-deferred path - a top-level,
    // non-closure publishDir string interpolating ${meta.id} directly would
    // be evaluated at process definition/parse time, before `meta` exists.
    // conf/modules.config's `withName: 'HLA_READCOUNT_RECONCILE_DIFF'` block
    // supplies the per-sample path instead.

    input:
    tuple val(meta), path(fc_tsv), path(pers_tsv)
    path gtf

    output:
    tuple val(meta), path("${meta.id}.hla_readcount_reconcile.tsv"), emit: read_count_diff
    tuple val(meta), path("${meta.id}.gene_id_resolution_warnings.tsv"), emit: gene_id_resolution_warnings
    path "versions.yml", emit: versions

    script:
    """
    reconcile_hla_readcounts.py \\
        "${fc_tsv}" \\
        "${pers_tsv}" \\
        --gtf "${gtf}" \\
        --max-edit-distance ${params.hlapm_quantify_max_edit_distance} \\
        -o "${meta.id}.hla_readcount_reconcile.tsv" \\
        --warnings-output "${meta.id}.gene_id_resolution_warnings.tsv"

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python3: \$(python3 --version | sed 's/Python //')
        pandas: \$(python3 -c "import pandas; print(pandas.__version__)")
    END_VERSIONS
    """

    stub:
    // A stub: block is required here (matching COUNTS_COMMONREF_HLA_REFORMAT/
    // HLAPM_QUANTIFY_READS precedent): the real script would otherwise try
    // to parse HLAPM_QUANTIFY_READS' own stubbed edit_distance.tsv (whose
    // stub row's gene_name is "placeholder_allele", not HLA--prefixed, which
    // would trip load_personref_table()/reconcile()'s "all rows must be HLA
    // genes" integrity check) - the stub instead writes header-only
    // placeholder outputs with the new column schemas.
    //
    // The warnings file keeps all six columns even though only
    // reason=missing_gene_name / resolution=na_placeholder are still
    // reachable: an ambiguous gene_name that takes a row in the diff table now
    // fails the task outright (exit 1) instead of being resolved to a first or
    // joined id and recorded here. See the header of
    // bin/reconcile_hla_readcounts.py for why that failure is scoped to
    // ambiguity the output actually consumes, so that the hundreds of
    // ambiguous names a corrected GENCODE GTF still carries do not fail a run.
    """
    printf 'gene_id\\tgene_name\\tcategory\\toriginal_fc_count\\tpersonalized_count\\tdiff\\n' > "${meta.id}.hla_readcount_reconcile.tsv"
    printf 'gene_name\\tcategory\\treason\\tgene_ids\\tresolution\\tresolved_gene_id\\n' > "${meta.id}.gene_id_resolution_warnings.tsv"

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python3: unknown
        pandas: unknown
    END_VERSIONS
    """
}

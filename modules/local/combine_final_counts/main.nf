process COMBINE_FINAL_COUNTS_PATCH {
    // Named _PATCH, not COMBINE_FINAL_COUNTS, even though this is the only
    // process in this module/directory: the wrapping subworkflow of the same
    // feature is itself named COMBINE_FINAL_COUNTS (see
    // subworkflows/local/combine_final_counts/main.nf), and Nextflow does not
    // allow a workflow and an `include`d process to share one symbol name in
    // the same script ("`X` is already included"). Same precedent as
    // HLA_READCOUNT_RECONCILE_DIFF / HLA_READCOUNT_RECONCILE and
    // COUNTS_COMMONREF_HLA_REFORMAT / COUNTS_COMMONREF_HLA.
    tag "${meta.id}"
    label 'process_single'

    // Shared python3 + R environment, not module-local: see
    // containers/datatools/README.md. bin/combine_final_counts.py uses the
    // Python standard library only (it streams two TSVs and writes two TSVs),
    // so this adds no package to that environment and needs no image rebuild
    // or tag bump.
    conda "${projectDir}/containers/datatools/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        "${projectDir}/containers/datatools/datatools.sif" :
        'quay.io/hlarnaseq/datatools:1.1' }"

    // No module-level publishDir here (matches HLA_READCOUNT_RECONCILE_DIFF's
    // and COUNTS_COMMONREF_HLA_REFORMAT's own precedent): this process's
    // publish path varies per sample (${meta.id}), which requires a
    // closure-deferred path - a top-level, non-closure publishDir string
    // interpolating ${meta.id} directly would be evaluated at process
    // definition/parse time, before `meta` exists.
    // conf/modules.config's `withName: 'COMBINE_FINAL_COUNTS_PATCH'` block
    // supplies the per-sample path instead.

    input:
    // No `path gtf`: the diff table already carries a resolved, unambiguous
    // gene_id for both categories and the featureCounts table is keyed by
    // gene_id (`-g gene_id`), so this patch is an exact gene_id join. See the
    // header of bin/combine_final_counts.py.
    tuple val(meta), path(fc_tsv), path(diff_tsv)

    output:
    tuple val(meta), path("${meta.id}.final_counts.tsv"), emit: final_counts
    tuple val(meta), path("${meta.id}.final_counts.change_log.tsv"), emit: change_log
    path "versions.yml", emit: versions

    script:
    """
    # The conda/container directives above provision python3. Neither applies
    # when the pipeline is run with no -profile conda/docker/singularity/
    # apptainer at all, in which case the task falls back to the host PATH -
    # fail with an actionable message and exit 127, as the other datatools
    # modules do, so a missing environment stays distinguishable from this
    # step's own data failures (exit 1: an unverifiable count unit, a diff
    # gene_id absent from the count table, or a negative resulting count).
    command -v python3 >/dev/null 2>&1 || {
        echo "ERROR: python3 is not available. Run the pipeline with -profile conda, docker, singularity, or apptainer so this module gets the environment declared in containers/datatools/environment.yml." >&2
        exit 127
    }

    combine_final_counts.py \\
        "${fc_tsv}" \\
        "${diff_tsv}" \\
        -o "${meta.id}.final_counts.tsv" \\
        --change-log "${meta.id}.final_counts.change_log.tsv"

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python3: \$(python3 --version | sed 's/Python //')
    END_VERSIONS
    """

    stub:
    // A stub: block is required here (matching HLA_READCOUNT_RECONCILE_DIFF's
    // and COUNTS_COMMONREF_HLA_REFORMAT's precedent): under -stub-run /
    // -profile test both upstream inputs are placeholders the real script
    // rightly rejects - SUBREAD_FEATURECOUNTS's vendored stub just `touch`es
    // an empty *.featureCounts.tsv (no `# Program:` line and no `Geneid`
    // header, so the count-unit assertion and the header check both fail),
    // and HLA_READCOUNT_RECONCILE_DIFF's stub emits a header-only diff table.
    // The stub instead writes header-only placeholder outputs with the real
    // column schemas.
    """
    printf 'gene_id\\tcount\\n' > "${meta.id}.final_counts.tsv"
    printf 'gene_id\\tgene_name\\tcategory\\toriginal_count\\tnew_count\\taction\\n' > "${meta.id}.final_counts.change_log.tsv"

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python3: unknown
    END_VERSIONS
    """
}

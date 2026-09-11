process GTF_HLA_GENE_ID_CHECK {
    tag "gtf_hla_gene_id_check"
    label 'process_single'

    // Shared python3 + R environment, not module-local: see
    // containers/datatools/README.md. bin/check_gtf_hla_gene_ids.py uses the
    // Python standard library only, so this adds no package to that
    // environment and needs no image rebuild.
    conda "${projectDir}/containers/datatools/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        "${projectDir}/containers/datatools/datatools.sif" :
        'quay.io/hlarnaseq/datatools:1.1' }"

    // publishDir and errorStrategy live in conf/modules.config's
    // `withName: 'GTF_HLA_GENE_ID_CHECK'` block, kept together there because
    // the point of this process is the errorStrategy override
    // (`'terminate'`, not conf/base.config's `'finish'`) and splitting the two
    // across two files would hide it.

    input:
    path gtf

    output:
    path "hla_region_gene_id_map.tsv", emit: report
    path "versions.yml", emit: versions

    script:
    """
    # The conda/container directives above provision python3. Neither applies
    # when the pipeline is run with no -profile conda/docker/singularity/
    # apptainer at all, in which case the task falls back to the host PATH -
    # fail with an actionable message and exit 127, as the other datatools
    # modules do, so a missing environment stays distinguishable from this
    # check's own gene_name/gene_id uniqueness failure (exit 1).
    command -v python3 >/dev/null 2>&1 || {
        echo "ERROR: python3 is not available. Run the pipeline with -profile conda, docker, singularity, or apptainer so this module gets the environment declared in containers/datatools/environment.yml." >&2
        exit 127
    }

    check_gtf_hla_gene_ids.py \\
        --gtf "${gtf}" \\
        --hla-region "${params.hla_region}" \\
        --report hla_region_gene_id_map.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python3: \$(python3 --version | sed 's/Python //')
    END_VERSIONS
    """

    // No stub: block, deliberately (the ARCASHLA_EXTRACT precedent). --gtf is
    // a real, readable GTF in every profile (nf-schema enforces
    // `required` + `exists: true`), the check is a single streaming pass that
    // takes milliseconds on the test fixture, and skipping the stub gives
    // -stub-run coverage of the real check - including -profile test's
    // placeholder.gtf zero-region-genes warning path - for free.
}

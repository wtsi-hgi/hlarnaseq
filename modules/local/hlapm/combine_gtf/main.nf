process HLAPM_COMBINE_GTF {
    tag "hlapm_combine_gtf"
    label 'process_single'

    // Shared environment, not module-local: see containers/datatools/README.md
    // ("The shell-only consumers"). Pure shell (cat/grep), same rationale as
    // HLALA_COMBINE.
    conda "${projectDir}/containers/datatools/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        "${projectDir}/containers/datatools/datatools.sif" :
        'quay.io/hlarnaseq/datatools:1.1' }"

    publishDir "${params.outdir}/hlapm/quantify",
        mode: params.publish_dir_mode,
        saveAs: { filename -> filename.equals('versions.yml') ? null : filename }

    input:
    path gtfs

    output:
    path "combined.gtf", emit: gtf
    path "versions.yml", emit: versions

    script:
    // A single-file input can arrive unwrapped rather than as a list. Sorted
    // by name for a deterministic concatenation order, independent of the
    // order collect() delivered. Joined onto one line: a multi-line
    // interpolated value would break the script block's common-indentation
    // stripping (see HLALA_COMBINE).
    def gtf_list = (gtfs instanceof List ? gtfs : [gtfs]).sort { it.getName() }
    def gtf_args = gtf_list.collect { "\"${it}\"" }.join(' ')
    """
    set -euo pipefail

    # Concatenate exactly the staged inputs. Never glob *.gtf here: the output
    # combined.gtf matches that glob, and because both sides of the pipeline
    # start concurrently the redirect can create it before the glob expands,
    # so cat reads its own growing output forever (seen on Lustre: a 4.1 TB
    # combined.gtf killed at the 8 h LSF runlimit).
    cat ${gtf_args} | grep -v '^#' > combined.gtf

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        bash: \$(bash --version | head -n1 | sed 's/^GNU bash, version //; s/ .*//')
    END_VERSIONS
    """
}

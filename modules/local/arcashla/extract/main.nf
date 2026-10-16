process ARCASHLA_EXTRACT {
    tag "$meta.id"
    label 'process_medium'

    conda "${moduleDir}/environment.yml"
    // Standard nf-core pattern: one environment.yml feeds the `conda`
    // directive, paired with a matching pinned container. The image below is
    // deliberately the *same* one the vendored nf-core SAMTOOLS_SORT module
    // uses (see modules/nf-core/samtools/sort/main.nf) - the pipeline's only
    // other samtools call site - so the two can never run different samtools
    // versions, and containerized profiles pull no image the pipeline was not
    // already pulling. Like ARCASHLA_VALIDATE_FASTQ (and unlike
    // ARCASHLA_GENOTYPE) this needs no bespoke Dockerfile and no committed
    // .sif: both branches below are public references.
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/e9/e994bf4eb3731150511a14f5706b7bdfd64df1b6d40898fff334286c027e0859/data':
        'community.wave.seqera.io/library/htslib_samtools:1.24--d697cfb9dce007cd' }"

    publishDir "${params.outdir}/arcashla/extracted",
        mode: params.publish_dir_mode,
        saveAs: { filename -> filename == 'versions.yml' ? null : filename }

    input:
    tuple val(meta), path(bam), path(bai), path(unpaired_reads)

    output:
    tuple val(meta), path("${meta.id}.mhc_1.fq.gz"), path("${meta.id}.mhc_2.fq.gz"), emit: reads
    tuple val(meta), path("${meta.id}.mhc.namesort.bam"), emit: bam
    path "versions.yml", emit: versions

    script:
    def unpaired_r1 = unpaired_reads[0]
    def unpaired_r2 = unpaired_reads[1]
    """
    # samtools is provisioned by the conda/container directives above. Fail
    # with an actionable message rather than a bare "command not found" if
    # neither provisioned it - which is what happens when the pipeline is run
    # with no -profile conda/docker/singularity/apptainer at all.
    command -v samtools >/dev/null 2>&1 || {
        echo "ERROR: samtools is not available in the active environment or container. Run with -profile conda, docker, singularity, or apptainer so this module can provision it." >&2
        exit 127
    }

    if [[ "${bai}" != "${bam}.bai" ]]; then
        ln -sf "${bai}" "${bam}.bai"
    fi

    # Contig-naming pre-check (exit 3). samtools view does not reliably fail on
    # a region whose contig is absent from the BAM (it warns "unknown
    # reference ... Continue anyway" and exits 0), so a "chr6" vs "6" mismatch
    # between --hla_region and the BAM would otherwise surface far downstream,
    # if at all. The contig is everything before the last ':' - the same split
    # bin/check_gtf_hla_gene_ids.py's parse_region() uses. Pure bash on purpose:
    # nothing beyond samtools and bash is assumed of the container.
    hla_region="${params.hla_region}"
    hla_contig="\${hla_region%:*}"
    case "\${hla_contig}" in
        chrM) alt_contig="MT" ;;
        MT)   alt_contig="chrM" ;;
        chr*) alt_contig="\${hla_contig#chr}" ;;
        *)    alt_contig="chr\${hla_contig}" ;;
    esac

    bam_header="\$(samtools view -H "${bam}")"
    sq_names=()
    while IFS= read -r header_line; do
        [[ "\${header_line}" == @SQ* ]] || continue
        IFS=\$'\\t' read -r -a header_fields <<< "\${header_line}"
        for header_field in "\${header_fields[@]}"; do
            if [[ "\${header_field}" == SN:* ]]; then
                sq_names+=("\${header_field#SN:}")
            fi
        done
    done <<< "\${bam_header}"

    has_contig=0
    has_alt_contig=0
    for sq_name in "\${sq_names[@]+"\${sq_names[@]}"}"; do
        if [[ "\${sq_name}" == "\${hla_contig}" ]]; then has_contig=1; fi
        if [[ "\${sq_name}" == "\${alt_contig}" ]]; then has_alt_contig=1; fi
    done

    if [[ \${has_contig} -eq 0 ]]; then
        echo "ERROR: --hla_region contig '\${hla_contig}' is not an @SQ reference in ${bam}." >&2
        if [[ \${has_alt_contig} -eq 1 ]]; then
            echo "       The BAM uses '\${alt_contig}' instead; use --hla_region \${alt_contig}\${hla_region:\${#hla_contig}} (and make sure --gtf uses the same contig naming)." >&2
        else
            echo "       First @SQ names in the BAM: \${sq_names[*]:0:5}" >&2
        fi
        exit 3
    fi

    samtools view \
        --uncompressed \
        --fetch-pairs \
        -@ ${task.cpus} \
        -F 2304 \
        "${bam}" \
        "${params.hla_region}" \
        | samtools sort \
            -n \
            -@ ${task.cpus} \
            -T "${meta.id}.sort" \
            -o "${meta.id}.mhc.namesort.bam" \
            -

    # Empty-extraction check (exit 4). The contig exists, so zero primary
    # alignments in the slice means wrong coordinates for this BAM's build
    # (e.g. GRCh38 coordinates on a GRCh37 BAM); without this, arcasHLA fails
    # later with a far less specific error.
    n_extracted="\$(samtools view -c "${meta.id}.mhc.namesort.bam")"
    if [[ "\${n_extracted}" -eq 0 ]]; then
        echo "ERROR: no primary alignments in --hla_region ${params.hla_region} of ${bam}." >&2
        echo "       The contig exists, so the coordinates probably do not match this BAM's genome build." >&2
        exit 4
    fi

    samtools fastq \
        -@ ${task.cpus} \
        -0 /dev/null \
        -1 "${meta.id}.bam_1.fq.gz" \
        -2 "${meta.id}.bam_2.fq.gz" \
        -s "${meta.id}.singleton.fq.gz" \
        "${meta.id}.mhc.namesort.bam"

    cat "${unpaired_r1}" "${meta.id}.bam_1.fq.gz" > "${meta.id}.mhc_1.fq.gz"
    cat "${unpaired_r2}" "${meta.id}.bam_2.fq.gz" > "${meta.id}.mhc_2.fq.gz"

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        samtools: \$(samtools --version | sed -n '1s/^samtools //p')
    END_VERSIONS
    """

    stub:
    """
    # A minimal but *valid* gzipped FASTQ pair rather than a bare `touch`:
    # tests/default.nf.test asserts these are non-empty, and downstream stubs
    # are handed these paths. Content is not snapshotted (see
    # tests/.nftignore's arcashla/extracted/*.fq.gz entry) - only the names.
    #
    # Before this module had a stub: block, `-profile test -stub-run` fell
    # through to the script: block above and really ran samtools off the host
    # PATH. Stubbing it is what makes the stub pipeline test genuinely
    # engine-free and tool-free.
    printf '@stub_read/1\\nACGT\\n+\\nIIII\\n' | gzip -c > "${meta.id}.mhc_1.fq.gz"
    printf '@stub_read/2\\nACGT\\n+\\nIIII\\n' | gzip -c > "${meta.id}.mhc_2.fq.gz"

    # An empty touch, unlike the two FASTQs above: nothing under -stub-run
    # reads this BAM's content. Its only consumer is SUBREAD_FEATURECOUNTS_HLA,
    # whose own vendored stub: block never opens its inputs, and
    # COUNTS_COMMONREF_HLA_REFORMAT's stub: block exists precisely because that
    # chain hands on empty placeholders (see the comment there). The output is
    # declared, so it must exist or the stub run fails with "Missing output
    # file(s)".
    touch "${meta.id}.mhc.namesort.bam"

    # Hardcoded rather than parsed: environment.yml pins this module to exactly
    # samtools 1.24. Bump both together if that pin ever changes. Left unquoted
    # to match exactly what the script: block's `samtools --version` parse
    # produces (a bare 1.24, which YAML loads as a number) - quoting it would
    # turn the collected version into the string "1.24" and churn
    # tests/default.nf.test.snap for no reason.
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        samtools: 1.24
    END_VERSIONS
    """
}

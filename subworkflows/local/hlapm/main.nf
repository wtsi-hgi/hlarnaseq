include { HLAPM_PREPARE_INPUT } from '../../../modules/local/hlapm/prepare_input'
include { HLAPM_BUILD_REF     } from '../../../modules/local/hlapm/build_ref'

workflow HLAPM {

    take:
    ch_hla_consensus_key // channel: [ path(hla_consensus.rna_wgs_hla_consensus.tsv) ]

    main:

    HLAPM_PREPARE_INPUT(ch_hla_consensus_key)

    // --hlapm_repo is an optional override of the HLApm checkout baked into
    // HLAPM_BUILD_REF's container image, and mandatory when no container
    // engine is in use (enforced at launch by hlapmRepoExistsError() in
    // subworkflows/local/utils_wtsihgi_hlarnaseq_pipeline). It is passed as a
    // staged path input rather than read from params inside the module, so
    // that Nextflow mounts it into the container - the same reason
    // subworkflows/local/hlala passes its graph directory this way.
    ch_hlapm_repo = params.hlapm_repo
        ? channel.value(file(params.hlapm_repo, checkIfExists: true))
        : channel.value([])

    HLAPM_BUILD_REF(HLAPM_PREPARE_INPUT.out.sample_tsvs, ch_hlapm_repo)

    ch_versions = HLAPM_PREPARE_INPUT.out.versions.mix(HLAPM_BUILD_REF.out.versions)

    emit:
    sample_tsvs      = HLAPM_PREPARE_INPUT.out.sample_tsvs // channel: [ path("*.tsv") ]
    personalized_ref = HLAPM_BUILD_REF.out.personalized_ref // channel: [ path("out") ]
    versions         = ch_versions
}

//
// Subworkflow with functionality specific to the wtsi-hgi/hlarnaseq pipeline
//

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT FUNCTIONS / MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { UTILS_NFSCHEMA_PLUGIN     } from '../../nf-core/utils_nfschema_plugin'
include { paramsSummaryMap          } from 'plugin/nf-schema'
include { samplesheetToList         } from 'plugin/nf-schema'
include { paramsHelp                } from 'plugin/nf-schema'
include { completionEmail           } from '../../nf-core/utils_nfcore_pipeline'
include { completionSummary         } from '../../nf-core/utils_nfcore_pipeline'
include { imNotification            } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NFCORE_PIPELINE     } from '../../nf-core/utils_nfcore_pipeline'
include { UTILS_NEXTFLOW_PIPELINE   } from '../../nf-core/utils_nextflow_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW TO INITIALISE PIPELINE
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_INITIALISATION {

    take:
    version           // boolean: Display version and exit
    validate_params   // boolean: Boolean whether to validate parameters against the schema at runtime
    monochrome_logs   // boolean: Do not use coloured log outputs
    nextflow_cli_args //   array: List of positional nextflow CLI args
    outdir            //  string: The output directory where the results will be saved
    rna_samples       //  string: Path to RNA samplesheet
    wgs_samples       //  string: Path to WGS samplesheet
    array_samples     //  string: Path to SNP-array samplesheet
    sample_key        //  string: Path to RNA/WGS sample key
    help              // boolean: Display help message and exit
    help_full         // boolean: Show the full help message
    show_hidden       // boolean: Show hidden parameters in the help message

    main:

    ch_versions = channel.empty()

    //
    // Print version and exit if required and dump pipeline parameters to JSON file
    //
    UTILS_NEXTFLOW_PIPELINE (
        version,
        true,
        outdir,
        workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1
    )

    //
    // Validate parameters and generate parameter summary to stdout
    //
    before_text = """
-\033[2m----------------------------------------------------\033[0m-
                                        \033[0;32m,--.\033[0;30m/\033[0;32m,-.\033[0m
\033[0;34m        ___     __   __   __   ___     \033[0;32m/,-._.--~\'\033[0m
\033[0;34m  |\\ | |__  __ /  ` /  \\ |__) |__         \033[0;33m}  {\033[0m
\033[0;34m  | \\| |       \\__, \\__/ |  \\ |___     \033[0;32m\\`-._,-`-,\033[0m
                                        \033[0;32m`._,._,\'\033[0m
\033[0;35m  wtsi-hgi/hlarnaseq ${workflow.manifest.version}\033[0m
-\033[2m----------------------------------------------------\033[0m-
"""
    after_text = """${workflow.manifest.doi ? "\n* The pipeline\n" : ""}${workflow.manifest.doi.tokenize(",").collect { doi -> "    https://doi.org/${doi.trim().replace('https://doi.org/','')}"}.join("\n")}${workflow.manifest.doi ? "\n" : ""}
* The nf-core framework
    https://doi.org/10.1038/s41587-020-0439-x

* Software dependencies
    https://github.com/wtsi-hgi/hlarnaseq/blob/main/CITATIONS.md
"""
    command = "nextflow run ${workflow.manifest.name} --rna_samples rna_samples.csv --sample_key rna_wgs_key.csv --hla_region chr6:28500000-33400000 --gtf annotation.gtf --arcashla_reference_dir arcashla_reference/ --outdir <OUTDIR>"

    UTILS_NFSCHEMA_PLUGIN (
        workflow,
        validate_params,
        null,
        help,
        help_full,
        show_hidden,
        before_text,
        after_text,
        command
    )

    //
    // Check config provided to the pipeline
    //
    UTILS_NFCORE_PIPELINE (
        nextflow_cli_args
    )

    //
    // Custom validation for pipeline parameters
    //
    validateInputParameters()

    //
    // Create channel from RNA samplesheet provided through params.rna_samples
    //

    validateRnaSamplesheetHeader(rna_samples)
    validateRnaSamplesheetIds(rna_samples)

    channel
        .fromList(samplesheetToList(rna_samples, "${projectDir}/assets/schema_rna_samples.json"))
        .map {
            meta, bam, bai, unpaired_r1, unpaired_r2 ->
                return [
                    meta + [ single_end:false ],
                    validateRnaSamplesheetFile(rna_samples, bam, "bam"),
                    validateRnaSamplesheetFile(rna_samples, bai, "bai"),
                    [
                        validateRnaSamplesheetFile(rna_samples, unpaired_r1, "unpaired_r1"),
                        validateRnaSamplesheetFile(rna_samples, unpaired_r2, "unpaired_r2")
                    ]
                ]
        }
        .set { ch_rna_samplesheet }

    //
    // Create channel from WGS samplesheet provided through params.wgs_samples
    //
    if (wgs_samples) {
        validateWgsSamplesheetHeader(wgs_samples)

        channel
            .fromList(samplesheetToList(wgs_samples, "${projectDir}/assets/schema_wgs_samples.json"))
            .map {
                meta, WGS_BAM_path, WGS_BAI_path ->
                    return [
                        meta,
                        validateWgsSamplesheetFile(wgs_samples, WGS_BAM_path, "WGS_BAM_path"),
                        validateWgsSamplesheetFile(wgs_samples, WGS_BAI_path, "WGS_BAI_path")
                    ]
            }
            .set { ch_wgs_samplesheet }
    } else {
        ch_wgs_samplesheet = channel.empty()
    }

    //
    // Create channel from SNP-array samplesheet provided through params.array_samples
    //
    // A row is one PLINK dataset, not one sample: HIBAG predicts every sample
    // in the fileset at once, and the sample IDs that reach HLA_CONSENSUS come
    // from the .fam IID column rather than from array_sample_id.
    //
    if (array_samples) {
        validateArraySamplesheetHeader(array_samples)

        channel
            .fromList(samplesheetToList(array_samples, "${projectDir}/assets/schema_array_samples.json"))
            .map {
                meta, array_bed_path, array_bim_path, array_fam_path ->
                    return [
                        meta,
                        validateArraySamplesheetFile(array_samples, array_bed_path, "array_bed_path"),
                        validateArraySamplesheetFile(array_samples, array_bim_path, "array_bim_path"),
                        validateArraySamplesheetFile(array_samples, array_fam_path, "array_fam_path")
                    ]
            }
            .set { ch_array_samplesheet }
    } else {
        ch_array_samplesheet = channel.empty()
    }

    //
    // Create channel from RNA/WGS sample key provided through params.sample_key
    //
    // Unconditional: --sample_key is a required parameter (see
    // nextflow_schema.json), like --rna_samples above.
    //
    validateSampleKeyHeader(sample_key)
    ch_sample_key = channel.fromPath(sample_key)

    emit:
    rna_samplesheet   = ch_rna_samplesheet
    wgs_samplesheet   = ch_wgs_samplesheet
    array_samplesheet = ch_array_samplesheet
    sample_key        = ch_sample_key
    versions          = ch_versions
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    SUBWORKFLOW FOR PIPELINE COMPLETION
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PIPELINE_COMPLETION {

    take:
    email           //  string: email address
    email_on_fail   //  string: email address sent on pipeline failure
    plaintext_email // boolean: Send plain-text email instead of HTML
    outdir          //    path: Path to output directory where results will be published
    monochrome_logs // boolean: Disable ANSI colour codes in log output
    hook_url        //  string: hook URL for notifications

    main:
    summary_params = paramsSummaryMap(workflow, parameters_schema: "nextflow_schema.json")

    //
    // Completion email and summary
    //
    workflow.onComplete {
        if (email || email_on_fail) {
            completionEmail(
                summary_params,
                email,
                email_on_fail,
                plaintext_email,
                outdir,
                monochrome_logs,
                []
            )
        }

        completionSummary(monochrome_logs)
        if (hook_url) {
            imNotification(summary_params, hook_url)
        }
    }

    workflow.onError {
        log.error "Pipeline failed. Please refer to docs/usage.md, or contact Gennadii Zakharov <gz3@sanger.ac.uk>"
    }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
//
// Check and validate pipeline parameters
//
def validateInputParameters() {
    genomeExistsError()
    genotypeSourceExclusiveError()
    hlalaGraphDirExistsError()
    hibagModelExistsError()
    hlapmRepoExistsError()
    arcashlaReferenceDirExistsError()
}

//
// Validate RNA samplesheet header
//
def validateRnaSamplesheetHeader(samplesheet) {
    def expected_header = "rna_id,bam,bai,unpaired_r1,unpaired_r2"
    def observed_header = file(samplesheet).readLines().find { line -> line.trim() }?.trim()

    if (observed_header != expected_header) {
        error("Please check RNA samplesheet -> Header must be exactly: ${expected_header}")
    }
}

//
// Validate that RNA sample identifiers are unique
//
def validateRnaSamplesheetIds(samplesheet) {
    def lines = file(samplesheet).readLines().findAll { line -> line.trim() }
    def ids = lines.drop(1).collect { line -> line.split(',', -1)[0].trim() }
    def duplicate_ids = ids.countBy { it }.findAll { id, count -> id && count > 1 }.keySet().sort()

    if (duplicate_ids) {
        error("Please check RNA samplesheet -> Duplicate rna_id values are not allowed: ${duplicate_ids.join(', ')}")
    }
}

//
// Validate and resolve RNA samplesheet file entries
//
def validateRnaSamplesheetFile(samplesheet, entry, field_name) {
    def entry_path = file(entry)

    if (entry_path.isAbsolute() && entry_path.exists()) {
        return entry_path
    }

    def launch_path = file(workflow.launchDir)
    def relative_entry = entry_path.isAbsolute() && entry_path.startsWith(launch_path) ? launch_path.relativize(entry_path) : entry_path
    def candidate_paths = [
        file(samplesheet).parent.resolve(relative_entry).normalize(),
        launch_path.resolve(relative_entry).normalize(),
        file(projectDir).resolve(relative_entry).normalize()
    ]

    def resolved_path = candidate_paths.find { candidate -> candidate.exists() }

    if (!resolved_path) {
        def searched_paths = candidate_paths.collect { candidate -> candidate.toString() }.unique().join(", ")
        error("Please check RNA samplesheet -> ${field_name} does not exist: ${entry}. Searched: ${searched_paths}")
    }

    return resolved_path
}

//
// Validate WGS samplesheet header
//
def validateWgsSamplesheetHeader(samplesheet) {
    def expected_header = "WGS_sample_id,WGS_BAM_path,WGS_BAI_path"
    def observed_header = file(samplesheet).readLines().find { line -> line.trim() }?.trim()

    if (observed_header != expected_header) {
        error("Please check WGS samplesheet -> Header must be exactly: ${expected_header}")
    }
}

//
// Validate and resolve WGS samplesheet file entries
//
def validateWgsSamplesheetFile(samplesheet, entry, field_name) {
    def entry_path = file(entry)

    if (entry_path.isAbsolute()) {
        if (entry_path.exists()) {
            return entry_path
        }
        error("Please check WGS samplesheet -> ${field_name} does not exist: ${entry}")
    }

    def candidate_paths = [
        file(samplesheet).parent.resolve(entry).normalize(),
        file("${workflow.launchDir}/${entry}").normalize(),
        file("${projectDir}/${entry}").normalize()
    ]

    def resolved_path = candidate_paths.find { candidate -> candidate.exists() }

    if (!resolved_path) {
        def searched_paths = candidate_paths.collect { candidate -> candidate.toString() }.unique().join(", ")
        error("Please check WGS samplesheet -> ${field_name} does not exist: ${entry}. Searched: ${searched_paths}")
    }

    return resolved_path
}
//
// Validate SNP-array samplesheet header
//
def validateArraySamplesheetHeader(samplesheet) {
    def expected_header = "array_sample_id,array_bed_path,array_bim_path,array_fam_path"
    def observed_header = file(samplesheet).readLines().find { line -> line.trim() }?.trim()

    if (observed_header != expected_header) {
        error("Please check SNP-array samplesheet -> Header must be exactly: ${expected_header}")
    }
}

//
// Validate and resolve SNP-array samplesheet file entries
//
def validateArraySamplesheetFile(samplesheet, entry, field_name) {
    def entry_path = file(entry)

    if (entry_path.isAbsolute() && entry_path.exists()) {
        return entry_path
    }

    // nf-schema resolves every `format: file-path` samplesheet value against
    // the launch directory, so a relative entry arrives here already absolute
    // and wrong whenever the pipeline is launched from outside the repo (which
    // is what nf-test does). Undo that before searching, exactly as
    // validateRnaSamplesheetFile does.
    def launch_path = file(workflow.launchDir)
    def relative_entry = entry_path.isAbsolute() && entry_path.startsWith(launch_path) ? launch_path.relativize(entry_path) : entry_path
    def candidate_paths = [
        file(samplesheet).parent.resolve(relative_entry).normalize(),
        launch_path.resolve(relative_entry).normalize(),
        file(projectDir).resolve(relative_entry).normalize()
    ]

    def resolved_path = candidate_paths.find { candidate -> candidate.exists() }

    if (!resolved_path) {
        def searched_paths = candidate_paths.collect { candidate -> candidate.toString() }.unique().join(", ")
        error("Please check SNP-array samplesheet -> ${field_name} does not exist: ${entry}. Searched: ${searched_paths}")
    }

    return resolved_path
}

//
// Validate RNA/WGS sample key header
//
def validateSampleKeyHeader(sample_key) {
    def expected_header = "rnaseq_sample_id,wgs_sample_id"
    def observed_header = file(sample_key).readLines().find { line -> line.trim() }?.trim()

    if (observed_header != expected_header) {
        error("Please check sample key -> Header must be exactly: ${expected_header}")
    }
}

//
// Get attribute from genome config file e.g. fasta
//
def getGenomeAttribute(attribute) {
    if (params.genomes && params.genome && params.genomes.containsKey(params.genome)) {
        if (params.genomes[ params.genome ].containsKey(attribute)) {
            return params.genomes[ params.genome ][ attribute ]
        }
    }
    return null
}

//
// Exit pipeline if incorrect --genome key provided
//
def genomeExistsError() {
    if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
        def error_string = "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n" +
            "  Genome '${params.genome}' not found in any config files provided to the pipeline.\n" +
            "  Currently, the available genome keys are:\n" +
            "  ${params.genomes.keySet().join(", ")}\n" +
            "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        error(error_string)
    }
}

//
// Exit pipeline if both genotype-side HLA callers are requested at once
//
// HLA-LA (from WGS) and HIBAG (from SNP arrays) both fill the same
// `sample_id/Locus/HLA_allele` channel feeding HLA_CONSENSUS. Running both
// would mean silently choosing one, so require the user to choose instead.
//
def genotypeSourceExclusiveError() {
    if (params.wgs_samples && params.array_samples) {
        error(
            "--wgs_samples and --array_samples are mutually exclusive.\n" +
            "  --wgs_samples calls genotype-side HLA alleles from WGS with HLA-LA.\n" +
            "  --array_samples calls them from SNP-array data with HIBAG.\n" +
            "  Both feed the same consensus input, so please provide exactly one."
        )
    }
}

//
// Exit pipeline if SNP-array inputs are provided without a usable HIBAG model
//
def hibagModelExistsError() {
    if (params.array_samples && !params.hibag_model) {
        error("Please provide --hibag_model when using --array_samples so HIBAG can find its pre-fit model file.")
    }
    if (params.hibag_model && !file(params.hibag_model).exists()) {
        error("Please check --hibag_model -> the HIBAG model file does not exist: ${params.hibag_model}")
    }
}

//
// Exit pipeline if WGS HLA-LA inputs are provided without a prepared graph directory
//
// The bwa-index check is a fail-fast for a bug that is otherwise expensive and
// deeply confusing to hit. HLA-LA bwa-indexes the graph's extended reference
// genome lazily, on first use, writing the index NEXT TO THE FASTA - i.e. back
// into the graph directory (BWAmapper::map() -> make_sure_ref_is_indexed(), in
// HLA-LA's src/mapper/bwa/BWAmapper.cpp). The graph reaches HLALA_TYPING as a
// single shared `path` input, so every per-sample task sees the same underlying
// directory: with an unindexed graph, all of them start that same `bwa index`
// at once and clobber each other, and all but (at most) one sample fails hours
// into the run. Refusing here, before any task launches, turns that into one
// line of output and one re-run of scripts/build_reference_hlala.sh.
//
def hlalaGraphDirExistsError() {
    if (params.wgs_samples && !params.hlala_graph_dir) {
        error("Please provide --hlala_graph_dir when using --wgs_samples so HLA-LA can find its prepared graph directory.")
    }

    if (params.wgs_samples && !file(params.hlala_graph_dir).exists()) {
        error("Please check --hlala_graph_dir -> Directory does not exist: ${params.hlala_graph_dir}")
    }

    if (params.wgs_samples) {
        // Only the conventional in-graph location is checked. A graph that
        // redirects its extended reference genome elsewhere with
        // extendedReferenceGenomePath.txt, or that has none at all, is left
        // alone rather than guessed at - as are the stub graph directories the
        // test profiles point at, which have no FASTA here either.
        def graph_dir = file("${params.hlala_graph_dir}/${params.hlala_graph}")
        def ext_ref   = graph_dir.resolve('extendedReferenceGenome/extendedReferenceGenome.fa')

        if (!graph_dir.resolve('extendedReferenceGenomePath.txt').exists() && ext_ref.exists()) {
            // HLA-LA's own definition of "indexed": BWAmapper::ref_is_indexed()
            // tests exactly these three suffixes.
            def missing = ['.sa', '.ann', '.bwt'].findAll { suffix ->
                !graph_dir.resolve("extendedReferenceGenome/extendedReferenceGenome.fa${suffix}").exists()
            }

            if (missing) {
                error(
                    "The HLA-LA graph at ${graph_dir} is not fully prepared: its extended reference\n" +
                    "genome has no bwa index (missing ${missing.join(', ')} beside extendedReferenceGenome.fa).\n" +
                    "  HLA-LA would build that index itself, inside every HLALA_TYPING task, writing to the\n" +
                    "  same shared files - so concurrent WGS samples overwrite each other's index and all but\n" +
                    "  one fail. Build it once, up front, by re-running:\n" +
                    "      scripts/build_reference_hlala.sh ${params.hlala_graph_dir}\n" +
                    "  That adds only the missing index: it neither re-downloads the graph package nor\n" +
                    "  re-runs the multi-hour prepareGraph step."
                )
            }
        }
    }
}
//
// Exit pipeline if there is no source of HLApm at all
//
// HLApm is an unpackaged git repository, so it can only reach HLAPM_BUILD_REF
// two ways: baked into the module's container image (built by
// scripts/build_image_hlapm.sh), or as a checkout passed with --hlapm_repo.
// The module's environment.yml provides HLApm's R dependencies but cannot
// provide HLApm itself, so without a container engine --hlapm_repo is still
// mandatory; with one it is an optional override of the baked-in copy.
// workflow.containerEngine is null under -profile conda and under no profile
// at all, which is exactly the set of runs that need a host checkout.
//
// HLAPM_BUILD_REF always runs (it is downstream of the unconditional
// HLA_CONSENSUS), so this depends only on whether a container engine is in
// play - a runtime fact JSON Schema cannot see, which is why --hlapm_repo
// stays a Groovy check rather than moving to the schema's `required` array.
//
def hlapmRepoExistsError() {
    if (!params.hlapm_repo && !workflow.containerEngine) {
        error("Please provide --hlapm_repo when running without a container profile, so HLApm can find its prepared repository checkout. Alternatively run with -profile docker, singularity, or apptainer, whose image bakes HLApm in (build it once with scripts/build_image_hlapm.sh).")
    }

    if (params.hlapm_repo && !file(params.hlapm_repo).exists()) {
        error("Please check --hlapm_repo -> Directory does not exist: ${params.hlapm_repo}")
    }
}
//
// Exit pipeline if --arcashla_reference_dir does not hold a fully built reference
//
// Presence and existence are enforced by nextflow_schema.json instead
// (`required` + `format: directory-path` + `exists: true`), which gives the
// standard nf-schema `Missing required parameter(s)` message. Only the content
// check below is left here, because JSON Schema cannot express "this directory
// contains a built reference".
//
def arcashlaReferenceDirExistsError() {
    // Existence alone is not enough: `scripts/build_arcashla_reference.sh`
    // creates its output directory before it does any work, so a build that
    // aborted part-way (no network, not enough scratch space) leaves an empty
    // directory behind that satisfies the schema's existence check.
    // ARCASHLA_GENOTYPE then fails deep inside the run with arcasHLA's own
    // "FileNotFoundError: .../dat/ref/hla.p.json", which points at the
    // container rather than at the real problem. hla.idx (the kallisto index)
    // and hla.p.json are only ever produced by `arcasHLA reference` itself, so
    // requiring both here is a reliable "this is a real, built reference" test.
    //
    // Skipped for stub runs: -profile test points at
    // tests/fixtures/arcashla_reference_stub/, a deliberate placeholder that
    // exists only to satisfy the path checks, and no stub task reads a
    // reference at all.
    if (params.arcashla_reference_dir && !workflow.stubRun) {
        def missing = ['hla.idx', 'hla.p.json'].findAll { ref_file ->
            !file("${params.arcashla_reference_dir}/${ref_file}").exists()
        }
        if (missing) {
            error("Please check --arcashla_reference_dir -> Not a built arcasHLA reference, missing ${missing.join(', ')}: ${params.arcashla_reference_dir}\nBuild one with scripts/build_arcashla_reference.sh (this directory exists but has no IMGT/HLA + kallisto index in it).")
        }
    }
}

//
// Generate methods description for MultiQC
//
def toolCitationText() {
    // TODO nf-core: Optionally add in-text citation tools to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "Tool (Foo et al. 2023)" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def citation_text = [
            "Tools used in the workflow included:",
            "."
        ].join(' ').trim()

    return citation_text
}

def toolBibliographyText() {
    // TODO nf-core: Optionally add bibliographic entries to this list.
    // Can use ternary operators to dynamically construct based conditions, e.g. params["run_xyz"] ? "<li>Author (2023) Pub name, Journal, DOI</li>" : "",
    // Uncomment function in methodsDescriptionText to render in MultiQC report
    def reference_text = [
        ].join(' ').trim()

    return reference_text
}

def methodsDescriptionText(mqc_methods_yaml) {
    // Convert  to a named map so can be used as with familiar NXF ${workflow} variable syntax in the MultiQC YML file
    def meta = [:]
    meta.workflow = workflow.toMap()
    meta["manifest_map"] = workflow.manifest.toMap()

    // Pipeline DOI
    if (meta.manifest_map.doi) {
        // Using a loop to handle multiple DOIs
        // Removing `https://doi.org/` to handle pipelines using DOIs vs DOI resolvers
        // Removing ` ` since the manifest.doi is a string and not a proper list
        def temp_doi_ref = ""
        def manifest_doi = meta.manifest_map.doi.tokenize(",")
        manifest_doi.each { doi_ref ->
            temp_doi_ref += "(doi: <a href=\'https://doi.org/${doi_ref.replace("https://doi.org/", "").replace(" ", "")}\'>${doi_ref.replace("https://doi.org/", "").replace(" ", "")}</a>), "
        }
        meta["doi_text"] = temp_doi_ref.substring(0, temp_doi_ref.length() - 2)
    } else meta["doi_text"] = ""
    meta["nodoi_text"] = meta.manifest_map.doi ? "" : "<li>If available, make sure to update the text to include the Zenodo DOI of version of the pipeline used. </li>"

    // Tool references
    meta["tool_citations"] = ""
    meta["tool_bibliography"] = ""

    // TODO nf-core: Only uncomment below if logic in toolCitationText/toolBibliographyText has been filled!
    // meta["tool_citations"] = toolCitationText().replaceAll(", \\.", ".").replaceAll("\\. \\.", ".").replaceAll(", \\.", ".")
    // meta["tool_bibliography"] = toolBibliographyText()


    def methods_text = mqc_methods_yaml.text

    def engine =  new groovy.text.SimpleTemplateEngine()
    def description_html = engine.createTemplate(methods_text).make(meta)

    return description_html.toString()
}

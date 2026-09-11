#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  pipeline_testdata_run.sh [nextflow arguments...]

Runs the local nf-core/hlarnaseq testdata through Nextflow.

Environment:
  PROFILE            Optional Nextflow profile to use. Default: unset
  RUN_DIR            Directory for generated inputs, logs, work, and default results.
                     Default: <repo>/artifacts/testdata-run
  OUTDIR             Nextflow --outdir. Default: <RUN_DIR>/results
  NEXTFLOW_WORKDIR   Nextflow work directory. Default: <RUN_DIR>/nextflow.workdir
  NEXTFLOW_LOG       Nextflow log path. Default: <RUN_DIR>/testdata.log
  WGS_SAMPLESHEET    WGS samplesheet path (HLA-LA path, currently commented out).
                     Default: <repo>/assets/wgs_samples.csv
  ARRAY_SAMPLESHEET  SNP-array samplesheet path (HIBAG path).
                     Default: <repo>/assets/array_samples.csv
  HIBAG_MODEL        Pre-fit HIBAG model .RData. Default: the published
                     multi-locus model fetched by
                     testdata-make/11-download-hibag-model
  HIBAG_MATCH_TYPE   HIBAG SNP matching criterion. Default: Pos+Allele
  HLA_REGION         Region passed unchanged to samtools. Default: chr6:28500000-33400000

Genotype-side HLA calls come from HIBAG (SNP arrays) in this script. HLA-LA
(WGS) is the alternative and the two are mutually exclusive - its options are
left commented out below, because HLA-LA takes a long time to complete.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${RUN_DIR:-${ROOT_DIR}/artifacts/testdata-run}"
OUTDIR="${OUTDIR:-${RUN_DIR}/results}"
NEXTFLOW_WORKDIR="${NEXTFLOW_WORKDIR:-${RUN_DIR}/nextflow.workdir}"
NEXTFLOW_LOG="${NEXTFLOW_LOG:-${RUN_DIR}/testdata.log}"
RNA_SAMPLESHEET="${RNA_SAMPLESHEET:-${ROOT_DIR}/assets/rna_samples.csv}"
WGS_SAMPLESHEET="${WGS_SAMPLESHEET:-${ROOT_DIR}/assets/wgs_samples.csv}"
ARRAY_SAMPLESHEET="${ARRAY_SAMPLESHEET:-${ROOT_DIR}/assets/array_samples.csv}"
RNA_WGS_KEY="${RNA_WGS_KEY:-${ROOT_DIR}/assets/rna_wgs_key.csv}"
ARCASHLA_REF="${ROOT_DIR}/testdata-make/hlarnases-testdata/arcashla-ref"
# Only needed if the HLA-LA options below are uncommented.
HLALA_GRAPHS="${ROOT_DIR}/testdata-make/hlarnases-testdata/hla-la_graphs"

# The published multi-locus model (A, B, C, DRB1, DQA1, DQB1, DPB1) fetched by
# testdata-make/11-download-hibag-model. The model bundled with the HIBAG R
# package - this repo's test fixture - has HLA-A only, so falling back to it
# silently would report one locus and look like a HIBAG limitation.
HIBAG_MODEL="${HIBAG_MODEL:-${ROOT_DIR}/testdata-make/hlarnases-testdata/array/European-HLA4-hg19.RData}"
# The published models carry accurate hg19 positions but 2012-era rsIDs, many
# since merged or retired, so rsID matching finds only ~5% of each model's SNPs
# while Pos+Allele finds ~98%. The pipeline default (RefSNP+Position) is right
# for a model built against your own current manifest, not for these.
HIBAG_MATCH_TYPE="${HIBAG_MATCH_TYPE:-Pos+Allele}"

PROFILE="${PROFILE:-}"
HLA_REGION="${HLA_REGION:-chr6:28500000-33400000}"
HLAPM_DIR="${RUN_DIR}/HLApm/"
GTF="${ROOT_DIR}/testdata-make/hlarnases-testdata/reference/gencode.v50.primary_assembly.annotation.gtf.gz"
GTF_PATCHED="${ROOT_DIR}/testdata-make/hlarnases-testdata/reference/gencode.v50.primary_assembly.annotation.hla-unique.gtf.gz"

mkdir -p "${RUN_DIR}"

cd "${ROOT_DIR}"
echo "Running nf-core/hlarnaseq testdata"
echo "Profile: ${PROFILE:-<none>}"
echo "Run dir: ${RUN_DIR}"
echo "Outdir: ${OUTDIR}"
echo "Work dir: ${NEXTFLOW_WORKDIR}"
echo "Log: ${NEXTFLOW_LOG}"
echo "RNA_SAMPLESHEET: $RNA_SAMPLESHEET"
echo "ARRAY_SAMPLESHEET: $ARRAY_SAMPLESHEET"
echo "HIBAG_MODEL: $HIBAG_MODEL (--hibag_match_type ${HIBAG_MATCH_TYPE})"

if [ ! -s "${HIBAG_MODEL}" ]; then
    cat >&2 <<EOF
ERROR: HIBAG model not found: ${HIBAG_MODEL}

Fetch it with:
    testdata-make/11-download-hibag-model

That downloads the published model covering A, B, C, DRB1, DQA1, DQB1 and
DPB1. To run against a different model, set HIBAG_MODEL (and probably
HIBAG_MATCH_TYPE) explicitly.
EOF

    exit 1
fi

# if [ ! -d "$HLAPM_DIR" ]; then
#    git clone https://github.com/davenportlab/HLApm.git "$HLAPM_DIR"
# fi

if [ ! -s "$GTF_PATCHED" ]; then
   scripts/patch_gtf_gene_ids.py --gtf "$GTF" --patch gencodev50.mapping_patch.tsv | gzip > "$GTF_PATCHED"
fi


nextflow -log "${NEXTFLOW_LOG}" \
    run . \
    -work-dir "${NEXTFLOW_WORKDIR}" \
    -profile singularity \
    -resume \
    --gtf "$GTF_PATCHED" \
    --arcashla_reference_dir "$ARCASHLA_REF" \
    --rna_samples "${RNA_SAMPLESHEET}" \
    --hla_region "${HLA_REGION}" \
    --array_samples "${ARRAY_SAMPLESHEET}" \
    --hibag_model "${HIBAG_MODEL}" \
    --hibag_match_type "${HIBAG_MATCH_TYPE}" \
    --sample_key "$RNA_WGS_KEY" \
    --outdir "${OUTDIR}" \
    "$@"

# External HLApm repo is required only with Conda profile
# Container has the utility baked inside
#    --hlapm_repo "$HLAPM_DIR" \


# Genotype-side HLA calls come from HIBAG above. HLA-LA is the alternative:
# it takes a long time to complete, so it is disabled here.
#
# To use HLA-LA instead, remove the three --hibag_*/--array_samples options
# above and restore these two. They are mutually exclusive with --array_samples
# and the pipeline will refuse to start if both are given:
#
#     --wgs_samples "${WGS_SAMPLESHEET}" \
#     --hlala_graph_dir "$HLALA_GRAPHS"  \

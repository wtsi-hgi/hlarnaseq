#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/build_image_datatools.sh

Builds the shared python3 + R data-tools image locally, so the `container`
directive of every module that runs one of this pipeline's own bin/ analysis
scripts - or one of its small inline-shell data-shuffling steps - resolves with
no registry push required:

  HLA_CONSENSUS, HLAPM_PREPARE_INPUT, ARCASHLA_COMBINE, HLAPM_SUMMARIZE_READCOUNTS,
  HLA_READCOUNT_RECONCILE_DIFF, GTF_HLA_GENE_ID_CHECK,
  COUNTS_COMMONREF_HLA_REFORMAT, HLALA_COMBINE,
  HIBAG_COMBINE, HLAPM_COMBINE_GTF, HLAPM_LIST_STAR_TARGETS,
  HLAPM_RESOLVE_SAMPLE_ALLELES

  - Docker: builds and tags the image as IMAGE_TAG (default
    quay.io/hlarnaseq/datatools:1.1 - matching nextflow.config's
    docker.registry, so Docker finds it locally under -profile docker without
    ever attempting a network pull).
  - Singularity/Apptainer: if `singularity` or `apptainer` is also available,
    additionally converts that same local Docker image straight from the
    Docker daemon (docker-daemon://) into a .sif file at SIF_PATH (default
    containers/datatools/datatools.sif), which those modules reference by
    path - Singularity has no access to Docker's local image store, and a bare
    image name is not a filesystem path, so without this .sif Nextflow would
    try (and fail) to pull from quay.io over the network.

Unlike the other build_image_*.sh scripts here, this image is shared rather
than module-local; see containers/datatools/README.md. If you change
containers/datatools/environment.yml, bump IMAGE_TAG below AND the `container`
directive in all twelve modules above so a tag always means one set of contents.

Environment:
  IMAGE_TAG   Docker image reference to build/tag. Default: quay.io/hlarnaseq/datatools:1.1
  SIF_PATH    Output path for the converted Singularity image. Default: containers/datatools/datatools.sif
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER_DIR="${ROOT_DIR}/containers/datatools"
IMAGE_TAG="${IMAGE_TAG:-quay.io/hlarnaseq/datatools:1.1}"
SIF_PATH="${SIF_PATH:-${CONTAINER_DIR}/datatools.sif}"

command -v docker >/dev/null 2>&1 || {
    echo "ERROR: docker is required to build this image" >&2
    exit 127
}

echo "Building ${IMAGE_TAG} from ${CONTAINER_DIR} ..."
# --no-cache: a stale cached layer silently surviving an environment.yml change
# is a much more confusing failure mode than a slower rebuild.
docker build --no-cache -t "${IMAGE_TAG}" "${CONTAINER_DIR}"
echo "Built ${IMAGE_TAG}."

SIF_BUILDER=""
if command -v singularity >/dev/null 2>&1; then
    SIF_BUILDER="singularity"
elif command -v apptainer >/dev/null 2>&1; then
    SIF_BUILDER="apptainer"
fi

if [[ -n "${SIF_BUILDER}" ]]; then
    echo "Converting ${IMAGE_TAG} to ${SIF_PATH} with ${SIF_BUILDER} (from the local Docker daemon, no registry involved) ..."
    "${SIF_BUILDER}" build --force "${SIF_PATH}" "docker-daemon://${IMAGE_TAG}"
    echo "Built ${SIF_PATH}."
else
    echo "NOTE: neither singularity nor apptainer found on PATH - skipped building ${SIF_PATH}." >&2
    echo "      -profile singularity/apptainer will not work for those modules until this is built." >&2
fi

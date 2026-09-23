#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# This script FETCHES AND INDEXES A PUBLISHED PRG graph. It downloads the
# prebuilt PRG data package, verifies it, extracts it, and indexes it twice
# over:
#
#   1. `HLA-LA --action prepareGraph`, producing `serializedGRAPH` - exactly,
#      and only, what nf-core's `hlala/preparegraph` module does; and
#   2. `bwa index` over `extendedReferenceGenome/extendedReferenceGenome.fa`.
#
# Step 2 is not part of `prepareGraph`, and the published tarball does not ship
# it: `mapping_PRGonly/referenceGenome.fa` arrives pre-indexed but
# `extendedReferenceGenome/` contains the FASTA alone. HLA-LA therefore builds
# that index lazily, at typing time - see the comment on step 7 for why leaving
# it to do that breaks multi-sample runs. Both indexes together are what the
# pipeline needs.
#
# CONSTRUCTING a PRG graph from scratch (for a newer IMGT/HLA release, or for
# custom loci) is NOT the aim of the script.
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage:
  scripts/build_reference_hlala.sh <output-dir>

Fetches a published HLA-LA PRG graph package into <output-dir> and indexes it,
by running `HLA-LA --action prepareGraph` and then `bwa index` over the graph's
extended reference genome, inside the SAME pinned container image the
HLALA_TYPING module itself runs (hla-la 1.0.4) - so the graph is indexed by the
exact build that will later consume it, with no separate Conda environment to
set up. That image already contains the bwa the second step needs (bwa 0.7.12
is a dependency of the hla-la Conda package), so it needs no extra tooling.

Both indexes matter. HLA-LA builds the bwa index itself, lazily, the first time
it maps reads against the extended reference genome - writing it INTO the graph
directory. Since the pipeline shares one graph directory across every WGS
sample, all concurrent HLALA_TYPING tasks would start that same `bwa index` at
once and clobber each other's output, so all but (at most) one sample fails.
Building it here, once, out of band, removes the race.

Unlike arcasHLA's reference, this image is public (Biocontainers/Galaxy
depot), so there is no companion build_image_*.sh script: the container is
pulled on first use.

This script does NOT construct a graph from scratch - it downloads and indexes
a graph the HLA-LA authors published. Building a PRG graph from a newer
IMGT/HLA release is not scriptable outside the tool author's own environment
(see the comment block at the top of this file for the details). If you need a
newer graph, ask upstream.

What to expect before you start it:
  * ~2.25 GB download, and about 29 GB on disk once extracted and fully
    indexed (serializedGRAPH alone is ~5.5 GB, and the bwa index over the
    3 GB extended reference genome adds ~5.1 GB more). The free-space
    pre-flight below refuses up front rather than failing hours in.
  * prepareGraph takes a few hours and, per HLA-LA's own README, "might take
    up to 40G of memory"; `bwa index` over a 3 GB FASTA adds roughly another
    hour but is not memory-hungry. This is a one-off, out-of-band operation.

Point the pipeline at the result with (both values are printed on success):
  --hlala_graph_dir <output-dir> --hlala_graph <GRAPH_NAME>

Re-running is free: if the graph is already fully indexed, the script says so
and exits without downloading, extracting or indexing anything - it checks that
BEFORE the download, so pointing it at a finished graph costs nothing. Each
indexing step is skipped independently when its own output is already there, so
a graph built by an earlier version of this script (serializedGRAPH present,
bwa index missing) is repaired by just re-running the script on the same
directory: it adds the missing bwa index and neither re-downloads nor
re-serializes. To force a full rebuild, delete the graph directory
(<output-dir>/<GRAPH_NAME>) and re-run. That is deliberately the only way to do
it; there is no FORCE_* override (see the comment where the check is
implemented).

Environment:
  GRAPH_NAME    Graph directory name inside <output-dir>, and the value to pass
                to --hlala_graph. Default: PRG_MHC_GRCh38_withIMGT
  GRAPH_URL     Source tarball URL.
                Default: https://www.chg.ox.ac.uk/downloads/PRG_MHC_GRCh38_withIMGT.tar.gz
  GRAPH_MD5     Expected md5 of the tarball; `-` skips the check (not advised).
                Default: 525a8aa0c7f357bf29fe2c75ef1d477d
  TARBALL       Path to an already-downloaded tarball to use instead of
                fetching one (e.g. an offline/shared copy). Default: unset
  IMAGE_TAG     Docker image to run.
                Default: quay.io/biocontainers/hla-la:1.0.4--h077b44d_1
  SIF_PATH      Singularity/Apptainer image (local .sif path, or a URL to pull)
                used when Docker is unavailable.
                Default: https://depot.galaxyproject.org/singularity/hla-la:1.0.4--h077b44d_1
  REQUIRED_GB   Free-space floor, in GB, on <output-dir>'s filesystem.
                Default: 35

GRAPH_NAME/GRAPH_URL/GRAPH_MD5 exist so this script also works for the other
graph packages HLA-LA publishes, and so a future move of the download host
does not require editing it. They do not imply that new graphs can be
constructed.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || -z "${1:-}" ]]; then
    usage
    exit 0
fi

if [[ $# -gt 1 ]]; then
    echo "ERROR: expected exactly one argument (the output directory), got $#." >&2
    echo "       Run with --help for usage." >&2
    exit 1
fi

GRAPH_NAME="${GRAPH_NAME:-PRG_MHC_GRCh38_withIMGT}"
# The canonical location. HLA-LA's README still advertises
# http://www.well.ox.ac.uk/downloads/PRG_MHC_GRCh38_withIMGT.tar.gz, which
# 302-redirects here (verified 2026-08-26); `curl -L` below follows either, so
# both spellings work and neither needs to be special-cased.
GRAPH_URL="${GRAPH_URL:-https://www.chg.ox.ac.uk/downloads/PRG_MHC_GRCh38_withIMGT.tar.gz}"
# Documented in HLA-LA's README, and confirmed against an independently
# downloaded copy of the tarball.
GRAPH_MD5="${GRAPH_MD5:-525a8aa0c7f357bf29fe2c75ef1d477d}"
IMAGE_TAG="${IMAGE_TAG:-quay.io/biocontainers/hla-la:1.0.4--h077b44d_1}"
SIF_PATH="${SIF_PATH:-https://depot.galaxyproject.org/singularity/hla-la:1.0.4--h077b44d_1}"
REQUIRED_GB="${REQUIRED_GB:-35}"
TARBALL="${TARBALL:-}"

# The compiled binary, not the HLA-LA.pl wrapper: `--action prepareGraph` is a
# binary-level action, and this is the path nf-core's hlala/preparegraph module
# invokes in this same image.
HLALA_BIN="/usr/local/opt/hla-la/bin/HLA-LA"
# Unqualified on purpose: bwa arrives as a Conda dependency of hla-la, so it is
# on PATH inside the image, and HLA-LA itself locates it the same way (its
# find_path() falls through to `which bwa`). Hard-coding a prefix here would
# only add a way for the two to disagree.
BWA_BIN="bwa"

mkdir -p "$1" 2>/dev/null || {
    echo "ERROR: cannot create output directory '$1' - check the path and its permissions." >&2
    exit 1
}
OUTPUT_DIR="$(cd "$1" && pwd)"
if [[ ! -w "${OUTPUT_DIR}" ]]; then
    echo "ERROR: output directory ${OUTPUT_DIR} is not writable." >&2
    exit 1
fi
GRAPH_DIR="${OUTPUT_DIR}/${GRAPH_NAME}"

# Resolve the extended reference genome FASTA exactly the way HLA-LA's own
# binary does in its `--action HLA` path (src/HLA-LA.cpp): the path named on the
# first line of extendedReferenceGenomePath.txt when that file exists, and
# otherwise the conventional location inside the graph directory. Mirroring the
# tool's own resolution is the point - the file this script indexes has to be
# the file the tool will look for.
#
# `head -n 1 | tr -d '\r\n'` matches HLA-LA's Utilities::getFirstLine(), which
# strips the line terminator and nothing else - so a path containing spaces
# survives here just as it does there.
extended_reference_fasta() {
    if [[ -e "${GRAPH_DIR}/extendedReferenceGenomePath.txt" ]]; then
        head -n 1 "${GRAPH_DIR}/extendedReferenceGenomePath.txt" | tr -d '\r\n'
    else
        printf '%s' "${GRAPH_DIR}/extendedReferenceGenome/extendedReferenceGenome.fa"
    fi
}

# The three suffixes are HLA-LA's own definition of "indexed"
# (BWAmapper::ref_is_indexed(), src/mapper/bwa/BWAmapper.cpp): if any one of
# them is missing it runs `bwa index`. `bwa index` also writes .amb and .pac,
# but testing for those too would let this script's idea of "indexed" disagree
# with the tool's, which is the only thing that actually matters.
extended_reference_is_indexed() {
    local fasta="$1" suffix
    [[ -n "${fasta}" && -s "${fasta}" ]] || return 1
    for suffix in .sa .ann .bwt; do
        [[ -s "${fasta}${suffix}" ]] || return 1
    done
    return 0
}

# --------------------------------------------------------------------------
# 1. Already indexed? Then there is nothing to do.
#
# This runs FIRST, before any network access, so re-running the script against
# a finished graph is instant and cannot re-download 2.25 GB by accident.
#
# "Indexed" means BOTH indexing steps are done: serializedGRAPH from
# prepareGraph, and the bwa index over the extended reference genome. Testing
# serializedGRAPH alone - as this check used to - would make the bwa-index step
# unreachable for anyone who already has a serialized graph, which is precisely
# the population that needs it.
#
# There is deliberately no FORCE_REINDEX-style override: removing
# ${GRAPH_DIR} is already the obvious, sufficient and unambiguous way to force
# a rebuild, and a second mechanism would only add a way to half-overwrite an
# existing graph. Please don't re-add one.
# --------------------------------------------------------------------------
EXT_REF_FASTA="$(extended_reference_fasta)"

if [[ -s "${GRAPH_DIR}/serializedGRAPH" ]] && extended_reference_is_indexed "${EXT_REF_FASTA}"; then
    echo "Graph already indexed: ${GRAPH_DIR}/serializedGRAPH and the bwa index for"
    echo "${EXT_REF_FASTA} are both present and non-empty."
    echo "Nothing to download or index. To rebuild, remove ${GRAPH_DIR} and re-run."
    echo
    echo "Use it with: --hlala_graph_dir ${OUTPUT_DIR} --hlala_graph ${GRAPH_NAME}"
    exit 0
fi

# A graph left half-finished by an earlier version of this script (which did
# not build the bwa index at all), or by an interrupted run. Say so plainly,
# because from here on the script skips almost everything.
if [[ -s "${GRAPH_DIR}/serializedGRAPH" ]]; then
    echo "Graph at ${GRAPH_DIR} is serialized but its extended reference genome is not"
    echo "bwa-indexed. Only the missing bwa index will be built: nothing is downloaded,"
    echo "extracted, or re-serialized."
    echo
fi

# --------------------------------------------------------------------------
# 2. Pre-flight: fail on the cheap, obvious problems now rather than after a
#    2.25 GB download and a multi-hour index.
# --------------------------------------------------------------------------

# Resolve a container runtime. Docker first (if its daemon actually answers -
# the client alone being on PATH proves nothing), then Singularity/Apptainer,
# same shape and precedence as scripts/build_arcashla_reference.sh.
RUNTIME=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    RUNTIME="docker"
elif command -v singularity >/dev/null 2>&1; then
    RUNTIME="singularity"
elif command -v apptainer >/dev/null 2>&1; then
    RUNTIME="apptainer"
else
    echo "ERROR: no usable container runtime found - need a running Docker daemon, or singularity/apptainer on PATH." >&2
    echo "       The graph must be indexed by the pinned hla-la 1.0.4 image (${IMAGE_TAG})," >&2
    echo "       which is what HLALA_TYPING itself runs; there is no non-container path here." >&2
    exit 1
fi

# Free space on the output directory's own filesystem (df resolves the mount
# point for us, so this is correct whether OUTPUT_DIR is on / or on a
# separately mounted volume). POSIX `df -Pk` for portability; column 4 is the
# available space in 1 KB blocks.
AVAILABLE_KB="$(df -Pk "${OUTPUT_DIR}" | awk 'NR == 2 { print $4 }')"
REQUIRED_KB=$(( REQUIRED_GB * 1024 * 1024 ))
if [[ -z "${AVAILABLE_KB}" ]]; then
    echo "WARNING: could not determine free space on ${OUTPUT_DIR}; skipping the space check." >&2
elif (( AVAILABLE_KB < REQUIRED_KB )); then
    echo "ERROR: not enough free space on ${OUTPUT_DIR}'s filesystem." >&2
    echo "       Need ~${REQUIRED_GB} GB (2.25 GB tarball + ~29 GB extracted and indexed graph)," >&2
    echo "       have $(( AVAILABLE_KB / 1024 / 1024 )) GB." >&2
    echo "       Point <output-dir> at a larger filesystem, or override REQUIRED_GB if you know better." >&2
    exit 1
fi

# Memory is only a warning: HLA-LA's README says indexing "might take up to
# 40G of memory", but that is an upper bound from upstream rather than a
# measured hard requirement, so refusing outright would be wrong.
TOTAL_RAM_KB=""
if [[ -r /proc/meminfo ]]; then
    TOTAL_RAM_KB="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
elif command -v sysctl >/dev/null 2>&1; then
    TOTAL_RAM_KB="$(( $(sysctl -n hw.memsize) / 1024 ))"
fi
if [[ -n "${TOTAL_RAM_KB}" ]] && (( TOTAL_RAM_KB < 40 * 1024 * 1024 )); then
    echo "WARNING: this machine has $(( TOTAL_RAM_KB / 1024 / 1024 )) GB of RAM. HLA-LA's README says indexing" >&2
    echo "         \"can take a few hours and might take up to 40G of memory\". Proceeding anyway;" >&2
    echo "         if the container is killed by the OOM killer, that is why." >&2
fi

echo "Output directory : ${OUTPUT_DIR}"
echo "Graph            : ${GRAPH_NAME}"
echo "Container runtime: ${RUNTIME}"

# --------------------------------------------------------------------------
# 3. Fetch the graph package (unless we already have it, or were handed one).
# --------------------------------------------------------------------------

md5_of() {
    # md5sum on Linux, md5 on macOS; both print the digest as the first field
    # of their output once normalized.
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | awk '{ print $1 }'
    elif command -v md5 >/dev/null 2>&1; then
        md5 -q "$1"
    else
        echo "ERROR: neither md5sum nor md5 is available; set GRAPH_MD5=- to skip verification if you accept the risk." >&2
        return 1
    fi
}

SKIP_EXTRACT=""
if [[ -d "${GRAPH_DIR}" ]] && [[ -s "${GRAPH_DIR}/sequences.txt" ]]; then
    # An extracted-but-not-yet-indexed graph: a previous run was interrupted
    # during (or before) indexing. Skip straight to indexing rather than
    # re-downloading 2.25 GB to recreate files we already have.
    echo "Found an extracted but unindexed graph at ${GRAPH_DIR}; skipping download and extraction."
    SKIP_EXTRACT="yes"
fi

if [[ -z "${SKIP_EXTRACT}" ]]; then
    if [[ -n "${TARBALL}" ]]; then
        if [[ ! -s "${TARBALL}" ]]; then
            echo "ERROR: TARBALL=${TARBALL} does not exist or is empty." >&2
            exit 1
        fi
        echo "Using the tarball supplied via TARBALL: ${TARBALL} (no download)."
    else
        TARBALL="${OUTPUT_DIR}/$(basename "${GRAPH_URL}")"
        DOWNLOAD="yes"
        if [[ -s "${TARBALL}" && "${GRAPH_MD5}" != "-" ]] && [[ "$(md5_of "${TARBALL}")" == "${GRAPH_MD5}" ]]; then
            echo "Tarball already present and md5 matches: ${TARBALL} (no download)."
            DOWNLOAD=""
        fi
        if [[ -n "${DOWNLOAD}" ]]; then
            if ! command -v curl >/dev/null 2>&1; then
                echo "ERROR: curl is required to download ${GRAPH_URL}." >&2
                echo "       Alternatively, download it yourself and pass it via TARBALL=..." >&2
                exit 1
            fi
            echo "Downloading ${GRAPH_URL} -> ${TARBALL} (~2.25 GB) ..."
            # -L: the canonical URL has already moved host once (well.ox.ac.uk
            #     -> chg.ox.ac.uk) and still redirects.
            # -C -: resume a partial transfer instead of restarting 2.25 GB.
            # A non-zero exit here is NOT fatal on its own: curl also fails
            # when there is nothing left to resume (the server rejects the
            # range request on an already-complete file). The md5 check below
            # is the real gate - a genuinely truncated or missing file fails
            # there, loudly.
            if ! curl -fL --retry 5 --retry-delay 10 -C - -o "${TARBALL}" "${GRAPH_URL}"; then
                echo "NOTE: curl exited non-zero. If the file was already complete this is expected" >&2
                echo "      (nothing to resume); the md5 check below decides." >&2
            fi
        fi
    fi

    # ----------------------------------------------------------------------
    # 4. Verify the download before spending hours indexing it.
    # ----------------------------------------------------------------------
    if [[ ! -s "${TARBALL}" ]]; then
        echo "ERROR: ${TARBALL} is missing or empty after the download step - see the curl output above." >&2
        exit 1
    fi
    if [[ "${GRAPH_MD5}" == "-" ]]; then
        echo "WARNING: GRAPH_MD5=- , skipping the integrity check of ${TARBALL}." >&2
    else
        echo "Verifying md5 of ${TARBALL} ..."
        ACTUAL_MD5="$(md5_of "${TARBALL}")"
        if [[ "${ACTUAL_MD5}" != "${GRAPH_MD5}" ]]; then
            # Deliberately leave the file in place: it is either a truncated
            # download worth resuming, or the wrong/changed file worth looking
            # at. Silently deleting and retrying would hide both.
            echo "ERROR: md5 mismatch for ${TARBALL}" >&2
            echo "       expected ${GRAPH_MD5}" >&2
            echo "       actual   ${ACTUAL_MD5}" >&2
            echo "       The file has been left in place for inspection. Delete it to re-download from" >&2
            echo "       scratch, or set GRAPH_MD5 if you are intentionally using a different graph package." >&2
            exit 1
        fi
        echo "md5 OK (${ACTUAL_MD5})."
    fi

    # ----------------------------------------------------------------------
    # 5. Extract. The package's top-level directory is the graph directory.
    # ----------------------------------------------------------------------
    echo "Extracting ${TARBALL} into ${OUTPUT_DIR} ..."
    tar -xzf "${TARBALL}" -C "${OUTPUT_DIR}"
    if [[ ! -d "${GRAPH_DIR}" ]]; then
        echo "ERROR: expected ${GRAPH_DIR} to exist after extraction, but it does not." >&2
        echo "       The tarball's top-level directory is probably named something else -" >&2
        echo "       set GRAPH_NAME to match it (it is also the value you pass to --hlala_graph)." >&2
        exit 1
    fi
fi

# --------------------------------------------------------------------------
# 6. Index the graph, inside the container, exactly the way nf-core's
#    hlala/preparegraph module does.
#
#    prepareGraph WRITES INTO the graph directory (serializedGRAPH and
#    serializedGRAPH_preGapPathIndex land there), so the bind mount has to be
#    writable - it is the same reason the nf-core module stages its graph with
#    `stageInMode 'copy'`.
#
#    The output directory is mounted at its own host path, so the paths the
#    tool sees, logs and (if it ever serializes any) records are the same ones
#    that exist on the host.
# --------------------------------------------------------------------------

# Skipped when serializedGRAPH is already there, so a re-run that only needs
# the bwa index below does not redo a multi-hour serialization.
if [[ -s "${GRAPH_DIR}/serializedGRAPH" ]]; then
    echo
    echo "Skipping prepareGraph: ${GRAPH_DIR}/serializedGRAPH already exists and is non-empty."
else
    echo
    echo "Indexing ${GRAPH_DIR} with ${HLALA_BIN} --action prepareGraph (this takes a few hours) ..."
    case "${RUNTIME}" in
        docker)
            # -u: write serializedGRAPH as the invoking user, not root, so the
            # result is usable (and deletable) afterwards - the same fix
            # nextflow.config's docker profile applies via docker.runOptions.
            echo "+ docker run --rm -u $(id -u):$(id -g) -v ${OUTPUT_DIR}:${OUTPUT_DIR} ${IMAGE_TAG} ${HLALA_BIN} --action prepareGraph --PRG_graph_dir ${GRAPH_DIR}"
            docker run --rm \
                -u "$(id -u):$(id -g)" \
                -v "${OUTPUT_DIR}:${OUTPUT_DIR}" \
                "${IMAGE_TAG}" \
                "${HLALA_BIN}" --action prepareGraph --PRG_graph_dir "${GRAPH_DIR}"
            ;;
        singularity | apptainer)
            # Singularity/Apptainer run as the invoking host user already, so no
            # -u equivalent is needed; --bind is writable by default.
            echo "+ ${RUNTIME} exec --bind ${OUTPUT_DIR}:${OUTPUT_DIR} ${SIF_PATH} ${HLALA_BIN} --action prepareGraph --PRG_graph_dir ${GRAPH_DIR}"
            "${RUNTIME}" exec \
                --bind "${OUTPUT_DIR}:${OUTPUT_DIR}" \
                "${SIF_PATH}" \
                "${HLALA_BIN}" --action prepareGraph --PRG_graph_dir "${GRAPH_DIR}"
            ;;
    esac
fi

if [[ ! -s "${GRAPH_DIR}/serializedGRAPH" ]]; then
    echo "ERROR: ${GRAPH_DIR}/serializedGRAPH is missing or empty after indexing -" >&2
    echo "       check the output above for the actual failure and re-run." >&2
    exit 1
fi

# --------------------------------------------------------------------------
# 7. bwa-index the extended reference genome.
#
#    WHY THIS STEP EXISTS. `prepareGraph` does not build this index, and the
#    published tarball does not ship it: mapping_PRGonly/referenceGenome.fa
#    arrives with its .amb/.ann/.bwt/.pac/.sa, but extendedReferenceGenome/
#    contains the FASTA alone. HLA-LA copes by indexing it lazily - in the
#    `--action HLA` path, BWAmapper::map() calls make_sure_ref_is_indexed(),
#    which shells out to `bwa index` (src/mapper/bwa/BWAmapper.cpp) - and
#    writes the result NEXT TO THE FASTA, i.e. back into the graph directory.
#
#    That is fine for one sample at a time and broken for a pipeline. The graph
#    is a single shared, read-mostly input: HLALA_TYPING receives it as a
#    `path` input, so every per-sample task sees the same underlying directory.
#    Run N WGS samples and all N tasks find the index missing, all N launch
#    `bwa index` against the same paths, and they overwrite each other's
#    half-written output - so all but (at most) one sample fails, hours in, for
#    a reason that looks nothing like its cause.
#
#    Building it once here removes the race outright, and is why
#    hlalaGraphDirExistsError() in
#    subworkflows/local/utils_wtsihgi_hlarnaseq_pipeline/main.nf now refuses to
#    start a --wgs_samples run against a graph that lacks it.
#
#    `bwa index` takes no thread or memory options - there is nothing to size
#    to the host here, unlike prepareGraph.
# --------------------------------------------------------------------------

# Re-resolve: on a fresh run the graph directory did not exist when this was
# first computed, so extendedReferenceGenomePath.txt (if the package ships one)
# could not be read yet.
EXT_REF_FASTA="$(extended_reference_fasta)"

if [[ ! -s "${EXT_REF_FASTA}" ]]; then
    # Advisory, not fatal, for the same reason as the file-set loop below: the
    # exact layout differs between the graph packages HLA-LA publishes, and a
    # graph with no extended reference genome simply has no index to build.
    echo
    echo "WARNING: ${EXT_REF_FASTA} is missing or empty, so there is no extended reference" >&2
    echo "         genome to bwa-index. If this graph does use one, HLA-LA will try to index" >&2
    echo "         it at typing time and concurrent samples will race on it." >&2
elif extended_reference_is_indexed "${EXT_REF_FASTA}"; then
    echo
    echo "Skipping bwa index: ${EXT_REF_FASTA} already has its .sa, .ann and .bwt."
else
    echo
    echo "Building the bwa index for ${EXT_REF_FASTA} (~1 hour for a 3 GB FASTA) ..."
    # Mounted the same way as prepareGraph above. When
    # extendedReferenceGenomePath.txt points outside ${OUTPUT_DIR}, that path's
    # own directory has to be mounted as well, since the OUTPUT_DIR mount does
    # not cover it - and it has to be writable, because that is where the index
    # files land.
    EXT_REF_DIR="$(cd "$(dirname "${EXT_REF_FASTA}")" && pwd)"
    EXTRA_MOUNT=""
    if [[ "${EXT_REF_DIR}" != "${OUTPUT_DIR}" && "${EXT_REF_DIR}" != "${OUTPUT_DIR}/"* ]]; then
        echo "NOTE: ${EXT_REF_FASTA} lies outside ${OUTPUT_DIR} (via"
        echo "      extendedReferenceGenomePath.txt), so ${EXT_REF_DIR} is mounted too."
        if [[ ! -w "${EXT_REF_DIR}" ]]; then
            echo "ERROR: ${EXT_REF_DIR} is not writable, and bwa index writes its output there." >&2
            exit 1
        fi
        EXTRA_MOUNT="${EXT_REF_DIR}"
    fi

    case "${RUNTIME}" in
        docker)
            DOCKER_MOUNTS=(-v "${OUTPUT_DIR}:${OUTPUT_DIR}")
            [[ -n "${EXTRA_MOUNT}" ]] && DOCKER_MOUNTS+=(-v "${EXTRA_MOUNT}:${EXTRA_MOUNT}")
            echo "+ docker run --rm -u $(id -u):$(id -g) ${DOCKER_MOUNTS[*]} ${IMAGE_TAG} ${BWA_BIN} index ${EXT_REF_FASTA}"
            docker run --rm \
                -u "$(id -u):$(id -g)" \
                "${DOCKER_MOUNTS[@]}" \
                "${IMAGE_TAG}" \
                "${BWA_BIN}" index "${EXT_REF_FASTA}"
            ;;
        singularity | apptainer)
            SINGULARITY_BINDS=(--bind "${OUTPUT_DIR}:${OUTPUT_DIR}")
            [[ -n "${EXTRA_MOUNT}" ]] && SINGULARITY_BINDS+=(--bind "${EXTRA_MOUNT}:${EXTRA_MOUNT}")
            echo "+ ${RUNTIME} exec ${SINGULARITY_BINDS[*]} ${SIF_PATH} ${BWA_BIN} index ${EXT_REF_FASTA}"
            "${RUNTIME}" exec \
                "${SINGULARITY_BINDS[@]}" \
                "${SIF_PATH}" \
                "${BWA_BIN}" index "${EXT_REF_FASTA}"
            ;;
    esac

    if ! extended_reference_is_indexed "${EXT_REF_FASTA}"; then
        echo "ERROR: ${EXT_REF_FASTA} still lacks one of .sa, .ann or .bwt after bwa index -" >&2
        echo "       check the output above for the actual failure and re-run." >&2
        exit 1
    fi
fi

# --------------------------------------------------------------------------
# 8. Verify the result, then print what to hand the pipeline.
# --------------------------------------------------------------------------

# Advisory only: these are the files HLA-LA.pl itself looks for at typing
# time, so flagging them now beats a confusing failure on the first real
# sample. Not fatal, because the exact file set differs between the graph
# packages HLA-LA publishes, and the serializedGRAPH and bwa-index checks above
# are the ones that actually prove indexing succeeded.
for expected in sequences.txt knownReferences extendedReferenceGenome; do
    if [[ ! -e "${GRAPH_DIR}/${expected}" ]]; then
        echo "WARNING: ${GRAPH_DIR}/${expected} is missing. HLA-LA.pl checks for it when typing," >&2
        echo "         so this graph may be incomplete." >&2
    fi
done

echo
echo "Indexed HLA-LA graph at ${GRAPH_DIR}."
echo "Use it with: --hlala_graph_dir ${OUTPUT_DIR} --hlala_graph ${GRAPH_NAME}"

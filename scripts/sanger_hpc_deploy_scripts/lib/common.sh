# Shared helpers for the Sanger HPC deploy wrappers in ../module_executables/.
#
# This file is SOURCED, never executed. It is the single place that knows:
#   - where the pipeline checkout lives, relative to this file;
#   - which site values come from site.env;
#   - which NXF_*/SINGULARITY_* variables a run needs;
#   - how the `nextflow run` command line is assembled.
#
# The yascp scripts this deployment is adapted from duplicate all of that across
# ten near-identical files, which is how they drifted out of step with each
# other. Keep new wrappers thin and put shared logic here.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: lib/common.sh is meant to be sourced by a wrapper, not executed." >&2
    exit 64
fi

# ---------------------------------------------------------------------------
# Locate the pipeline
# ---------------------------------------------------------------------------

# Resolve symlinks where possible: the module executables may be reached through
# a symlink farm rather than directly on PATH, and a wrong PIPELINE_DIR would
# silently run the wrong checkout.
_hlarnaseq_realpath() {
    if readlink -f / >/dev/null 2>&1; then
        readlink -f -- "$1"
    else
        local dir base
        dir="$(dirname -- "$1")"
        base="$(basename -- "$1")"
        printf '%s/%s\n' "$(cd -- "${dir}" && pwd -P)" "${base}"
    fi
}

_HLARNASEQ_COMMON_SH="$(_hlarnaseq_realpath "${BASH_SOURCE[0]}")"
# <deploy>/lib/common.sh -> <deploy>
DEPLOY_DIR="$(cd -- "$(dirname -- "${_HLARNASEQ_COMMON_SH}")/.." && pwd -P)"
# <repo>/scripts/sanger_hpc_deploy_scripts -> <repo>
PIPELINE_DIR="$(cd -- "${DEPLOY_DIR}/../.." && pwd -P)"

if [[ ! -f "${PIPELINE_DIR}/main.nf" || ! -f "${PIPELINE_DIR}/nextflow.config" ]]; then
    cat >&2 <<EOF
ERROR: cannot find the wtsi-hgi/hlarnaseq checkout.

Expected main.nf and nextflow.config in:
    ${PIPELINE_DIR}

These wrappers derive that path from their own location, so this means the
deploy tree was copied out of the pipeline repository. Install the whole
repository and point the modulefile at it; do not copy
scripts/sanger_hpc_deploy_scripts/ on its own.
EOF
    exit 78
fi

export PIPELINE_DIR DEPLOY_DIR

# ---------------------------------------------------------------------------
# Site configuration
# ---------------------------------------------------------------------------

# site.env is the one file a deployer edits. It is optional: with no site.env
# the wrappers still work, they just leave Nextflow's own defaults in place
# (in particular they do not invent a container cache directory).
HLARNASEQ_SITE_ENV="${HLARNASEQ_SITE_ENV:-${DEPLOY_DIR}/site.env}"
if [[ -r "${HLARNASEQ_SITE_ENV}" ]]; then
    # shellcheck disable=SC1090  # path is deploy-specific by design
    source "${HLARNASEQ_SITE_ENV}"
fi

# Defaults for everything site.env may set. A value already in the environment
# always wins over site.env, and site.env wins over these.
HLARNASEQ_PROFILE="${HLARNASEQ_PROFILE:-singularity,sanger}"
HLARNASEQ_QUEUE="${HLARNASEQ_QUEUE:-oversubscribed}"
HLARNASEQ_MEM_MB="${HLARNASEQ_MEM_MB:-4800}"
HLARNASEQ_JAVA_OPTS="${HLARNASEQ_JAVA_OPTS:--Xms1G -Xmx4G}"

# ---------------------------------------------------------------------------
# Launcher tools
# ---------------------------------------------------------------------------

# Per AGENTS.md, the launcher environment is the ONLY environment these scripts
# may expect a tool from, and nextflow/bsub are launcher tools. Every pipeline
# tool comes from its own module's conda/container directive, so nothing here
# ever puts a pipeline tool on PATH or falls back to one that happens to exist.
hlarnaseq_require_launcher() {
    local tool="$1" hint="$2"
    if ! command -v "${tool}" >/dev/null 2>&1; then
        cat >&2 <<EOF
ERROR: '${tool}' is not on PATH.

${hint}

This is a launcher tool. Pipeline tools are never taken from your environment -
each process declares its own conda/container - so this is the one class of
missing command you fix on the host side.
EOF
        exit 127
    fi
}

# ---------------------------------------------------------------------------
# Run environment
# ---------------------------------------------------------------------------

hlarnaseq_export_nextflow_env() {
    export NXF_OPTS="${NXF_OPTS:-${HLARNASEQ_JAVA_OPTS}}"
    # Default is 5s, which is far too chatty for a run measured in days.
    export NXF_MONITOR_DUMP_INTERVAL="${NXF_MONITOR_DUMP_INTERVAL:-60s}"

    if [[ -n "${HLARNASEQ_SINGULARITY_CACHEDIR:-}" ]]; then
        export NXF_SINGULARITY_CACHEDIR="${NXF_SINGULARITY_CACHEDIR:-${HLARNASEQ_SINGULARITY_CACHEDIR}}"
    fi

    # Cluster /tmp is small and node-local; image extraction and sort spills
    # belong on the same (shared, roomy) filesystem as the work directory.
    # NXF_WORK is honoured; a -work-dir passed on the command line is not
    # visible here, so set NXF_WORK (or TMPDIR) if your work directory lives on
    # a different filesystem from the one you launch in.
    local tmp="${NXF_WORK:-${PWD}/work}/tmp"
    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        mkdir -p "${tmp}"
    fi
    export SINGULARITY_TMPDIR="${SINGULARITY_TMPDIR:-${tmp}}"
    export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-${tmp}}"
    export TMPDIR="${TMPDIR:-${tmp}}"
    export TEMP="${TEMP:-${tmp}}"
}

# ---------------------------------------------------------------------------
# Command assembly
# ---------------------------------------------------------------------------

_hlarnaseq_has_profile_arg() {
    local arg
    for arg in "$@"; do
        if [[ "${arg}" == "-profile" || "${arg}" == -profile=* ]]; then
            return 0
        fi
    done
    return 1
}

# Populates the HLARNASEQ_CMD array with the full command to run.
#
# -profile is injected only when the caller did not pass one of their own, so
# `hlarnaseq -profile conda ...` works and never ends up with two -profile
# options on one command line.
#
# Set HLARNASEQ_NXF_LOG to place the Nextflow log somewhere other than
# ./.nextflow.log; it has to go before `run`, hence the two-stage build.
hlarnaseq_nextflow_cmd() {
    HLARNASEQ_CMD=(nextflow)
    if [[ -n "${HLARNASEQ_NXF_LOG:-}" ]]; then
        HLARNASEQ_CMD+=(-log "${HLARNASEQ_NXF_LOG}")
    fi
    HLARNASEQ_CMD+=(run "${PIPELINE_DIR}")
    if ! _hlarnaseq_has_profile_arg "$@"; then
        HLARNASEQ_CMD+=(-profile "${HLARNASEQ_PROFILE}")
    fi
    HLARNASEQ_CMD+=("$@")
}

# Print a command array in a form that can be pasted back into a shell.
#
# Only arguments that actually need quoting get it: printf '%q' would render
# -profile singularity,sanger as singularity\,sanger, which is correct but reads
# like a mistake in output users are meant to copy.
hlarnaseq_print_cmd() {
    local arg out=""
    for arg in "$@"; do
        if [[ -n "${arg}" && "${arg}" != *[^[:alnum:]_@%+=:,./-]* ]]; then
            out+=" ${arg}"
        else
            out+=" $(printf '%q' "${arg}")"
        fi
    done
    printf '%s\n' "${out# }"
}

hlarnaseq_pipeline_version() {
    local branch commit version
    branch="$(git -C "${PIPELINE_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    commit="$(git -C "${PIPELINE_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
    # From the manifest rather than a hardcoded string, so it cannot go stale.
    version="$(sed -n "s/^[[:space:]]*version[[:space:]]*=[[:space:]]*'\(.*\)'.*/\1/p" \
        "${PIPELINE_DIR}/nextflow.config" | head -n 1)"
    cat <<EOF
wtsi-hgi/hlarnaseq ${version:-unknown}
install: ${PIPELINE_DIR}
branch:  ${branch}
commit:  ${commit}
EOF
}

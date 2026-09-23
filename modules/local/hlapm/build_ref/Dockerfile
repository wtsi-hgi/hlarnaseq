# wtsi-hgi/hlarnaseq: HLAPM_BUILD_REF container image.
#
# Installs the R stack declared in this module's environment.yml AND bakes in
# HLApm itself at a pinned commit.
#
# Why bake the tool in: HLApm (https://github.com/davenportlab/HLApm) is an
# unpackaged lab git repository, not a Conda/PyPI package - there is nothing
# for `conda install` to fetch. It is also small enough to live inside the
# image (~129 MB, of which ~59 MB is the bundled data/references/ tree it
# reads at runtime), unlike the arcasHLA IMGT/HLA reference next door, which
# is a ~4 GB clone and is therefore built out of band instead
# (see modules/local/arcashla/genotype/Dockerfile).
#
# The clone is pinned by commit, not branch: HLApm publishes no releases or
# tags, so a commit SHA is the only reproducible handle on a version. Override
# it with --build-arg HLAPM_COMMIT=<sha> (scripts/build_image_hlapm.sh passes
# $HLAPM_COMMIT through) to build an image against a different HLApm.
FROM mambaorg/micromamba:1.5.8

ARG MAMBA_DOCKERFILE_ACTIVATE=1

# github.com/davenportlab/HLApm HEAD as of 2025-06-17 ("Update README.md").
ARG HLAPM_COMMIT=38faa6087bbd827ccab969d947f8df101e95d688

COPY --chown=$MAMBA_USER:$MAMBA_USER environment.yml /tmp/environment.yml
RUN micromamba install -y -n base -f /tmp/environment.yml \
    && micromamba clean --all --yes

# The micromamba base image only puts this environment on PATH via an
# entrypoint script that wraps whatever command `docker run` is given.
# Singularity/Apptainer's `exec` (what Nextflow actually uses to run tasks)
# does not honor a Docker image's ENTRYPOINT at all, and neither does
# Nextflow's own task-runner script under either engine - both exec commands
# directly, bypassing that wrapper entirely. Without this, Rscript and the
# R libraries this environment provides are installed but unreachable under
# -profile singularity/apptainer. Set before the clone below so that `git`
# also resolves in the root-owned build step, which the entrypoint's
# per-user activation does not cover.
ENV PATH="${MAMBA_ROOT_PREFIX}/bin:${PATH}"

# /opt is root-owned and this base image runs as $MAMBA_USER, so the clone
# needs root; dropped back immediately afterwards.
USER root

# Fetch just the pinned commit rather than cloning full history: HLApm's
# data/references/ blobs make a full clone considerably larger than the
# working tree, and none of that history is used.
#
# .git is then dropped (the image records its version in HLApm.version
# instead, which main.nf reads) and the tree is made world-readable:
# Singularity/Apptainer runs the container process as whichever host user
# invoked it, not as $MAMBA_USER who would otherwise own these files.
# Read-only is sufficient - HLApm only ever reads from this directory on the
# reference-building path (all data/references/*.gz loads in
# scripts/load_ref.R), so no writable overlay is needed at runtime.
RUN mkdir -p /opt/HLApm \
    && cd /opt/HLApm \
    && git init -q . \
    && git remote add origin https://github.com/davenportlab/HLApm.git \
    && git fetch -q --depth 1 origin "${HLAPM_COMMIT}" \
    && git checkout -q FETCH_HEAD \
    && rm -rf /opt/HLApm/.git \
    && printf '%s\n' "${HLAPM_COMMIT}" > /opt/HLApm/HLApm.version \
    && chmod -R a+rX /opt/HLApm

USER $MAMBA_USER

# Fail the build rather than ship an image whose HLApm is missing the
# reference data main.nf's R script loads on every run, or whose R stack
# cannot load what HLApm's scripts/load_ref.R declares. Runs as $MAMBA_USER,
# so it also proves the tree is readable by a non-owner - which is how
# Singularity/Apptainer will read it, running as the invoking host user.
RUN test -s /opt/HLApm/scripts/load_ref.R \
    && test -s /opt/HLApm/data/references/hg38/chr6.fa.gz \
    && Rscript -e 'library(seqinr); library(Biostrings); library(stringr); library(DECIPHER); library(data.table); library(dplyr)'

# main.nf defaults HLAPM_HOME to this path when no --hlapm_repo override is
# staged; set here too so the image is usable interactively (e.g. debugging
# with `docker run -it <tag> Rscript ...`) without repeating the path.
ENV HLAPM_HOME="/opt/HLApm"

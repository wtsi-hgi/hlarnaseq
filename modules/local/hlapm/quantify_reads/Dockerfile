# wtsi-hgi/hlarnaseq: HLAPM_QUANTIFY_READS container image.
#
# Installs the pinned Python 2.7 stack declared in this module's
# environment.yml - nothing else. See that file for why Python 2.7.15, why
# pybam is pinned by commit, and why quicksect is deliberately absent.
#
# PYBAM_COMMIT is duplicated here as a build arg so the pin can be overridden
# at build time without editing environment.yml (scripts/build_image_hlapm_quantify.sh
# passes $PYBAM_COMMIT through). It defaults to the same commit environment.yml
# pins, and the two must be kept in step: environment.yml is what -profile conda
# installs, this arg is what the image installs.
FROM mambaorg/micromamba:1.5.8

ARG MAMBA_DOCKERFILE_ACTIVATE=1

# github.com/JohnLonginotto/pybam HEAD as of 2026-09-04; matches environment.yml.
ARG PYBAM_COMMIT=846d98603905c57c31bf7b9abaf2eb8c89899e60

COPY --chown=$MAMBA_USER:$MAMBA_USER environment.yml /tmp/environment.yml
RUN micromamba install -y -n base -f /tmp/environment.yml \
    && micromamba clean --all --yes

# Re-install pybam from PYBAM_COMMIT when it differs from the commit
# environment.yml already installed above, so --build-arg actually takes
# effect. A no-op for the default build.
RUN if [ "${PYBAM_COMMIT}" != "846d98603905c57c31bf7b9abaf2eb8c89899e60" ]; then \
        python -m pip install --no-cache-dir --force-reinstall \
            "https://github.com/JohnLonginotto/pybam/archive/${PYBAM_COMMIT}.zip"; \
    fi

# The micromamba base image only puts this environment on PATH via an
# entrypoint script that wraps whatever command `docker run` is given.
# Singularity/Apptainer's `exec` (what Nextflow actually uses to run tasks)
# does not honor a Docker image's ENTRYPOINT at all, and neither does
# Nextflow's own task-runner script under either engine - both exec commands
# directly, bypassing that wrapper entirely. Without this, python2 and the
# packages this environment provides are installed but unreachable under
# -profile singularity/apptainer.
ENV PATH="${MAMBA_ROOT_PREFIX}/bin:${PATH}"

# Recorded so the running task can report exactly which pybam it carries;
# main.nf reads this for versions.yml (pybam itself reports only "1.0",
# unchanged across commits).
ENV PYBAM_COMMIT="${PYBAM_COMMIT}"

# Fail the build rather than ship an image whose interpreter or imports are
# wrong. Runs as $MAMBA_USER, which is also how Singularity/Apptainer will read
# the environment (as the invoking host user, not the image's owner).
RUN python2 --version 2>&1 | grep -q '^Python 2\.7\.' \
    && python2 -c "import pybam, intervaltree, sortedcontainers; print('imports ok')"

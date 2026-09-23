# wtsi-hgi/hlarnaseq: ARCASHLA_GENOTYPE container image.
#
# Installs the same pinned arcasHLA + kallisto versions declared in this
# module's environment.yml. That's all - it deliberately does NOT build the
# arcasHLA IMGT/HLA + kallisto reference here.
#
# Why: arcasHLA has no option to point `genotype` at an external reference
# database at runtime - whatever reference exists inside its own install
# (share/arcas-hla-*/dat/ref) is the one used - but building it
# (`arcasHLA reference`) clones the ~4GB github.com/ANHIG/IMGTHLA database,
# which is slow and a poor fit for an automated image build (a transient
# network hiccup fails the whole build). Instead, main.nf symlinks
# dat/ref to an externally-supplied --arcashla_reference_dir at task runtime
# (the same pattern this pipeline already uses for HLA-LA's
# --hlala_graph_dir), and scripts/build_arcashla_reference.sh builds that
# directory once, out of band, using this same image.
FROM mambaorg/micromamba:1.5.8

ARG MAMBA_DOCKERFILE_ACTIVATE=1

COPY --chown=$MAMBA_USER:$MAMBA_USER environment.yml /tmp/environment.yml
RUN micromamba install -y -n base -f /tmp/environment.yml \
    && micromamba clean --all --yes

# The arcas-hla package ships dat/ref pre-populated with some baseline
# files (allele_groups.json, cDNA JSONs, tiny placeholder GRCh38.*.fasta
# stubs - never hla.idx/hla.fasta/hla.convert.json/hla_partial.*, which only
# `arcasHLA reference` produces); main.nf never reads these, so they're
# removed here. More importantly: Singularity/Apptainer runs the container
# process as whichever host user invoked it, not as $MAMBA_USER who owns
# these files by default, so main.nf's runtime `rm -rf`/`ln -s` symlink
# swap (see main.nf) would otherwise fail with "Permission denied"
# regardless of --writable-tmpfs (conf/modules.config) making the
# filesystem itself writable - chmod here makes dat/ writable by any UID,
# sidestepping the need to match a specific one at runtime.
RUN ARCASHLA_HOME="$(find "${MAMBA_ROOT_PREFIX}/share" -maxdepth 1 -iname 'arcas-hla-*' -type d | head -n1)" \
    && rm -rf "${ARCASHLA_HOME}/dat/ref"/* \
    && chmod -R a+rwX "${ARCASHLA_HOME}/dat"

# The micromamba base image only puts this environment on PATH via an
# entrypoint script that wraps whatever command `docker run` is given.
# Singularity/Apptainer's `exec` (what Nextflow actually uses to run tasks)
# does not honor a Docker image's ENTRYPOINT at all, and neither does
# Nextflow's own task-runner script under either engine - both exec
# commands directly, bypassing that wrapper entirely. Without this, tools
# this environment provides (arcasHLA, kallisto, git, ps, ...) are
# installed but unreachable under -profile singularity/apptainer.
ENV PATH="${MAMBA_ROOT_PREFIX}/bin:${PATH}"

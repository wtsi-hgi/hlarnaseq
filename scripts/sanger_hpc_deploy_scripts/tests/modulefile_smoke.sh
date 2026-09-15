#!/usr/bin/env bash
# Smoke-test the modulefile's Tcl without an Environment Modules installation.
#
# Evaluates ../sanger_module_files/<version> and then invokes ModulesHelp, with
# the Modules commands stubbed out. This catches Tcl errors - the one that
# prompted this script was `module help` failing with
#
#     Module ERROR: can't read "install": no such variable
#
# because Tcl procs do not see top-level variables unless the proc declares
# them `global`. That class of bug is invisible to review and to `module load`
# (ModulesHelp runs only for `module help`), but it is caught here in a second.
#
# What this does NOT check is Modules-specific semantics: whether
# `module-info version` returns what the file expects, or whether prepend-path
# and `module load` behave as intended in the real module hierarchy. Run
# `module help <name>` and `module load <name>` on the cluster for that.
#
# Usage:
#   tests/modulefile_smoke.sh [modulefile ...]   # default: every file in ../sanger_module_files/
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)"
DEPLOY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

if ! command -v tclsh >/dev/null 2>&1; then
    echo "SKIP: tclsh is not on PATH, cannot evaluate the modulefile." >&2
    echo "      It ships with the nf-core launcher environment, or install tcl." >&2
    exit 0
fi

if [[ $# -gt 0 ]]; then
    MODULEFILES=("$@")
else
    mapfile -t MODULEFILES < <(find "${DEPLOY_DIR}/sanger_module_files" -type f | sort)
fi

if [[ ${#MODULEFILES[@]} -eq 0 ]]; then
    echo "ERROR: no modulefiles found under ${DEPLOY_DIR}/sanger_module_files" >&2
    exit 78
fi

HARNESS="$(mktemp)"
trap 'rm -f "${HARNESS}"' EXIT

cat >"${HARNESS}" <<'TCL'
# Minimal stand-ins for the Modules commands a modulefile may call, so its Tcl
# can be evaluated and ModulesHelp invoked the way `module help` does.
proc module-info {what args} {
    switch -- $what {
        name    { return "hlarnaseq/0.0-smoketest" }
        version { return [lindex $args 0] }
        mode    { return "help" }
        default { return "" }
    }
}
proc module-whatis {args} {}
proc prepend-path {args} {}
proc append-path {args} {}
proc setenv {args} {}
proc module {args} {}
proc conflict {args} {}
proc prereq {args} {}

source [lindex $argv 0]
if {[info procs ModulesHelp] eq ""} {
    puts stderr "no ModulesHelp proc defined"
    exit 1
}
ModulesHelp
TCL

failed=0
for mf in "${MODULEFILES[@]}"; do
    printf '== %s\n' "${mf}"
    if out="$(tclsh "${HARNESS}" "${mf}" 2>&1)"; then
        # ModulesHelp writes to stderr, which is captured above; show it
        # indented so a human can eyeball the rendered help text too.
        printf '%s\n' "${out}" | sed 's/^/   | /'
        echo "   PASS"
    else
        printf '%s\n' "${out}" | sed 's/^/   | /'
        echo "   FAIL"
        failed=1
    fi
done

if [[ "${failed}" -ne 0 ]]; then
    echo "modulefile smoke test FAILED" >&2
    exit 1
fi
echo "modulefile smoke test passed"

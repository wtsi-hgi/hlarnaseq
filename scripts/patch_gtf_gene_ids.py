#!/usr/bin/env python3
"""
Rename or remove genes in a GTF, addressed by gene_id, and print the result.

Why this exists
---------------
The HLApm utility constructs personal references using HLA gene name.
Therefore, to reconcile initial featurecouns table,
we need a GTF file that carries a one-to-one gene_name <-> gene_id mapping in the HLA region.
Stock gencode.v50.primary_assembly.annotation.gtf.gz CONTAINS non-unique mappings.
This script applies a small patch file to the original GTF and
produces deduplicated GTF for the pipeline.

Patch file format
-----------------
Two-column TSV; the second column is optional per row.
Blank lines, lines starting with "#",
and an optional "gene_id<TAB>new_gene_name" header row are ignored.

  1  gene_id        matched exactly against the row's gene_id attribute,
                    version suffix included (ENSG00000206341.7, not
                    ENSG00000206341)
  2  new_gene_name  optional; absent, empty, or whitespace-only all mean
                    "remove this gene"

The rule
--------
For every GTF row, read its gene_id attribute:

  gene_id NOT in the patch     -> emit the row unchanged, byte for byte
  gene_id in the patch, col 2  -> rename: rewrite this row's gene_name
  gene_id in the patch, no col 2 -> remove: drop this row

Because the rule is keyed on the row's own gene_id, it reaches a whole gene
automatically: gene, transcript, exon, CDS, UTR, etc.

Exit status
-----------
0  the patched GTF was written to stdout
2  an input could not be used: --patch is malformed (bad row, duplicate
   gene_id, unusable name), or --gtf/--patch could not be read
3  --patch does not match --gtf (a listed gene_id is not in the file)
"""

import argparse
import gzip
import re
import signal
import sys

description = (
    "Rename or remove genes in a GTF, addressed by gene_id, from a two-column "
    "patch TSV, and print the patched GTF to stdout. See module docstring for "
    "the patch format, the exact rule, and exit statuses."
)

# gene_id "X"; and gene_name "X"; as GTF attribute tokens. The gene_name
# pattern keeps the surrounding literal text in groups 1 and 3 so a rename can
# splice a new value in without disturbing quoting, spacing or attribute order.
_GENE_ID_RE = re.compile(r'gene_id\s+"([^"]*)"')
_GENE_NAME_RE = re.compile(r'(gene_name\s+")([^"]*)(")')

# A gene_name is written into a quoted GTF attribute, so it cannot contain a
# double quote; tabs and newlines would break the column structure.
_BAD_NAME_CHARS = ('"', "\t", "\n", "\r")

ACTION_RENAME = "rename"
ACTION_REMOVE = "remove"

def open_maybe_gzip(path, mode="rt"):
    return gzip.open(path, mode) if path.endswith(".gz") else open(path, mode)

def parse_patch(patch_path):
    """
    Read --patch into an insertion-ordered {gene_id: new_gene_name or None}.
    None means "remove".
    """
    patch = {}
    header_allowed = True

    with open(patch_path, "rt") as handle:
        for lineno, raw_line in enumerate(handle, start=1):
            line = raw_line.rstrip("\n").rstrip("\r")
            if not line.strip() or line.lstrip().startswith("#"):
                continue

            fields = line.split("\t")
            # Skipping optional first line
            if header_allowed:
                header_allowed = False
                if fields[0].strip() == "gene_id":
                    continue

            if len(fields) > 2:
                raise ValueError(
                    f"{patch_path}:{lineno}: expected at most 2 tab-separated "
                    f"columns (gene_id, new_gene_name), found {len(fields)}. "
                    "A 3-column gene_name/gene_id/new_gene_name patch is the "
                    "older format and is not accepted: drop the gene_name "
                    "column and keep only the rows that actually change."
                )

            gene_id = fields[0].strip()
            if not gene_id:
                raise ValueError(f"{patch_path}:{lineno}: empty gene_id in column 1")

            if gene_id in patch:
                raise ValueError(
                    f"{patch_path}:{lineno}: gene_id {gene_id} is listed more "
                    "than once; one gene_id cannot be both renamed and removed, "
                    "or renamed twice"
                )

            new_name = fields[1].strip() if len(fields) > 1 else ""
            if not new_name:
                patch[gene_id] = None
                continue

            bad = [char for char in _BAD_NAME_CHARS if char in new_name]
            if bad:
                raise PatchError(
                    f"{patch_path}:{lineno}: new_gene_name {new_name!r} contains "
                    f"a character that cannot appear in a GTF attribute: {bad!r}"
                )

            patch[gene_id] = new_name

    if not patch:
        raise ValueError(f"{patch_path}: no patch rows (only comments or blank lines)")

    return patch


def scan_gtf(gtf_path, patch):
    """
    First pass of the GTF file: find out which patched gene_ids are really in --gtf,
    and which gene_name each one currently carries.

    Also builds gene_name -> {gene_id} over `gene` rows only, so a rename onto
    a name some other gene already owns can be warned about before it is made.
    Only `gene` rows contribute, so a gene's own transcript/exon rows
    never look like a second owner of its name.

    Costs a second read of --gtf. That is deliberate: the alternative is
    discovering a stale patch halfway through writing, which would leave a
    truncated GTF on stdout looking like a successful result.
    """
    current_names = {}
    name_owners = {}

    with open_maybe_gzip(gtf_path, "rt") as handle:
        for line in handle:
            if line.startswith("#"):
                # Skip header lines
                continue

            gene_id_match = _GENE_ID_RE.search(line)
            if gene_id_match is None:
                # Skip lines without gene name
                continue
            gene_id = gene_id_match.group(1)

            if gene_id in patch and gene_id not in current_names:
                # Adding pair gene_id -> gene_name
                gene_name_match = _GENE_NAME_RE.search(line)
                current_names[gene_id] = gene_name_match.group(2) if gene_name_match else None

            fields = line.split("\t")
            if len(fields) >= 3 and fields[2] == "gene":
                # We analyze only gene lines
                gene_name_match = _GENE_NAME_RE.search(line)
                if gene_name_match is not None:
                    name = gene_name_match.group(2)
                    if name not in name_owners:
                        name_owners[name] = set()
                    name_owners[name].add(gene_id)

    return current_names, name_owners


def missing_gene_ids(patch, current_names):
    """
    Patched gene_ids that --gtf does not contain, in patch order. A non-empty
    result is exit 3: the patch does not describe this GTF.
    """
    return [gene_id for gene_id in patch if gene_id not in current_names]


def collision_warnings(patch, name_owners):
    """
    Non-fatal problems worth naming before the operator ships the result.

    Neither is an error here: bin/check_gtf_hla_gene_ids.py is the authority on
    whether a GTF is acceptable, and it will catch both on the next run. The
    operator may also be patching for some other purpose entirely.
    """
    warnings = []

    renames = {
        gene_id: new_name
        for gene_id, new_name in patch.items()
        if new_name is not None
    }

    targets = {}
    for gene_id, new_name in renames.items():
        targets.setdefault(new_name, []).append(gene_id)

    for new_name, gene_ids in targets.items():
        if len(gene_ids) > 1:
            warnings.append(
                f"{len(gene_ids)} gene_ids are all renamed to {new_name!r} "
                f"({', '.join(gene_ids)}); that leaves the name ambiguous"
            )

        others = sorted(name_owners.get(new_name, set()) - set(gene_ids) - set(patch))
        if others:
            warnings.append(
                f"{new_name!r} is already the gene_name of {', '.join(others)}; "
                "renaming onto it creates a new duplicate"
            )

    return warnings


def patch_gtf(gtf_path, patch, out):
    """
    Second pass: write the patched GTF.

    Returns (stats, totals): per-gene_id row tallies, and (rows_in, rows_out,
    rows_renamed, rows_removed) over the whole file.
    """
    stats = {gene_id: {"renamed": 0, "removed": 0, "no_gene_name": 0} for gene_id in patch}
    rows_in = 0
    rows_out = 0
    rows_renamed = 0
    rows_removed = 0

    with open_maybe_gzip(gtf_path, "rt") as handle:
        for line in handle:
            if line.startswith("#"):
                # Skip header lines
                out.write(line)
                continue

            rows_in += 1

            id_match = _GENE_ID_RE.search(line)
            gene_id = id_match.group(1) if id_match is not None else None

            if gene_id is None or gene_id not in patch:
                # Skip lines we don't want to patch
                out.write(line)
                rows_out += 1
                continue

            new_name = patch[gene_id]
            if new_name is None:
                # Removing row with this gene_id
                stats[gene_id]["removed"] += 1
                rows_removed += 1
                continue

            # Replacing gene name
            patched, n_subs = _GENE_NAME_RE.subn(
                lambda match: match.group(1) + new_name + match.group(3),
                line,
                count=1,
            )
            if n_subs:
                stats[gene_id]["renamed"] += 1
                rows_renamed += 1
            else:
                # No gene_name attribute to rewrite. The row still belongs to a
                # patched gene, so it is kept as-is rather than dropped, and
                # counted so the summary can say so out loud.
                stats[gene_id]["no_gene_name"] += 1

            out.write(patched)
            rows_out += 1

    return stats, (rows_in, rows_out, rows_renamed, rows_removed)


def report_summary(patch, current_names, stats, totals, gtf_path, patch_path):
    """
    Per-gene_id actions and file totals, on stderr.

    The blast radius of a patch is the thing worth seeing before the output is
    used, so every listed gene_id gets a line, with the gene_name it had - a
    removal of something the personalized reference still expects is much
    easier to spot as a name than as an accession.
    """
    rows_in, rows_out, rows_renamed, rows_removed = totals

    n_rename = sum(1 for new_name in patch.values() if new_name is not None)
    n_remove = len(patch) - n_rename

    print(f"Patch: {patch_path}", file=sys.stderr)
    print(
        f"       {len(patch)} gene_ids - {n_rename} to rename, {n_remove} to remove",
        file=sys.stderr,
    )
    print(f"GTF:   {gtf_path}", file=sys.stderr)
    print("", file=sys.stderr)

    id_width = max(len(gene_id) for gene_id in patch)
    for gene_id, new_name in patch.items():
        was = current_names.get(gene_id) or "?"
        counts = stats[gene_id]
        if new_name is None:
            action = f"remove  (was gene_name {was})"
            n_rows = counts["removed"]
        else:
            action = f"rename  {was} -> {new_name}"
            n_rows = counts["renamed"]
        print(
            f"  {gene_id.ljust(id_width)}  {action}   {n_rows} rows",
            file=sys.stderr,
        )
        if counts["no_gene_name"]:
            print(
                f"  {' ' * id_width}  WARNING: {counts['no_gene_name']} rows of "
                "this gene have no gene_name attribute and were kept unchanged",
                file=sys.stderr,
            )

    print("", file=sys.stderr)
    print(
        f"Summary: {rows_in} feature rows in, {rows_out} out - "
        f"{rows_renamed} renamed, {rows_removed} removed.",
        file=sys.stderr,
    )


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument(
        "--gtf",
        required=True,
        help="Reference GTF to patch (plain or gzipped), i.e. the pipeline's --gtf.",
    )
    parser.add_argument(
        "--patch",
        required=True,
        help=(
            "Two-column TSV: gene_id, and an optional new_gene_name. A row with "
            "a new_gene_name renames that gene and all of its nested entries; a "
            "row without one removes them."
        ),
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    sys.stderr.write("=== Reading patch file ===\n")
    try:
        patch = parse_patch(args.patch)
    except PatchError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"ERROR: could not read --patch: {exc}", file=sys.stderr)
        return 2

    sys.stderr.write("=== First scan of GTF file - checking names and patch correctness ===\n")
    try:
        current_names, name_owners = scan_gtf(args.gtf, patch)
    except OSError as exc:
        print(f"ERROR: could not read --gtf: {exc}", file=sys.stderr)
        return 2

    missing = missing_gene_ids(patch, current_names)
    if missing:
        print(
            f"ERROR: {len(missing)} gene_id(s) in --patch are not in --gtf "
            f"{args.gtf}:",
            file=sys.stderr,
        )
        for gene_id in missing:
            print(f"  {gene_id}", file=sys.stderr)
        print(
            "Nothing was written. Check that --gtf is the annotation this patch "
            "was written against, and that gene_ids carry the same version "
            "suffix (ENSG00000206341.7, not ENSG00000206341).",
            file=sys.stderr,
        )
        return 3

    for warning in collision_warnings(patch, name_owners):
        print(f"WARNING: {warning}", file=sys.stderr)

    sys.stderr.write("=== Patching GTF file ===\n")
    try:
        stats, totals = patch_gtf(args.gtf, patch, sys.stdout)
    except OSError as exc:
        print(f"ERROR: could not read --gtf: {exc}", file=sys.stderr)
        return 2

    report_summary(patch, current_names, stats, totals, args.gtf, args.patch)

    return 0


def run():
    """
    Entry point wrapper for a reader that goes away.

    stdout is a whole GTF, so piping into `head`, or into a `gzip` that dies,
    is a normal thing for an operator to do and must not end in a
    BrokenPipeError traceback. Restoring SIGPIPE's default disposition - which
    Python replaces with an exception at startup - makes this behave like any
    other Unix filter and die quietly with 141. Catching BrokenPipeError
    instead is not enough: the interpreter flushes stdout again during
    shutdown, which fails a second time and exits 120.
    """
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    try:
        return main()
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(run())

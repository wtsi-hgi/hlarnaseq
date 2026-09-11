#!/usr/bin/env python3
"""
Fail fast when --gtf does not carry a one-to-one gene_name <-> gene_id
mapping for its HLA-region annotation.

Why this exists
---------------
bin/reconcile_hla_readcounts.py resolves every gene name appearing in the
HLA read-count reconciliation output back to a gene_id via the whole-genome
--gtf (load_gene_name_to_ids()). That resolution is deliberately soft: an
ambiguous name resolves to the first-appearing id (HLA rows) or to every
candidate id, semicolon-joined (non-HLA rows), and the run continues. Neither
outcome is a usable gene_id for the planned downstream count-matrix patching
step, so ambiguity in the *HLA region* is now rejected before any counting or
reconciliation result is produced, rather than resolved silently.

This is intentionally strict: stock
gencode.v50.primary_assembly.annotation.gtf.gz IS rejected by this check
(HLA-H, HLA-L, HLA-V and HLA-DRB6 are each annotated twice inside the MHC,
with two distinct gene_ids). Users must supply a corrected GTF - see
docs/usage.md#gtf-hla-gene-id-uniqueness-check.

Scope (the union of two definitions, matching the two ways an HLA gene name
reaches the reconciliation output)
-----------------------------------------------------------------------------
1. gene rows overlapping --hla-region: the same samtools region string
   ARCASHLA_EXTRACT slices the BAM with, which is where the reconciliation's
   non-HLA gene names come from.
2. gene names starting with --hla-gene-prefix (default "HLA-") anywhere in the
   file: the personalized-reference gene names, which come from HLApm and not
   from the region slice, so definition 1 alone would not cover them.

For every in-scope gene_name, distinct gene_ids are counted across the WHOLE
GTF, not just within the region - that is exactly what
load_gene_name_to_ids() does, so an off-region duplicate of an in-region name
is just as much of a problem.

Only feature_type == "gene" rows are considered (same restriction
load_gene_name_to_ids() uses), so a gene with many transcript/exon rows is
never mistaken for a duplicate.

Both directions fail:
- a gene_name with more than one distinct gene_id  -> duplicated_gene_name
- a gene_id carrying more than one distinct in-scope gene_name
  -> duplicated_gene_id

Exit status
-----------
0  every in-scope gene_name/gene_id pairing is unique
1  at least one offender (every offending pair is printed to stderr; a failed
   Nextflow task publishes nothing, so stderr is the user's only copy)
2  --hla-region could not be parsed
"""

import argparse
import gzip
import re
import sys

description = (
    "Reject a --gtf whose HLA-region annotation does not have a one-to-one "
    "gene_name <-> gene_id mapping. See module docstring for the exact scope "
    "definition and exit statuses."
)

REPORT_HEADER = (
    "gene_name",
    "gene_ids",
    "n_gene_ids",
    "in_region",
    "hla_prefixed",
    "status",
)

STATUS_UNIQUE = "unique"
STATUS_DUP_NAME = "duplicated_gene_name"
STATUS_DUP_ID = "duplicated_gene_id"

# start[-end], either side optionally omitted, thousands separators tolerated
# (samtools accepts "chr6:28,500,000-33,400,000", "chr6:28500000-",
# "chr6:-33400000" and a bare "chr6:28500000" meaning "to the end of the
# contig").
_RANGE_RE = re.compile(r"^(?P<start>[0-9][0-9,]*)?(?P<dash>-)?(?P<end>[0-9][0-9,]*)?$")

_ATTR_RE = re.compile(r'(\S+)\s+"([^"]*)";')


def parse_gtf_attributes(attr_text):
    """
    Parse the 9th GTF column into a dict.

    Deliberately identical in behaviour to
    bin/reconcile_hla_readcounts.py's own parse_gtf_attributes(), so the
    check and the consumer can never disagree about what a row's gene_id or
    gene_name is.
    """
    attrs = {}
    for match in _ATTR_RE.finditer(attr_text):
        attrs[match.group(1)] = match.group(2)
    return attrs


def parse_region(region):
    """
    Parse a samtools region string "contig[:start[-end]]".

    Returns (contig, start, end) with 1-based inclusive coordinates; `end` is
    None for an open-ended region. Raises ValueError on anything unparseable
    (the caller turns that into exit 2) rather than silently checking the
    wrong interval.
    """
    text = region.strip()
    if not text:
        raise ValueError("region string is empty")

    contig, separator, rest = text.rpartition(":")
    if not separator:
        # A bare contig name - the whole contig is in scope.
        return text, 1, None

    if not contig:
        raise ValueError(f"no contig name in region {region!r}")

    match = _RANGE_RE.match(rest)
    if match is None:
        raise ValueError(f"could not parse coordinate range {rest!r} in region {region!r}")

    start_text = match.group("start")
    end_text = match.group("end")
    if not start_text and not end_text:
        raise ValueError(f"no coordinates in region {region!r}")

    start = int(start_text.replace(",", "")) if start_text else 1
    if match.group("dash"):
        end = int(end_text.replace(",", "")) if end_text else None
    else:
        # "chr6:28500000" - from that position to the end of the contig.
        end = None

    if start < 1:
        raise ValueError(f"start coordinate must be >= 1 in region {region!r}")
    if end is not None and end < start:
        raise ValueError(f"end coordinate precedes start coordinate in region {region!r}")

    return contig, start, end


def open_maybe_gzip(path, mode="rt"):
    return gzip.open(path, mode) if path.endswith(".gz") else open(path, mode)


def scan_gtf(gtf_path, contig, start, end, hla_gene_prefix):
    """
    Single streaming pass over --gtf, feature_type == "gene" rows only.

    Returns (name_to_ids, id_to_names, in_region_names, prefixed_names,
    n_region_gene_rows). The first four are insertion-ordered dicts used as
    ordered sets, so every reported id list is in first-appearance-in-file
    order (matching load_gene_name_to_ids()) and therefore reproducible.
    """
    name_to_ids = {}
    id_to_names = {}
    in_region_names = {}
    prefixed_names = {}
    n_region_gene_rows = 0

    with open_maybe_gzip(gtf_path, "rt") as handle:
        for line in handle:
            if not line or line.startswith("#"):
                continue

            fields = line.rstrip("\n").split("\t")
            if len(fields) < 9:
                continue

            if fields[2] != "gene":
                continue

            attrs = parse_gtf_attributes(fields[8])
            gene_id = attrs.get("gene_id")
            gene_name = attrs.get("gene_name")
            if not gene_id or not gene_name:
                continue

            name_to_ids.setdefault(gene_name, {})[gene_id] = None
            id_to_names.setdefault(gene_id, {})[gene_name] = None

            if gene_name.startswith(hla_gene_prefix):
                prefixed_names[gene_name] = None

            if fields[0] != contig:
                continue

            try:
                row_start = int(fields[3])
                row_end = int(fields[4])
            except ValueError:
                # A malformed coordinate cannot be tested for overlap; the
                # row still counted toward the genome-wide id tally above.
                continue

            if row_end >= start and (end is None or row_start <= end):
                in_region_names[gene_name] = None
                n_region_gene_rows += 1

    return name_to_ids, id_to_names, in_region_names, prefixed_names, n_region_gene_rows


def build_report_rows(name_to_ids, id_to_names, in_region_names, prefixed_names):
    """
    One row per in-scope gene_name, sorted by gene_name.

    A row's status is duplicated_gene_name when its name has more than one
    distinct gene_id, otherwise duplicated_gene_id when one of its gene_ids
    is shared with another in-scope gene_name, otherwise unique. The forward
    direction takes precedence when a row is both, so `status` stays a single
    one of the three documented values.
    """
    in_scope = set(in_region_names) | set(prefixed_names)

    rows = []
    for gene_name in sorted(in_scope):
        gene_ids = list(name_to_ids.get(gene_name, {}))

        shared_ids = {}
        for gene_id in gene_ids:
            other_names = [
                other
                for other in id_to_names.get(gene_id, {})
                if other != gene_name and other in in_scope
            ]
            if other_names:
                shared_ids[gene_id] = other_names

        if len(gene_ids) > 1:
            status = STATUS_DUP_NAME
        elif shared_ids:
            status = STATUS_DUP_ID
        else:
            status = STATUS_UNIQUE

        rows.append(
            {
                "gene_name": gene_name,
                "gene_ids": gene_ids,
                "in_region": gene_name in in_region_names,
                "hla_prefixed": gene_name in prefixed_names,
                "shared_ids": shared_ids,
                "status": status,
            }
        )

    return rows


def write_report(rows, report_path):
    with open(report_path, "w") as handle:
        handle.write("\t".join(REPORT_HEADER) + "\n")
        for row in rows:
            handle.write(
                "\t".join(
                    (
                        row["gene_name"],
                        ";".join(row["gene_ids"]),
                        str(len(row["gene_ids"])),
                        "yes" if row["in_region"] else "no",
                        "yes" if row["hla_prefixed"] else "no",
                        row["status"],
                    )
                )
                + "\n"
            )


def report_offenders(offenders, region, report_path):
    """
    Print EVERY offending pair to stderr - uncapped, deliberately. A failed
    Nextflow task publishes nothing, so this is the only copy of the list the
    user gets without digging into the task work directory.

    A trailing one-line summary repeats the count and the offending gene names,
    so the verdict survives Nextflow's last-~50-lines truncation of the error
    block even when the per-pair list above it is long.
    """
    name_width = max(len(row["gene_name"]) for row in offenders)

    print(
        "ERROR: --gtf has a non-unique gene_name <-> gene_id mapping in the HLA region",
        file=sys.stderr,
    )
    print(
        f"       ({len(offenders)} offending gene "
        f"{'name' if len(offenders) == 1 else 'names'}, HLA region = {region}).",
        file=sys.stderr,
    )

    for row in offenders:
        detail = ""
        if row["status"] == STATUS_DUP_ID:
            shared = "; ".join(
                f"{gene_id} is also gene_name {', '.join(other_names)}"
                for gene_id, other_names in row["shared_ids"].items()
            )
            detail = f"   ({shared})"
        print(
            f"  {row['gene_name'].ljust(name_width)}  "
            f"{', '.join(row['gene_ids'])}   {row['status']}{detail}",
            file=sys.stderr,
        )

    # Nextflow's error report keeps only the last ~50 stderr lines (it truncates
    # by line, not by character, and does not clip long lines), so on a
    # pathological GTF with dozens of offenders the ERROR: header and the first
    # offending rows scroll out of the error block. Repeat the verdict and the
    # offending gene names here, near the end, where they always survive.
    print(
        f"Summary: {len(offenders)} non-unique gene "
        f"{'name' if len(offenders) == 1 else 'names'} in {region} - "
        f"{', '.join(row['gene_name'] for row in offenders)}",
        file=sys.stderr,
    )
    print(
        "Fix --gtf (drop or rename the duplicate gene rows) and re-run. "
        "This check has no opt-out: an ambiguous gene_name cannot be resolved "
        "to a single gene_id for the HLA read-count reconciliation.",
        file=sys.stderr,
    )
    print(
        f"Full table: {report_path} (in this task's work directory, printed as "
        '"Work dir:" in the Nextflow error report above)',
        file=sys.stderr,
    )


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument(
        "--gtf",
        required=True,
        help="Whole-genome reference GTF (plain or gzipped), i.e. the pipeline's --gtf.",
    )
    parser.add_argument(
        "--hla-region",
        required=True,
        help=(
            "HLA region as a samtools region string, contig[:start[-end]] "
            "(the pipeline's --hla_region, e.g. chr6:28500000-33400000)."
        ),
    )
    parser.add_argument(
        "--hla-gene-prefix",
        default="HLA-",
        help=(
            "Gene-name prefix that marks a personalized-reference HLA gene "
            "wherever it appears in --gtf (default: %(default)s)."
        ),
    )
    parser.add_argument(
        "--report",
        default="hla_region_gene_id_map.tsv",
        help="Path of the provenance table to write (default: %(default)s).",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    try:
        contig, start, end = parse_region(args.hla_region)
    except ValueError as exc:
        print(f"ERROR: could not parse --hla-region: {exc}", file=sys.stderr)
        return 2

    (
        name_to_ids,
        id_to_names,
        in_region_names,
        prefixed_names,
        n_region_gene_rows,
    ) = scan_gtf(args.gtf, contig, start, end, args.hla_gene_prefix)

    if n_region_gene_rows == 0:
        # Non-fatal: -profile test's tiny placeholder.gtf legitimately has no
        # HLA-region annotation at all. On a real GTF this almost always means
        # a contig-notation mismatch ("chr6" vs "6").
        print(
            f"WARNING: no gene rows in {args.gtf} overlap --hla-region "
            f"{args.hla_region}. If this is a real whole-genome GTF, check that "
            "its contig naming matches --hla_region (e.g. 'chr6' vs '6'); only "
            f"gene names starting with {args.hla_gene_prefix!r} were checked.",
            file=sys.stderr,
        )

    rows = build_report_rows(name_to_ids, id_to_names, in_region_names, prefixed_names)
    write_report(rows, args.report)

    offenders = [row for row in rows if row["status"] != STATUS_UNIQUE]
    if offenders:
        report_offenders(offenders, args.hla_region, args.report)
        return 1

    print(
        f"OK: {len(rows)} in-scope gene "
        f"{'name' if len(rows) == 1 else 'names'} "
        f"({len(in_region_names)} overlapping {args.hla_region}, "
        f"{len(prefixed_names)} carrying the {args.hla_gene_prefix!r} "
        "gene-name prefix) each map to exactly one gene_id, and no gene_id is "
        "shared between them.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

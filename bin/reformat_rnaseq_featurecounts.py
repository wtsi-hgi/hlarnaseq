#!/usr/bin/env python3
"""
Convert featureCounts' `-R BAM` per-read gene assignments (as text) into the
read_name/direction/gene_name/edit_distance TSV the HLA read-count
reconciliation consumes, translating each read's assigned gene_id to a
gene_name via the same whole-genome --gtf.

Ambiguity is fatal, but only where it is consumed
-------------------------------------------------
A gene_id annotated with more than one distinct gene_name cannot be translated
to "the" gene name, and silently taking one of them would put a wrong
gene_name - and so a wrong gene's count - into the reconciliation downstream.
Such a gene_id therefore fails the task (exit 1, every offender printed to
stderr) instead of resolving to whichever row was read last.

The failure is keyed to *consumption*, not to presence: only a gene_id that
actually appears on an assigned read in this sample is checked. The upstream
GTF_HLA_GENE_ID_CHECK resolves ambiguity only inside --hla_region (plus
HLA--prefixed names), so a --gtf that legitimately passes it still contains
ambiguous annotation elsewhere in the genome, and that must not fail a run.
Because this script's input is an HLA-region-restricted BAM, the gene_ids that
can reach the check are in-region by construction - the same set
GTF_HLA_GENE_ID_CHECK covers.

A gene_id with no gene_name at all is unchanged, soft behaviour: the gene_id
itself is emitted as the gene name. That is a missing mapping, not an ambiguous
one, and it is the same soft class as the reconciliation's own
missing_gene_name.
"""

import argparse
import gzip
import re
import sys

def open_maybe_gzip(path, mode="rt"):
    if path.endswith(".gz"):
        return gzip.open(path, mode)
    return open(path, mode)


def parse_gtf_attributes(attr_text):
    """
    Parse GTF attributes like:
    gene_id "ENSG00000279928"; gene_name "DDX11L17";
    """
    attrs = {}
    for match in re.finditer(r'(\S+)\s+"([^"]*)";', attr_text):
        key, value = match.group(1), match.group(2)
        attrs[key] = value
    return attrs


def load_gene_names_from_gtf(gtf_path):
    """
    Build gene_id -> [gene_name, ...] from GTF.

    Names from feature_type == "gene" rows are authoritative - the same
    restriction bin/check_gtf_hla_gene_ids.py and
    bin/reconcile_hla_readcounts.py's load_gene_name_to_ids() both apply, so
    the upstream check and this consumer can never disagree about what a
    gene_id's name is. Names from other feature rows are kept only as a
    fallback for a gene_id that has no `gene` row at all, preserving this
    script's original behaviour on a GTF carrying no gene rows.

    The value is a list rather than a single name so convert_assignments() can
    fail on a gene_id with more than one distinct gene_name. Collecting them
    here is deliberately NOT fatal, however far the GTF strays: a --gtf
    corrected for the HLA region still legitimately carries ambiguous
    annotation elsewhere, and a gene_id no read uses cannot affect this
    sample's output. Ids are kept in first-appearance-in-file order (a dict
    used as an insertion-ordered set) so a reported list is reproducible.
    """
    gene_row_names = {}
    other_row_names = {}

    with open_maybe_gzip(gtf_path, "rt") as f:
        for line in f:
            if not line or line.startswith("#"):
                continue

            fields = line.rstrip("\n").split("\t")
            if len(fields) < 9:
                continue

            feature_type = fields[2]
            attrs = parse_gtf_attributes(fields[8])

            gene_id = attrs.get("gene_id")
            if not gene_id:
                continue

            gene_name = attrs.get("gene_name")
            if not gene_name:
                continue

            if feature_type == "gene":
                gene_row_names.setdefault(gene_id, {})[gene_name] = None
            else:
                other_row_names.setdefault(gene_id, {})[gene_name] = None

    gene_id_to_names = {gene_id: list(names) for gene_id, names in gene_row_names.items()}
    for gene_id, names in other_row_names.items():
        if gene_id not in gene_id_to_names:
            gene_id_to_names[gene_id] = list(names)

    return gene_id_to_names


def report_ambiguous_offenders(offenders, gtf_path):
    """
    Print EVERY offending gene_id to stderr - uncapped, deliberately, matching
    bin/check_gtf_hla_gene_ids.py's own report_offenders() and
    bin/reconcile_hla_readcounts.py's: a failed Nextflow task publishes
    nothing, so this is the only copy of the list the user gets without digging
    into the task work directory. The trailing summary repeats the verdict so
    it survives Nextflow's last-~50-lines truncation of the error block.
    """
    id_width = max(len(gene_id) for gene_id in offenders)

    print(
        "ERROR: a gene_id carrying reads in this sample has more than one distinct "
        "gene_name in --gtf",
        file=sys.stderr,
    )
    print(
        f"       ({len(offenders)} offending gene "
        f"{'id' if len(offenders) == 1 else 'ids'}, --gtf = {gtf_path}).",
        file=sys.stderr,
    )

    for gene_id, gene_names in offenders.items():
        print(f"  {gene_id.ljust(id_width)}  {', '.join(gene_names)}", file=sys.stderr)

    print(
        f"Summary: {len(offenders)} ambiguous gene "
        f"{'id' if len(offenders) == 1 else 'ids'} among this sample's assigned reads - "
        f"{', '.join(offenders)}",
        file=sys.stderr,
    )
    print(
        "Reads were assigned to each of these, so there is no single gene_name to "
        "attribute their counts to. Gene ids that are ambiguous elsewhere in --gtf are "
        "fine and are not reported here - only ids that carried a read are. "
        "GTF_HLA_GENE_ID_CHECK normally rejects such a --gtf before this step runs "
        "(as duplicated_gene_id), so reaching this message means an id got here from "
        "outside that check's scope (see "
        "docs/usage.md#gtf-hla-gene-id-uniqueness-check). Fix --gtf for the ids above "
        "(drop or rename the duplicate gene rows) and re-run.",
        file=sys.stderr,
    )


def flag_to_mate_direction(flag):
    """
    SAM flag bits:
      0x40 = first in pair
      0x80 = second in pair
    """
    if flag & 0x40:
        return "R1"
    if flag & 0x80:
        return "R2"
    return "NA"


def parse_optional_fields(fields):
    """
    Parse SAM optional fields like:
      NH:i:1
      XT:Z:ENSG00000231389
      nM:i:1
      NM:i:1

    Returns dict tag -> value string
    """
    result = {}
    for field in fields:
        parts = field.split(":", 2)
        if len(parts) == 3:
            tag, typ, value = parts
            result[tag] = value
    return result


def convert_assignments(assignments_path, gtf_path, output_path):
    """
    Returns the process exit status: 0, or 1 when at least one gene_id
    carrying a read turned out to have more than one gene_name in --gtf.
    """
    print("Parsing reads: ", assignments_path, file=sys.stderr)
    gene_id_to_names = load_gene_names_from_gtf(gtf_path)
    offenders = {}
    with open_maybe_gzip(assignments_path, "rt") as fin, open(output_path, "wt") as fout:
        fout.write("read_name\tdirection\tgene_name\tedit_distance\n")

        for line_num, line in enumerate(fin, start=1):
            line = line.rstrip("\n")
            if not line:
                print(f"WARNING: empty line {line_num}", file=sys.stderr)
                continue

            fields = line.split("\t")
            if len(fields) < 12:
                raise ValueError(f"Malformed line {line_num}")

            read_id = fields[0]

            try:
                flag = int(fields[1])
            except ValueError:
                raise ValueError(f"WARNING: invalid FLAG on line {line_num}")

            direction = flag_to_mate_direction(flag)
            optional = parse_optional_fields(fields[11:])

            gene_id = optional.get("XT")
            if not gene_id:
                raise ValueError(f"WARNING: missing XT tag on line {line_num}")

            # An ambiguous gene_id is only an offender once a read is actually
            # assigned to it - which is exactly here, and nowhere else.
            gene_names = gene_id_to_names.get(gene_id, [])
            if len(gene_names) > 1:
                offenders[gene_id] = gene_names
            # A gene_id with no gene_name at all keeps the original soft
            # behaviour of standing in for its own name. The ambiguous case
            # writes gene_names[0] only so the loop stays simple: the run exits
            # 1 below and this file is never published or read.
            gene_name = gene_names[0] if gene_names else gene_id

            # STAR BAM uses nM, but standard SAM usually uses NM - checking for both
            edit_distance = optional.get("nM", optional.get("NM", 100))

            fout.write(f"{read_id}\t{direction}\t{gene_name}\t{edit_distance}\n")

    if offenders:
        report_ambiguous_offenders(offenders, gtf_path)
        return 1

    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Convert featureCounts assigned-read output into a table for reads quantification: read, gene name, edit distance."
    )
    parser.add_argument(
        "-i", "--input",
        required=True,
        help="Input featureCounts assignment file (SAM-like tab-delimited text, optionally .gz)"
    )
    parser.add_argument(
        "-g", "--gtf",
        required=True,
        help="GTF annotation file used for RNA-seq (optionally .gz)"
    )
    parser.add_argument(
        "-o", "--output",
        required=True,
        help="Output TSV file"
    )

    args = parser.parse_args()
    return convert_assignments(args.input, args.gtf, args.output)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
Patch a whole-genome featureCounts gene-count table (COUNTS_COMMONREF's
`<rna_id>.featureCounts.tsv`) with this sample's reconciled personalized-HLA
counts (HLA_READCOUNT_RECONCILE's `<rna_id>.hla_readcount_reconcile.tsv`), and
emit a two-column `gene_id`/`count` table plus a change log of every row the
patch touched or could not touch.

This is the final step of the "hijack original count matrix" roadmap item, and
an adaptation of artifacts/scripts/hijack-original-featurecounts.py. Unlike
that prototype, this script:

- reads the RAW 7-column featureCounts table (`Geneid Chr Start End Strand
  Length <bam>`) and projects it down to `gene_id`/`count` itself, instead of
  assuming a pre-converted 2-column input (the prototype read `fields[1]`,
  which in a real featureCounts table is `Chr`);
- needs NO --gtf. The prototype keyed its HLA replacements by `gene_name` and
  so had to re-derive a `gene_name` <-> `gene_id` mapping itself (its
  HLA-only, "first seen wins" load_gene_mappings_from_gtf()). This pipeline's
  diff table already carries a resolved, unambiguous `gene_id` for both
  categories, and the featureCounts table is keyed by `gene_id`
  (`-g gene_id`), so the patch is an exact `gene_id` join. Re-deriving that
  mapping here would reintroduce the loose resolution GTF_HLA_GENE_ID_CHECK
  and bin/reconcile_hla_readcounts.py deliberately replaced;
- keys EVERY output row by `gene_id`, including patched HLA rows (the
  prototype rewrote those to `gene_name`), so a cohort's per-sample columns
  stay joinable on one key type;
- asserts the count unit rather than rescaling it (see "Counts are read
  pairs", below).

Patch semantics
---------------
Row order and the row key set of the output are exactly the featureCounts
table's: no row is ever added and no row is ever dropped, so per-sample
columns stay `cbind`-able across a cohort.

- a `category: hla` diff row REPLACES that `gene_id`'s count with
  `personalized_count` (change-log action `replaced_with_personalized`);
- a `category: non_hla` diff row ADJUSTS that `gene_id`'s count by the
  (negative) `diff` (change-log action `adjusted_by_diff`);
- every other gene keeps its original whole-genome count and takes no
  change-log row.

Missing is soft, wrong is fatal
-------------------------------
A diff row whose `gene_id` is the literal string "NA" is NOT applied: it has
no row in the whole-genome table to patch. The run continues, the gene is
recorded in the change log as `unapplied_missing_gene_id`, and a batched
WARNING is printed to stderr. This has to stay soft because
bin/reconcile_hla_readcounts.py deliberately soft-fails a gene name absent
from --gtf to "NA" (a personalized-reference-only or renamed symbol is
legitimate), and a real cohort does hit it - HLA-DRB3, for one. Failing here
would reject runs the upstream step intentionally accepts. The consequence,
carried knowingly: those HLA read pairs do not reach the final table at all.
The fix is upstream, in --gtf (see bin/patch_gtf_gene_ids.py), not here.

A diff row whose `gene_id` is NOT "NA" but is absent from the featureCounts
table is FATAL (exit 1). Both tables were built from the same --gtf, so that
can only mean the two steps saw different annotation.

A resulting count below zero is FATAL (exit 1). A `non_hla` `diff` is computed
against the HLA-region-restricted featureCounts run while the count being
patched comes from the whole-genome run, so it is not arithmetically
guaranteed to fit; a negative count is never a publishable number.

Both fatal classes are collected across the whole table before either is
allowed to fail, so one run reports every offender rather than aborting on the
first, and nothing is written on failure.

Counts are read pairs, and that is asserted
-------------------------------------------
The reconciled HLA counts are read pairs (one row per read pair in
bin/reconcile_hla_readcounts.py's output), so the whole-genome table must be
counted the same way for the two to be comparable. In this pipeline it always
is: conf/modules.config passes `--countReadPairs` to SUBREAD_FEATURECOUNTS and
utils_wtsihgi_hlarnaseq_pipeline hardcodes `single_end: false`, so the module
always adds `-p`.

Rather than offer the prototype's `--fc-is-paired` switch and its x2
read-pairs-to-reads rescale, this script ASSERTS the unit: it parses the
`# Program:...Command:` line featureCounts writes into its own output and
exits 1 unless that command line shows both `--countReadPairs` and `-p`. If
the line is absent or unparsable it also exits 1 - the assumption cannot be
verified, and silently assuming it is what would halve or double every HLA
count. No CLI switch is exposed, so the unit cannot be overridden into being
wrong.
"""

import argparse
import gzip
import re
import sys
from typing import Any, Dict, List, Optional, Tuple

description = (
    "Patch a whole-genome featureCounts gene-count table with reconciled "
    "personalized-HLA counts, emitting a two-column gene_id/count table and a "
    "change log.\n\n"
    "See module docstring for the full patch semantics and failure policy."
)

# The six columns bin/reconcile_hla_readcounts.py writes, in order. Read by
# name below, never by position - but the header is still required to be
# exactly this, so a schema change upstream fails here loudly instead of
# being half-understood.
DIFF_COLUMNS = [
    "gene_id",
    "gene_name",
    "category",
    "original_fc_count",
    "personalized_count",
    "diff",
]

# The raw featureCounts table's fixed shape: Geneid Chr Start End Strand
# Length <bam>. Exactly one BAM per call (COUNTS_COMMONREF passes one), so
# the count column is unambiguously the last one.
FEATURECOUNTS_N_COLUMNS = 7
FEATURECOUNTS_COUNT_INDEX = 6

# The literal string bin/reconcile_hla_readcounts.py writes when a gene name
# could not be resolved to any gene_id in --gtf. Not a gene_id, a sentinel.
MISSING_GENE_ID = "NA"

CHANGE_LOG_COLUMNS = [
    "gene_id",
    "gene_name",
    "category",
    "original_count",
    "new_count",
    "action",
]

PROGRAM_LINE_PREFIX = "# Program:"


class InputFormatError(Exception):
    """
    Raised for a structural problem in either input table (bad header, wrong
    column count, duplicated key, non-integer count, unverifiable count unit).

    Carries a ready-to-print message; main() prints it and exits 1.
    """


def open_maybe_gzip(path: str, mode: str = "rt") -> Any:
    return gzip.open(path, mode) if path.endswith(".gz") else open(path, mode)


def find_program_line(comment_lines: List[str]) -> Optional[str]:
    """
    Return the `# Program:` comment featureCounts writes as the first line of
    its own output, or None if the table carries no such line.
    """
    for line in comment_lines:
        if line.startswith(PROGRAM_LINE_PREFIX):
            return line
    return None


def parse_command_tokens(program_line: str) -> Optional[List[str]]:
    """
    Extract the quoted argv tokens from a featureCounts `# Program:` line.

    Real example:
      # Program:featureCounts v2.1.1; Command:"featureCounts" "--countReadPairs" "-g" "gene_id" "-p" ...

    Tokens are taken from the quoted spans only, so a flag is matched as a
    whole argv element - `-p` can never be matched inside a file path, and a
    path containing the text "--countReadPairs" can never satisfy the
    assertion. Returns None when the line has no `Command:` part or no quoted
    tokens at all, i.e. when the unit cannot be verified.
    """
    marker = "Command:"
    index = program_line.find(marker)
    if index < 0:
        return None

    tokens = re.findall(r'"([^"]*)"', program_line[index + len(marker):])
    return tokens or None


def assert_counted_in_read_pairs(program_line: Optional[str], fc_path: str) -> None:
    """
    Fail unless the featureCounts table was counted in read pairs.

    See "Counts are read pairs, and that is asserted" in the module docstring
    for why this is an assertion rather than a rescale option.
    """
    remedy = (
        "This pipeline's reconciled HLA counts are read pairs (one per read pair), so the "
        "whole-genome table must be counted the same way. Ensure SUBREAD_FEATURECOUNTS runs "
        "with `--countReadPairs` (conf/modules.config's `ext.args`) on paired-end data, so "
        "featureCounts also adds `-p`."
    )

    if program_line is None:
        raise InputFormatError(
            f"ERROR: {fc_path} carries no '{PROGRAM_LINE_PREFIX}' comment line, so the count "
            "unit (read pairs vs. reads) cannot be verified.\n"
            f"       {remedy}\n"
            "Summary: count unit unverifiable - no featureCounts '# Program:' line in "
            f"{fc_path}."
        )

    tokens = parse_command_tokens(program_line)
    if tokens is None:
        raise InputFormatError(
            f"ERROR: could not parse a command line out of {fc_path}'s "
            f"'{PROGRAM_LINE_PREFIX}' comment, so the count unit (read pairs vs. reads) "
            "cannot be verified.\n"
            f"       Observed: {program_line}\n"
            f"       {remedy}\n"
            "Summary: count unit unverifiable - unparsable featureCounts '# Program:' line "
            f"in {fc_path}."
        )

    missing = [flag for flag in ("--countReadPairs", "-p") if flag not in tokens]
    if missing:
        raise InputFormatError(
            f"ERROR: {fc_path} was not counted in read pairs: its featureCounts command line "
            f"is missing {', '.join(missing)}.\n"
            f"       Observed: {program_line}\n"
            f"       {remedy}\n"
            f"Summary: count unit mismatch - {', '.join(missing)} absent from "
            f"{fc_path}'s featureCounts command line."
        )


def load_featurecounts(path: str) -> Tuple[Dict[str, int], Optional[str]]:
    """
    Read the raw 7-column featureCounts table into an insertion-ordered
    gene_id -> count mapping (a plain dict: Python dicts preserve insertion
    order, which is what keeps the output's row order identical to the
    input's), and return it together with the `# Program:` provenance line.

    The count unit is asserted here, before any row is read, so an
    unverifiable table fails before it can produce numbers.
    """
    counts: Dict[str, int] = {}

    with open_maybe_gzip(path, "rt") as handle:
        comment_lines: List[str] = []

        header = handle.readline()
        while header.startswith("#"):
            comment_lines.append(header.rstrip("\n"))
            header = handle.readline()

        program_line = find_program_line(comment_lines)
        assert_counted_in_read_pairs(program_line, path)

        header_text = header.rstrip("\n")
        header_fields = header_text.split("\t")
        if not header_fields or header_fields[0] != "Geneid":
            observed_first = header_fields[0] if header_fields else ""
            raise InputFormatError(
                f"ERROR: {path} does not look like a featureCounts gene-count table: its "
                f"header row must start with 'Geneid', but starts with "
                f"'{observed_first}'.\n"
                f"       Observed header: {header_text}\n"
                f"Summary: unexpected header in {path} - 'Geneid' expected in column 1."
            )

        if len(header_fields) != FEATURECOUNTS_N_COLUMNS:
            raise InputFormatError(
                f"ERROR: {path} has {len(header_fields)} columns, expected exactly "
                f"{FEATURECOUNTS_N_COLUMNS} (Geneid, Chr, Start, End, Strand, Length and one "
                "count column). COUNTS_COMMONREF passes exactly one BAM per featureCounts "
                "call, so a different column count means the caller changed and the count "
                "column is no longer unambiguously the last one.\n"
                f"       Observed header: {header_text}\n"
                f"Summary: unexpected column count in {path} - {len(header_fields)} columns, "
                f"{FEATURECOUNTS_N_COLUMNS} expected."
            )

        for line_number, line in enumerate(handle, start=len(comment_lines) + 2):
            line = line.rstrip("\n")
            if not line:
                continue

            fields = line.split("\t")
            if len(fields) != FEATURECOUNTS_N_COLUMNS:
                raise InputFormatError(
                    f"ERROR: {path} line {line_number} has {len(fields)} columns, expected "
                    f"{FEATURECOUNTS_N_COLUMNS}.\n"
                    f"       Observed: {line}\n"
                    f"Summary: malformed row in {path} at line {line_number}."
                )

            gene_id = fields[0]
            if gene_id in counts:
                raise InputFormatError(
                    f"ERROR: {path} lists gene_id '{gene_id}' more than once (line "
                    f"{line_number}), so there is no single count to patch.\n"
                    f"Summary: duplicated gene_id '{gene_id}' in {path}."
                )

            raw_count = fields[FEATURECOUNTS_COUNT_INDEX]
            try:
                counts[gene_id] = int(raw_count)
            except ValueError:
                raise InputFormatError(
                    f"ERROR: {path} line {line_number} has a non-integer count "
                    f"'{raw_count}' for gene_id '{gene_id}'.\n"
                    f"Summary: non-integer count in {path} at line {line_number}."
                )

    return counts, program_line


def load_diff_rows(path: str) -> List[Dict[str, str]]:
    """
    Read the reconciliation diff table into a list of column-name -> value
    dicts, preserving file order so the change log is reproducible.

    The header must be exactly DIFF_COLUMNS; values are then read by name,
    never by position.

    Duplicate detection deliberately ignores gene_id == "NA": that is a
    sentinel for "no gene_id could be resolved", not a key, and a real cohort
    legitimately has more than one HLA gene missing from --gtf. Every "NA"
    row is recorded individually in the change log.
    """
    rows: List[Dict[str, str]] = []
    seen: Dict[str, int] = {}

    with open_maybe_gzip(path, "rt") as handle:
        header = handle.readline().rstrip("\n")
        header_fields = header.split("\t") if header else []

        if header_fields != DIFF_COLUMNS:
            expected = "\t".join(DIFF_COLUMNS)
            raise InputFormatError(
                f"ERROR: {path} does not have the expected HLA read-count reconciliation "
                "header.\n"
                f"       Expected: {expected}\n"
                f"       Observed: {header}\n"
                f"Summary: unexpected header in {path}."
            )

        for line_number, line in enumerate(handle, start=2):
            line = line.rstrip("\n")
            if not line:
                continue

            fields = line.split("\t")
            if len(fields) != len(DIFF_COLUMNS):
                raise InputFormatError(
                    f"ERROR: {path} line {line_number} has {len(fields)} columns, expected "
                    f"{len(DIFF_COLUMNS)}.\n"
                    f"       Observed: {line}\n"
                    f"Summary: malformed row in {path} at line {line_number}."
                )

            row = dict(zip(DIFF_COLUMNS, fields))
            gene_id = row["gene_id"]

            if gene_id != MISSING_GENE_ID:
                if gene_id in seen:
                    raise InputFormatError(
                        f"ERROR: {path} lists gene_id '{gene_id}' more than once (lines "
                        f"{seen[gene_id]} and {line_number}), so the patch for that gene is "
                        "not well defined.\n"
                        f"Summary: duplicated gene_id '{gene_id}' in {path}."
                    )
                seen[gene_id] = line_number

            rows.append(row)

    return rows


def parse_int(value: str, column: str, row: Dict[str, str], path: str) -> int:
    try:
        return int(value)
    except ValueError:
        raise InputFormatError(
            f"ERROR: {path} has a non-integer {column} '{value}' for gene_id "
            f"'{row['gene_id']}' (gene_name '{row['gene_name']}').\n"
            f"Summary: non-integer {column} in {path} for gene_id '{row['gene_id']}'."
        )


def apply_patch(
    counts: Dict[str, int],
    diff_rows: List[Dict[str, str]],
    diff_path: str,
) -> Tuple[Dict[str, int], List[Dict[str, str]], List[Dict[str, str]], List[Dict[str, str]]]:
    """
    Apply every diff row to a copy of the whole-genome counts.

    Returns (patched counts, change-log rows, missing-gene_id offenders,
    negative-count offenders). Both offender lists are collected across the
    WHOLE diff table before either is allowed to fail (see report_offenders()
    and main()), so a user fixing their inputs sees the complete list from one
    run rather than one offender per re-run.
    """
    patched = dict(counts)
    change_log: List[Dict[str, str]] = []
    missing_offenders: List[Dict[str, str]] = []
    negative_offenders: List[Dict[str, str]] = []

    for row in diff_rows:
        gene_id = row["gene_id"]
        category = row["category"]

        if category not in ("hla", "non_hla"):
            raise InputFormatError(
                f"ERROR: {diff_path} has an unrecognised category '{category}' for gene_id "
                f"'{gene_id}' (gene_name '{row['gene_name']}'); expected 'hla' or "
                "'non_hla'.\n"
                f"Summary: unrecognised category '{category}' in {diff_path}."
            )

        # Soft: no row to patch. Recorded, warned about, and skipped.
        if gene_id == MISSING_GENE_ID:
            change_log.append(
                {
                    "gene_id": MISSING_GENE_ID,
                    "gene_name": row["gene_name"],
                    "category": category,
                    "original_count": "NA",
                    "new_count": "NA",
                    "action": "unapplied_missing_gene_id",
                }
            )
            continue

        # Fatal: both tables came from the same --gtf, so a resolved gene_id
        # absent from the whole-genome table means they saw different
        # annotation. Collected, not raised, so every offender is reported.
        if gene_id not in patched:
            missing_offenders.append(row)
            continue

        original_count = patched[gene_id]

        if category == "hla":
            new_count = parse_int(row["personalized_count"], "personalized_count", row, diff_path)
            action = "replaced_with_personalized"
        else:
            new_count = original_count + parse_int(row["diff"], "diff", row, diff_path)
            action = "adjusted_by_diff"

        if new_count < 0:
            negative_offenders.append({**row, "original_count": str(original_count), "new_count": str(new_count)})
            continue

        patched[gene_id] = new_count
        change_log.append(
            {
                "gene_id": gene_id,
                "gene_name": row["gene_name"],
                "category": category,
                "original_count": str(original_count),
                "new_count": str(new_count),
                "action": action,
            }
        )

    return patched, change_log, missing_offenders, negative_offenders


def warn_unapplied(change_log: List[Dict[str, str]]) -> None:
    """
    Batched stderr WARNING for every diff row that could not be applied
    because its gene_name resolved to no gene_id upstream. Capped at five
    examples here (the change log carries all of them, uncapped) - the same
    treatment bin/reconcile_hla_readcounts.py gives its own non-fatal
    missing-gene-name summary.
    """
    unapplied = [row["gene_name"] for row in change_log if row["action"] == "unapplied_missing_gene_id"]
    if not unapplied:
        return

    examples = ", ".join(sorted(unapplied)[:5])
    print(
        f"WARNING: {len(unapplied)} reconciled gene(s) have gene_id '{MISSING_GENE_ID}' in the "
        "diff table (absent from --gtf upstream), so they have no row in the whole-genome "
        "count table to patch and their counts do not reach the final table. Recorded as "
        f"unapplied_missing_gene_id in the change log. Examples: {examples}",
        file=sys.stderr,
    )


def report_offenders(
    missing_offenders: List[Dict[str, str]],
    negative_offenders: List[Dict[str, str]],
    fc_path: str,
    diff_path: str,
) -> None:
    """
    Print EVERY offender to stderr - uncapped, deliberately, in the same shape
    as bin/reconcile_hla_readcounts.py's own report_ambiguous_offenders(): a
    failed Nextflow task publishes nothing, so this is the only copy of the
    list the user gets without digging into the task work directory.

    Each block ends with a one-line summary that repeats the verdict and names
    the offenders, so the verdict survives Nextflow's last-~50-lines
    truncation of the error block even when the per-gene list above it is
    long.
    """
    if missing_offenders:
        width = max(len(row["gene_id"]) for row in missing_offenders)
        print(
            f"ERROR: {len(missing_offenders)} gene_id(s) in {diff_path} are absent from "
            f"{fc_path}, so there is no row to patch.",
            file=sys.stderr,
        )
        for row in missing_offenders:
            print(
                f"  {row['gene_id'].ljust(width)}  {row['gene_name']}  {row['category']}",
                file=sys.stderr,
            )
        print(
            f"Summary: {len(missing_offenders)} unknown gene "
            f"{'id' if len(missing_offenders) == 1 else 'ids'} in the reconciliation diff "
            f"table - {', '.join(row['gene_id'] for row in missing_offenders)}",
            file=sys.stderr,
        )
        print(
            "Both tables are built from the same --gtf, so a resolved (non-NA) gene_id that "
            "the whole-genome table does not carry means the two steps saw different "
            "annotation. Re-run both counting steps against one --gtf. A gene_name that "
            "simply has no gene_id in --gtf is the separate, non-fatal "
            "unapplied_missing_gene_id case and is not reported here.",
            file=sys.stderr,
        )

    if negative_offenders:
        width = max(len(row["gene_id"]) for row in negative_offenders)
        print(
            f"ERROR: patching {fc_path} with {diff_path} would give "
            f"{len(negative_offenders)} gene(s) a negative count.",
            file=sys.stderr,
        )
        for row in negative_offenders:
            # Name the column the result actually came from: an `hla` row's new
            # count is `personalized_count` outright, only a `non_hla` row's is
            # `original + diff`. Printing `diff=` for both would describe
            # arithmetic that never happened.
            if row["category"] == "hla":
                source = f"personalized_count={row['personalized_count']}"
            else:
                source = f"diff={row['diff']}"
            print(
                f"  {row['gene_id'].ljust(width)}  {row['gene_name']}  {row['category']}  "
                f"original={row['original_count']}  {source}  "
                f"result={row['new_count']}",
                file=sys.stderr,
            )
        offender_list = ", ".join(
            "{}={}".format(row["gene_id"], row["new_count"]) for row in negative_offenders
        )
        print(
            f"Summary: {len(negative_offenders)} negative resulting "
            f"{'count' if len(negative_offenders) == 1 else 'counts'} - {offender_list}",
            file=sys.stderr,
        )
        print(
            "A negative count is never published. A non_hla `diff` is computed against the "
            "HLA-region-restricted featureCounts run while the count being patched comes from "
            "the whole-genome run, so the two are not arithmetically guaranteed to fit; a "
            "result this far apart means the two runs did not see the same reads or the same "
            "annotation.",
            file=sys.stderr,
        )


def write_final_counts(path: str, patched: Dict[str, int]) -> None:
    """
    Write the two-column final matrix column: header `gene_id<TAB>count`, one
    row per featureCounts row, in the featureCounts table's own order.

    Every row is keyed by gene_id, patched HLA rows included (unlike
    artifacts/scripts/hijack-original-featurecounts.py, which rewrote those to
    gene_name), so a cohort's per-sample columns join on one key type. The
    featureCounts `# Program:` provenance line is not carried over - it
    describes the input, and lands in the change log's header comment instead.
    """
    with open(path, "wt", encoding="utf-8") as handle:
        handle.write("gene_id\tcount\n")
        for gene_id, count in patched.items():
            handle.write(f"{gene_id}\t{count}\n")


def write_change_log(path: str, change_log: List[Dict[str, str]], program_line: Optional[str]) -> None:
    """
    Write one row per gene the patch touched or could not touch, always -
    header-only when the patch changed nothing, so downstream tooling sees a
    uniform, always-present output rather than a conditionally-created file.

    The featureCounts `# Program:` line is recorded here as a leading comment,
    which is where the input table's provenance lives now that the output
    itself is a bare two-column table.
    """
    with open(path, "wt", encoding="utf-8") as handle:
        if program_line is not None:
            handle.write(f"{program_line}\n")
        handle.write("\t".join(CHANGE_LOG_COLUMNS) + "\n")
        for row in change_log:
            handle.write("\t".join(row[column] for column in CHANGE_LOG_COLUMNS) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=description,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "featurecounts",
        help="COUNTS_COMMONREF whole-genome featureCounts table (raw 7-column *.featureCounts.tsv)",
    )
    parser.add_argument(
        "reconcile_diff",
        help="HLA_READCOUNT_RECONCILE per-sample diff table (*.hla_readcount_reconcile.tsv)",
    )
    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="Path to write the two-column final gene-count table (gene_id, count)",
    )
    parser.add_argument(
        "--change-log",
        required=True,
        help="Path to write the patch change log TSV (always written, header-only when the patch changed nothing)",
    )
    args = parser.parse_args()

    try:
        print("Loading whole-genome featureCounts table:", args.featurecounts, file=sys.stderr)
        counts, program_line = load_featurecounts(args.featurecounts)

        print("Loading HLA read-count reconciliation diff table:", args.reconcile_diff, file=sys.stderr)
        diff_rows = load_diff_rows(args.reconcile_diff)

        patched, change_log, missing_offenders, negative_offenders = apply_patch(
            counts, diff_rows, args.reconcile_diff
        )
    except InputFormatError as error:
        print(str(error), file=sys.stderr)
        return 1

    # Nothing is written on a patch failure: exit 1 before producing either
    # output, so no partially-patched or negative count can be published (a
    # failed Nextflow task publishes nothing either way, but this also keeps a
    # direct, non-Nextflow invocation from leaving a half-written table
    # behind).
    if missing_offenders or negative_offenders:
        report_offenders(missing_offenders, negative_offenders, args.featurecounts, args.reconcile_diff)
        return 1

    warn_unapplied(change_log)

    write_final_counts(args.output, patched)
    write_change_log(args.change_log, change_log, program_line)

    applied = len([row for row in change_log if row["action"] != "unapplied_missing_gene_id"])
    print(f"genes_in_count_table\t{len(patched)}", file=sys.stderr)
    print(f"diff_rows\t{len(diff_rows)}", file=sys.stderr)
    print(f"patched_genes\t{applied}", file=sys.stderr)
    print(f"unapplied_missing_gene_id\t{len(change_log) - applied}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

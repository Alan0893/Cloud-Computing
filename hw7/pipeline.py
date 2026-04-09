from __future__ import annotations

import argparse
import glob
import os
import re
import sys
import time
from collections import Counter
from pathlib import Path

import apache_beam as beam
from apache_beam.io import fileio
from apache_beam.options.pipeline_options import (
    GoogleCloudOptions,
    PipelineOptions,
    SetupOptions,
    WorkerOptions,
)
from apache_beam.pvalue import TaggedOutput

class ExtractFileId(beam.DoFn):
    def process(self, file_path):
        filename = os.path.basename(file_path)
        file_id = filename.replace(".html", "")
        yield (file_id, file_path)


class ReadFile(beam.DoFn):
    def process(self, element):
        file_id, file_path = element
        try:
            with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
            print(f"Read: {file_path}", flush=True)
            yield (file_id, content)
        except OSError as e:
            print(f"Error reading {file_path}: {e}", file=sys.stderr)


class ReadMatchedFile(beam.DoFn):
    def process(self, rf):
        path = rf.metadata.path
        filename = os.path.basename(path)
        file_id = filename.replace(".html", "")
        try:
            content = rf.read_utf8()
            print(f"Read: {path}", flush=True)
            yield (file_id, content)
        except Exception as e:
            print(f"Error reading {path}: {e}", file=sys.stderr)


class ExtractLinksAndBigrams(beam.DoFn):
    def process(self, element):
        file_id, content = element
        outgoing = re.findall(r'HREF="(\d+)\.html"', content, re.IGNORECASE)
        yield TaggedOutput("out", (file_id, len(outgoing)))
        for target_id, c in Counter(outgoing).items():
            yield TaggedOutput("inc", (f"INCOMING_{target_id}", c))

        text = re.sub(r"<[^>]+>", " ", content)
        words = re.findall(r"\b[a-z]+\b", text.lower())
        if len(words) < 2:
            return
        pairs = (f"{words[i]} {words[i + 1]}" for i in range(len(words) - 1))
        for bigram, c in Counter(pairs).items():
            yield TaggedOutput("bi", (bigram, c))


class SumCounts(beam.CombineFn):
    def create_accumulator(self):
        return 0

    def add_input(self, acc, x):
        return acc + x

    def merge_accumulators(self, accs):
        return sum(accs)

    def extract_output(self, acc):
        return acc


class FormatResults(beam.DoFn):
    def __init__(self, task_name):
        self.task_name = task_name

    def process(self, element):
        if self.task_name == "incoming":
            file_id, count = element
            yield f"File {file_id}: {count} incoming links"
        elif self.task_name == "outgoing":
            file_id, count = element
            yield f"File {file_id}: {count} outgoing links"
        else:
            bigram, count = element
            yield f"'{bigram}': {count} occurrences"


def add_analytics_transforms(file_contents):
    split = file_contents | "ExtractLinksAndBigrams" >> beam.ParDo(
        ExtractLinksAndBigrams()
    ).with_outputs("out", "inc", "bi")

    outgoing_counts = split.out | "SumOutgoing" >> beam.CombinePerKey(SumCounts())
    incoming_counts = split.inc | "SumIncoming" >> beam.CombinePerKey(SumCounts())
    bigram_counts = split.bi | "SumBigrams" >> beam.CombinePerKey(SumCounts())

    top_in = (
        incoming_counts
        | "PickTopIncoming" >> beam.combiners.Top.Largest(5, key=lambda kv: kv[1])
        | "FlattenIncomingTop" >> beam.FlatMap(lambda xs: xs)
    )
    top_in = top_in | "StripIncomingPrefix" >> beam.Map(
        lambda kv: (str(kv[0]).replace("INCOMING_", "", 1), kv[1])
    )

    top_out = (
        outgoing_counts
        | "PickTopOutgoing" >> beam.combiners.Top.Largest(5, key=lambda kv: kv[1])
        | "FlattenOutgoingTop" >> beam.FlatMap(lambda xs: xs)
    )
    top_bi = (
        bigram_counts
        | "PickTopBigrams" >> beam.combiners.Top.Largest(5, key=lambda kv: kv[1])
        | "FlattenBigramTop" >> beam.FlatMap(lambda xs: xs)
    )
    return top_in, top_out, top_bi


def run_local(pages_dir: str, output_dir: str, max_files: int | None) -> float:
    os.makedirs(output_dir, exist_ok=True)
    html_files = sorted(Path(pages_dir).glob("*.html"))
    if not html_files:
        raise SystemExit(f"No HTML files under {pages_dir}")
    total_discovered = len(html_files)
    if max_files is not None and max_files > 0:
        html_files = html_files[:max_files]
        print(
            f"Using first {len(html_files)} of {total_discovered} files (--max-files).",
            flush=True,
        )

    print("Runner: BundleBasedDirectRunner (local)")
    print(f"Input:  {pages_dir} ({len(html_files)} files)")
    print(f"Output: {output_dir}\n")

    start = time.perf_counter()
    options = PipelineOptions(
        flags=[],
        runner="BundleBasedDirectRunner",
        temp_location=os.path.join(output_dir, "temp"),
    )

    with beam.Pipeline(options=options) as p:
        file_list = p | "CreateFileList" >> beam.Create([str(f) for f in html_files])
        file_ids = file_list | "ExtractFileId" >> beam.ParDo(ExtractFileId())
        file_contents = file_ids | "ReadFile" >> beam.ParDo(ReadFile())

        top_in, top_out, top_bi = add_analytics_transforms(file_contents)

        (
            top_in
            | "FmtIn" >> beam.ParDo(FormatResults("incoming"))
            | "WriteIn"
            >> beam.io.WriteToText(
                os.path.join(output_dir, "top_5_incoming.txt"), file_name_suffix=""
            )
        )
        (
            top_out
            | "FmtOut" >> beam.ParDo(FormatResults("outgoing"))
            | "WriteOut"
            >> beam.io.WriteToText(
                os.path.join(output_dir, "top_5_outgoing.txt"), file_name_suffix=""
            )
        )
        (
            top_bi
            | "FmtBi" >> beam.ParDo(FormatResults("bigrams"))
            | "WriteBi"
            >> beam.io.WriteToText(
                os.path.join(output_dir, "top_5_bigrams.txt"), file_name_suffix=""
            )
        )

    elapsed = time.perf_counter() - start

    with open(os.path.join(output_dir, "runtime.txt"), "w", encoding="utf-8") as f:
        f.write("Runner: Apache Beam BundleBasedDirectRunner (local)\n")
        f.write(f"Runtime: {elapsed:.2f} seconds\n")
        f.write(f"Files processed: {len(html_files)}\n")
        if max_files is not None and total_discovered > len(html_files):
            f.write(f"(Subset of {total_discovered} files in directory.)\n")

    print(f"Runtime (wall clock, pipeline finished): {elapsed:.2f} s")
    print("(Written runtime.txt)\n")

    for label, pattern in [
        ("Top 5 — incoming", "top_5_incoming.txt-*"),
        ("Top 5 — outgoing", "top_5_outgoing.txt-*"),
        ("Top 5 — bigrams", "top_5_bigrams.txt-*"),
    ]:
        paths = sorted(glob.glob(os.path.join(output_dir, pattern)))
        print(f"--- {label} ---")
        if not paths:
            print("(no shard files found)\n")
            continue
        with open(paths[0], encoding="utf-8") as fh:
            print(fh.read().rstrip() + "\n")

    return elapsed


def run_dataflow(
    project: str,
    region: str,
    input_pattern: str,
    output_prefix: str,
    num_workers: int,
    machine_type: str,
    worker_zone: str | None = None,
) -> float:
    out_rest = output_prefix.replace("gs://", "", 1)
    out_bucket, _, out_blob_prefix = out_rest.partition("/")
    base = out_blob_prefix.rstrip("/")
    temp_location = f"gs://{out_bucket}/{base}/temp" if base else f"gs://{out_bucket}/temp"
    staging_location = (
        f"gs://{out_bucket}/{base}/staging" if base else f"gs://{out_bucket}/staging"
    )

    print("Runner: DataflowRunner")
    print(f"Project:  {project}")
    print(f"Region:   {region}")
    print(f"Input:    {input_pattern}")
    print(f"Output:   {output_prefix}-*.txt")
    if worker_zone:
        print(f"Worker zone: {worker_zone}")
    print()

    options = PipelineOptions(
        flags=[],
        runner="DataflowRunner",
        project=project,
        region=region,
        temp_location=temp_location,
        staging_location=staging_location,
        save_main_session=False,
    )
    g = options.view_as(GoogleCloudOptions)
    g.project = project
    g.region = region
    g.job_name = f"hw7-beam-{int(time.time())}"

    w = options.view_as(WorkerOptions)
    w.num_workers = num_workers
    w.autoscaling_algorithm = "NONE"
    w.machine_type = machine_type
    if worker_zone:
        w.worker_zone = worker_zone

    options.view_as(SetupOptions).requirements_file = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "requirements.txt"
    )

    start = time.perf_counter()

    with beam.Pipeline(options=options) as p:
        file_contents = (
            p
            | "CreatePattern" >> beam.Create([input_pattern])
            | "MatchAll" >> fileio.MatchAll()
            | "ReadMatches" >> fileio.ReadMatches()
            | "ReadUtf8" >> beam.ParDo(ReadMatchedFile())
        )

        top_in, top_out, top_bi = add_analytics_transforms(file_contents)

        (
            top_in
            | "FmtIn" >> beam.ParDo(FormatResults("incoming"))
            | "WriteIn"
            >> beam.io.WriteToText(f"{output_prefix}_incoming", file_name_suffix=".txt")
        )
        (
            top_out
            | "FmtOut" >> beam.ParDo(FormatResults("outgoing"))
            | "WriteOut"
            >> beam.io.WriteToText(f"{output_prefix}_outgoing", file_name_suffix=".txt")
        )
        (
            top_bi
            | "FmtBi" >> beam.ParDo(FormatResults("bigrams"))
            | "WriteBi"
            >> beam.io.WriteToText(f"{output_prefix}_bigrams", file_name_suffix=".txt")
        )

    elapsed = time.perf_counter() - start

    blob_name = (
        f"{base}/hw7_dataflow_runtime.txt" if base else "hw7_dataflow_runtime.txt"
    )

    try:
        from google.cloud import storage

        client = storage.Client(project=project)
        b = client.bucket(out_bucket)
        body = (
            "Runner: Apache Beam DataflowRunner\n"
            f"Runtime (client wait until job finished): {elapsed:.2f} seconds\n"
            f"Input pattern: {input_pattern}\n"
        )
        b.blob(blob_name).upload_from_string(body, content_type="text/plain")
        print(f"Wrote runtime summary to gs://{out_bucket}/{blob_name}")
    except Exception as e:
        print(f"Could not upload runtime file to GCS: {e}", file=sys.stderr)

    print(f"\nWall-clock time until pipeline completed: {elapsed:.2f} s")
    print("Fetch outputs with gsutil, e.g. gsutil cat 'gs://.../*incoming*.txt'")
    return elapsed


def main():
    parser = argparse.ArgumentParser(
        description="HW7: Beam pipeline (local or Dataflow)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_local = sub.add_parser("local", help="BundleBasedDirectRunner on a pages directory")
    p_local.add_argument("--pages-dir", required=True)
    p_local.add_argument("--output-dir", required=True)
    p_local.add_argument(
        "--max-files",
        type=int,
        default=None,
        metavar="N",
        help="Only first N files (sorted by path), for quick tests.",
    )

    p_df = sub.add_parser("dataflow", help="DataflowRunner on GCS")
    p_df.add_argument("--project", required=True)
    p_df.add_argument("--region", default="us-central1")
    p_df.add_argument("--input-pattern", required=True, help="e.g. gs://bucket/pages/*.html")
    p_df.add_argument(
        "--output-prefix",
        required=True,
        help="e.g. gs://bucket/hw7/run1 → run1_incoming-*.txt, ...",
    )
    p_df.add_argument(
        "--num-workers",
        type=int,
        default=1,
        help="Worker VMs (default 1; fewer VMs avoids zone stockouts).",
    )
    p_df.add_argument(
        "--machine-type",
        default="e2-medium",
        help=(
            "Worker VM type (default e2-medium). If zones are exhausted, try n1-standard-1 "
            "or e2-small."
        ),
    )
    p_df.add_argument(
        "--worker-zone",
        default=None,
        metavar="ZONE",
        help=(
            "Force workers into this zone"
            '(e.g. errors only mention "us-east1-c" → try --worker-zone us-east1-b or '
            "us-east1-d)."
        ),
    )

    args = parser.parse_args()

    if args.command == "local":
        if not os.path.isdir(args.pages_dir):
            sys.exit(f"Not a directory: {args.pages_dir}")
        run_local(args.pages_dir, args.output_dir, args.max_files)
    else:
        if not args.input_pattern.startswith("gs://"):
            sys.exit("--input-pattern must start with gs://")
        if not args.output_prefix.startswith("gs://"):
            sys.exit("--output-prefix must start with gs://")
        run_dataflow(
            args.project,
            args.region,
            args.input_pattern,
            args.output_prefix.rstrip("/"),
            args.num_workers,
            args.machine_type,
            worker_zone=args.worker_zone,
        )


if __name__ == "__main__":
    main()

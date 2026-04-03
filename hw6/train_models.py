import argparse
import os
import subprocess
import tempfile
from dataclasses import dataclass

import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import accuracy_score
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OrdinalEncoder, TargetEncoder
from sqlalchemy import create_engine, text


@dataclass
class ModelArtifacts:
    accuracy: float
    output_file: str


def load_data(database_url: str) -> pd.DataFrame:
    engine = create_engine(database_url, pool_pre_ping=True)
    sql = text(
        """
        SELECT
            re.event_id,
            ip.client_ip,
            c.country_name AS country,
            d.gender,
            d.age,
            d.income,
            re.is_banned,
            re.time_of_day,
            re.requested_file,
            re.request_time
        FROM request_events re
        JOIN ip_addresses ip ON ip.ip_id = re.ip_id
        JOIN countries c ON c.country_id = ip.country_id
        JOIN demographics d ON d.demographic_id = re.demographic_id
        """
    )
    with engine.connect() as conn:
        return pd.read_sql(sql, conn)


def load_demo_dataframe(n_rows: int = 8000) -> pd.DataFrame:
    n = max(100, int(n_rows))
    rng = pd.date_range("2025-01-01", periods=n, freq="min", tz="UTC")
    ips = [f"10.0.0.{i % 50}" for i in range(n)]
    countries = ["A" if "10.0.0.0" <= ip <= "10.0.0.24" else "B" for ip in ips]
    return pd.DataFrame(
        {
            "event_id": range(n),
            "client_ip": ips,
            "country": countries,
            "gender": (["M", "F"] * (n // 2)) + (["M"] if n % 2 else []),
            "age": [20 + (i % 40) for i in range(n)],
            "income": (["low", "med", "high"] * (n // 3)) + ["low"] * (n % 3),
            "is_banned": [False] * n,
            "time_of_day": ["12:00:00"] * n,
            "requested_file": [f"p{i % 10}" for i in range(n)],
            "request_time": rng,
        }
    )


def train_country_model(df: pd.DataFrame, output_prefix: str, output_dir: str = ".") -> ModelArtifacts:
    data = df[["client_ip", "country"]].dropna().copy()
    train_parts: list[pd.DataFrame] = []
    test_parts: list[pd.DataFrame] = []
    for _, g in data.groupby("client_ip", sort=False):
        if len(g) < 2:
            train_parts.append(g)
            continue
        tr, te = train_test_split(g, test_size=0.2, random_state=42)
        train_parts.append(tr)
        test_parts.append(te)
    train_df = pd.concat(train_parts, axis=0) if train_parts else data.iloc[0:0]
    test_df = pd.concat(test_parts, axis=0) if test_parts else data.iloc[0:0]
    if test_df.empty:
        train_df, test_df = train_test_split(data, test_size=0.2, random_state=42)

    # Memorization model: learns IP -> country mapping from training data.
    ip_to_country = train_df.groupby("client_ip")["country"].agg(lambda x: x.mode().iat[0]).to_dict()
    majority_country = train_df["country"].mode().iat[0]

    test_pred = test_df["client_ip"].map(ip_to_country).fillna(majority_country)
    acc = accuracy_score(test_df["country"], test_pred)

    basename = f"{output_prefix}_country_test_predictions.csv"
    out_path = os.path.join(output_dir, basename)
    test_out = test_df.copy()
    test_out["predicted_country"] = test_pred
    test_out.to_csv(out_path, index=False)

    return ModelArtifacts(accuracy=acc, output_file=basename)


def train_income_model(df: pd.DataFrame, output_prefix: str, output_dir: str = ".") -> ModelArtifacts:
    data = df.copy()
    data["hour"] = pd.to_datetime(data["request_time"], utc=True, errors="coerce").dt.hour.fillna(-1).astype(int)
    data["age"] = data["age"].fillna(-1).astype(int)
    data["is_banned"] = data["is_banned"].astype(int)
    data["income"] = data["income"].fillna("Unknown")

    # TargetEncoder + HistGradientBoostingClassifier on full dataset.
    # TargetEncoder encodes high-cardinality categoricals (client_ip, country) as
    # per-class mean targets, capturing IP->income signal 
    features = ["client_ip", "country", "gender", "age", "is_banned", "time_of_day", "hour"]
    X = data[features]
    y = data["income"]

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=7, stratify=y
    )

    # High-cardinality cols → TargetEncoder (fit on training data only via Pipeline)
    target_encode_cols = ["client_ip", "country"]
    # Low-cardinality categoricals → OrdinalEncoder
    ordinal_cols = ["gender", "time_of_day"]
    num_cols = ["age", "is_banned", "hour"]

    preprocessor = ColumnTransformer(
        transformers=[
            ("te", TargetEncoder(random_state=7), target_encode_cols),
            ("oe", OrdinalEncoder(handle_unknown="use_encoded_value", unknown_value=-1), ordinal_cols),
            ("num", "passthrough", num_cols),
        ]
    )

    model = HistGradientBoostingClassifier(
        max_iter=300,
        learning_rate=0.05,
        max_depth=6,
        random_state=7,
    )
    pipeline = Pipeline(steps=[("prep", preprocessor), ("model", model)])
    pipeline.fit(X_train, y_train)

    preds = pipeline.predict(X_test)
    acc = accuracy_score(y_test, preds)

    basename = f"{output_prefix}_income_test_predictions.csv"
    out_path = os.path.join(output_dir, basename)
    out_df = X_test.copy()
    out_df["actual_income"] = y_test.values
    out_df["predicted_income"] = preds
    out_df.to_csv(out_path, index=False)

    return ModelArtifacts(accuracy=acc, output_file=basename)


def upload_file(bucket_name: str, local_file: str, remote_blob: str) -> None:
    from google.auth.exceptions import DefaultCredentialsError

    dest = f"gs://{bucket_name}/{remote_blob}"
    try:
        from google.cloud import storage

        client = storage.Client()
        client.bucket(bucket_name).blob(remote_blob).upload_from_filename(local_file)
        return
    except DefaultCredentialsError:
        pass

    try:
        subprocess.run(["gcloud", "storage", "cp", local_file, dest], check=True)
        return
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass

    try:
        subprocess.run(["gsutil", "cp", local_file, dest], check=True)
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        raise RuntimeError(
            "Could not upload to GCS: on the assignment VM the service account is used automatically; "
            "locally install the Google Cloud SDK, run `gcloud auth login`, and ensure "
            "`gcloud storage` or `gsutil` works for your bucket."
        ) from exc


_MARKER_BODY = "HW6 model output prefix (auto-created).\n"


def ensure_bucket_prefix(bucket_name: str, prefix: str) -> None:
    prefix = prefix.strip().strip("/")
    marker_blob = f"{prefix}/.hw6_prefix"
    try:
        from google.auth.exceptions import DefaultCredentialsError
        from google.cloud import storage

        client = storage.Client()
        bucket = client.bucket(bucket_name)
        if any(bucket.list_blobs(prefix=f"{prefix}/", max_results=1)):
            return
        bucket.blob(marker_blob).upload_from_string(_MARKER_BODY, content_type="text/plain")
        print(f"created gs://{bucket_name}/{marker_blob}")
        return
    except DefaultCredentialsError:
        pass

    dest = f"gs://{bucket_name}/{marker_blob}"
    list_prefix = f"gs://{bucket_name}/{prefix}/"
    try:
        out = subprocess.run(
            ["gsutil", "ls", list_prefix],
            check=False,
            capture_output=True,
            text=True,
        )
        if out.returncode == 0 and out.stdout.strip():
            return
    except FileNotFoundError:
        pass

    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False, suffix=".txt") as f:
        f.write(_MARKER_BODY)
        tmp = f.name
    try:
        upload_file(bucket_name, tmp, marker_blob)
        print(f"created gs://{bucket_name}/{marker_blob}")
    finally:
        os.unlink(tmp)


def write_metrics(
    output_prefix: str,
    country_artifacts: ModelArtifacts,
    income_artifacts: ModelArtifacts,
    *,
    data_source: str = "database",
    output_dir: str = ".",
) -> str:
    basename = f"{output_prefix}_metrics.txt"
    metrics_path = os.path.join(output_dir, basename)
    with open(metrics_path, "w", encoding="utf-8") as f:
        f.write(f"data_source={data_source}\n")
        f.write(
            "note=Each model uses its own held-out test set; see country_test_output and income_test_output.\n"
        )
        f.write(f"country_model_accuracy={country_artifacts.accuracy:.4f}\n")
        f.write(f"income_model_accuracy={income_artifacts.accuracy:.4f}\n")
        f.write(f"country_test_output={country_artifacts.output_file}\n")
        f.write(f"income_test_output={income_artifacts.output_file}\n")
        if country_artifacts.accuracy < 0.99:
            f.write(
                "warning=Country model accuracy is below 99%; check for conflicting countries per IP in source data or inconsistent labels.\n"
            )
        if income_artifacts.accuracy < 0.40:
            f.write("warning=Income model accuracy is below 40%; this can vary with label imbalance and random split.\n")
    return metrics_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Train country + income models on held-out test sets; write two CSVs + metrics, "
            "then upload to GCS. Use --demo to run without MySQL (synthetic data)."
        )
    )
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Use built-in synthetic data instead of DATABASE_URL (no DB required).",
    )
    parser.add_argument(
        "--demo-rows",
        type=int,
        default=8000,
        help="Number of synthetic rows when --demo is set (default: 8000).",
    )
    parser.add_argument("--database-url", default=os.environ.get("DATABASE_URL", ""))
    parser.add_argument("--bucket-name", default=os.environ.get("BUCKET_NAME", ""))
    parser.add_argument("--output-prefix", default="hw6_outputs")
    parser.add_argument("--bucket-prefix", default="hw6/model_outputs")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not args.bucket_name:
        raise RuntimeError("bucket name must be provided with --bucket-name or BUCKET_NAME")

    if args.demo:
        df = load_demo_dataframe(args.demo_rows)
        data_source = "demo_synthetic"
    else:
        if not args.database_url:
            raise RuntimeError(
                "database URL must be provided with --database-url or DATABASE_URL "
                "(or use --demo to train without a database)"
            )
        df = load_data(args.database_url)
        if df.empty:
            raise RuntimeError("No rows found in normalized tables. Run normalize_schema.py first.")
        data_source = "database"

    with tempfile.TemporaryDirectory() as out_dir:
        country_artifacts = train_country_model(df, args.output_prefix, out_dir)
        income_artifacts = train_income_model(df, args.output_prefix, out_dir)
        metrics_path = write_metrics(
            args.output_prefix,
            country_artifacts,
            income_artifacts,
            data_source=data_source,
            output_dir=out_dir,
        )

        ensure_bucket_prefix(args.bucket_name, args.bucket_prefix)

        uploads = [
            (
                os.path.join(out_dir, country_artifacts.output_file),
                f"{args.bucket_prefix}/{country_artifacts.output_file}",
            ),
            (
                os.path.join(out_dir, income_artifacts.output_file),
                f"{args.bucket_prefix}/{income_artifacts.output_file}",
            ),
            (metrics_path, f"{args.bucket_prefix}/{os.path.basename(metrics_path)}"),
        ]
        for local_file, remote_blob in uploads:
            upload_file(args.bucket_name, local_file, remote_blob)
            print(f"uploaded gs://{args.bucket_name}/{remote_blob}")

    print(f"country_model_accuracy={country_artifacts.accuracy:.4f}")
    print(f"income_model_accuracy={income_artifacts.accuracy:.4f}")


if __name__ == "__main__":
    main()

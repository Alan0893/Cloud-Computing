import argparse
import os
import subprocess
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


def train_country_model(df: pd.DataFrame, output_prefix: str) -> ModelArtifacts:
    data = df[["client_ip", "country"]].dropna().copy()
    train_df, test_df = train_test_split(data, test_size=0.2, random_state=42)

    # Memorization model: learns IP -> country mapping from training data.
    ip_to_country = train_df.groupby("client_ip")["country"].agg(lambda x: x.mode().iat[0]).to_dict()
    majority_country = train_df["country"].mode().iat[0]

    test_pred = test_df["client_ip"].map(ip_to_country).fillna(majority_country)
    acc = accuracy_score(test_df["country"], test_pred)

    out_file = f"{output_prefix}_country_test_predictions.csv"
    test_out = test_df.copy()
    test_out["predicted_country"] = test_pred
    test_out.to_csv(out_file, index=False)

    return ModelArtifacts(accuracy=acc, output_file=out_file)


def train_income_model(df: pd.DataFrame, output_prefix: str) -> ModelArtifacts:
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

    out_file = f"{output_prefix}_income_test_predictions.csv"
    out_df = X_test.copy()
    out_df["actual_income"] = y_test.values
    out_df["predicted_income"] = preds
    out_df.to_csv(out_file, index=False)

    return ModelArtifacts(accuracy=acc, output_file=out_file)


def upload_file(bucket_name: str, local_file: str, remote_blob: str) -> None:
    dest = f"gs://{bucket_name}/{remote_blob}"
    subprocess.run(["gsutil", "cp", local_file, dest], check=True)


def write_metrics(
    output_prefix: str,
    country_artifacts: ModelArtifacts,
    income_artifacts: ModelArtifacts,
) -> str:
    metrics_file = f"{output_prefix}_metrics.txt"
    with open(metrics_file, "w", encoding="utf-8") as f:
        f.write(f"country_model_accuracy={country_artifacts.accuracy:.4f}\n")
        f.write(f"income_model_accuracy={income_artifacts.accuracy:.4f}\n")
        f.write(f"country_test_output={country_artifacts.output_file}\n")
        f.write(f"income_test_output={income_artifacts.output_file}\n")
        if country_artifacts.accuracy < 0.99:
            f.write("warning=Country model accuracy is below 99%; likely due to unseen IPs in test split.\n")
        if income_artifacts.accuracy < 0.40:
            f.write("warning=Income model accuracy is below 40%; this can vary with label imbalance and random split.\n")
    return metrics_file


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database-url", default=os.environ.get("DATABASE_URL", ""))
    parser.add_argument("--bucket-name", default=os.environ.get("BUCKET_NAME", ""))
    parser.add_argument("--output-prefix", default="hw6_outputs")
    parser.add_argument("--bucket-prefix", default="hw6/model_outputs")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if not args.database_url:
        raise RuntimeError("database URL must be provided with --database-url or DATABASE_URL")
    if not args.bucket_name:
        raise RuntimeError("bucket name must be provided with --bucket-name or BUCKET_NAME")

    df = load_data(args.database_url)
    if df.empty:
        raise RuntimeError("No rows found in normalized tables. Run normalize_schema.py first.")

    country_artifacts = train_country_model(df, args.output_prefix)
    income_artifacts = train_income_model(df, args.output_prefix)
    metrics_file = write_metrics(args.output_prefix, country_artifacts, income_artifacts)

    uploads = [
        (country_artifacts.output_file, f"{args.bucket_prefix}/{country_artifacts.output_file}"),
        (income_artifacts.output_file, f"{args.bucket_prefix}/{income_artifacts.output_file}"),
        (metrics_file, f"{args.bucket_prefix}/{metrics_file}"),
    ]
    for local_file, remote_blob in uploads:
        upload_file(args.bucket_name, local_file, remote_blob)
        print(f"uploaded gs://{args.bucket_name}/{remote_blob}")

    print(f"country_model_accuracy={country_artifacts.accuracy:.4f}")
    print(f"income_model_accuracy={income_artifacts.accuracy:.4f}")


if __name__ == "__main__":
    main()

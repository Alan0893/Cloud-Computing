import os
import tempfile
from pathlib import Path

import pandas as pd

from train_models import train_country_model, train_income_model, write_metrics


def _synthetic_df(n: int = 500) -> pd.DataFrame:
    rng = pd.date_range("2025-01-01", periods=n, freq="min", tz="UTC")
    ips = [f"10.0.0.{i % 50}" for i in range(n)]
    countries = ["A" if "10.0.0.0" <= ip <= "10.0.0.24" else "B" for ip in ips]
    return pd.DataFrame(
        {
            "event_id": range(n),
            "client_ip": ips,
            "country": countries,
            "gender": ["M", "F"] * (n // 2) + (["M"] if n % 2 else []),
            "age": [20 + (i % 40) for i in range(n)],
            "income": ["low", "med", "high"] * (n // 3) + ["low"] * (n % 3),
            "is_banned": [False] * n,
            "time_of_day": ["12:00:00"] * n,
            "requested_file": [f"p{i % 10}" for i in range(n)],
            "request_time": rng,
        }
    )


def main() -> None:
    df = _synthetic_df(400)
    with tempfile.TemporaryDirectory() as tmp:
        os.chdir(tmp)
        prefix = "hw6_test_outputs"
        c = train_country_model(df, prefix)
        i = train_income_model(df, prefix)
        mpath = write_metrics(prefix, c, i)

        assert Path(c.output_file).is_file(), f"missing {c.output_file}"
        assert Path(i.output_file).is_file(), f"missing {i.output_file}"
        assert Path(mpath).is_file(), f"missing {mpath}"

        c_df = pd.read_csv(c.output_file)
        i_df = pd.read_csv(i.output_file)
        assert "predicted_country" in c_df.columns
        assert "actual_income" in i_df.columns and "predicted_income" in i_df.columns
        # ~20% test split
        assert 0.15 * len(df) <= len(c_df) <= 0.25 * len(df)
        assert len(c_df) == len(i_df)

        text = Path(mpath).read_text(encoding="utf-8")
        assert "country_model_accuracy=" in text
        assert "income_model_accuracy=" in text
        assert "country_test_output=" in text
        assert "income_test_output=" in text

        print("OK: separate test-set CSVs + metrics with accuracies")
        print(text.strip())


if __name__ == "__main__":
    main()

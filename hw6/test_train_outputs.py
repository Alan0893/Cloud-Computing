import os
import tempfile
from pathlib import Path

import pandas as pd

from train_models import load_demo_dataframe, train_country_model, train_income_model, write_metrics


def main() -> None:
    df = load_demo_dataframe(400)
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
        # ~20% test split per model (country uses within-IP split; income uses stratified row split)
        assert 0.15 * len(df) <= len(c_df) <= 0.25 * len(df)
        assert 0.15 * len(df) <= len(i_df) <= 0.25 * len(df)

        text = Path(mpath).read_text(encoding="utf-8")
        assert "data_source=" in text
        assert "country_model_accuracy=" in text
        assert "income_model_accuracy=" in text
        assert "country_test_output=" in text
        assert "income_test_output=" in text

        print("OK: separate test-set CSVs + metrics with accuracies")
        print(text.strip())


if __name__ == "__main__":
    main()

# Build Guide: ADK Anomaly Detection Agent

Step-by-step walkthrough to rebuild this project from scratch in a GCP sandbox environment.

## Prerequisites

- GCP project with BigQuery enabled
- Cloud Shell access
- Gemini API key from [AI Studio](https://aistudio.google.com/apikey)
- Cloud Storage bucket

## Sandbox Safety

All services used are confirmed safe for GCP sandbox:

| Service | Level of Support | Our Usage |
|---------|-----------------|-----------|
| BigQuery | Supported | Dataset, tables, ML models |
| BigQuery ML | Supported (part of BigQuery) | ARIMA_PLUS models |
| Cloud Storage | Supported | CSV staging |
| Cloud Shell | Supported | CLI development |
| ADK + AI Studio | External API (no sandbox impact) | Gemini 2.5 Flash |

**Avoided**: Vertex AI (not supported), Cloud Run (conditional), Compute Engine, Cloud Functions.

---

## Phase 1: Environment Setup and Data Generation

### 1.1 Set Project

```bash
gcloud config set project YOUR_PROJECT_ID
bq ls
```

### 1.2 Create Dataset

```bash
bq mk --location=US anomaly_detection
```

### 1.3 Generate Synthetic Data

```bash
mkdir -p ~/adk-anomaly-detection/scripts
# Copy scripts/generate_data.py to this location
python3 ~/adk-anomaly-detection/scripts/generate_data.py
```

Output: 45,650 rows in `/tmp/fct_daily_sales.csv` and 10 anomaly references in `/tmp/anomaly_reference.csv`.

Data characteristics:
- 5 years (2020-01-01 to 2024-12-30), 1,826 days
- 5 regions x 5 categories = 25 combinations per day
- Seasonal patterns: holiday spike (Nov/Dec), summer bump (Jun/Jul), January dip
- Weekly patterns: weekend higher, Monday lower
- Growth trend: 3% annual
- 10 injected anomaly windows: revenue drops, surges, stockout spikes

### 1.4 Upload to Cloud Storage

```bash
gsutil cp /tmp/fct_daily_sales.csv gs://YOUR_BUCKET/anomaly_detection/
gsutil cp /tmp/anomaly_reference.csv gs://YOUR_BUCKET/anomaly_detection/
```

### 1.5 Load into BigQuery

```bash
bq load --source_format=CSV --skip_leading_rows=1 --autodetect \
  anomaly_detection.fct_daily_sales \
  gs://YOUR_BUCKET/anomaly_detection/fct_daily_sales.csv

bq load --source_format=CSV --skip_leading_rows=1 --autodetect \
  anomaly_detection.anomaly_reference \
  gs://YOUR_BUCKET/anomaly_detection/anomaly_reference.csv
```

### 1.6 Validate

```bash
bq query --use_legacy_sql=false '
SELECT COUNT(*) as total_rows, MIN(sale_date) as min_date, MAX(sale_date) as max_date,
  COUNT(DISTINCT region) as regions, COUNT(DISTINCT category) as categories,
  ROUND(SUM(revenue), 2) as total_revenue,
  SUM(CASE WHEN is_anomaly = true THEN 1 ELSE 0 END) as anomaly_rows
FROM anomaly_detection.fct_daily_sales'
```

Expected: 45,650 rows, 5 regions, 5 categories, approximately $2.92B revenue.

---

## Phase 2: BigQuery ML Models and Anomaly Detection

### 2.1 Create Aggregated Daily Totals

```bash
bq query --use_legacy_sql=false '
CREATE OR REPLACE TABLE anomaly_detection.daily_totals AS
SELECT sale_date,
  ROUND(SUM(revenue), 2) AS total_revenue,
  SUM(order_count) AS total_orders,
  SUM(stockout_count) AS total_stockouts,
  LOGICAL_OR(is_anomaly) AS has_anomaly
FROM anomaly_detection.fct_daily_sales
GROUP BY sale_date ORDER BY sale_date'
```

### 2.2 Train Revenue ARIMA_PLUS Model

```bash
bq query --use_legacy_sql=false '
CREATE OR REPLACE MODEL anomaly_detection.revenue_forecast_model
OPTIONS(model_type="ARIMA_PLUS", time_series_timestamp_col="sale_date",
  time_series_data_col="total_revenue", auto_arima=TRUE,
  data_frequency="DAILY", holiday_region="US")
AS SELECT sale_date, total_revenue FROM anomaly_detection.daily_totals'
```

Training takes 1-3 minutes. Model auto-detects weekly and yearly seasonality.

### 2.3 Train Stockout ARIMA_PLUS Model

```bash
bq query --use_legacy_sql=false '
CREATE OR REPLACE MODEL anomaly_detection.stockout_forecast_model
OPTIONS(model_type="ARIMA_PLUS", time_series_timestamp_col="sale_date",
  time_series_data_col="total_stockouts", auto_arima=TRUE,
  data_frequency="DAILY", holiday_region="US")
AS SELECT sale_date, CAST(total_stockouts AS FLOAT64) AS total_stockouts
FROM anomaly_detection.daily_totals'
```

### 2.4 Detect Revenue Anomalies (Z-score)

Note: We use Z-score detection instead of ML.DETECT_ANOMALIES because the ARIMA_PLUS model's has_spikes_and_dips feature absorbs anomalies into its decomposition, causing ML.DETECT_ANOMALIES to return NULL probabilities for all rows. See QA_GUIDE.md Part 1 for full explanation.

```bash
bq query --use_legacy_sql=false '
CREATE OR REPLACE TABLE anomaly_detection.revenue_anomalies AS
WITH rolling AS (
  SELECT sale_date, total_revenue, has_anomaly AS injected_anomaly,
    AVG(total_revenue) OVER (ORDER BY sale_date ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING) AS rolling_avg,
    STDDEV(total_revenue) OVER (ORDER BY sale_date ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING) AS rolling_std
  FROM anomaly_detection.daily_totals
)
SELECT sale_date, total_revenue, rolling_avg, rolling_std,
  ROUND((total_revenue - rolling_avg) / NULLIF(rolling_std, 0), 2) AS z_score,
  CASE
    WHEN (total_revenue - rolling_avg) / NULLIF(rolling_std, 0) < -2.0 THEN "revenue_drop"
    WHEN (total_revenue - rolling_avg) / NULLIF(rolling_std, 0) > 2.0 THEN "revenue_surge"
    ELSE "normal"
  END AS detected_type, injected_anomaly
FROM rolling
WHERE ABS((total_revenue - rolling_avg) / NULLIF(rolling_std, 0)) > 2.0
ORDER BY sale_date'
```

### 2.5 Detect Stockout Anomalies (Z-score)

```bash
bq query --use_legacy_sql=false '
CREATE OR REPLACE TABLE anomaly_detection.stockout_anomalies AS
WITH rolling AS (
  SELECT sale_date, total_stockouts, has_anomaly AS injected_anomaly,
    AVG(total_stockouts) OVER (ORDER BY sale_date ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING) AS rolling_avg,
    STDDEV(total_stockouts) OVER (ORDER BY sale_date ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING) AS rolling_std
  FROM anomaly_detection.daily_totals
)
SELECT sale_date, total_stockouts, rolling_avg, rolling_std,
  ROUND((total_stockouts - rolling_avg) / NULLIF(rolling_std, 0), 2) AS z_score,
  CASE
    WHEN (total_stockouts - rolling_avg) / NULLIF(rolling_std, 0) > 2.0 THEN "stockout_spike"
    ELSE "normal"
  END AS detected_type, injected_anomaly
FROM rolling
WHERE (total_stockouts - rolling_avg) / NULLIF(rolling_std, 0) > 2.0
ORDER BY sale_date'
```

### 2.6 Validate

```bash
bq query --use_legacy_sql=false '
SELECT COUNT(*) as anomalies_found, COUNTIF(injected_anomaly) as matched_injected
FROM anomaly_detection.revenue_anomalies'

bq query --use_legacy_sql=false '
SELECT COUNT(*) as anomalies_found, COUNTIF(injected_anomaly) as matched_injected
FROM anomaly_detection.stockout_anomalies'

bq ls anomaly_detection
```

Expected: 108 revenue anomalies (31 matched), 119 stockout anomalies (36 matched), 5 tables + 2 models.

---

## Phase 3: Build ADK Agent

### 3.1 Create Project Structure

```bash
mkdir -p ~/adk-anomaly-detection/anomaly_detection_agent
```

### 3.2 Create Files

Copy the following files from this repository:
- `anomaly_detection_agent/__init__.py`
- `anomaly_detection_agent/agent.py`
- `anomaly_detection_agent/tools.py`
- `requirements.txt`

### 3.3 Install Dependencies

```bash
cd ~/adk-anomaly-detection
pip install -r requirements.txt --break-system-packages
export PATH="$HOME/.local/bin:$PATH"
```

### 3.4 Test Tools

```bash
python3 -c "
from anomaly_detection_agent.tools import get_anomaly_summary
result = get_anomaly_summary()
print('Status:', result['status'])
print('Revenue types:', result['revenue_anomaly_types'])
print('Known events:', len(result['known_events']))
"
```

### 3.5 Launch Agent

```bash
export GOOGLE_GENAI_USE_VERTEXAI=FALSE
export GOOGLE_API_KEY="your-api-key"
cd ~/adk-anomaly-detection
adk web .
```

Select `anomaly_detection_agent` from the dropdown and test.

---

## Phase 4: Documentation and GitHub

### 4.1 Initialize Repository

```bash
cd ~/adk-anomaly-detection
git init
git add .
git commit -m "feat: ADK anomaly detection agent with BigQuery ML"
```

### 4.2 Push to GitHub

```bash
git remote add origin https://github.com/gbhorne/adk-anomaly-detection.git
git branch -M main
git push -u origin main
```

---

## Issues Encountered and Resolved

| Issue | Resolution |
|-------|-----------|
| ML.DETECT_ANOMALIES returned NULL probabilities | ARIMA_PLUS has_spikes_and_dips absorbed anomalies into decomposition. Switched to Z-score statistical detection for historical analysis. |
| ML.EXPLAIN_FORECAST with horizon=0 | Horizon must be at least 1. Used ML.FORECAST for future predictions only. |
| "Object of type date is not JSON serializable" | BigQuery returns datetime.date objects. Added _run_query helper that converts dates to ISO strings and Decimals to floats. |
| ADK web UI shows empty dropdown | Must run `adk web .` from the parent directory containing the agent package. |
| PATH warning for adk command | Added `export PATH="$HOME/.local/bin:$PATH"` after pip install. |

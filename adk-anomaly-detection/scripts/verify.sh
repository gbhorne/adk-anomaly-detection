#!/bin/bash
# verify.sh - Full verification script for ADK Anomaly Detection Agent
# Run from Cloud Shell: bash ~/adk-anomaly-detection/scripts/verify.sh
#
# This script validates all data, models, anomaly detection results,
# and agent tool functionality. It produces a proof-of-work summary.

set -e

PROJECT_ID="playground-s-11-362011b0"
DATASET="anomaly_detection"
PASS=0
FAIL=0
TOTAL=0

green() { echo -e "\033[32m[PASS]\033[0m $1"; }
red() { echo -e "\033[31m[FAIL]\033[0m $1"; }
header() { echo ""; echo "========================================"; echo "  $1"; echo "========================================"; }

check() {
    TOTAL=$((TOTAL + 1))
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$actual" = "$expected" ]; then
        green "$desc (expected: $expected, got: $actual)"
        PASS=$((PASS + 1))
    else
        red "$desc (expected: $expected, got: $actual)"
        FAIL=$((FAIL + 1))
    fi
}

check_gte() {
    TOTAL=$((TOTAL + 1))
    local desc="$1"
    local minimum="$2"
    local actual="$3"
    if [ "$actual" -ge "$minimum" ] 2>/dev/null; then
        green "$desc (minimum: $minimum, got: $actual)"
        PASS=$((PASS + 1))
    else
        red "$desc (minimum: $minimum, got: $actual)"
        FAIL=$((FAIL + 1))
    fi
}

echo "============================================================"
echo "  ADK ANOMALY DETECTION AGENT - VERIFICATION REPORT"
echo "  Project: $PROJECT_ID"
echo "  Dataset: $DATASET"
echo "  Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"

# ---------------------------------------------------------------
header "1. DATASET AND TABLE EXISTENCE"
# ---------------------------------------------------------------

TABLES=$(bq ls $DATASET 2>/dev/null | grep TABLE | wc -l)
check "Number of tables in dataset" "5" "$TABLES"

MODELS=$(bq ls --models $DATASET 2>/dev/null | grep -c "MODEL" || echo "0")
# bq ls --models may not show MODEL keyword; count non-header lines
MODELS=$(bq ls --models $DATASET 2>/dev/null | tail -n +3 | grep -v "^$" | wc -l)
check "Number of ML models in dataset" "2" "$MODELS"

for TABLE in fct_daily_sales daily_totals revenue_anomalies stockout_anomalies anomaly_reference; do
    EXISTS=$(bq show $DATASET.$TABLE 2>/dev/null | grep -c "Table" || echo "0")
    TOTAL=$((TOTAL + 1))
    if [ "$EXISTS" -ge "1" ]; then
        green "Table exists: $TABLE"
        PASS=$((PASS + 1))
    else
        red "Table missing: $TABLE"
        FAIL=$((FAIL + 1))
    fi
done

# ---------------------------------------------------------------
header "2. DATA VOLUME AND INTEGRITY"
# ---------------------------------------------------------------

ROW_COUNT=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT COUNT(*) FROM '"$PROJECT_ID.$DATASET"'.fct_daily_sales' | tail -1)
check "fct_daily_sales row count" "45650" "$ROW_COUNT"

DAILY_COUNT=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT COUNT(*) FROM '"$PROJECT_ID.$DATASET"'.daily_totals' | tail -1)
check "daily_totals row count" "1826" "$DAILY_COUNT"

REF_COUNT=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT COUNT(*) FROM '"$PROJECT_ID.$DATASET"'.anomaly_reference' | tail -1)
check "anomaly_reference row count" "10" "$REF_COUNT"

REGIONS=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT COUNT(DISTINCT region) FROM '"$PROJECT_ID.$DATASET"'.fct_daily_sales' | tail -1)
check "Distinct regions" "5" "$REGIONS"

CATEGORIES=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT COUNT(DISTINCT category) FROM '"$PROJECT_ID.$DATASET"'.fct_daily_sales' | tail -1)
check "Distinct categories" "5" "$CATEGORIES"

MIN_DATE=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT MIN(sale_date) FROM '"$PROJECT_ID.$DATASET"'.fct_daily_sales' | tail -1)
check "Earliest date" "2020-01-01" "$MIN_DATE"

MAX_DATE=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT MAX(sale_date) FROM '"$PROJECT_ID.$DATASET"'.fct_daily_sales' | tail -1)
check "Latest date" "2024-12-30" "$MAX_DATE"

ANOMALY_ROWS=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT SUM(CASE WHEN is_anomaly = true THEN 1 ELSE 0 END) FROM '"$PROJECT_ID.$DATASET"'.fct_daily_sales' | tail -1)
check_gte "Rows with injected anomalies" "1900" "$ANOMALY_ROWS"

# ---------------------------------------------------------------
header "3. REVENUE ANOMALY DETECTION"
# ---------------------------------------------------------------

REV_ANOMALIES=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT COUNT(*) FROM '"$PROJECT_ID.$DATASET"'.revenue_anomalies' | tail -1)
check_gte "Revenue anomalies detected" "100" "$REV_ANOMALIES"

REV_MATCHED=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT COUNTIF(injected_anomaly) FROM '"$PROJECT_ID.$DATASET"'.revenue_anomalies' | tail -1)
check_gte "Revenue anomalies matching injected events" "25" "$REV_MATCHED"

REV_DROPS=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT COUNT(*) FROM '"$PROJECT_ID.$DATASET"'.revenue_anomalies WHERE detected_type = "revenue_drop"' | tail -1)
check_gte "Revenue drops detected" "30" "$REV_DROPS"

REV_SURGES=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT COUNT(*) FROM '"$PROJECT_ID.$DATASET"'.revenue_anomalies WHERE detected_type = "revenue_surge"' | tail -1)
check_gte "Revenue surges detected" "50" "$REV_SURGES"

# ---------------------------------------------------------------
header "4. STOCKOUT ANOMALY DETECTION"
# ---------------------------------------------------------------

STOCK_ANOMALIES=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT COUNT(*) FROM '"$PROJECT_ID.$DATASET"'.stockout_anomalies' | tail -1)
check_gte "Stockout anomalies detected" "100" "$STOCK_ANOMALIES"

STOCK_MATCHED=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT COUNTIF(injected_anomaly) FROM '"$PROJECT_ID.$DATASET"'.stockout_anomalies' | tail -1)
check_gte "Stockout anomalies matching injected events" "30" "$STOCK_MATCHED"

MAX_ZSCORE=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT ROUND(MAX(z_score), 2) FROM '"$PROJECT_ID.$DATASET"'.stockout_anomalies' | tail -1)
check_gte "Max stockout Z-score" "80" "${MAX_ZSCORE%.*}"

# ---------------------------------------------------------------
header "5. BIGQUERY ML MODELS"
# ---------------------------------------------------------------

REV_MODEL=$(bq show --model $DATASET.revenue_forecast_model 2>/dev/null | grep -c "ARIMA_PLUS" || echo "0")
TOTAL=$((TOTAL + 1))
if [ "$REV_MODEL" -ge "1" ]; then
    green "Revenue forecast model exists and is ARIMA_PLUS"
    PASS=$((PASS + 1))
else
    red "Revenue forecast model check failed"
    FAIL=$((FAIL + 1))
fi

STOCK_MODEL=$(bq show --model $DATASET.stockout_forecast_model 2>/dev/null | grep -c "ARIMA_PLUS" || echo "0")
TOTAL=$((TOTAL + 1))
if [ "$STOCK_MODEL" -ge "1" ]; then
    green "Stockout forecast model exists and is ARIMA_PLUS"
    PASS=$((PASS + 1))
else
    red "Stockout forecast model check failed"
    FAIL=$((FAIL + 1))
fi

# Test ML.FORECAST works
FORECAST_ROWS=$(bq query --use_legacy_sql=false --format=csv --quiet '
SELECT COUNT(*) FROM ML.FORECAST(MODEL '"$PROJECT_ID.$DATASET"'.revenue_forecast_model, STRUCT(7 AS horizon, 0.95 AS confidence_level))' | tail -1)
check "ML.FORECAST returns 7-day forecast" "7" "$FORECAST_ROWS"

# ---------------------------------------------------------------
header "6. AGENT FILES"
# ---------------------------------------------------------------

for FILE in anomaly_detection_agent/__init__.py anomaly_detection_agent/agent.py anomaly_detection_agent/tools.py anomaly_detection_agent/anomaly_detection_eval.evalset.json requirements.txt; do
    TOTAL=$((TOTAL + 1))
    if [ -f "$HOME/adk-anomaly-detection/$FILE" ]; then
        green "File exists: $FILE"
        PASS=$((PASS + 1))
    else
        red "File missing: $FILE"
        FAIL=$((FAIL + 1))
    fi
done

# Check root_agent is defined
TOTAL=$((TOTAL + 1))
if grep -q "root_agent" "$HOME/adk-anomaly-detection/anomaly_detection_agent/agent.py" 2>/dev/null; then
    green "root_agent defined in agent.py"
    PASS=$((PASS + 1))
else
    red "root_agent not found in agent.py"
    FAIL=$((FAIL + 1))
fi

# Check tool count
TOOL_COUNT=$(grep -c "def get_" "$HOME/adk-anomaly-detection/anomaly_detection_agent/tools.py" 2>/dev/null || echo "0")
check "Tool functions in tools.py" "6" "$TOOL_COUNT"

# ---------------------------------------------------------------
header "7. TOOL FUNCTIONALITY TEST"
# ---------------------------------------------------------------

TOTAL=$((TOTAL + 1))
TOOL_TEST=$(cd "$HOME/adk-anomaly-detection" && python3 -c "
from anomaly_detection_agent.tools import get_anomaly_summary
result = get_anomaly_summary()
assert result['status'] == 'success'
assert len(result['known_events']) == 10
assert len(result['revenue_anomaly_types']) == 2
assert len(result['stockout_anomaly_types']) == 1
print('ALL_TOOLS_OK')
" 2>/dev/null)
if [ "$TOOL_TEST" = "ALL_TOOLS_OK" ]; then
    green "get_anomaly_summary returns valid data"
    PASS=$((PASS + 1))
else
    red "get_anomaly_summary failed"
    FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
TOOL_TEST2=$(cd "$HOME/adk-anomaly-detection" && python3 -c "
from anomaly_detection_agent.tools import get_recent_revenue_anomalies
result = get_recent_revenue_anomalies(days=90)
assert result['status'] == 'success'
assert result['anomaly_count'] > 0
print('REVENUE_OK')
" 2>/dev/null)
if [ "$TOOL_TEST2" = "REVENUE_OK" ]; then
    green "get_recent_revenue_anomalies returns valid data"
    PASS=$((PASS + 1))
else
    red "get_recent_revenue_anomalies failed"
    FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
TOOL_TEST3=$(cd "$HOME/adk-anomaly-detection" && python3 -c "
from anomaly_detection_agent.tools import get_anomaly_detail
result = get_anomaly_detail('2022-06-20')
assert result['status'] == 'success'
assert len(result['regional_breakdown']) == 5
assert len(result['category_breakdown']) == 5
print('DETAIL_OK')
" 2>/dev/null)
if [ "$TOOL_TEST3" = "DETAIL_OK" ]; then
    green "get_anomaly_detail returns 5 regions and 5 categories"
    PASS=$((PASS + 1))
else
    red "get_anomaly_detail failed"
    FAIL=$((FAIL + 1))
fi

TOTAL=$((TOTAL + 1))
TOOL_TEST4=$(cd "$HOME/adk-anomaly-detection" && python3 -c "
from anomaly_detection_agent.tools import get_revenue_forecast
result = get_revenue_forecast(horizon_days=7)
assert result['status'] == 'success'
assert result['forecast_count'] == 7
print('FORECAST_OK')
" 2>/dev/null)
if [ "$TOOL_TEST4" = "FORECAST_OK" ]; then
    green "get_revenue_forecast returns 7-day forecast"
    PASS=$((PASS + 1))
else
    red "get_revenue_forecast failed"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------
header "8. DOCUMENTATION FILES"
# ---------------------------------------------------------------

for FILE in README.md LICENSE .gitignore docs/ARCHITECTURE.md docs/BUILD_GUIDE.md docs/QA_GUIDE.md docs/architecture_diagram.svg scripts/generate_data.py scripts/verify.sh; do
    TOTAL=$((TOTAL + 1))
    if [ -f "$HOME/adk-anomaly-detection/$FILE" ]; then
        green "Doc exists: $FILE"
        PASS=$((PASS + 1))
    else
        red "Doc missing: $FILE"
        FAIL=$((FAIL + 1))
    fi
done

for PNG in 01_adk_welcome_screen.png 02_recent_revenue_anomalies.png 03_anomaly_detail_2022_06_20.png 04_revenue_forecast_30day.png 05_anomaly_summary.png 06_stockout_spikes.png; do
    TOTAL=$((TOTAL + 1))
    if [ -f "$HOME/adk-anomaly-detection/docs/screenshots/$PNG" ]; then
        green "Screenshot exists: $PNG"
        PASS=$((PASS + 1))
    else
        red "Screenshot missing: $PNG"
        FAIL=$((FAIL + 1))
    fi
done

# ---------------------------------------------------------------
header "VERIFICATION SUMMARY"
# ---------------------------------------------------------------

echo ""
echo "  Total checks:  $TOTAL"
echo "  Passed:        $PASS"
echo "  Failed:        $FAIL"
echo ""

if [ "$FAIL" -eq "0" ]; then
    echo -e "  \033[32mALL $TOTAL CHECKS PASSED\033[0m"
else
    echo -e "  \033[31m$FAIL CHECKS FAILED\033[0m"
fi

echo ""
echo "============================================================"
echo "  END OF VERIFICATION REPORT"
echo "============================================================"

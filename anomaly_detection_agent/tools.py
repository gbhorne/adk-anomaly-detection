"""
BigQuery tools for the Anomaly Detection Agent.
6 tools: recent anomalies, anomaly detail, revenue forecast,
stockout forecast, anomaly summary, compare to reference.
"""

from datetime import date, datetime
from decimal import Decimal
from google.cloud import bigquery

PROJECT_ID = "playground-s-11-362011b0"
DATASET = "anomaly_detection"
client = bigquery.Client(project=PROJECT_ID)


def _run_query(sql: str) -> list[dict]:
    """Execute SQL and return list of JSON-safe dicts."""
    rows = client.query(sql).result()
    results = []
    for row in rows:
        clean = {}
        for key, val in dict(row).items():
            if isinstance(val, (date, datetime)):
                clean[key] = val.isoformat()
            elif isinstance(val, Decimal):
                clean[key] = float(val)
            else:
                clean[key] = val
        results.append(clean)
    return results


def get_recent_revenue_anomalies(days: int = 90) -> dict:
    """Get revenue anomalies detected in the last N days of data.

    Args:
        days: Number of recent days to check (default 90).

    Returns:
        dict with status, count, and anomaly details.
    """
    sql = f"""
    SELECT sale_date, total_revenue, rolling_avg, z_score, detected_type
    FROM `{PROJECT_ID}.{DATASET}.revenue_anomalies`
    WHERE sale_date >= (
      SELECT DATE_SUB(MAX(sale_date), INTERVAL {days} DAY)
      FROM `{PROJECT_ID}.{DATASET}.revenue_anomalies`
    )
    ORDER BY sale_date DESC
    """
    results = _run_query(sql)
    return {
        "status": "success",
        "metric": "revenue",
        "period_days": days,
        "anomaly_count": len(results),
        "anomalies": results
    }


def get_recent_stockout_anomalies(days: int = 90) -> dict:
    """Get stockout anomalies detected in the last N days of data.

    Args:
        days: Number of recent days to check (default 90).

    Returns:
        dict with status, count, and anomaly details.
    """
    sql = f"""
    SELECT sale_date, total_stockouts, rolling_avg, z_score, detected_type
    FROM `{PROJECT_ID}.{DATASET}.stockout_anomalies`
    WHERE sale_date >= (
      SELECT DATE_SUB(MAX(sale_date), INTERVAL {days} DAY)
      FROM `{PROJECT_ID}.{DATASET}.stockout_anomalies`
    )
    ORDER BY sale_date DESC
    """
    results = _run_query(sql)
    return {
        "status": "success",
        "metric": "stockouts",
        "period_days": days,
        "anomaly_count": len(results),
        "anomalies": results
    }


def get_anomaly_detail(sale_date: str) -> dict:
    """Get full context for a specific anomaly date including daily breakdown.

    Args:
        sale_date: Date string in YYYY-MM-DD format.

    Returns:
        dict with daily totals, regional breakdown, and category breakdown.
    """
    daily_sql = f"""
    SELECT sale_date, total_revenue, total_orders, total_stockouts, has_anomaly
    FROM `{PROJECT_ID}.{DATASET}.daily_totals`
    WHERE sale_date = '{sale_date}'
    """
    daily = _run_query(daily_sql)

    region_sql = f"""
    SELECT region,
      ROUND(SUM(revenue), 2) AS revenue,
      SUM(order_count) AS orders,
      SUM(stockout_count) AS stockouts
    FROM `{PROJECT_ID}.{DATASET}.fct_daily_sales`
    WHERE sale_date = '{sale_date}'
    GROUP BY region
    ORDER BY revenue DESC
    """
    regions = _run_query(region_sql)

    category_sql = f"""
    SELECT category,
      ROUND(SUM(revenue), 2) AS revenue,
      SUM(order_count) AS orders,
      SUM(stockout_count) AS stockouts
    FROM `{PROJECT_ID}.{DATASET}.fct_daily_sales`
    WHERE sale_date = '{sale_date}'
    GROUP BY category
    ORDER BY revenue DESC
    """
    categories = _run_query(category_sql)

    return {
        "status": "success",
        "date": sale_date,
        "daily_totals": daily,
        "regional_breakdown": regions,
        "category_breakdown": categories
    }


def get_revenue_forecast(horizon_days: int = 30) -> dict:
    """Generate revenue forecast for the next N days using ARIMA_PLUS model.

    Args:
        horizon_days: Number of days to forecast (default 30, max 365).

    Returns:
        dict with forecasted values and confidence intervals.
    """
    horizon_days = min(horizon_days, 365)
    sql = f"""
    SELECT
      forecast_timestamp AS forecast_date,
      ROUND(forecast_value, 2) AS forecasted_revenue,
      ROUND(prediction_interval_lower_bound, 2) AS lower_bound,
      ROUND(prediction_interval_upper_bound, 2) AS upper_bound
    FROM ML.FORECAST(
      MODEL `{PROJECT_ID}.{DATASET}.revenue_forecast_model`,
      STRUCT({horizon_days} AS horizon, 0.95 AS confidence_level)
    )
    ORDER BY forecast_timestamp
    """
    results = _run_query(sql)
    return {
        "status": "success",
        "model": "revenue_forecast_model",
        "horizon_days": horizon_days,
        "forecast_count": len(results),
        "forecasts": results
    }


def get_stockout_forecast(horizon_days: int = 30) -> dict:
    """Generate stockout forecast for the next N days using ARIMA_PLUS model.

    Args:
        horizon_days: Number of days to forecast (default 30, max 365).

    Returns:
        dict with forecasted values and confidence intervals.
    """
    horizon_days = min(horizon_days, 365)
    sql = f"""
    SELECT
      forecast_timestamp AS forecast_date,
      ROUND(forecast_value, 2) AS forecasted_stockouts,
      ROUND(prediction_interval_lower_bound, 2) AS lower_bound,
      ROUND(prediction_interval_upper_bound, 2) AS upper_bound
    FROM ML.FORECAST(
      MODEL `{PROJECT_ID}.{DATASET}.stockout_forecast_model`,
      STRUCT({horizon_days} AS horizon, 0.95 AS confidence_level)
    )
    ORDER BY forecast_timestamp
    """
    results = _run_query(sql)
    return {
        "status": "success",
        "model": "stockout_forecast_model",
        "horizon_days": horizon_days,
        "forecast_count": len(results),
        "forecasts": results
    }


def get_anomaly_summary() -> dict:
    """Get a high-level summary of all detected anomalies across the full dataset.

    Returns:
        dict with total counts, breakdown by type, and monthly distribution.
    """
    rev_type_sql = f"""
    SELECT detected_type, COUNT(*) as count,
      ROUND(AVG(z_score), 2) as avg_z_score,
      ROUND(MIN(z_score), 2) as min_z_score,
      ROUND(MAX(z_score), 2) as max_z_score
    FROM `{PROJECT_ID}.{DATASET}.revenue_anomalies`
    GROUP BY detected_type
    """
    rev_types = _run_query(rev_type_sql)

    stock_type_sql = f"""
    SELECT detected_type, COUNT(*) as count,
      ROUND(AVG(z_score), 2) as avg_z_score,
      ROUND(MIN(z_score), 2) as min_z_score,
      ROUND(MAX(z_score), 2) as max_z_score
    FROM `{PROJECT_ID}.{DATASET}.stockout_anomalies`
    GROUP BY detected_type
    """
    stock_types = _run_query(stock_type_sql)

    monthly_sql = f"""
    SELECT
      FORMAT_DATE('%Y-%m', sale_date) AS month,
      COUNTIF(r.sale_date IS NOT NULL) AS revenue_anomalies,
      COUNTIF(s.sale_date IS NOT NULL) AS stockout_anomalies
    FROM `{PROJECT_ID}.{DATASET}.daily_totals` d
    LEFT JOIN `{PROJECT_ID}.{DATASET}.revenue_anomalies` r USING(sale_date)
    LEFT JOIN `{PROJECT_ID}.{DATASET}.stockout_anomalies` s USING(sale_date)
    WHERE r.sale_date IS NOT NULL OR s.sale_date IS NOT NULL
    GROUP BY month
    ORDER BY month
    """
    monthly = _run_query(monthly_sql)

    ref_sql = f"""
    SELECT * FROM `{PROJECT_ID}.{DATASET}.anomaly_reference`
    ORDER BY start_date
    """
    references = _run_query(ref_sql)

    return {
        "status": "success",
        "revenue_anomaly_types": rev_types,
        "stockout_anomaly_types": stock_types,
        "monthly_distribution": monthly,
        "known_events": references
    }

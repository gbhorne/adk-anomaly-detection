# ADK Anomaly Detection Agent

A retail anomaly detection system built with [Google ADK](https://github.com/google/adk-python) (Agent Development Kit), BigQuery ML ARIMA_PLUS forecasting, and Z-score statistical analysis. The agent monitors 5 years of daily sales data, detects revenue anomalies and stockout spikes, explains findings in natural language, and forecasts future trends with 95% confidence intervals.

**Repository**: [github.com/gbhorne/adk-anomaly-detection](https://github.com/gbhorne/adk-anomaly-detection)

![Architecture Diagram](docs/architecture_diagram.svg)

## Screenshots

| Query | Tool Called | Result |
|-------|-----------|--------|
| "Show me recent revenue anomalies" | `get_recent_revenue_anomalies` | [View](docs/screenshots/02_recent_revenue_anomalies.png) |
| "What happened on 2022-06-20?" | `get_anomaly_detail` | [View](docs/screenshots/03_anomaly_detail_2022_06_20.png) |
| "Give me a 30-day revenue forecast" | `get_revenue_forecast` | [View](docs/screenshots/04_revenue_forecast_30day.png) |
| "Summarize all anomalies across the dataset" | `get_anomaly_summary` | [View](docs/screenshots/05_anomaly_summary.png) |
| "Are there any stockout spikes recently?" | `get_recent_stockout_anomalies` | [View](docs/screenshots/06_stockout_spikes.png) |

![Recent Revenue Anomalies](docs/screenshots/02_recent_revenue_anomalies.png)
![Anomaly Detail Drill-Down](docs/screenshots/03_anomaly_detail_2022_06_20.png)
![Revenue Forecast](docs/screenshots/04_revenue_forecast_30day.png)

## Key Features

- **Anomaly Detection**: Z-score analysis against 30-day rolling averages flags revenue drops, surges, and stockout spikes (threshold: +/- 2.0 standard deviations)
- **Time-Series Forecasting**: BigQuery ML ARIMA_PLUS models trained on 5 years of data predict future revenue and stockout levels with 95% confidence intervals
- **Natural Language Explanations**: Agent explains anomalies with regional and category breakdowns, Z-scores in plain language, and context from known events
- **6 Specialized Tools**: Each tool queries BigQuery with fixed SQL for reliability, security, and cost control

## Dataset

| Metric | Value |
|--------|-------|
| Time range | 2020-01-01 to 2024-12-30 |
| Daily records | 45,650 (5 regions x 5 categories x 1,826 days) |
| Total revenue | $2.92B |
| Regions | Northeast, Southeast, Midwest, West, Southwest |
| Categories | Electronics, Clothing, Home and Garden, Sports, Grocery |
| Injected anomalies | 10 known events (revenue drops, surges, stockout spikes) |
| Detected anomalies | 108 revenue + 119 stockout |

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Agent Framework | Google ADK 1.25.1 |
| LLM | Gemini 2.5 Flash (AI Studio free tier) |
| Data Warehouse | BigQuery |
| ML Models | BigQuery ML ARIMA_PLUS |
| Detection Method | Z-score (30-day rolling window) |
| Language | Python 3.14 |
| Auth | gcloud application-default |
| Cost | $0 (all free tier) |

## Tools

| Tool | Description |
|------|-------------|
| `get_recent_revenue_anomalies(days)` | Revenue anomalies in last N days |
| `get_recent_stockout_anomalies(days)` | Stockout spikes in last N days |
| `get_anomaly_detail(sale_date)` | Regional + category breakdown for a date |
| `get_revenue_forecast(horizon_days)` | ARIMA_PLUS revenue predictions |
| `get_stockout_forecast(horizon_days)` | ARIMA_PLUS stockout predictions |
| `get_anomaly_summary()` | Full dataset anomaly overview with known events |

## Example Queries

```
Show me recent revenue anomalies
What happened on 2022-06-20?
Give me a 30-day revenue forecast
Summarize all anomalies across the dataset
Are there any stockout spikes recently?
Forecast stockouts for the next 2 weeks
Explain the anomaly on January 1, 2023
```

## Project Structure

```
adk-anomaly-detection/
├── README.md
├── LICENSE
├── .gitignore
├── requirements.txt
├── anomaly_detection_agent/
│   ├── __init__.py
│   ├── agent.py                          # ADK agent definition (6 tools)
│   ├── tools.py                          # BigQuery tool functions
│   └── anomaly_detection_eval.evalset.json
├── scripts/
│   ├── generate_data.py                  # Synthetic data generator
│   └── verify.sh                         # Full verification script
└── docs/
    ├── ARCHITECTURE.md                   # 7 ADRs and design decisions
    ├── BUILD_GUIDE.md                    # Step-by-step build walkthrough
    ├── QA_GUIDE.md                       # In-depth Q&A (10 parts)
    ├── architecture_diagram.svg          # Colored SVG (renders on GitHub)
    └── screenshots/                      # 6 named PNGs
```

## Quick Start

### Prerequisites

- Google Cloud project with BigQuery enabled
- Python 3.11+
- gcloud CLI authenticated
- Gemini API key from [AI Studio](https://aistudio.google.com/apikey)

### Setup

```bash
git clone https://github.com/gbhorne/adk-anomaly-detection.git
cd adk-anomaly-detection
pip install -r requirements.txt
export GOOGLE_GENAI_USE_VERTEXAI=FALSE
export GOOGLE_API_KEY="your-api-key"
```

See [docs/BUILD_GUIDE.md](docs/BUILD_GUIDE.md) for full data loading and ML model training steps.

### Launch

```bash
adk web .
```

Select `anomaly_detection_agent` from the dropdown.

## Architecture Decisions

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for full ADRs:

1. **ADK for agent framework** -- Native GCP integration, Gemini-optimized
2. **AI Studio over Vertex AI** -- Sandbox blocks aiplatform.googleapis.com
3. **Single specialist agent** -- Focused context, all 6 tools in one agent
4. **Z-score + ARIMA_PLUS hybrid** -- Statistical detection for historical, ML for forecasting
5. **Fixed SQL over text-to-SQL** -- Reliability, security, cost control
6. **Dict return with status field** -- Consistent tool contract
7. **Synthetic data with injected anomalies** -- Ground truth for validation

## Testing Results

- 100% tool selection accuracy across all 5 test queries
- All 6 tools returning valid BigQuery results
- Date serialization handled (datetime to ISO string)
- 10 injected anomalies detected by Z-score analysis
- ARIMA_PLUS models capturing weekly + yearly seasonality with US holidays
- Agent correctly cross-references detected anomalies with known events

## Agent Build Portfolio Context

This is project 5 in a GCP data engineering portfolio:

| # | Project | Status |
|---|---------|--------|
| 1 | [Enterprise Analytics](https://github.com/gbhorne/enterprise-analytics) | Complete |
| 2 | [Terraform IaC](https://github.com/gbhorne/terraform-gcp-analytics) | Complete |
| 3 | [ADK Multi-Agent System](https://github.com/gbhorne/adk-retail-agents) | Complete |
| 4 | ADK NL2SQL Agent | Complete |
| 5 | **ADK Anomaly Detection** | Complete |
| 6 | Research Agent | Planned |
| 7 | MLOps Pipeline | Planned |

## License

MIT

# Q&A Guide: ADK Anomaly Detection Agent

In-depth explanations of design decisions, technical tradeoffs, and implementation details. Organized in 10 parts covering every aspect of the system.

---

## Part 1: Why Z-Score Instead of ML.DETECT_ANOMALIES

**Q: BigQuery ML has a built-in ML.DETECT_ANOMALIES function. Why did you build your own anomaly detection with Z-scores instead of using the native function?**

A: We tried ML.DETECT_ANOMALIES first. It returned NULL for every anomaly_probability value across all 1,826 days. The root cause is that ARIMA_PLUS with auto_arima enabled automatically activates two decomposition features: `has_spikes_and_dips` and `has_step_changes`. These features cause the model to absorb anomalous data points into its internal decomposition rather than treating them as outliers. The model essentially learns the anomalies as part of the signal, so when you ask it to detect anomalies against the same data it trained on, it sees nothing unusual.

This is not a bug. It is the expected behavior when the model's spike/step decomposition captures the very events you want to flag. The BigQuery ML documentation does not make this interaction obvious, and it only surfaces when you have sharp, discrete anomalies in your training data.

**Q: Could you have disabled has_spikes_and_dips to make ML.DETECT_ANOMALIES work?**

A: Yes, in theory. But auto_arima selects those features because they improve forecast accuracy. Disabling them would degrade the model's ability to forecast, which is the other half of our system. We chose to keep the models optimized for forecasting (their primary ML purpose) and use a complementary statistical method for detection.

**Q: Why Z-score specifically? There are other statistical methods for anomaly detection.**

A: Z-score against a rolling window was chosen for four reasons. First, it is interpretable: the agent can say "revenue was 2.5 standard deviations below normal" and any business user understands the severity. Second, it is implementable in pure SQL with window functions, so there is no additional infrastructure or Python dependency at query time. Third, the 30-day rolling window naturally adapts to the data's recent baseline, which handles the growth trend without explicit detrending. Fourth, it is deterministic and reproducible. The same data always produces the same Z-scores.

**Q: What are the limitations of Z-score detection?**

A: The main limitation is that Z-score does not account for seasonality. A revenue surge during the November holiday season is expected, but the Z-score method may still flag it if the 30-day window ending in late October has a lower average. In our dataset, this produces some false positives during seasonal transitions. A production system would use seasonally-adjusted Z-scores or a seasonal decomposition step before computing deviations. For this portfolio project, the tradeoff is acceptable because the detections are still directionally correct.

**Q: What does the hybrid approach (Z-score + ARIMA_PLUS) give you that neither alone provides?**

A: Z-score handles retrospective detection: "what happened in the past that was unusual?" ARIMA_PLUS handles prospective forecasting: "what do we expect to happen next?" Neither does the other's job well. ML.DETECT_ANOMALIES failed for historical detection as described above. Z-scores cannot predict the future. The combination gives the agent both backward-looking analysis and forward-looking prediction, which is what a real anomaly monitoring system needs.

---

## Part 2: ARIMA_PLUS Model Details

**Q: What is ARIMA_PLUS and how does it differ from standard ARIMA?**

A: ARIMA_PLUS is BigQuery ML's enhanced time-series model. Standard ARIMA handles trend and autoregressive patterns. ARIMA_PLUS adds automatic seasonality detection (it found weekly and yearly patterns in our revenue data), US holiday effects, spike and dip decomposition, and step change detection. It also runs auto_arima, which tests multiple (p,d,q) configurations and selects the one with the best AIC score.

**Q: What did the models learn from the data?**

A: The revenue model selected ARIMA(1,1,1) without drift, detecting weekly seasonality (weekends higher), yearly seasonality (holiday spike, summer bump), and US holiday effects. The stockout model selected ARIMA(0,1,1) without drift, finding no seasonality but detecting spikes, dips, and step changes. This makes sense because stockout counts are inherently more random and event-driven than revenue.

**Q: How does ML.FORECAST produce confidence intervals?**

A: ARIMA_PLUS generates prediction intervals based on the model's residual variance. We use a 95% confidence level, meaning the actual value is expected to fall within the interval 95% of the time. Wider intervals mean more uncertainty. The agent explains these intervals in practical terms when responding to forecast queries.

**Q: Why did you train on aggregated daily totals instead of per-region or per-category series?**

A: ARIMA_PLUS in BigQuery ML operates on a single time series per model. We could have created 25 separate models (5 regions times 5 categories), but that would have been excessive for a portfolio project and would complicate the agent's tool interface. Aggregating to one daily total gives the model the most signal with the least noise. The per-region and per-category breakdowns are still available through the `get_anomaly_detail` tool, which queries the raw `fct_daily_sales` table.

---

## Part 3: Data Generation and Anomaly Injection

**Q: Why synthetic data instead of a public dataset?**

A: We needed specific characteristics that public retail datasets rarely provide. First, we needed exactly 5 years of daily granularity for robust ARIMA_PLUS training. Second, we needed known anomaly windows with ground truth labels so we could validate detection accuracy. Third, we needed clean, consistent dimensions (regions, categories) that map well to the agent's explanation capabilities. Generating the data gave us full control over all of these.

**Q: How realistic is the synthetic data?**

A: The generator includes five realism layers. Seasonal patterns model holiday spikes in November/December (40% increase), a summer bump in June/July (15% increase), and a January dip (15% decrease). Weekly patterns make weekends 20% higher and Mondays 15% lower. A 3% annual growth trend models organic business growth over 5 years. Regional multipliers (West at 1.15x, Southwest at 0.85x) create geographic variation. Gaussian noise with 8% standard deviation prevents artificial smoothness. The result is data that behaves like aggregated retail sales while remaining deterministic (seeded random generator).

**Q: How were anomalies injected?**

A: Ten anomaly windows were defined with specific start offsets, durations, types, and magnitudes. Revenue drops multiply revenue by a factor less than 1 (for example, 0.45 for a 55% drop). Revenue surges multiply by a factor greater than 1 (for example, 1.8 for an 80% increase). Stockout spikes multiply the stockout count by 3x-4x and add a random 5-15 additional stockouts. Each window has a business description (supply chain disruption, warehouse fire, system outage) that the anomaly_reference table stores for the agent to cross-reference.

**Q: Why 10 anomalies? Why those specific types?**

A: Ten events across 5 years gives roughly 2 events per year, which is realistic for a mid-size retail operation. The mix of revenue drops (4), revenue surges (2), and stockout spikes (4) covers the three main anomaly categories a retail analyst would monitor. The durations range from 5 to 14 days, testing the detector's sensitivity to both brief and extended events.

---

## Part 4: Agent Architecture

**Q: Why a single agent instead of the multi-agent pattern you used in Project 3?**

A: Project 3 had three distinct domains (inventory, sales, customers) with non-overlapping tool sets, which justified separate specialist agents and a routing orchestrator. This project has one domain (anomaly detection and forecasting) where all six tools serve the same analytical purpose. Splitting into sub-agents would add routing complexity without improving accuracy or maintainability. This demonstrates an important architectural skill: knowing when multi-agent is overkill and a focused single agent is the better design.

**Q: How does the agent decide which tool to call?**

A: Gemini 2.5 Flash uses the tool descriptions and the system instruction to select the appropriate tool. The system instruction explicitly maps capabilities to tools: detection queries go to the anomaly tools, date-specific queries go to get_anomaly_detail, forward-looking queries go to the forecast tools, and broad overview queries go to get_anomaly_summary. In testing, tool selection was 100% accurate across all five test query types.

**Q: What is the tool contract pattern?**

A: Every tool returns a Python dict with a "status" field set to "success" and the relevant data fields. This pattern was established in Project 3 and continued here for consistency. It enables the agent to check whether a tool call succeeded before attempting to reason about the results. All non-JSON-serializable types (datetime.date, Decimal) are converted in the _run_query helper function.

**Q: Why did you encounter a JSON serialization error?**

A: BigQuery's Python client returns datetime.date objects for DATE columns and Decimal objects for NUMERIC columns. ADK serializes tool return values to JSON before passing them to the LLM, and Python's json module does not handle these types natively. The fix was adding a _run_query helper that iterates over each row and converts dates to ISO format strings and Decimals to floats before returning. This is a common gotcha when connecting BigQuery to any JSON-based system.

---

## Part 5: Fixed SQL vs Text-to-SQL

**Q: Why not let the LLM generate SQL dynamically?**

A: Fixed SQL provides five guarantees that text-to-SQL cannot. First, security: the SQL is read-only by construction. There is no possibility of the LLM generating a DROP TABLE or UPDATE statement. Second, cost control: every query is predictable in its BigQuery slot usage. A malicious or confused text-to-SQL query could scan entire tables repeatedly. Third, reliability: the SQL is tested and known to work. Text-to-SQL can generate syntactically valid but semantically wrong queries. Fourth, speed: no SQL generation step means lower latency. Fifth, auditability: every possible query the agent can run is visible in the tools.py source code.

**Q: Does this limit what users can ask?**

A: Yes, intentionally. The agent can answer a defined set of question types, which is appropriate for a monitoring system. Users who need ad-hoc analysis should use a BI tool. The agent's value is in fast, reliable answers to the most common anomaly and forecasting questions, not in being a general-purpose SQL interface.

---

## Part 6: BigQuery and GCP Integration

**Q: What BigQuery features does this project use?**

A: The project uses five BigQuery capabilities. Standard SQL for data loading and aggregation. Window functions (AVG, STDDEV with ROWS BETWEEN) for the Z-score rolling calculations. BigQuery ML for ARIMA_PLUS model training via CREATE MODEL. ML.FORECAST for generating predictions with confidence intervals. And ML.EVALUATE for inspecting model parameters and fit quality.

**Q: How does authentication work?**

A: In Cloud Shell, gcloud auth is automatic. The BigQuery Python client picks up the application-default credentials without any explicit configuration. For the Gemini LLM, we use an AI Studio API key set via the GOOGLE_API_KEY environment variable, with GOOGLE_GENAI_USE_VERTEXAI set to FALSE to bypass Vertex AI (which is blocked in the sandbox).

**Q: What sandbox restrictions affected this project?**

A: Vertex AI endpoints are not supported, which forced the use of AI Studio for Gemini access. Cloud Run is conditionally supported with limits, so we avoided it entirely. Cloud Functions are limited to 3, which we did not need. BigQuery, BigQuery ML, Cloud Storage, and Cloud Shell are all fully supported with no restrictions that affected our workload.

---

## Part 7: Detection Results Analysis

**Q: The Z-score detector found 108 revenue anomalies but only 31 matched the injected events. What are the other 77?**

A: The other 77 are natural statistical outliers from the Gaussian noise in the data generator. With 1,826 days and a Z-score threshold of +/- 2.0, you would statistically expect about 5% of days (approximately 91) to fall outside the threshold by random chance alone. The actual count of 108 is slightly above that expectation, which is consistent with the 10 injected anomaly windows adding extra flagged days. This is realistic behavior: a real anomaly detector would also flag naturally extreme days alongside genuine business events.

**Q: The stockout model found 119 anomalies with 36 matched. Why more stockout anomalies than revenue?**

A: Stockout counts have higher relative variance than revenue. Revenue is a continuous, relatively smooth metric. Stockout counts are discrete integers that can jump from 60 to 400+ during an injection window. The Z-score threshold of 2.0 standard deviations captures more of these jumps. Additionally, stockout injections used multipliers of 3.0x to 4.0x with added random noise, producing more extreme deviations than the revenue drop multipliers of 0.35x to 0.50x.

**Q: What is the Z-score of 92.36 in the stockout anomalies?**

A: That extreme Z-score occurred during the "Logistics disruption Dec 2024" injection window, where stockout counts jumped to 438 against a rolling average of 61.70. This is 92 standard deviations above the mean, which in normal data would be effectively impossible. It indicates the injection magnitude was very large relative to the baseline variance. In a production system, you might cap Z-scores or use a logarithmic scale for display purposes.

---

## Part 8: Forecasting Capabilities

**Q: How accurate are the ARIMA_PLUS forecasts?**

A: The revenue model's best candidate (ARIMA(1,1,1) without drift) had an AIC of 42,027.76 and variance of 5.85e8. These are relative metrics; lower AIC is better among candidates. The model correctly captures the weekly pattern (weekends higher) and yearly pattern (holiday spike), as confirmed by the seasonal_periods output showing ["WEEKLY","YEARLY"]. The 95% confidence intervals in the forecast output give a practical measure of uncertainty.

**Q: Can the agent forecast arbitrary time horizons?**

A: The tools accept a horizon_days parameter up to 365 days. The further out you forecast, the wider the confidence intervals become, reflecting increasing uncertainty. The agent explains this when presenting forecast results. In practice, ARIMA_PLUS forecasts beyond 30-90 days become increasingly speculative for daily retail data.

**Q: Why did you keep the ARIMA_PLUS models even though ML.DETECT_ANOMALIES did not work?**

A: The models serve a different and valuable purpose: forecasting. ML.FORECAST works correctly and produces useful predictions with confidence intervals. The anomaly detection failure was specific to the ML.DETECT_ANOMALIES function's interaction with the spike/step decomposition features. The models themselves are well-trained and the forecasting capability is a key feature of the agent.

---

## Part 9: Testing and Verification

**Q: What testing was performed?**

A: Five test query types were run through the ADK web interface, each targeting a different tool. "Show me recent revenue anomalies" correctly called get_recent_revenue_anomalies with days=90. "What happened on 2022-06-20?" correctly called get_anomaly_detail with sale_date="2022-06-20". "Give me a 30-day revenue forecast" correctly called get_revenue_forecast with horizon_days=30. "Summarize all anomalies across the dataset" correctly called get_anomaly_summary. "Are there any stockout spikes recently?" correctly called get_recent_stockout_anomalies with days=90. All five returned valid data and the agent produced coherent natural language explanations.

**Q: How was the tool test validated before launching the agent?**

A: Before starting the ADK web interface, we ran a standalone Python test that imported get_anomaly_summary directly and verified the return structure: status="success", correct anomaly type counts (65 surges, 43 drops, 119 stockout spikes), and 10 known reference events. This confirmed BigQuery connectivity, SQL correctness, and JSON serialization before introducing the LLM layer.

**Q: What is the evalset for?**

A: The anomaly_detection_eval.evalset.json file contains 10 test cases mapping natural language queries to expected tool calls with expected parameters. This supports ADK's built-in evaluation framework, which can automatically verify that the LLM routes queries to the correct tools. It also serves as documentation of the agent's intended behavior.

---

## Part 10: Comparison to Project 3 (ADK Retail Agents)

**Q: How does this project differ from the ADK Retail Agents project?**

A: Project 3 was a multi-agent system with a root orchestrator routing to three specialist agents (inventory, sales, customer), totaling 11 tools. This project is a single-agent system with 6 tools focused on one domain. The key new capabilities are BigQuery ML model training and querying, time-series forecasting, statistical anomaly detection, and the hybrid ML + statistics approach. Project 3 demonstrated multi-agent routing; this project demonstrates ML integration and analytical depth.

**Q: What architectural patterns carry over?**

A: Four patterns are consistent across both projects. The dict return contract with a status field. Fixed SQL over text-to-SQL. AI Studio for Gemini access (bypassing Vertex AI sandbox restrictions). And the documentation structure with ADRs, build guide, and eval set. This consistency is intentional and demonstrates a mature, repeatable approach to agent development.

**Q: What would a combined system look like?**

A: The anomaly_detection_agent could be added as a fourth sub-agent to the retail_orchestrator from Project 3. The orchestrator's routing instruction would include anomaly and forecast queries in its delegation rules. The existing inventory, sales, and customer agents would continue handling their domains. A user could ask "What are our top products?" (routed to sales_analyst) followed by "Are there any revenue anomalies this quarter?" (routed to anomaly_detection_agent) in the same conversation.

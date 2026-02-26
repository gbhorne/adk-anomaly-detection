"""
Generate 5 years of daily retail sales data with injected anomalies.
Output: CSV files for BigQuery loading.
"""
import csv
import math
import random
from datetime import datetime, timedelta

random.seed(42)

START_DATE = datetime(2020, 1, 1)
DAYS = 1826
REGIONS = ["Northeast", "Southeast", "Midwest", "West", "Southwest"]
CATEGORIES = ["Electronics", "Clothing", "Home & Garden", "Sports", "Grocery"]
BASE_REVENUE = 50000.0
BASE_ORDERS = 200
BASE_STOCKOUTS = 3

ANOMALIES = [
    (180, 7, "revenue_drop", 0.45, "Supply chain disruption Jul 2020"),
    (365, 5, "stockout_spike", 3.0, "Warehouse fire Jan 2021"),
    (540, 10, "revenue_drop", 0.50, "Regional storm Jun 2021"),
    (730, 14, "revenue_surge", 1.8, "Viral product trend Jan 2022"),
    (900, 7, "stockout_spike", 4.0, "Supplier bankruptcy Jun 2022"),
    (1095, 5, "revenue_drop", 0.35, "System outage Jan 2023"),
    (1280, 8, "stockout_spike", 3.5, "Port delays Jul 2023"),
    (1460, 6, "revenue_drop", 0.40, "Competitor mega-sale Jan 2024"),
    (1600, 10, "revenue_surge", 2.0, "New product launch Jul 2024"),
    (1750, 7, "stockout_spike", 3.0, "Logistics disruption Dec 2024"),
]


def seasonal_factor(day_of_year):
    base = 1.0
    if day_of_year >= 305:
        base += 0.4 * math.sin(math.pi * (day_of_year - 305) / 60)
    elif 152 <= day_of_year <= 213:
        base += 0.15 * math.sin(math.pi * (day_of_year - 152) / 61)
    elif day_of_year <= 31:
        base -= 0.15
    return base


def weekly_factor(weekday):
    if weekday >= 5:
        return 1.2
    elif weekday == 4:
        return 1.1
    elif weekday == 0:
        return 0.85
    return 1.0


def growth_factor(day_offset):
    years = day_offset / 365.0
    return 1.0 + (0.03 * years)


def get_anomaly(day_offset):
    for start, duration, atype, magnitude, desc in ANOMALIES:
        if start <= day_offset < start + duration:
            return (atype, magnitude, desc)
    return None


def generate():
    daily_rows = []
    for d in range(DAYS):
        current_date = START_DATE + timedelta(days=d)
        doy = current_date.timetuple().tm_yday
        weekday = current_date.weekday()
        sf = seasonal_factor(doy)
        wf = weekly_factor(weekday)
        gf = growth_factor(d)
        anomaly = get_anomaly(d)

        for region in REGIONS:
            region_mult = {"Northeast": 1.1, "Southeast": 1.0, "Midwest": 0.9,
                           "West": 1.15, "Southwest": 0.85}[region]
            for category in CATEGORIES:
                cat_mult = {"Electronics": 1.3, "Clothing": 1.0,
                            "Home & Garden": 0.9, "Sports": 0.8,
                            "Grocery": 1.4}[category]
                noise = random.gauss(1.0, 0.08)
                revenue = BASE_REVENUE * sf * wf * gf * region_mult * cat_mult * noise
                orders = int(BASE_ORDERS * sf * wf * gf * region_mult * cat_mult * random.gauss(1.0, 0.1))
                stockouts = max(0, int(BASE_STOCKOUTS * (1 / sf) * random.gauss(1.0, 0.3)))

                anomaly_flag = False
                anomaly_type = "none"
                if anomaly:
                    atype, mag, desc = anomaly
                    if atype == "revenue_drop":
                        revenue *= mag
                        orders = int(orders * mag)
                        anomaly_flag = True
                        anomaly_type = "revenue_drop"
                    elif atype == "revenue_surge":
                        revenue *= mag
                        orders = int(orders * mag)
                        anomaly_flag = True
                        anomaly_type = "revenue_surge"
                    elif atype == "stockout_spike":
                        stockouts = int(stockouts * mag) + random.randint(5, 15)
                        anomaly_flag = True
                        anomaly_type = "stockout_spike"

                revenue = round(max(0, revenue), 2)
                orders = max(0, orders)
                stockouts = max(0, stockouts)
                daily_rows.append([
                    current_date.strftime("%Y-%m-%d"),
                    region, category, revenue, orders, stockouts,
                    anomaly_flag, anomaly_type
                ])

    with open("/tmp/fct_daily_sales.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["sale_date", "region", "category", "revenue",
                     "order_count", "stockout_count", "is_anomaly", "anomaly_type"])
        w.writerows(daily_rows)

    with open("/tmp/anomaly_reference.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["start_date", "end_date", "duration_days", "anomaly_type",
                     "magnitude", "description"])
        for start, duration, atype, magnitude, desc in ANOMALIES:
            sd = (START_DATE + timedelta(days=start)).strftime("%Y-%m-%d")
            ed = (START_DATE + timedelta(days=start + duration - 1)).strftime("%Y-%m-%d")
            w.writerow([sd, ed, duration, atype, magnitude, desc])

    print(f"Generated {len(daily_rows):,} daily sales rows")
    print(f"Date range: {START_DATE.strftime('%Y-%m-%d')} to "
          f"{(START_DATE + timedelta(days=DAYS - 1)).strftime('%Y-%m-%d')}")
    print(f"Regions: {len(REGIONS)}, Categories: {len(CATEGORIES)}")
    print(f"Anomaly windows: {len(ANOMALIES)}")
    print(f"Files: /tmp/fct_daily_sales.csv, /tmp/anomaly_reference.csv")


if __name__ == "__main__":
    generate()

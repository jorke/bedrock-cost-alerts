#!/usr/bin/env python3
"""Retune the Bedrock daily budget and anomaly alert from recent usage.

Terraform (main.tf) creates the budget, anomaly monitor and subscription.
This script only moves their thresholds. Spend is the daily unblended cost of
the "Amazon Bedrock" and "Amazon Bedrock Service" services, charge type Usage
only, so credits, refunds and tax are excluded.

Thresholds come from the median of the last N complete days (default 7) and
a multiplier m (default 1.5):
  daily budget    = max(floor, m * median)
  anomaly impact  = max(floor, (m - 1) * median)
Each run moves a threshold by at most --max-change, so a runaway can't drag
it up fast.

CLI:
  python bedrock_cost_guard.py --dry-run
  python bedrock_cost_guard.py --profile my-admin --days 7 --multiplier 1.5

Lambda handler: bedrock_cost_guard.handler (settings come from env vars).
"""
import argparse
import os
import statistics
from datetime import date, timedelta

import boto3

# Cost Explorer, Budgets and Anomaly Detection are served from us-east-1.
REGION = "us-east-1"


def parse_args(argv=None):
    env = os.environ.get
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--days", type=int, default=int(env("LOOKBACK_DAYS", 7)),
                   help="lookback window in complete days (default 7)")
    p.add_argument("--multiplier", type=float, default=float(env("MULTIPLIER", 1.5)),
                   help="alert when a day exceeds this multiple of the median (default 1.5)")
    p.add_argument("--max-change", type=float, default=float(env("MAX_CHANGE", 0.5)),
                   help="max fractional change per run (default 0.5 = +/-50%%)")
    p.add_argument("--floor-daily", type=float, default=float(env("FLOOR_DAILY", 10)),
                   help="minimum daily budget in USD (default 10)")
    p.add_argument("--floor-impact", type=float, default=float(env("FLOOR_IMPACT", 5)),
                   help="minimum anomaly impact in USD (default 5)")
    p.add_argument("--services", type=lambda s: s.split(","),
                   default=env("BEDROCK_SERVICES", "Amazon Bedrock,Amazon Bedrock Service")
                   .split(","),
                   help="comma-separated Cost Explorer SERVICE names")
    p.add_argument("--budget-name", default=env("BUDGET_NAME", "bedrock-daily-spend"))
    p.add_argument("--subscription-name",
                   default=env("SUBSCRIPTION_NAME", "bedrock-spend-anomaly-alerts"))
    p.add_argument("--profile", default=None, help="AWS profile for CLI runs")
    p.add_argument("--dry-run", action="store_true", help="print changes, apply nothing")
    return p.parse_args(argv)


def daily_usage(ce, args):
    """Usage cost per day for the last args.days complete days (zero-filled)."""
    end = date.today()  # exclusive, so today's partial day is left out
    start = end - timedelta(days=args.days)
    totals, token = {}, None
    while True:
        req = dict(
            TimePeriod={"Start": start.isoformat(), "End": end.isoformat()},
            Granularity="DAILY",
            Metrics=["UnblendedCost"],
            Filter={"And": [
                {"Dimensions": {"Key": "SERVICE", "Values": args.services}},
                {"Dimensions": {"Key": "RECORD_TYPE", "Values": ["Usage"]}},
            ]},
        )
        if token:
            req["NextPageToken"] = token
        resp = ce.get_cost_and_usage(**req)
        for day in resp["ResultsByTime"]:
            totals[day["TimePeriod"]["Start"]] = float(day["Total"]["UnblendedCost"]["Amount"])
        token = resp.get("NextPageToken")
        if not token:
            break
    return [totals.get((start + timedelta(days=i)).isoformat(), 0.0) for i in range(args.days)]


def thresholds(median, args):
    """(daily budget, anomaly impact) for a given median daily spend."""
    budget = max(args.floor_daily, args.multiplier * median)
    impact = max(args.floor_impact, (args.multiplier - 1) * median)
    return budget, impact


def clamp(new, current, max_change):
    """Limit how far a threshold moves in one run."""
    if not current:
        return new
    return min(max(new, current * (1 - max_change)), current * (1 + max_change))


def report(label, current, target, applied):
    note = f" (capped from ${target:.2f})" if abs(applied - target) >= 0.005 else ""
    print(f"{label}: ${current:.2f} -> ${applied:.2f}{note}")


def tune_budget(budgets, account_id, target, args):
    budget = budgets.describe_budget(AccountId=account_id, BudgetName=args.budget_name)["Budget"]
    # UpdateBudget replaces the whole definition. Refuse to write back a budget
    # without its filter (e.g. an SDK too old to return FilterExpression),
    # which would turn it into an all-services budget.
    if "FilterExpression" not in budget:
        raise RuntimeError(f"budget {args.budget_name} has no FilterExpression; "
                           "upgrade boto3 or check the budget in the console")
    current = float(budget["BudgetLimit"]["Amount"])
    new = round(clamp(target, current, args.max_change), 2)
    report("daily budget", current, target, new)
    if args.dry_run or new == round(current, 2):
        return
    for key in ("CalculatedSpend", "LastUpdatedTime", "HealthStatus", "CostFilters", "CostTypes"):
        budget.pop(key, None)
    budget["BudgetLimit"]["Amount"] = f"{new:.2f}"
    budgets.update_budget(AccountId=account_id, NewBudget=budget)


def tune_anomaly_alert(ce, target, args):
    sub, token = None, None
    while sub is None:
        resp = ce.get_anomaly_subscriptions(**({"NextPageToken": token} if token else {}))
        sub = next((s for s in resp["AnomalySubscriptions"]
                    if s["SubscriptionName"] == args.subscription_name), None)
        token = resp.get("NextPageToken")
        if not token:
            break
    if sub is None:
        raise RuntimeError(f"anomaly subscription {args.subscription_name} not found; "
                           "run terraform apply first")
    dim = sub["ThresholdExpression"]["Dimensions"]
    current = float(dim["Values"][0])
    new = round(clamp(target, current, args.max_change), 2)
    report("anomaly impact", current, target, new)
    if args.dry_run or new == round(current, 2):
        return
    dim["Values"] = [f"{new:.2f}"]
    ce.update_anomaly_subscription(SubscriptionArn=sub["SubscriptionArn"],
                                   ThresholdExpression=sub["ThresholdExpression"])


def main(argv=None):
    args = parse_args(argv)
    session = boto3.Session(profile_name=args.profile, region_name=REGION)
    ce, budgets = session.client("ce"), session.client("budgets")
    account_id = session.client("sts").get_caller_identity()["Account"]

    series = daily_usage(ce, args)
    if not any(series):
        # Don't drag thresholds down to the floors on an empty window.
        print(f"No Bedrock usage in the last {args.days} days; thresholds unchanged.")
        return
    median = statistics.median(series)
    budget_target, impact_target = thresholds(median, args)
    print(f"last {args.days} days: total ${sum(series):.2f}, median ${median:.2f}/day, "
          f"max ${max(series):.2f}" + ("  [dry run]" if args.dry_run else ""))
    tune_budget(budgets, account_id, budget_target, args)
    tune_anomaly_alert(ce, impact_target, args)


def handler(event, context):
    main([])
    return {"status": "ok"}


if __name__ == "__main__":
    main()

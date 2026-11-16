# bedrock-cost-alerts

Daily budget and anomaly alerts for Amazon Bedrock usage. You get an alert when a day's usage exceeds 1.5x the median of the last 7 days. A daily Lambda retunes both thresholds (`--multiplier`, `--days`).

Scope: unblended cost of the "Amazon Bedrock" and "Amazon Bedrock Service" services, charge type Usage only, so credits, refunds and tax are excluded. To change it, edit `bedrock_services` and `bedrock_service_codes` in `main.tf`. The anomaly monitor's cost category can only match on service code.

## Deploy

```sh
terraform init
terraform apply -var alert_email=you@example.com -var initial_daily_budget=50
```

Confirm the SNS subscription email. The anomaly monitor's cost category takes up to 24 hours to process.

## Run the script locally

```sh
pip install boto3
python bedrock_cost_guard.py --dry-run          # show proposed thresholds
python bedrock_cost_guard.py --profile <name>   # apply them
python bedrock_cost_guard.py --help             # all options
```

Each run moves a threshold by at most 50% (`--max-change`).
# bedrock-cost-alerts

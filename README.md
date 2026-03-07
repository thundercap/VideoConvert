# VideoConvert

A production-grade, fully serverless video transcoding pipeline on AWS. Upload a video file to S3 and receive a 4-rung HLS adaptive bitrate stream — no servers to manage, no idle capacity to pay for.

```
S3 upload  →  SQS  →  Lambda  →  MediaConvert  →  S3 output  →  CloudFront
                                       ↓
                               EventBridge → SNS → Email
```

---

## Features

- **HLS adaptive bitrate output** — 1080p, 720p, 480p, and 360p H.264/AAC renditions in a single job
- **Serverless end-to-end** — Lambda, MediaConvert, SQS, DynamoDB; nothing to provision or patch
- **CloudFront delivery** — edge-cached HLS with HTTPS enforcement; players get segments from the nearest PoP
- **Job deduplication** — DynamoDB conditional writes prevent double-billing from S3's at-least-once delivery
- **Reliable retry model** — S3 → SQS → Lambda event source mapping with `ReportBatchItemFailures`; only failed messages go back to the queue
- **ARM64 Lambda** — Graviton2 runtime is ~20% cheaper per GB-second with no code changes
- **Separate input/output buckets** — independent versioning, lifecycle rules, and IAM boundaries
- **MediaConvert Job Template** — encoding settings live in MediaConvert, not in Lambda code; update bitrates without redeploying
- **Structured JSON logging** — every log line carries a `request_id` correlation ID; queryable in CloudWatch Logs Insights
- **Full observability** — 5 CloudWatch alarms, a pipeline dashboard, and custom `JobsSubmitted` / `JobsDeduplicated` metrics
- **Terraform-managed** — all infrastructure is version-controlled with validated input variables

---

## Architecture

### Request flow

```
┌─────────────────────────────────────────────────────────────────┐
│  INGESTION                                                       │
│                                                                  │
│  User  ──PUT──►  S3 input bucket (uploads/)                     │
│                        │                                         │
│                   S3 ObjectCreated notification                  │
│                        │                                         │
│                        ▼                                         │
│                  SQS intake queue  ◄── redrive ── SQS DLQ       │
│                        │                                         │
│              Lambda event source mapping                         │
│              (batch_size=10, ReportBatchItemFailures)            │
│                        │                                         │
│                        ▼                                         │
│               Lambda (Python 3.12, ARM64)                        │
│               ├─ Validate bucket, prefix, extension, size        │
│               ├─ DynamoDB dedup check (key#etag)                 │
│               └─ MediaConvert CreateJob                          │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  TRANSCODING                                                     │
│                                                                  │
│  MediaConvert (dedicated queue)                                  │
│  ├─ Job Template: HLS ABR 1080p / 720p / 480p / 360p            │
│  └─ Output → S3 output bucket (processed/<name>/)               │
│                   │                                              │
│              EventBridge rule (pipeline=video-convert)           │
│              └─► SNS → Email notification                        │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  DELIVERY                                                        │
│                                                                  │
│  CloudFront distribution                                         │
│  ├─ *.m3u8  →  CachingDisabled (short TTL, live manifests)      │
│  └─ *.ts    →  CachingOptimized (long TTL, immutable segments)   │
│                   │                                              │
│              Video player  ◄── HTTPS                             │
└─────────────────────────────────────────────────────────────────┘
```

### HLS output renditions

| Name | Resolution | Max Video Bitrate | Audio Bitrate | QVBR Level |
|------|------------|-------------------|---------------|------------|
| `_1080p` | 1920 × 1080 | 6,000 kbps | 128 kbps | 8 |
| `_720p`  | 1280 × 720  | 3,500 kbps | 128 kbps | 8 |
| `_480p`  | 854 × 480   | 2,000 kbps | 96 kbps  | 7 |
| `_360p`  | 640 × 360   | 1,000 kbps | 96 kbps  | 7 |

All renditions use H.264 CABAC, 2-second GOP, scene-change detection, and AAC 48 kHz stereo.

### Supported input formats

`.mp4` `.mov` `.mkv` `.avi` `.wmv` `.flv` `.webm` `.m4v` `.mxf` `.ts`

---

## Infrastructure

| File | Resources |
|------|-----------|
| `main.tf` | Provider, backend template, locals |
| `s3.tf` | Input bucket (versioned), output bucket (Intelligent-Tiering) |
| `lambda.tf` | Lambda function, DLQ |
| `sqs_intake.tf` | Intake queue, Lambda ESM, SQS read IAM policy |
| `dynamodb.tf` | Deduplication table with TTL |
| `mediaconvert.tf` | Dedicated queue, Job Template, MediaConvert IAM role |
| `cloudfront.tf` | CloudFront distribution with OAC, output bucket policy |
| `iam.tf` | Lambda execution role and inline policies |
| `cloudwatch.tf` | EventBridge rule, SNS topic policy, 5 alarms, dashboard |
| `sns.tf` | Encrypted SNS topic, email subscription |
| `variables.tf` | All input variables with validation |
| `outputs.tf` | Bucket names, CloudFront domain, queue URLs, dashboard link |

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.3
- AWS CLI configured (`aws configure` or environment variables)
- An AWS account with MediaConvert enabled in your target region
- Two globally unique S3 bucket names chosen in advance

---

## Deployment

### 1. Clone and initialise

```bash
git clone https://github.com/thundercap/VideoConvert
cd VideoConvert
terraform init
```

### 2. Create `terraform.tfvars`

```hcl
# Required
region             = "ap-south-1"
bucket_name        = "my-company-video-input"
output_bucket_name = "my-company-video-output"
notification_email = "alerts@mycompany.com"

# Optional — sensible defaults shown
environment                 = "dev"              # dev | staging | prod
uploads_expiry_days         = 7                  # days before raw source files are deleted
processed_expiry_days       = 90                 # days before HLS output is deleted (0 = keep forever)
lambda_reserved_concurrency = 10                 # max simultaneous MediaConvert job submissions
dedup_ttl_hours             = 24                 # dedup window for duplicate S3 events
log_retention_days          = 30                 # CloudWatch Logs retention
enable_cloudfront           = true               # set false to skip CloudFront
cloudfront_price_class      = "PriceClass_100"   # PriceClass_100 | PriceClass_200 | PriceClass_All
status_update_interval      = "SECONDS_60"       # MediaConvert progress event frequency
```

### 3. Deploy

```bash
terraform plan
terraform apply
```

Terraform outputs the CloudFront domain, bucket names, queue URLs, and dashboard URL after a successful apply.

### 4. Confirm SNS subscription

Check your inbox for the AWS SNS confirmation email and click **Confirm subscription** to start receiving job alerts.

### 5. Upload a video

```bash
aws s3 cp myvideo.mp4 s3://my-company-video-input/uploads/myvideo.mp4
```

The pipeline starts automatically. HLS output will appear at:

```
s3://my-company-video-output/processed/myvideo/
  ├── myvideo.m3u8          ← master playlist
  ├── myvideo_1080p.m3u8
  ├── myvideo_720p.m3u8
  ├── myvideo_480p.m3u8
  ├── myvideo_360p.m3u8
  └── *.ts                  ← segments
```

The master playlist URL for a video player:

```
https://<cloudfront_domain>/processed/myvideo/myvideo.m3u8
```

---

## Variables reference

### Required

| Variable | Type | Description |
|----------|------|-------------|
| `bucket_name` | string | S3 input bucket name (globally unique) |
| `output_bucket_name` | string | S3 output bucket name (globally unique, must differ from input) |
| `notification_email` | string | Email address for job completion and error alerts |

### Optional

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `region` | string | `ap-south-1` | AWS region to deploy into |
| `environment` | string | `dev` | Tag label; one of `dev`, `staging`, `prod` |
| `lambda_function_name` | string | `video-transcode-lambda` | Name of the Lambda function |
| `uploads_expiry_days` | number | `7` | Days until raw source files are deleted from the input bucket |
| `processed_expiry_days` | number | `90` | Days until HLS output is deleted from the output bucket; `0` = keep forever |
| `log_retention_days` | number | `30` | CloudWatch Logs retention period for Lambda |
| `lambda_reserved_concurrency` | number | `10` | Max simultaneous Lambda invocations; `-1` = unreserved |
| `dedup_ttl_hours` | number | `24` | Hours a job claim is held in DynamoDB before expiring |
| `enable_cloudfront` | bool | `true` | Create a CloudFront distribution in front of the output bucket |
| `cloudfront_price_class` | string | `PriceClass_100` | Edge coverage: `PriceClass_100`, `PriceClass_200`, or `PriceClass_All` |
| `status_update_interval` | string | `SECONDS_60` | How often MediaConvert sends progress events to EventBridge |
| `mediaconvert_queue` | string | `""` | Override the dedicated queue ARN; empty = use the queue created by this module |
| `mediaconvert_endpoint` | string | `""` | Pin a MediaConvert endpoint to skip cold-start discovery |
| `job_template_arn` | string | `""` | Use an existing Job Template ARN; empty = use the template created by this module |

---

## Outputs

| Output | Description |
|--------|-------------|
| `input_bucket_name` | Name of the S3 input bucket |
| `output_bucket_name` | Name of the S3 output bucket |
| `cloudfront_domain_name` | Full HTTPS base URL for HLS playback |
| `lambda_function_name` | Name of the Lambda function |
| `lambda_function_arn` | ARN of the Lambda function |
| `lambda_log_group` | CloudWatch log group path |
| `lambda_dlq_url` | SQS URL of the Lambda dead-letter queue |
| `intake_queue_url` | SQS URL of the S3 intake queue |
| `intake_queue_arn` | ARN of the intake queue |
| `mediaconvert_queue_arn` | ARN of the dedicated MediaConvert queue |
| `mediaconvert_role_arn` | ARN of the MediaConvert IAM role |
| `dedup_table_name` | DynamoDB deduplication table name |
| `sns_topic_arn` | ARN of the notification SNS topic |
| `dashboard_url` | Direct link to the CloudWatch pipeline dashboard |

---

## Observability

### CloudWatch alarms

All alarms notify via SNS and send a recovery notification when they clear.

| Alarm | Metric | Threshold | Why it matters |
|-------|--------|-----------|----------------|
| `lambda-errors` | `AWS/Lambda Errors` | > 0 | Any Lambda execution failure |
| `lambda-throttles` | `AWS/Lambda Throttles` | > 0 | Reserved concurrency exhausted |
| `lambda-duration-high` | `AWS/Lambda Duration` | avg > 50 s | Approaching the 60 s timeout |
| `mediaconvert-errors` | `AWS/MediaConvert JobsErrored` | > 0 | Encoding job failed |
| `lambda-dlq-messages` | `AWS/SQS ApproximateNumberOfMessagesVisible` | > 0 | Event failed all 3 retry attempts |

### CloudWatch dashboard

A single-pane dashboard (`VideoConvert-<environment>`) is created automatically. It shows Lambda invocations/errors, duration, throttles, intake queue depth, and MediaConvert job counts. Open it via the `dashboard_url` Terraform output.

### Logs Insights queries

Find all log lines for a single Lambda invocation:

```
fields @message
| filter request_id = "your-request-id"
| sort @timestamp asc
```

Count jobs submitted per hour over the last day:

```
fields @timestamp, event
| filter event = "job_submitted"
| stats count() by bin(1h)
```

List all deduplication suppressions:

```
fields @timestamp, key, etag
| filter event = "duplicate_skipped"
| sort @timestamp desc
```

---

## Job deduplication

S3 event notifications are delivered at-least-once — the same upload can trigger Lambda more than once. Without deduplication, this produces multiple identical MediaConvert jobs and duplicate output files at double the cost.

Before submitting a job, Lambda writes `{s3_key}#{eTag}` to DynamoDB using a conditional `PutItem` that fails if the key already exists. If another invocation has already claimed that pair, the record is skipped and a `JobsDeduplicated` metric is emitted.

A genuine re-upload of the same filename produces a different eTag and gets a new job — intentional re-transcodes are not blocked.

DynamoDB items expire automatically via TTL after `dedup_ttl_hours` (default 24 h).

---

## Encoding settings

Encoding settings are stored in the `video-convert-hls-abr` MediaConvert Job Template rather than in Lambda code. To change bitrates, resolutions, or codec parameters without redeploying:

1. AWS Console → **MediaConvert** → **Job templates**
2. Select `video-convert-hls-abr` and click **Edit**
3. Adjust settings and save — the next upload uses the updated template

To manage the template in Terraform, edit `aws_media_convert_job_template.hls_abr` in `mediaconvert.tf` and run `terraform apply`.

To use a pre-existing template from another stack, set `job_template_arn` in `terraform.tfvars`.

---

## Reserved MediaConvert pricing

The pipeline uses a dedicated queue (`video-convert`) on the ON_DEMAND plan. Switching to Reserved pricing reduces per-minute transcoding cost by approximately 20%. To switch:

1. AWS Console → **MediaConvert** → **Queues** → select `video-convert`
2. Click **Edit** → change pricing plan to **Reserved**

The queue ARN stays the same — no Terraform or Lambda changes required.

---

## Remote state

For team use, uncomment the `backend "s3"` block in `main.tf`:

```hcl
backend "s3" {
  bucket         = "your-terraform-state-bucket"
  key            = "videoconvert/terraform.tfstate"
  region         = "ap-south-1"
  dynamodb_table = "terraform-state-lock"
  encrypt        = true
}
```

Then run `terraform init -reconfigure` to migrate existing state.

---

## Teardown

```bash
terraform destroy
```

> **Note:** S3 buckets must be empty before Terraform can delete them. If destroy fails on a non-empty bucket:
> ```bash
> aws s3 rm s3://my-company-video-input --recursive
> aws s3 rm s3://my-company-video-output --recursive
> terraform destroy
> ```

---

## Security

- All S3 buckets block public access on all four ACL settings
- Input and output buckets are AES-256 encrypted at rest
- SNS topic encrypted with the AWS-managed SNS KMS key
- SQS queues encrypted with the AWS-managed SQS KMS key
- CloudFront uses Origin Access Control (OAC) — S3 objects are not accessible directly
- SNS topic policy uses `aws:SourceAccount` + `aws:SourceArn` conditions to prevent confused deputy attacks
- Lambda IAM policy is least-privilege: `s3:GetObject` scoped to `uploads/*`, `iam:PassRole` scoped to the MediaConvert role ARN only, `cloudwatch:PutMetricData` scoped to the `VideoConvert` namespace
- MediaConvert IAM role can only read from `uploads/*` and write to `processed/*`

---
# Serverless Video Transcoding Pipeline (AWS)

## Overview

This project provisions an **event-driven video processing pipeline** on AWS using:

* Amazon S3 — Video ingestion + output storage
* AWS Lambda — Event-driven orchestration
* AWS Elemental MediaConvert — HLS Adaptive Bitrate (ABR) transcoding
* Amazon SNS — Job completion notifications
* Amazon CloudWatch — Operational monitoring & alarms
* Terraform — Infrastructure as Code (IaC)

The system automatically transcodes uploaded videos into **HLS adaptive bitrate streams (1080p, 720p, 480p & 360p)** and stores the output in a structured directory within the same S3 bucket.

---

## Architecture

```
User Upload → S3 (uploads/)
      ↓
S3 Event Notification
      ↓
AWS Lambda
      ↓
MediaConvert Job
      ↓
S3 (processed/{filename}/)
      ↓
EventBridge → SNS (Completion Notification)
      ↓
CloudWatch Alarms (Error Monitoring)
```

---

## Features

* HLS Adaptive Bitrate output (1080p + 720p + 480p + 360p)
* Encrypted S3 bucket (AES256)
* Bucket versioning enabled
* Least-privilege IAM roles
* MediaConvert job completion notification via SNS
* CloudWatch alarms for:
  * Lambda errors
  * MediaConvert job failures
* Serverless and fully event-driven
* Infrastructure fully managed via Terraform

---

## Project Structure

```
terraform/
 ├── main.tf
 ├── variables.tf
 ├── outputs.tf
 ├── s3.tf
 ├── lambda.tf
 ├── iam.tf
 ├── mediaconvert.tf
 ├── sns.tf
 ├── cloudwatch.tf
 └── lambda_function.py
```

---

## Prerequisites

* AWS Account
* Terraform ≥ 1.3
* AWS CLI configured (`aws configure`)
* IAM permissions to create:
  * S3
  * Lambda
  * MediaConvert
  * SNS
  * CloudWatch
  * IAM roles & policies

---

## Deployment

### 1. Initialize Terraform

```bash
terraform init
```

### 2. Configure Variables

Create `terraform.tfvars`:

```hcl
bucket_name           = "your-unique-video-bucket"
notification_email    = "your-email@example.com"
region                = "ap-south-1"

# Optional: provide the MediaConvert regional endpoint to skip auto-discovery
# on Lambda cold starts. Leave unset to let the Lambda discover it automatically.
# mediaconvert_endpoint = "https://xxxxxxxx.mediaconvert.ap-south-1.amazonaws.com"

# Optional: override the MediaConvert queue (defaults to "Default")
# mediaconvert_queue = "Default"
```

### 3. Apply Infrastructure

```bash
terraform apply
```

Confirm the SNS email subscription when you receive the confirmation email.

---

## Upload Workflow

Upload video files into:

```
s3://your-bucket/uploads/
```

Example:

```bash
aws s3 cp sample.mp4 s3://your-bucket/uploads/
```

---

## Output Structure

After MediaConvert completes:

```
s3://your-bucket/processed/sample/
 ├── sample_1080p.m3u8
 ├── sample_720p.m3u8
 ├── sample_480p.m3u8
 ├── sample_360p.m3u8
 ├── segments...
 └── master playlist
```

These files are HLS compatible and can be served via:

* CloudFront
* Video.js
* Safari native HLS player

---

## Security Controls

| Control | Status |
|---|---|
| Bucket Encryption | Enabled (AES256) |
| Bucket Versioning | Enabled |
| Least Privilege IAM | Enforced |
| PassRole Restriction | Scoped |
| CloudWatch Monitoring | Enabled |
| EventBridge Integration | Enabled |

---

## Monitoring & Alerts

### Lambda Alarm
Triggers if Lambda function errors > 0 within a 1-minute window.

### MediaConvert Alarm
Triggers if any job transitions to ERROR state within a 5-minute window.

Alerts are published to the SNS topic and delivered to `notification_email`.

---

## HLS Configuration

The pipeline generates a 4-rung ABR ladder:

<!-- FIX: README previously listed only 1080p + 720p; actual code produces 4 renditions -->

| Resolution | Codec | Max Bitrate | Audio | Mode |
|---|---|---|---|---|
| 1080p | H.264 + AAC | 6 Mbps | 128 kbps | QVBR |
| 720p  | H.264 + AAC | 3.5 Mbps | 128 kbps | QVBR |
| 480p  | H.264 + AAC | 2 Mbps | 96 kbps | QVBR |
| 360p  | H.264 + AAC | 1 Mbps | 96 kbps | QVBR |

Segment length: 6 seconds
Output format: HLS (M3U8 playlists + TS segments)

---

## Failure Handling

* Lambda errors → CloudWatch Alarm → SNS
* MediaConvert job failures → EventBridge → SNS
* S3 trigger filtered to only `uploads/` prefix

---

## Cost Considerations

Primary cost drivers:

* MediaConvert processing minutes
* S3 storage (original + processed)
* Lambda invocations
* CloudWatch alarms
* SNS notifications

Optimization recommendations:
- Apply S3 lifecycle policy for original uploads
- Use QVBR instead of CBR (already configured)
- Use a dedicated MediaConvert queue for workload control

---

## Testing Strategy

1. Upload a test file under `uploads/`
2. Check Lambda logs in CloudWatch
3. Confirm MediaConvert job creation in the AWS console
4. Verify SNS completion email
5. Validate HLS playback locally or via CloudFront

---

## Troubleshooting

**MediaConvert Job Fails**
- Verify IAM role permissions
- Check S3 object accessibility
- Confirm correct endpoint discovery

**Lambda Not Triggering**
- Verify bucket notification configuration
- Confirm prefix filter (`uploads/`)
- Check Lambda permissions for S3 invocation

---

## Version

v1.1 — Bug fixes: s3.tf resource name, missing Lambda env vars, README ABR ladder correction.

---

## Author

Serverless Video Processing Pipeline using Terraform and AWS Native Services.

Serverless Video Transcoding Pipeline (AWS)
Overview

This project provisions an event-driven video processing pipeline on AWS using:

Amazon S3 – Video ingestion + output storage

AWS Lambda – Event-driven orchestration

AWS Elemental MediaConvert – HLS Adaptive Bitrate (ABR) transcoding

Amazon SNS – Job completion notifications

Amazon CloudWatch – Operational monitoring & alarms

Terraform – Infrastructure as Code (IaC)

The system automatically transcodes uploaded videos into HLS adaptive bitrate streams (1080p & 720p) and stores the output in a structured directory within the same S3 bucket.

Architecture
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

Features

HLS Adaptive Bitrate output (1080p + 720p)

Encrypted S3 bucket (AES256)

Bucket versioning enabled

Least-privilege IAM roles

MediaConvert job completion notification via SNS

CloudWatch alarms for:

Lambda errors

MediaConvert job failures

Serverless and fully event-driven

Infrastructure fully managed via Terraform

Project Structure
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

Prerequisites

AWS Account

Terraform ≥ 1.3

AWS CLI configured (aws configure)

IAM permissions to create:

S3

Lambda

MediaConvert

SNS

CloudWatch

IAM roles & policies

Deployment
1️ Initialize Terraform
terraform init

2️ Configure Variables

Create terraform.tfvars:

bucket_name         = "your-unique-video-bucket"
notification_email  = "your-email@example.com"
region              = "ap-south-1"

3️ Apply Infrastructure
terraform apply


Confirm the SNS email subscription when you receive the confirmation message.

Upload Workflow

Upload video files into:

s3://your-bucket/uploads/


Example:

aws s3 cp sample.mp4 s3://your-bucket/uploads/

Output Structure

After MediaConvert completes:

s3://your-bucket/processed/sample/
 ├── sample_1080p.m3u8
 ├── sample_720p.m3u8
 ├── segments...
 └── master playlist


These files are HLS compatible and can be served via:

CloudFront

Video.js

Safari native HLS player

Security Controls
Control	Status
Bucket Encryption	Enabled (AES256)
Bucket Versioning	Enabled
Least Privilege IAM	Enforced
PassRole Restriction	Scoped
CloudWatch Monitoring	Enabled
EventBridge Integration	Enabled
Monitoring & Alerts
Lambda Alarm

Triggers if:

Function errors > 0 within 1 minute

MediaConvert Alarm

Triggers if:

Any job transitions to ERROR state

Alerts are published to the SNS topic.

HLS Configuration

The pipeline generates:

Resolution	Codec	Bitrate Mode
1080p	H.264 + AAC	QVBR
720p	H.264 + AAC	QVBR

Segment length: 6 seconds
Output format: HLS (M3U8 playlists + TS segments)

Failure Handling

Lambda errors → CloudWatch Alarm → SNS

MediaConvert job failures → EventBridge → SNS

S3 trigger filtered to only uploads/ prefix

Cost Considerations

Primary cost drivers:

MediaConvert processing minutes

S3 storage (original + processed)

Lambda invocations

CloudWatch alarms

SNS notifications

Optimization recommendations:

Apply S3 lifecycle policy for original uploads

Use QVBR instead of CBR

Use dedicated MediaConvert queue for workload control

Recommended Enhancements

For production-grade OTT deployment:

Use separate input/output buckets

Enable SSE-KMS

Add CloudFront with signed URLs

Use MediaConvert Job Templates

Add DLQ to Lambda

Add Step Functions for orchestration

Implement tagging strategy for cost tracking

Testing Strategy

Upload test file under /uploads/

Check Lambda logs in CloudWatch

Confirm MediaConvert job creation

Verify SNS completion email

Validate HLS playback locally or via CloudFront

Troubleshooting

MediaConvert Job Fails

Verify IAM role permissions

Check S3 object accessibility

Confirm correct endpoint discovery

Lambda Not Triggering

Verify bucket notification configuration

Confirm prefix filter (uploads/)

Check Lambda permissions for S3 invocation

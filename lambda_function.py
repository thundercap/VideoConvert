import json
import boto3
import os
import urllib.parse
import logging
from botocore.config import Config
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---------- Supported video file extensions ----------
# IMPROVEMENT #2: File type validation — reject non-video files before submitting
# a paid MediaConvert job. Previously any file dropped in uploads/ would be submitted.
SUPPORTED_EXTENSIONS = {
    ".mp4", ".mov", ".mkv", ".avi", ".wmv",
    ".flv", ".webm", ".m4v", ".mxf", ".ts"
}

# ---------- Environment Variables ----------

REGION                = os.environ["REGION"]
MEDIACONVERT_ROLE     = os.environ["MEDIACONVERT_ROLE"]
MEDIACONVERT_QUEUE    = os.environ.get("MEDIACONVERT_QUEUE", "Default")
MEDIACONVERT_ENDPOINT = os.environ.get("MEDIACONVERT_ENDPOINT")

# IMPROVEMENT #4: BUCKET_NAME is now used as an explicit guard to reject events from
# unexpected buckets rather than being an unused dead env var.
EXPECTED_BUCKET = os.environ.get("BUCKET_NAME")

# ---------- Boto3 Retry Config ----------
# IMPROVEMENT #12: Adaptive retry mode automatically backs off on
# TooManyRequestsException and other transient errors (max 3 attempts).
BOTO_RETRY_CONFIG = Config(
    retries={
        "max_attempts": 3,
        "mode": "adaptive"
    }
)

# ---------- Global Client Initialization (Cold Start Optimization) ----------
# IMPROVEMENT #3: Wrap the cold-start init in try/except. Previously, any transient
# failure in describe_endpoints() (network blip, IAM propagation delay) would crash
# the module at import time, permanently breaking Lambda with Runtime.ImportModuleError
# until redeployment.
try:
    if MEDIACONVERT_ENDPOINT:
        mediaconvert_client = boto3.client(
            "mediaconvert",
            region_name=REGION,
            endpoint_url=MEDIACONVERT_ENDPOINT,
            config=BOTO_RETRY_CONFIG
        )
    else:
        # Discover endpoint once and cache it for all warm invocations
        _mc = boto3.client("mediaconvert", region_name=REGION, config=BOTO_RETRY_CONFIG)
        _endpoints = _mc.describe_endpoints()
        _endpoint_url = _endpoints["Endpoints"][0]["Url"]
        mediaconvert_client = boto3.client(
            "mediaconvert",
            region_name=REGION,
            endpoint_url=_endpoint_url,
            config=BOTO_RETRY_CONFIG
        )
    logger.info("MediaConvert client initialized successfully")
except Exception as _init_err:
    logger.error(f"MediaConvert client init failed at cold start: {_init_err}")
    mediaconvert_client = None  # handler will surface this as a clean error

# IMPROVEMENT #22: S3 client for file size guard (0-byte file detection)
s3_client = boto3.client("s3", region_name=REGION)


# ---------- ABR Output Helpers ----------

def generate_outputs():
    """Return 4-rung HLS ABR ladder: 1080p / 720p / 480p / 360p."""
    return [
        _create_output("_1080p", 1920, 1080, 6000000, 8, 128000),
        _create_output("_720p",  1280, 720,  3500000, 8, 128000),
        _create_output("_480p",  854,  480,  2000000, 7, 96000),
        _create_output("_360p",  640,  360,  1000000, 7, 96000),
    ]


def _create_output(name_modifier, width, height, max_bitrate, qvbr_quality, audio_bitrate):
    return {
        "NameModifier": name_modifier,
        "VideoDescription": {
            "Width": width,
            "Height": height,
            "CodecSettings": {
                "Codec": "H_264",
                "H264Settings": {
                    "RateControlMode": "QVBR",
                    "QvbrSettings": {"QvbrQualityLevel": qvbr_quality},
                    "MaxBitrate": max_bitrate,
                    "GopSize": 2,
                    "GopSizeUnits": "SECONDS",
                    "NumberBFramesBetweenReferenceFrames": 3,
                    "SceneChangeDetect": "TRANSITION_DETECTION",
                    "EntropyEncoding": "CABAC"
                }
            }
        },
        "AudioDescriptions": [{
            "CodecSettings": {
                "Codec": "AAC",
                "AacSettings": {
                    "Bitrate": audio_bitrate,
                    "CodingMode": "CODING_MODE_2_0",
                    "SampleRate": 48000
                }
            }
        }],
        "ContainerSettings": {"Container": "M3U8"},
        "HlsSettings": {"SegmentModifier": "$dt$"}
    }


# ---------- Per-Record Processor ----------

def _process_record(record):
    """
    Process a single S3 event record.

    Returns a result dict on success, None if the record is intentionally skipped,
    or raises an exception on a hard failure.

    Separated from lambda_handler so that IMPROVEMENT #1 (per-record error isolation)
    is clean — an exception here only affects this one record, not the whole batch.
    """
    bucket = record["s3"]["bucket"]["name"]
    key    = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
    size   = record["s3"]["object"].get("size", -1)

    logger.info(f"Evaluating s3://{bucket}/{key} (size={size})")

    # IMPROVEMENT #4: Reject events from unexpected buckets
    if EXPECTED_BUCKET and bucket != EXPECTED_BUCKET:
        logger.warning(
            f"Ignoring event from bucket '{bucket}' — expected '{EXPECTED_BUCKET}'"
        )
        return None

    # Prefix guard (belt-and-suspenders alongside the bucket notification filter)
    if not key.startswith("uploads/"):
        logger.info(f"Skipping key outside uploads/ prefix: {key}")
        return None

    # IMPROVEMENT #2: Reject unsupported file types upfront
    _, ext = os.path.splitext(key.lower())
    if ext not in SUPPORTED_EXTENSIONS:
        logger.warning(f"Unsupported file type '{ext}' — skipping: {key}")
        return None

    # IMPROVEMENT #22: File size guard — 0-byte files will fail in MediaConvert
    if size == 0:
        logger.warning(f"Skipping zero-byte file: {key}")
        return None

    # If the event didn't include a size, confirm via HeadObject before submitting
    if size == -1:
        try:
            head = s3_client.head_object(Bucket=bucket, Key=key)
            if head["ContentLength"] == 0:
                logger.warning(f"Skipping zero-byte file (confirmed via HeadObject): {key}")
                return None
        except ClientError as e:
            logger.error(f"HeadObject failed for s3://{bucket}/{key}: {e}")
            raise

    if mediaconvert_client is None:
        raise RuntimeError(
            "MediaConvert client failed to initialize at cold start — check earlier logs"
        )

    base_filename = key.split("/")[-1].rsplit(".", 1)[0]

    job_settings = {
        "Role":  MEDIACONVERT_ROLE,
        "Queue": MEDIACONVERT_QUEUE,
        # IMPROVEMENT #5: Tag every job with pipeline identity so the EventBridge rule
        # in cloudwatch.tf can be scoped to only THIS pipeline's jobs, preventing
        # false alerts from other MediaConvert pipelines in the same AWS account.
        "UserMetadata": {
            "pipeline":      "video-convert",
            "source_bucket": bucket,
            "source_key":    key
        },
        "Settings": {
            "Inputs": [{
                "FileInput": f"s3://{bucket}/{key}",
                "AudioSelectors": {
                    "Audio Selector 1": {"DefaultSelection": "DEFAULT"}
                }
            }],
            "OutputGroups": [{
                "Name": "HLS ABR Group",
                "OutputGroupSettings": {
                    "Type": "HLS_GROUP_SETTINGS",
                    "HlsGroupSettings": {
                        "Destination": f"s3://{bucket}/processed/{base_filename}/",
                        "SegmentLength": 6,
                        "MinSegmentLength": 0,
                        "DirectoryStructure": "SINGLE_DIRECTORY",
                        "ManifestDurationFormat": "INTEGER",
                        "OutputSelection": "MANIFESTS_AND_SEGMENTS"
                    }
                },
                "Outputs": generate_outputs()
            }]
        },
        "StatusUpdateInterval": "SECONDS_60"
    }

    response = mediaconvert_client.create_job(**job_settings)
    job_id = response["Job"]["Id"]
    logger.info(f"MediaConvert job created: {job_id}  source=s3://{bucket}/{key}")
    return {"key": key, "job_id": job_id}


# ---------- Lambda Handler ----------

def lambda_handler(event, context):
    records = event.get("Records", [])

    if not records:
        logger.warning("Lambda invoked with no S3 records")
        return {"statusCode": 200, "body": json.dumps("No records to process")}

    submitted = []
    failed    = []

    # IMPROVEMENT #1: Per-record error isolation.
    # Previously the try/except wrapped the entire loop, so a failure on record N
    # silently dropped all records after N. Now each record is processed independently.
    for record in records:
        try:
            result = _process_record(record)
            if result:
                submitted.append(result)
        except Exception as e:
            key = record.get("s3", {}).get("object", {}).get("key", "unknown")
            logger.error(f"Failed to process record '{key}': {e}", exc_info=True)
            failed.append({"key": key, "error": str(e)})

    # If the entire batch failed, return 500 so Lambda's async retry fires
    # and the event is forwarded to the DLQ (if configured in lambda.tf).
    if failed and not submitted:
        return {
            "statusCode": 500,
            "body": json.dumps({"submitted": submitted, "failed": failed})
        }

    if failed:
        logger.warning(f"Partial failure: {len(failed)}/{len(records)} records failed")

    return {
        "statusCode": 200,
        "body": json.dumps({"submitted": submitted, "failed": failed})
    }

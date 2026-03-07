"""
VideoConvert Lambda — triggers AWS MediaConvert HLS transcoding jobs.

Invocation path (production):
  S3 upload → SQS intake queue → Lambda event source mapping → MediaConvert

Invocation path (legacy / direct test):
  S3 upload → Lambda (async direct invoke)

Both paths are handled transparently below.
"""

import json
import os
import time
import urllib.parse
import logging
from botocore.config import Config
from botocore.exceptions import ClientError

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── Supported video file extensions ───────────────────────────────────────────
SUPPORTED_EXTENSIONS = {
    ".mp4", ".mov", ".mkv", ".avi", ".wmv",
    ".flv", ".webm", ".m4v", ".mxf", ".ts"
}

# ── Environment variables ──────────────────────────────────────────────────────
REGION                 = os.environ["REGION"]
MEDIACONVERT_ROLE      = os.environ["MEDIACONVERT_ROLE"]
MEDIACONVERT_QUEUE     = os.environ.get("MEDIACONVERT_QUEUE", "Default")
MEDIACONVERT_ENDPOINT  = os.environ.get("MEDIACONVERT_ENDPOINT")
INPUT_BUCKET           = os.environ.get("BUCKET_NAME")
OUTPUT_BUCKET          = os.environ.get("OUTPUT_BUCKET") or INPUT_BUCKET  # separate output bucket (#9)
DEDUP_TABLE            = os.environ.get("DEDUP_TABLE")                    # DynamoDB dedup table (#6)
JOB_TEMPLATE_ARN       = os.environ.get("JOB_TEMPLATE_ARN", "")           # optional MC template (#7)
STATUS_UPDATE_INTERVAL = os.environ.get("STATUS_UPDATE_INTERVAL", "SECONDS_60")  # configurable (#17)
DEDUP_TTL_SECONDS      = int(os.environ.get("DEDUP_TTL_SECONDS", "86400"))

# ── Boto3 retry config ─────────────────────────────────────────────────────────
_RETRY = Config(retries={"max_attempts": 3, "mode": "adaptive"})

# ── Module-level cached ABR ladder (#8) ───────────────────────────────────────
# Constructed once at cold start — identical for every job so no reason to
# rebuild the dicts on every warm invocation.
def _make_output(name_modifier, width, height, max_bitrate, qvbr_level, audio_bitrate):
    return {
        "NameModifier": name_modifier,
        "VideoDescription": {
            "Width": width,
            "Height": height,
            "CodecSettings": {
                "Codec": "H_264",
                "H264Settings": {
                    "RateControlMode": "QVBR",
                    "QvbrSettings": {"QvbrQualityLevel": qvbr_level},
                    "MaxBitrate": max_bitrate,
                    "GopSize": 2,
                    "GopSizeUnits": "SECONDS",
                    "NumberBFramesBetweenReferenceFrames": 3,
                    "SceneChangeDetect": "TRANSITION_DETECTION",
                    "EntropyEncoding": "CABAC",
                },
            },
        },
        "AudioDescriptions": [{
            "CodecSettings": {
                "Codec": "AAC",
                "AacSettings": {
                    "Bitrate": audio_bitrate,
                    "CodingMode": "CODING_MODE_2_0",
                    "SampleRate": 48000,
                },
            }
        }],
        "ContainerSettings": {"Container": "M3U8"},
        "HlsSettings": {"SegmentModifier": "$dt$"},
    }


_ABR_OUTPUTS = [
    _make_output("_1080p", 1920, 1080, 6_000_000, 8, 128_000),
    _make_output("_720p",  1280,  720, 3_500_000, 8, 128_000),
    _make_output("_480p",   854,  480, 2_000_000, 7,  96_000),
    _make_output("_360p",   640,  360, 1_000_000, 7,  96_000),
]

# ── AWS client initialization (cold-start) ────────────────────────────────────
try:
    if MEDIACONVERT_ENDPOINT:
        _mc = boto3.client(
            "mediaconvert", region_name=REGION,
            endpoint_url=MEDIACONVERT_ENDPOINT, config=_RETRY,
        )
    else:
        _probe = boto3.client("mediaconvert", region_name=REGION, config=_RETRY)
        _ep    = _probe.describe_endpoints()["Endpoints"][0]["Url"]
        _mc    = boto3.client(
            "mediaconvert", region_name=REGION,
            endpoint_url=_ep, config=_RETRY,
        )
    logger.info(json.dumps({"event": "mc_client_ready"}))
except Exception as _err:
    logger.error(json.dumps({"event": "mc_client_failed", "error": str(_err)}))
    _mc = None

_s3  = boto3.client("s3",         region_name=REGION, config=_RETRY)
_cw  = boto3.client("cloudwatch", region_name=REGION, config=_RETRY)
_ddb = boto3.client("dynamodb",   region_name=REGION, config=_RETRY) if DEDUP_TABLE else None


# ── Structured logger (#14) ────────────────────────────────────────────────────
class _Log:
    """
    Emits JSON log lines with a Lambda request-ID on every entry.
    Enables fast cross-invocation queries in CloudWatch Logs Insights:
        fields @message | filter request_id = "abc-123"
    """
    def __init__(self, request_id: str):
        self._rid = request_id

    def _write(self, level: int, event: str, **kw):
        logger.log(level, json.dumps({"event": event, "request_id": self._rid, **kw}))

    def info(self,  event, **kw): self._write(logging.INFO,    event, **kw)
    def warn(self,  event, **kw): self._write(logging.WARNING, event, **kw)
    def error(self, event, **kw): self._write(logging.ERROR,   event, **kw)


# ── Custom CloudWatch metric (#16) ─────────────────────────────────────────────
def _metric(name: str, value: float = 1.0):
    """Fire-and-forget custom metric in the VideoConvert namespace."""
    try:
        _cw.put_metric_data(
            Namespace="VideoConvert",
            MetricData=[{
                "MetricName": name,
                "Value":      value,
                "Unit":       "Count",
                "Dimensions": [{"Name": "Pipeline", "Value": "video-convert"}],
            }],
        )
    except Exception as exc:
        logger.warning(json.dumps({"event": "metric_emit_failed", "metric": name, "error": str(exc)}))


# ── Job deduplication (#6) ─────────────────────────────────────────────────────
def _claim_job(key: str, etag: str) -> bool:
    """
    Atomically claims (key, etag) in DynamoDB before submitting a MediaConvert job.

    Returns True  -> claim succeeded, safe to submit.
    Returns False -> record exists within TTL window -> duplicate, skip.

    Composite key "{key}#{etag}" means:
      - Duplicate S3 at-least-once deliveries of the same upload -> deduplicated
      - Re-upload of the same filename (different eTag) -> new job submitted
    """
    if not _ddb:
        return True  # DEDUP_TABLE not configured -> dedup disabled

    dedup_key  = f"{key}#{etag}"
    expires_at = int(time.time()) + DEDUP_TTL_SECONDS

    try:
        _ddb.put_item(
            TableName=DEDUP_TABLE,
            Item={
                "dedup_key":  {"S": dedup_key},
                "source_key": {"S": key},
                "etag":       {"S": etag},
                "expires_at": {"N": str(expires_at)},
            },
            ConditionExpression="attribute_not_exists(dedup_key)",
        )
        return True   # First time seeing this key -> proceed
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False  # Already claimed within TTL -> duplicate
        raise   # Unexpected DynamoDB error -> propagate so SQS retries the message


# ── Per-record processor ───────────────────────────────────────────────────────
def _process_record(s3_record: dict, log: _Log):
    """
    Validates one S3 event record and submits a MediaConvert job.
    Returns a result dict on success, None for intentional skips, raises on hard failures.
    """
    bucket = s3_record["s3"]["bucket"]["name"]
    key    = urllib.parse.unquote_plus(s3_record["s3"]["object"]["key"])
    size   = s3_record["s3"]["object"].get("size", -1)
    etag   = s3_record["s3"]["object"].get("eTag", "noetag")

    log.info("evaluating", bucket=bucket, key=key, size=size)

    if INPUT_BUCKET and bucket != INPUT_BUCKET:
        log.warn("unexpected_bucket", bucket=bucket, expected=INPUT_BUCKET)
        return None

    if not key.startswith("uploads/"):
        log.info("skipped_prefix", key=key)
        return None

    _, ext = os.path.splitext(key.lower())
    if ext not in SUPPORTED_EXTENSIONS:
        log.warn("unsupported_extension", key=key, ext=ext)
        return None

    if size == 0:
        log.warn("zero_byte_skipped", key=key)
        return None

    if size < 0:
        try:
            head = _s3.head_object(Bucket=bucket, Key=key)
            if head["ContentLength"] == 0:
                log.warn("zero_byte_confirmed", key=key)
                return None
        except ClientError as exc:
            log.error("head_object_failed", key=key, error=str(exc))
            raise

    # Dedup (#6): atomic DynamoDB claim — skip if already in-flight or recently submitted
    if not _claim_job(key, etag):
        log.info("duplicate_skipped", key=key, etag=etag)
        _metric("JobsDeduplicated")
        return None

    if _mc is None:
        raise RuntimeError("MediaConvert client not initialised — see cold-start logs")

    base        = key.split("/")[-1].rsplit(".", 1)[0]
    destination = f"s3://{OUTPUT_BUCKET}/processed/{base}/"

    user_meta = {
        "pipeline":      "video-convert",
        "source_bucket": bucket,
        "source_key":    key,
    }
    hls_group = {
        "Destination":            destination,
        "SegmentLength":          6,
        "MinSegmentLength":       0,
        "DirectoryStructure":     "SINGLE_DIRECTORY",
        "ManifestDurationFormat": "INTEGER",
        "OutputSelection":        "MANIFESTS_AND_SEGMENTS",
    }

    if JOB_TEMPLATE_ARN:
        # (#7) Template path: encoding settings live in MediaConvert.
        # We only supply the Input and override the output Destination.
        # OutputGroups[0] here maps to the first group in the template by index,
        # overriding only the Destination; codec/segment settings stay in the template.
        job_params = {
            "Role":         MEDIACONVERT_ROLE,
            "Queue":        MEDIACONVERT_QUEUE,
            "JobTemplate":  JOB_TEMPLATE_ARN,
            "UserMetadata": user_meta,
            "Settings": {
                "Inputs": [{
                    "FileInput": f"s3://{bucket}/{key}",
                    "AudioSelectors": {"Audio Selector 1": {"DefaultSelection": "DEFAULT"}},
                }],
                "OutputGroups": [{
                    "OutputGroupSettings": {
                        "Type": "HLS_GROUP_SETTINGS",
                        "HlsGroupSettings": hls_group,
                    }
                }],
            },
            "StatusUpdateInterval": STATUS_UPDATE_INTERVAL,
        }
    else:
        # Inline path: uses cached _ABR_OUTPUTS (#8) — no dict rebuild per invocation
        job_params = {
            "Role":         MEDIACONVERT_ROLE,
            "Queue":        MEDIACONVERT_QUEUE,
            "UserMetadata": user_meta,
            "Settings": {
                "Inputs": [{
                    "FileInput": f"s3://{bucket}/{key}",
                    "AudioSelectors": {"Audio Selector 1": {"DefaultSelection": "DEFAULT"}},
                }],
                "OutputGroups": [{
                    "Name": "HLS ABR Group",
                    "OutputGroupSettings": {
                        "Type": "HLS_GROUP_SETTINGS",
                        "HlsGroupSettings": hls_group,
                    },
                    "Outputs": _ABR_OUTPUTS,
                }],
            },
            "StatusUpdateInterval": STATUS_UPDATE_INTERVAL,
        }

    response = _mc.create_job(**job_params)
    job_id   = response["Job"]["Id"]

    log.info("job_submitted", key=key, job_id=job_id, destination=destination)
    _metric("JobsSubmitted")  # (#16) pipeline throughput metric

    return {"key": key, "job_id": job_id}


# ── Lambda handler ─────────────────────────────────────────────────────────────
def lambda_handler(event, context):
    """
    Handles two invocation modes:

    1. SQS event source mapping (production, #11):
       Records[*].eventSource == "aws:sqs"
       Each SQS body contains a JSON-encoded S3 notification.
       Returns batchItemFailures so only failed messages are retried.

    2. Direct S3 / test invocation (legacy):
       Records[*].eventSource == "aws:s3"
       Returns standard statusCode response.
    """
    request_id = getattr(context, "aws_request_id", "local")
    log = _Log(request_id)

    raw = event.get("Records", [])
    if not raw:
        log.warn("no_records")
        return {"statusCode": 200, "body": json.dumps("no records")}

    is_sqs = raw[0].get("eventSource") == "aws:sqs"

    # Map message_id -> [s3_records] for per-message failure tracking
    work: dict = {}
    if is_sqs:
        for msg in raw:
            mid = msg.get("messageId", "unknown")
            try:
                body = json.loads(msg.get("body", "{}"))
                work[mid] = body.get("Records", [])  # S3 test events have no Records
            except (json.JSONDecodeError, TypeError) as exc:
                log.error("bad_sqs_body", message_id=mid, error=str(exc))
                work[mid] = []
    else:
        work["direct"] = raw

    submitted      = []
    failed         = []
    failed_msg_ids = []

    for msg_id, s3_records in work.items():
        msg_failed = False
        for rec in s3_records:
            try:
                result = _process_record(rec, log)
                if result:
                    submitted.append(result)
            except Exception as exc:
                key = rec.get("s3", {}).get("object", {}).get("key", "unknown")
                log.error("record_failed", key=key, error=str(exc))
                failed.append({"key": key, "error": str(exc)})
                msg_failed = True

        if msg_failed and msg_id != "direct":
            failed_msg_ids.append(msg_id)

    if failed:
        log.warn("partial_failure", submitted=len(submitted), failed=len(failed))

    # (#11) Partial batch failure: only failed SQS messages go back to the queue;
    # successfully processed messages are acknowledged.
    if is_sqs and failed_msg_ids:
        return {"batchItemFailures": [{"itemIdentifier": mid} for mid in failed_msg_ids]}

    if failed and not submitted:
        return {"statusCode": 500, "body": json.dumps({"submitted": submitted, "failed": failed})}

    return {"statusCode": 200, "body": json.dumps({"submitted": submitted, "failed": failed})}

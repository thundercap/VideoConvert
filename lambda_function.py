import json
import boto3
import os
import urllib.parse
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---------- Global Initialization (Cold Start Optimization) ----------

REGION = os.environ["REGION"]
MEDIACONVERT_ROLE = os.environ["MEDIACONVERT_ROLE"]
MEDIACONVERT_QUEUE = os.environ.get("MEDIACONVERT_QUEUE", "Default")

# Use pre-configured endpoint if provided (recommended)
MEDIACONVERT_ENDPOINT = os.environ.get("MEDIACONVERT_ENDPOINT")

if MEDIACONVERT_ENDPOINT:
    mediaconvert_client = boto3.client(
        "mediaconvert",
        region_name=REGION,
        endpoint_url=MEDIACONVERT_ENDPOINT
    )
else:
    # Discover endpoint once during cold start
    mc = boto3.client("mediaconvert", region_name=REGION)
    endpoints = mc.describe_endpoints()
    endpoint_url = endpoints["Endpoints"][0]["Url"]

    mediaconvert_client = boto3.client(
        "mediaconvert",
        region_name=REGION,
        endpoint_url=endpoint_url
    )


# ---------- Helper: Generate ABR Outputs ----------

def generate_outputs():
    return [

        # 1080p
        create_output("_1080p", 1920, 1080, 6000000, 8, 128000),

        # 720p
        create_output("_720p", 1280, 720, 3500000, 8, 128000),

        # 480p
        create_output("_480p", 854, 480, 2000000, 7, 96000),

        # 360p
        create_output("_360p", 640, 360, 1000000, 7, 96000),
    ]


def create_output(name_modifier, width, height, max_bitrate, qvbr_quality, audio_bitrate):
    return {
        "NameModifier": name_modifier,
        "VideoDescription": {
            "Width": width,
            "Height": height,
            "CodecSettings": {
                "Codec": "H_264",
                "H264Settings": {
                    "RateControlMode": "QVBR",
                    "QvbrSettings": {
                        "QvbrQualityLevel": qvbr_quality
                    },
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
        "ContainerSettings": {
            "Container": "M3U8"
        },
        "HlsSettings": {
            "SegmentModifier": "$dt$"
        }
    }


# ---------- Lambda Handler ----------

def lambda_handler(event, context):
    try:
        records = event.get("Records", [])

        for record in records:

            bucket = record["s3"]["bucket"]["name"]
            key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

            logger.info(f"Processing file: s3://{bucket}/{key}")

            if not key.startswith("uploads/"):
                logger.info("Skipping non-upload folder")
                continue

            base_filename = key.split("/")[-1].rsplit(".", 1)[0]

            job_settings = {
                "Role": MEDIACONVERT_ROLE,
                "Queue": MEDIACONVERT_QUEUE,
                "Settings": {
                    "Inputs": [{
                        "FileInput": f"s3://{bucket}/{key}",
                        "AudioSelectors": {
                            "Audio Selector 1": {
                                "DefaultSelection": "DEFAULT"
                            }
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
            logger.info(f"MediaConvert Job Created: {job_id}")

        return {
            "statusCode": 200,
            "body": json.dumps("MediaConvert jobs submitted successfully")
        }

    except Exception as e:
        logger.error(f"Error processing MediaConvert job: {str(e)}")

        return {
            "statusCode": 500,
            "body": json.dumps({
                "error": str(e)
            })
        }

import json
import boto3
import os
import urllib.parse

def lambda_handler(event, context):

    try:
        record = event['Records'][0]
        bucket = record['s3']['bucket']['name']
        key = urllib.parse.unquote_plus(record['s3']['object']['key'])

        if not key.startswith("uploads/"):
            print("Skipping non-upload folder")
            return {"statusCode": 200}

        region = os.environ['REGION']
        mediaconvert_role = os.environ['MEDIACONVERT_ROLE']

        # Get MediaConvert endpoint
        mc_client = boto3.client('mediaconvert', region_name=region)
        endpoints = mc_client.describe_endpoints()
        endpoint_url = endpoints['Endpoints'][0]['Url']

        mediaconvert = boto3.client(
            'mediaconvert',
            region_name=region,
            endpoint_url=endpoint_url
        )

        base_filename = key.split("/")[-1].split(".")[0]

        job_settings = {
            "Role": mediaconvert_role,
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
                    "Name": "HLS Group",
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
                    "Outputs": [
                        # 1080p
                        {
                            "NameModifier": "_1080p",
                            "VideoDescription": {
                                "Width": 1920,
                                "Height": 1080,
                                "CodecSettings": {
                                    "Codec": "H_264",
                                    "H264Settings": {
                                        "RateControlMode": "QVBR",
                                        "MaxBitrate": 6000000,
                                        "SceneChangeDetect": "TRANSITION_DETECTION"
                                    }
                                }
                            },
                            "AudioDescriptions": [{
                                "CodecSettings": {
                                    "Codec": "AAC",
                                    "AacSettings": {
                                        "Bitrate": 96000,
                                        "CodingMode": "CODING_MODE_2_0",
                                        "SampleRate": 48000
                                    }
                                }
                            }],
                            "ContainerSettings": {
                                "Container": "M3U8"
                            }
                        },
                        # 720p
                        {
                            "NameModifier": "_720p",
                            "VideoDescription": {
                                "Width": 1280,
                                "Height": 720,
                                "CodecSettings": {
                                    "Codec": "H_264",
                                    "H264Settings": {
                                        "RateControlMode": "QVBR",
                                        "MaxBitrate": 3500000,
                                        "SceneChangeDetect": "TRANSITION_DETECTION"
                                    }
                                }
                            },
                            "AudioDescriptions": [{
                                "CodecSettings": {
                                    "Codec": "AAC",
                                    "AacSettings": {
                                        "Bitrate": 96000,
                                        "CodingMode": "CODING_MODE_2_0",
                                        "SampleRate": 48000
                                    }
                                }
                            }],
                            "ContainerSettings": {
                                "Container": "M3U8"
                            }
                        }
                    ]
                }]
            },
            "StatusUpdateInterval": "SECONDS_60",
            "Queue": os.environ.get("MEDIACONVERT_QUEUE", "Default")
        }

        response = mediaconvert.create_job(**job_settings)

        print("MediaConvert Job Created:", response['Job']['Id'])

        return {
            "statusCode": 200,
            "body": json.dumps("MediaConvert job submitted successfully")
        }

    except Exception as e:
        print("Error:", str(e))
        raise

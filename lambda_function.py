import json
import boto3
import os

def lambda_handler(event, context):

    bucket = event['Records'][0]['s3']['bucket']['name']
    key = event['Records'][0]['s3']['object']['key']

    mediaconvert = boto3.client('mediaconvert', region_name=os.environ['REGION'])

    endpoints = mediaconvert.describe_endpoints()
    mediaconvert = boto3.client(
        'mediaconvert',
        region_name=os.environ['REGION'],
        endpoint_url=endpoints['Endpoints'][0]['Url']
    )

    job_settings = {
        "Role": os.environ['MEDIACONVERT_ROLE'],
        "Settings": {
            "Inputs": [{
                "FileInput": f"s3://{bucket}/{key}"
            }],
            "OutputGroups": [{
                "Name": "File Group",
                "OutputGroupSettings": {
                    "Type": "FILE_GROUP_SETTINGS",
                    "FileGroupSettings": {
                        "Destination": f"s3://{bucket}/processed/"
                    }
                },
                "Outputs": [{
                    "VideoDescription": {
                        "Width": 1280,
                        "Height": 720,
                        "CodecSettings": {
                            "Codec": "H_264",
                            "H264Settings": {
                                "Bitrate": 5000000,
                                "RateControlMode": "CBR"
                            }
                        }
                    },
                    "ContainerSettings": {
                        "Container": "MP4"
                    }
                }]
            }]
        }
    }

    response = mediaconvert.create_job(**job_settings)

    return {
        'statusCode': 200,
        'body': json.dumps('MediaConvert job submitted!')
    }

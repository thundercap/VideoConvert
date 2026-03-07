# ── Dedicated MediaConvert queue (#4) ─────────────────────────────────────────
#
# The "Default" queue is shared with all other MediaConvert workloads in the account.
# A dedicated queue isolates this pipeline, gives accurate per-pipeline metrics,
# and can be converted to Reserved pricing (~20% cheaper per processing minute)
# by contacting AWS — the queue ARN stays the same, so no infra change required.
resource "aws_media_convert_queue" "dedicated" {
  name   = "video-convert"
  status = "ACTIVE"
  # pricing_plan = "ON_DEMAND"  # Contact AWS to switch to RESERVED for ~20% savings
}


# ── HLS ABR Job Template (#7) ─────────────────────────────────────────────────
#
# Why a job template instead of inline settings in the Lambda function:
#   - Encoding parameters (bitrates, quality levels, segment length) live in
#     MediaConvert, not in Lambda code — update them in the console without
#     redeploying the Lambda function
#   - The Lambda API payload shrinks from ~60 lines of settings JSON to just
#     the input FileInput and output Destination
#   - Templates are versioned and auditable in the MediaConvert console
#   - Non-developers can tune encoding quality without touching code
#
# When JOB_TEMPLATE_ARN is set on the Lambda, the function sends only:
#   { JobTemplate: ARN, Settings: { Inputs: [...], OutputGroups[0].Destination } }
# MediaConvert merges the job's overrides with the template's codec settings.
resource "aws_media_convert_job_template" "hls_abr" {
  name        = "video-convert-hls-abr"
  description = "4-rung HLS ABR ladder: 1080p/720p/480p/360p H.264 QVBR + AAC"
  category    = "VideoConvert"

  settings_json = jsonencode({
    OutputGroups = [{
      Name = "HLS ABR Group"
      OutputGroupSettings = {
        Type = "HLS_GROUP_SETTINGS"
        HlsGroupSettings = {
          # Destination is a placeholder — overridden per-job by the Lambda function
          Destination            = "s3://placeholder/"
          SegmentLength          = 6
          MinSegmentLength       = 0
          DirectoryStructure     = "SINGLE_DIRECTORY"
          ManifestDurationFormat = "INTEGER"
          OutputSelection        = "MANIFESTS_AND_SEGMENTS"
        }
      }
      Outputs = [
        {
          NameModifier = "_1080p"
          VideoDescription = {
            Width  = 1920
            Height = 1080
            CodecSettings = {
              Codec = "H_264"
              H264Settings = {
                RateControlMode = "QVBR"
                QvbrSettings    = { QvbrQualityLevel = 8 }
                MaxBitrate      = 6000000
                GopSize         = 2
                GopSizeUnits    = "SECONDS"
                NumberBFramesBetweenReferenceFrames = 3
                SceneChangeDetect  = "TRANSITION_DETECTION"
                EntropyEncoding    = "CABAC"
              }
            }
          }
          AudioDescriptions = [{
            CodecSettings = {
              Codec = "AAC"
              AacSettings = { Bitrate = 128000, CodingMode = "CODING_MODE_2_0", SampleRate = 48000 }
            }
          }]
          ContainerSettings = { Container = "M3U8" }
          HlsSettings       = { SegmentModifier = "$dt$" }
        },
        {
          NameModifier = "_720p"
          VideoDescription = {
            Width  = 1280
            Height = 720
            CodecSettings = {
              Codec = "H_264"
              H264Settings = {
                RateControlMode = "QVBR"
                QvbrSettings    = { QvbrQualityLevel = 8 }
                MaxBitrate      = 3500000
                GopSize         = 2
                GopSizeUnits    = "SECONDS"
                NumberBFramesBetweenReferenceFrames = 3
                SceneChangeDetect  = "TRANSITION_DETECTION"
                EntropyEncoding    = "CABAC"
              }
            }
          }
          AudioDescriptions = [{
            CodecSettings = {
              Codec = "AAC"
              AacSettings = { Bitrate = 128000, CodingMode = "CODING_MODE_2_0", SampleRate = 48000 }
            }
          }]
          ContainerSettings = { Container = "M3U8" }
          HlsSettings       = { SegmentModifier = "$dt$" }
        },
        {
          NameModifier = "_480p"
          VideoDescription = {
            Width  = 854
            Height = 480
            CodecSettings = {
              Codec = "H_264"
              H264Settings = {
                RateControlMode = "QVBR"
                QvbrSettings    = { QvbrQualityLevel = 7 }
                MaxBitrate      = 2000000
                GopSize         = 2
                GopSizeUnits    = "SECONDS"
                NumberBFramesBetweenReferenceFrames = 3
                SceneChangeDetect  = "TRANSITION_DETECTION"
                EntropyEncoding    = "CABAC"
              }
            }
          }
          AudioDescriptions = [{
            CodecSettings = {
              Codec = "AAC"
              AacSettings = { Bitrate = 96000, CodingMode = "CODING_MODE_2_0", SampleRate = 48000 }
            }
          }]
          ContainerSettings = { Container = "M3U8" }
          HlsSettings       = { SegmentModifier = "$dt$" }
        },
        {
          NameModifier = "_360p"
          VideoDescription = {
            Width  = 640
            Height = 360
            CodecSettings = {
              Codec = "H_264"
              H264Settings = {
                RateControlMode = "QVBR"
                QvbrSettings    = { QvbrQualityLevel = 7 }
                MaxBitrate      = 1000000
                GopSize         = 2
                GopSizeUnits    = "SECONDS"
                NumberBFramesBetweenReferenceFrames = 3
                SceneChangeDetect  = "TRANSITION_DETECTION"
                EntropyEncoding    = "CABAC"
              }
            }
          }
          AudioDescriptions = [{
            CodecSettings = {
              Codec = "AAC"
              AacSettings = { Bitrate = 96000, CodingMode = "CODING_MODE_2_0", SampleRate = 48000 }
            }
          }]
          ContainerSettings = { Container = "M3U8" }
          HlsSettings       = { SegmentModifier = "$dt$" }
        }
      ]
    }]
    # Placeholder input — overridden per-job by Lambda with the actual s3:// URI
    Inputs = [{
      FileInput = "s3://placeholder/placeholder.mp4"
      AudioSelectors = {
        "Audio Selector 1" = { DefaultSelection = "DEFAULT" }
      }
    }]
  })
}


# ── MediaConvert IAM role ──────────────────────────────────────────────────────
resource "aws_iam_role" "mediaconvert_role" {
  name = "mediaconvert-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "mediaconvert.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "mediaconvert_s3_policy" {
  name = "mediaconvert-s3-access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # (#9) Read source video from the dedicated input bucket only
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.input_bucket.arn}/uploads/*"
      },
      {
        # (#9) Write HLS output to the dedicated output bucket only
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.output_bucket.arn}/processed/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "mediaconvert_custom_attach" {
  role       = aws_iam_role.mediaconvert_role.name
  policy_arn = aws_iam_policy.mediaconvert_s3_policy.arn
}

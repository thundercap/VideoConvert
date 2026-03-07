# ── Job deduplication table (#6) ───────────────────────────────────────────────
#
# S3 event notifications are at-least-once: the same upload can trigger Lambda
# more than once. Without dedup, that means multiple identical MediaConvert jobs
# — double (or triple) billing and duplicate output files.
#
# Before submitting a job, Lambda does a conditional DynamoDB put on
# {key}#{etag}. If another invocation already claimed that pair, the put fails
# the condition and the record is skipped. Items expire automatically via TTL.

resource "aws_dynamodb_table" "dedup" {
  name         = "${var.lambda_function_name}-dedup"
  billing_mode = "PAY_PER_REQUEST"  # On-demand — no capacity planning, minimal cost at low volume
  hash_key     = "dedup_key"

  attribute {
    name = "dedup_key"
    type = "S"
  }

  # DynamoDB TTL — items are deleted automatically after expires_at (set by Lambda).
  # This keeps the table small without any maintenance Lambda or scheduled job.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # PITR not needed — the table is ephemeral by design (all data expires via TTL).
  # Losing it just means the first re-delivery after recovery creates a fresh job,
  # which is correct behaviour.
  point_in_time_recovery { enabled = false }

  tags = {
    Purpose = "Lambda job deduplication"
  }
}

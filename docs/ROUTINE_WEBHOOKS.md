# Routine webhooks

Authenticated `POST /api/routines/:routine_id/triggers` requests create
webhook triggers in replay-safe `hmac_sha256` mode by default. The response
returns the signing secret once together with its authentication contract.
Store that value in the sender's secret manager.

For every delivery:

1. Set `x-cympho-timestamp` to the current Unix timestamp in seconds.
2. Compute `HMAC-SHA256(secret, timestamp + "." + raw_request_body)`.
3. Send the lowercase hex digest as
   `x-cympho-signature: sha256=<digest>`.

Cympho compares signatures in constant time, rejects timestamps outside the
trigger's `replay_window_seconds` (300 seconds by default), and durably rejects
an identical signed delivery with HTTP 409. The accepted raw body is limited to
`:cympho, :routine_webhook_max_body_bytes` (1 MB by default) before JSON
decoding. Timestamps up to the window in the future are accepted to tolerate
clock skew; anything farther in either direction is rejected. The signature
scheme name and 64-character hex digest are lowercase and exact.

Triggers created before signed webhooks remain in explicit `legacy_bearer`
mode. They continue accepting `x-webhook-secret` (and the deprecated JSON
`secret` field) without a silent compatibility break, but do not have replay
protection. API clients may request `legacy_bearer` explicitly while migrating;
new integrations should keep the HMAC default.

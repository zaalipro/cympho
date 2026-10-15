# Scheduled Routines & Inbound Webhooks

Cympho routines allow companies to automate recurring tasks, trigger scheduled agent sweeps, and execute autonomous workflows in response to external events (such as CI/CD completions, monitoring alerts, or third-party webhooks).

---

## 1. Routine Concepts & Lifecycle

A **Routine** (`Cympho.Routines.Routine`) is a company-scoped blueprint for recurring or event-driven execution. Each routine specifies:
- **Title & Description**: Plain-language objectives for the autonomous run.
- **Assigned Agent**: The company agent responsible for executing the routine.
- **Project**: The repository and workspace context where work takes place.
- **State**: `active`, `paused`, or `archived`.
- **Triggers**: One or more execution triggers (cron schedules or inbound webhooks).

When triggered, Cympho creates a routine-linked issue in `todo` status, dispatches the assigned agent, and tracks the execution run under the routine's run ledger.

---

## 2. Routine Creation

### 2.1 Via Web UI
1. Navigate to **Routines** in the main navigation (`/routines`).
2. Click **New Routine** (`/routines/new`).
3. Fill in the routine title, description, project, and assigned agent.
4. Add triggers: choose either **Schedule (Cron)** or **Inbound Webhook**.
5. Click **Save Routine**.

### 2.2 Via REST API
`POST /api/routines`
```bash
curl -fsS -X POST http://localhost:4329/api/routines \
  -H "Authorization: Bearer $USER_JWT" \
  -H "Content-Type: application/json" \
  -d '{
    "routine": {
      "title": "Nightly Security Audit",
      "description": "Scan dependencies for CVEs and review open security alerts.",
      "project_id": "3c983c21-f81d-4008-8e6f-fb94e1d1f054",
      "assigned_agent_id": "c1f7a61d-3bb3-4c90-93dc-8a716c5222ef"
    }
  }'
```

---

## 3. Quantum Cron Scheduling

Cympho uses [Quantum](https://github.com/quantum-elixir/quantum-core) for in-memory, distributed cron scheduling.

### 3.1 Cron Expression Format
Expressions follow the standard 5-field cron format:
```text
┌───────────── minute (0 - 59)
│ ┌───────────── hour (0 - 23)
│ │ ┌───────────── day of the month (1 - 31)
│ │ │ ┌───────────── month (1 - 12)
│ │ │ │ ┌───────────── day of the week (0 - 6) (Sunday to Saturday)
│ │ │ │ │
* * * * *
```

### 3.2 Common Schedule Expressions
| Schedule | Expression | Description |
|---|---|---|
| Hourly | `0 * * * *` | Runs at minute 0 of every hour |
| Every 15 minutes | `*/15 * * * *` | Runs every 15 minutes |
| Daily at Midnight | `0 0 * * *` | Runs every night at 00:00 UTC |
| Weekdays at 9am | `0 9 * * 1-5` | Runs Monday through Friday at 09:00 UTC |
| Weekly on Sunday | `0 0 * * 0` | Runs every Sunday at 00:00 UTC |
| Monthly | `0 0 1 * *` | Runs at midnight on the first day of each month |

### 3.3 Adding a Schedule Trigger via API
`POST /api/routines/:routine_id/triggers`
```json
{
  "type": "schedule",
  "cron_expression": "0 2 * * *",
  "enabled": true
}
```

---

## 4. Inbound Webhook Triggers

Webhook triggers enable external systems to fire Cympho routines on demand.

### 4.1 Creating a Webhook Trigger
`POST /api/routines/:routine_id/triggers`
```json
{
  "type": "webhook",
  "signing_mode": "hmac_sha256",
  "replay_window_seconds": 300,
  "enabled": true
}
```

#### Response (Secret Returned Once)
```json
{
  "data": {
    "id": "7ac23b81-99ee-4712-ba22-811c7ff09902",
    "public_id": "trig_sec_8a72be019",
    "type": "webhook",
    "signing_mode": "hmac_sha256",
    "replay_window_seconds": 300,
    "enabled": true,
    "routine_id": "97ac8801-b3b3-467b-99f2-ff6b42b78119"
  },
  "secret": "whsec_9bf281ca820e1948ba0281...",
  "authentication": {
    "mode": "hmac_sha256",
    "timestamp_header": "x-cympho-timestamp",
    "signature_header": "x-cympho-signature",
    "signature_format": "sha256=HMAC_SHA256(secret, timestamp + '.' + raw_body)",
    "replay_window_seconds": 300,
    "secret_returned_once": true
  }
}
```
> **Security Notice**: The signing secret is displayed **only once** upon creation. Store it in your external system's secret manager immediately.

---

## 5. Webhook Firing & HMAC Authentication Contract

### 5.1 Firing Endpoint
`POST /api/routine-triggers/:public_id/fire`
- **Authentication**: Secret-verified (no User JWT or Agent API key required in the URL or Authorization header).
- **Public ID**: Included directly in the path (`:public_id`).

### 5.2 HMAC-SHA256 Delivery Specifications
For every inbound delivery in `hmac_sha256` mode:
1. Capture the raw request body string before JSON parsing.
2. Set the `x-cympho-timestamp` header to the current Unix timestamp in seconds (integer).
3. Compute the HMAC:
   ```text
   HMAC-SHA256(secret, timestamp + "." + raw_body)
   ```
4. Send the lowercase 64-character hex digest in the header:
   ```http
   x-cympho-signature: sha256=<lowercase_hex_digest>
   ```

### 5.3 Verification & Safety Rules
- **Constant-Time Comparison**: Signatures are compared using constant-time byte equality (`Plug.Crypto.secure_compare/2`) to prevent timing attacks.
- **Replay Protection**: Timestamps outside the trigger's `replay_window_seconds` (default: 300 seconds) are rejected with HTTP 401. Identical signed deliveries within the window are tracked and rejected with **HTTP 409 Conflict** (`"webhook replay detected"`).
- **Clock Skew**: Timestamps up to `replay_window_seconds` into the future are tolerated for clock drift; anything beyond is rejected.
- **Payload Size Limits**: The raw request body is capped at `:routine_webhook_max_body_bytes` (default: **1 MB**) before JSON decoding.
- **Overlap Prevention**: If an execution run is already actively running for the routine, the trigger skips execution and returns **HTTP 409 Conflict** (`"run skipped — a run is already active for this routine"`).

---

## 6. Secret Rotation

If a webhook secret is compromised or routine security policies require scheduled credential rotation:

`POST /api/routine-triggers/:id/rotate-secret`
```bash
curl -fsS -X POST http://localhost:4329/api/routine-triggers/$TRIGGER_UUID/rotate-secret \
  -H "Authorization: Bearer $USER_JWT"
```

#### Response
```json
{
  "message": "secret rotated",
  "secret": "whsec_new_77bc129810af..."
}
```
The previous secret is invalidated immediately. Update external senders with the newly issued secret.

---

## 7. Client Code Examples

### 7.1 Python Example
```python
import hmac
import hashlib
import time
import requests

PUBLIC_ID = "trig_sec_8a72be019"
SECRET = "whsec_9bf281ca820e1948ba0281..."
URL = f"http://localhost:4329/api/routine-triggers/{PUBLIC_ID}/fire"

payload = '{"event": "alert", "severity": "high"}'
timestamp = str(int(time.time()))
message = f"{timestamp}.{payload}".encode("utf-8")
signature = hmac.new(SECRET.encode("utf-8"), message, hashlib.sha256).hexdigest()

headers = {
    "Content-Type": "application/json",
    "x-cympho-timestamp": timestamp,
    "x-cympho-signature": f"sha256={signature}",
}

response = requests.post(URL, data=payload, headers=headers)
print(response.status_code, response.json())
```

### 7.2 Node.js Example
```javascript
const crypto = require("crypto");

const publicId = "trig_sec_8a72be019";
const secret = "whsec_9bf281ca820e1948ba0281...";
const url = `http://localhost:4329/api/routine-triggers/${publicId}/fire`;

const payload = JSON.stringify({ event: "ci_completed", branch: "main" });
const timestamp = Math.floor(Date.now() / 1000).toString();

const hmac = crypto.createHmac("sha256", secret);
hmac.update(`${timestamp}.${payload}`);
const signature = `sha256=${hmac.digest("hex")}`;

fetch(url, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "x-cympho-timestamp": timestamp,
    "x-cympho-signature": signature
  },
  body: payload
})
.then(res => res.json())
.then(data => console.log(data));
```

### 7.3 Bash / cURL Example
```bash
PUBLIC_ID="trig_sec_8a72be019"
SECRET="whsec_9bf281ca820e1948ba0281..."
PAYLOAD='{"service":"payments","status":"degraded"}'
TIMESTAMP=$(date +%s)

SIGNATURE=$(printf "%s.%s" "$TIMESTAMP" "$PAYLOAD" | \
  openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')

curl -fsS -X POST "http://localhost:4329/api/routine-triggers/$PUBLIC_ID/fire" \
  -H "Content-Type: application/json" \
  -H "x-cympho-timestamp: $TIMESTAMP" \
  -H "x-cympho-signature: sha256=$SIGNATURE" \
  -d "$PAYLOAD"
```

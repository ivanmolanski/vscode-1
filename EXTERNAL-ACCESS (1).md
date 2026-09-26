# HyperAI Qwen3.8 — External Access Guide

**Status: 2026-09-17. Server is RUNNING and left as-is.**

Current live state:

| item | value |
|---|---|
| HyperAI container | `74o0engsl6l7` (RTX 5090, 32 GB) |
| llama-server bind | `0.0.0.0:8080` |
| VRAM in use | 31.0 / 32.6 GB |
| Context | 131072 (largest that fits 32 GB with Q6_K_P + q8_0 KV) |
| Model | `qwen3.8-27b-q6kp-fastmtp` |
| Auth | API key required on `/v1/chat/completions` |

---

## 1. The JSON that works TODAY (loopback / SSH tunnel)

External machines **cannot** use a direct URL yet (see §3). They must reach the
model through an SSH tunnel that exposes it on their own `127.0.0.1`.

Paste this into `chatLanguageModels.json` on any machine that has the tunnel up:

```json
{
  "name": "HyperAI Qwen3.8 (local)",
  "vendor": "customendpoint",
  "apiKey": "emT7P4QC-iqaVpYGWKyTlmW9l1gY6DWFPiWgl-cZmaM",
  "apiType": "chat-completions",
  "models": [
    {
      "id": "qwen3.8-27b-q6kp-fastmtp",
      "name": "Qwen3.8-27B Q6_K_P + FastMTP (HyperAI local)",
      "url": "http://127.0.0.1:18080/v1/chat/completions",
      "toolCalling": true,
      "vision": false,
      "maxInputTokens": 131072,
      "maxOutputTokens": 32768,
      "supportsReasoningEffort": ["low", "medium", "xhigh"],
      "defaultReasoningEffort": "medium",
      "reasoningEffortFormat": "chat-completions",
      "modelOptions": {
        "temperature": 1.0,
        "top_p": 0.95,
        "top_k": 20,
        "min_p": 0.0,
        "presence_penalty": 0.0,
        "repetition_penalty": 1.0
      },
      "requestHeaders": {
        "Authorization": "Bearer ${apiKey}"
      }
    }
  ]
}
```

### Bringing up the tunnel on a new machine

```bash
ssh -i <key> -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -L 18080:127.0.0.1:8080 -p <HYPERAI_SSH_PORT> -N root@ssh.hyper.ai
```

Then verify:

```bash
curl -s http://127.0.0.1:18080/health          # -> {"status":"ok"}
```

> ⚠️ **The SSH port changes every time the HyperAI container is recreated**
> (including after the 30-minute idle auto-shutdown). Read the current port from
> the HyperAI console, or use the discovery script — see §4.

---

## 2. The direct-URL JSON — DOES NOT WORK YET

This is the variant for machines that should connect straight to HyperAI with
no tunnel and no VPS proxy. **It is staged but non-functional** because no port
mapping exists on the container yet (both candidate URLs return 404).

```json
{
  "name": "HyperAI Qwen3.8 (direct)",
  "vendor": "customendpoint",
  "apiKey": "<HYPERAI_API_KEY>",
  "apiType": "chat-completions",
  "models": [
    {
      "id": "qwen3.8-27b-q6kp-fastmtp",
      "name": "Qwen3.8-27B Q6_K_P + FastMTP (HyperAI direct)",
      "url": "https://wa0xhxcwtn80-llama.gear.hyperai.host/v1/chat/completions",
      "toolCalling": true,
      "vision": false,
      "maxInputTokens": 131072,
      "maxOutputTokens": 32768,
      "supportsReasoningEffort": ["low", "medium", "xhigh"],
      "defaultReasoningEffort": "medium",
      "reasoningEffortFormat": "chat-completions",
      "modelOptions": {
        "temperature": 1.0,
        "top_p": 0.95,
        "top_k": 20,
        "min_p": 0.0,
        "presence_penalty": 0.0,
        "repetition_penalty": 1.0
      },
      "requestHeaders": {
        "Authorization": "Bearer ${apiKey}"
      }
    }
  ]
}
```

### Why it fails

- The container has **no port mapping** (`parameters` is `{}`).
- Verified 404 on both:
  - `https://wa0xhxcwtn80-llama.gear.hyperai.host/v1/models`
  - `https://wa0xhxcwtn80-74o0engsl6l7-8080.gear.hyperai.host/v1/models`

---

## 3. What must be done to make the direct URL work

Port mapping is **create-time only** — the docs describe it solely under
"Setting During Gear Container Creation", and there is no API field for it
(scanned the job document for `port_mapping` / `ports` / `expose` / `endpoint` /
`subdomain` — all absent). `PATCH` to the job API returns **405 Method Not
Allowed**.

There is also a hard constraint: **`EXCEED_JOB_COUNT_LIMITATION`** — you may
only have **one** `rtx-5090` container at a time. The old one must be gone
before the new one can be created.

### Procedure

| # | step | who | notes |
|---|---|---|---|
| 1 | Create a snapshot of the current container | script/API | `POST /jobs/74o0engsl6l7/snapshots` → 204. Preserves the 33 GB working dir, so **no re-upload** |
| 2 | Stop / delete the current container | script/API | Frees the single rtx-5090 slot |
| 3 | Create a new container **from the snapshot** | **you (web UI)** | In the **Port Mapping** section add: name `llama`, port `8080` |
| 4 | Use the generated URL | automatic | `https://wa0xhxcwtn80-llama.gear.hyperai.host` |

`llama-server` already binds `0.0.0.0:8080`, so it serves immediately once the
mapping exists — no config change needed.

**Reserved ports that cannot be mapped:** 22, 5901, 6006, 6637, 7088, 8888
(8080 is fine). Max 5 mappings per container.

> ⚠️ Once public, the API key is the only protection. `/v1/models` and
> `/health` remain unauthenticated by design in llama.cpp (they expose only the
> model name and context size).

---

## 4. Making it work through the Oracle VPS (as it does today)

On the Kali/Railway box the model is reached at `127.0.0.1:18080` and **all
other** egress rides the VPS. That works because of two things:

1. **The SSH tunnel is a direct connection, not proxied.**
   The tunnel command has no `ProxyCommand` / `ProxyJump`, and the route is
   `107.150.120.129 via 10.128.0.1 dev railnet0` — straight out, not via the VPS.
   Only the *outbound SSH to HyperAI* would be a proxy candidate, and it isn't.

2. **gost's forwarder bypass already includes loopback.**
   ```
   gost -L http://127.0.0.1:3128 -F socks5://127.0.0.1:1080?bypass=127.0.0.1,localhost,::1,10.0.0.0/8,...
   ```
   So `127.0.0.1:18080` is dialled directly while everything else egresses via
   the VPS. **No bypass change is needed for the loopback URL.**

### To replicate on another machine behind the VPS

1. Start the SSH tunnel (§1) so `127.0.0.1:18080` is live.
2. Ensure the VPS SOCKS5 tunnel is up (`127.0.0.1:1080`) and gost is running
   (`127.0.0.1:3128`) with `127.0.0.1` in the `-F` bypass list.
3. Use the **loopback JSON** from §1.

Result: LLM traffic goes to loopback (fast, direct); all other traffic egresses
through the VPS as usual.

### If you ever want the outbound SSH itself to ride the VPS

Add a `ProxyCommand` to the tunnel:

```bash
ssh -i <key> -o ProxyCommand="nc -X 5 -x 127.0.0.1:1080 %h %p" \
    -L 18080:127.0.0.1:8080 -p <PORT> -N root@ssh.hyper.ai
```

Not required today — the current setup already behaves correctly.

---

## 5. Keeping the SSH port current

The port is re-randomized on every container create. Two discovery scripts
exist:

| script | runs where | how |
|---|---|---|
| `hyperai/find_ssh_port.py` | inside HyperAI container | reads the job API (the job doc embeds `ssh root@ssh.hyper.ai -pNNNNN`) |
| `hyperai/find_hyperai_ssh_port.py` | on Kali / external | env var → cached state file → scan ports 30000–33000 |

`start-services.sh` calls `discover_hyperai_ssh_port()` at boot, so the tunnel
rebuilds itself after a restart — **no manual port update needed** on Kali.

---

## 6. Reasoning effort — which to use

The HF card says Qwen3.8 supports `xhigh`, `medium`, `low`. **Only those three
work** — verified against the live server:

| value | result |
|---|---|
| `xhigh` | ✅ accepted |
| `medium` | ✅ accepted |
| `low` | ✅ accepted |
| `high` | ❌ HTTP 500 (jinja chat-template error) |
| `none` | ❌ HTTP 500 |
| `minimal` | ❌ HTTP 500 |

### ⚠️ `xhigh` never produces an answer

It consumes the **entire** token budget on `reasoning_content` and returns
empty `content`:

| max_tokens | reasoning | content |
|---|---|---|
| 700 | 3,185 ch | **0 ch** |
| 1,500 | 6,370 ch | **0 ch** |
| 3,000 | 12,950 ch | **0 ch** |

Reproduced on both a coding task and a security task. `xhigh` is effectively
unbounded thinking — it will not stop until the budget is gone.

### Measured comparison

Coding task (`max_tokens=700`):

| level | reasoning | content |
|---|---|---|
| xhigh | 2,987 ch | **0 ch** |
| medium | 2,482 ch | 552 ch |
| low | 1,236 ch | 1,683 ch |

Security/recon task (`max_tokens=2000`):

| level | reasoning | content | finished |
|---|---|---|---|
| xhigh | 8,388 ch | **0 ch** | no |
| medium | 4,088 ch | 3,919 ch | no |
| low | 1,390 ch | 5,232 ch | **yes** |

### Recommendation

| workload | level | why |
|---|---|---|
| Long coding / autocoder | **`medium`** | reasons deeply **and** still emits code |
| Kali recon / enumeration | `low` | fastest, actually completes |
| `xhigh` | avoid for agents | never returns an answer |

`medium` is the only level that both reasons substantially and reliably
produces output — which is why it is the default in the JSON above.

> The server CLI passes `--reasoning-effort xhigh` (per the HF card), but a
> per-request `chat_template_kwargs.reasoning_effort` **overrides** it. Set the
> level per-request or in the client config; don't change the server flag.

### Turning thinking off entirely

```json
"chat_template_kwargs": {"enable_thinking": false}
```

HF non-thinking mode also specifies `presence_penalty=1.5` (vs `0.0` for
thinking mode). Both values are accepted by this server and do change output.

---

## 7. Config values vs the official HuggingFace card

All sampler values match the card's thinking-mode defaults exactly:

| HF card | this config |
|---|---|
| `temperature=1.0` | 1.0 ✅ |
| `top_p=0.95` | 0.95 ✅ |
| `top_k=20` | 20 ✅ |
| `min_p=0.0` | 0.0 ✅ |
| `presence_penalty=0.0` | 0.0 ✅ |
| `repetition_penalty=1.0` | 1.0 ✅ |
| `reasoning_effort=xhigh` | xhigh ✅ |

**Only deviation: context 131072 vs the card's 204800.** That is the measured
ceiling on a 32 GB RTX 5090 — 204800 and 163840 both OOM on the compute buffer,
and reducing `--ubatch-size` does not rescue it (the buffer has an ~800 MiB
fixed floor). The card's own guidance is to reduce context before model quality,
which is what was done. The card's reference numbers were measured on a 96 GB
RTX PRO 6000, not a 32 GB card.

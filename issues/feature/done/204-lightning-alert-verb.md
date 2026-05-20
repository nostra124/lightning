---
id: FEAT-204
type: feature
priority: medium
status: open
---

# `lightning alert <create|list|remove>` — threshold-driven webhooks

## Description

**As a** node operator (personal or routing)
**I want** `lightning alert` to fire webhooks (Slack / Discord /
Telegram / email / generic HTTP) when defined thresholds trip,
driven by a background runner
**So that** I notice a depleted channel, an offline peer, or a
stalled sync before my counterparties do.

Highest-leverage routing-node verb of the three named in
FEAT-203: small operational change, large UX improvement,
useful at any scale (a personal-node operator wants to know
when their channel went offline just as much).

## Implementation

### Surface

```
lightning alert create <name> --on <condition>
                              --webhook <url>
                              [--threshold <value>]
                              [--cooldown <duration>]
lightning alert list
lightning alert remove <name>
lightning alert test <name>
lightning alert run [--once]
```

`create` records the rule under
`$LIGHTNING_DIR/alerts/<name>.conf` (recfile). `run` is the
background scheduler that evaluates rules and fires webhooks.
Designed to be invoked from cron / launchd / systemd timer
(same sidecar pattern as `peer keepalive` from FEAT-199).

### Conditions

Each condition compiles to a JQ expression evaluated against a
known data source. Source picks the right `lightning-cli` call.

| Condition                  | Source            | Default threshold |
|----------------------------|-------------------|-------------------|
| `peer_offline`             | listpeers         | 1h                |
| `channel_ratio_outside`    | listpeerchannels  | [10%, 90%]        |
| `channel_offline`          | listpeerchannels  | 5min              |
| `failed_forwards`          | listforwards      | 5 in 1h           |
| `sync_lag`                 | getinfo           | 6h                |
| `daemon_down`              | local probe       | n/a               |
| `balance_below`            | wallet balance    | absolute sat      |
| `low_inbound_capacity`     | liquidity totals  | absolute sat      |

Conditions extensible — adding one means a new entry in a
`alert_conditions.sh` lookup + a JQ expression.

### Webhook integrations

Each is a thin POST wrapper:

| `--webhook` URL prefix     | Behavior                              |
|----------------------------|---------------------------------------|
| `https://hooks.slack.com/` | Slack Incoming Webhook payload        |
| `https://discord.com/api/` | Discord Webhook payload               |
| `https://api.telegram.org/`| Telegram bot sendMessage               |
| `mailto:<addr>`            | shells out to `mail(1)` / `sendmail`  |
| `https://...` (other)      | generic POST: `{"alert": "...", ...}` |

The recfile format for a rule:

```
name:        my-channel-online
on:          channel_offline
threshold:   5m
webhook:     https://hooks.slack.com/services/...
cooldown:    1h
last_fired:  2026-05-19T14:30:00Z
```

### Cooldown

`--cooldown` prevents alert spam — once a rule fires, it
won't fire again for the cooldown duration even if the
condition persists. State persisted in the recfile.

### Test

`alert test <name>` evaluates the rule once, prints the
result, and (if it would fire) sends a `[TEST]` webhook so
operators can verify the integration without waiting for a
real condition.

### Sidecar scheduling

`daemon install` wires `alert run` to a timer:
- macOS: extra LaunchAgent (sibling to keepalive from
  FEAT-199), StartInterval=60 (every minute).
- Linux: `lightning-alert.timer` + `.service`.

Per-rule conditions evaluate at ~1min granularity, which is
fine for the threshold types we support (minutes-to-hours).

## Acceptance Criteria

1. `alert create <name> --on peer_offline --webhook <url>`
   writes a recfile at `$LIGHTNING_DIR/alerts/<name>.conf`.
2. `alert list` returns one recfile record per rule (multi-
   record output) with current state (last fired, cooldown
   remaining).
3. `alert remove <name>` deletes the rule + cooldown state.
4. `alert run --once` evaluates all rules synchronously and
   exits; multiple firings batched into one webhook per
   destination.
5. `alert test <name>` fires the webhook with a `[TEST]`
   prefix and prints the would-have-been firing condition.
6. `daemon install` writes the alert sidecar (launchd +
   systemd).
7. Bats coverage with stubbed webhook curls + stubbed
   lightning-cli responses.

## Out of scope

- A web UI for rule management — recfile + verb is enough.
- Complex rule composition (AND / OR / nested) — keep it
  one condition per rule; users compose by creating multiple
  rules with the same webhook.
- Acknowledgement / silence semantics — operators can
  `alert remove` and re-create later.

## Milestone

0.7.0 — same as FEAT-200/201, since this is the operational
floor a serious node needs.

## See also

- FEAT-199 (peer keepalive — same sidecar scheduling pattern)
- FEAT-203 (routing-node guide — references this for the
  monitoring tier)
- FEAT-205 (autopilot — could use alert conditions to drive
  automated actions later, post-1.0)

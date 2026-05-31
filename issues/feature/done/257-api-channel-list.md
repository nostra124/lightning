---
id: FEAT-257
type: feature
priority: medium
status: research
---

# api-channel-list verb + GET /v1/channels endpoint

## Description

Operators want a quick channel overview: peer alias, capacity,
local/remote balance, state.  `lightning-cli listpeerchannels` has this;
a thin verb plus a public-ish CGI endpoint surfaces it.

## Scope

* `api-channel-list` (new verb) — calls `lightning-cli listpeerchannels`;
  returns `[{peer_id, alias, channel_id, capacity_sat, local_sat,
  remote_sat, state}]`.
* `channels.py` CGI — `GET /.well-known/lightning/v1/channels`.
  Bearer-required (any valid account key is enough — proves the caller
  is a wallet user on this node).
* `lnurlp.conf` — ScriptAlias.
* `sudoers.d/lightning` — verb entry.
* `llms.txt` — document the endpoint.
* `app.js` — "Channels" link in the Node info screen.
* bats tests.

## Acceptance criteria

1. `lightning api-channel-list` returns JSON array.
2. `GET /v1/channels` with bearer returns channel list.
3. Node info screen has a Channels link.

## Milestone

alpha polish (follows FEAT-256).

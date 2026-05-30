---
id: FEAT-252
type: feature
priority: medium
status: research
---

# Node info verb + PWA node screen

## Description

Operators need a quick summary of the node's state: pubkey, alias,
channel count, and total local capacity.  The `lightning-cli getinfo`
command surfaces this.

## Scope

* `api-node-info` (new verb) — calls `lightning-cli getinfo`, returns
  `{pubkey, alias, num_channels, local_msat}` subset.
* `accounts.py` equivalent — `node.py` CGI for the path
  `GET /.well-known/lightning/v1/node`.  No auth required (pubkey is
  public); returns the info JSON.
* `app.js` — add "Node" link in the account view header; `screenNode`
  screen showing the four fields.
* `sudoers.d/lightning` — allow `www-data` to run `api-node-info`.
* `llms.txt` — document the endpoint.
* bats tests.

## Acceptance criteria

1. `GET /.well-known/lightning/v1/node` returns `{pubkey, alias,
   num_channels, local_msat}`.
2. PWA account view has a "Node" button/link.
3. Node screen renders the four fields.

## Milestone

alpha polish (follows FEAT-251).

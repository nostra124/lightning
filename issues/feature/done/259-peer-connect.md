---
id: FEAT-259
type: feature
priority: medium
status: research
---

# peer-connect / peer-disconnect verbs

## Description

Routing node operators need to manage peer connections from the CLI:
connect to a new peer to open a channel, or disconnect a defunct one.

## Scope

* `peer-connect` (new verb) — `lightning peer-connect <pubkey>@<host>[:<port>]`;
  calls `lightning-cli connect`; returns `{peer_id, connected}`.
* `peer-disconnect` (new verb) — `lightning peer-disconnect <pubkey>`;
  calls `lightning-cli disconnect`; returns `{ok:true}`.
* `peer-list` (new verb) — lists connected peers from `listpeers`;
  returns `[{peer_id, connected, num_channels}]`.
* Man page update.
* bats tests.

## Acceptance criteria

1. `lightning peer-connect <addr>` connects and returns peer_id.
2. `lightning peer-disconnect <pubkey>` disconnects.
3. `lightning peer-list` returns connected peers.

## Milestone

alpha polish (follows FEAT-258).

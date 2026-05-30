---
id: FEAT-260
type: feature
priority: medium
status: done
---

# channel-open / channel-close verbs

## Description

Routing node operators need to manage channels from the CLI.
`channel-open <pubkey> <sat>` wraps `lightning-cli fundchannel`;
`channel-close <channel_id>` wraps `lightning-cli close`.

## Milestone

alpha polish (follows FEAT-259).

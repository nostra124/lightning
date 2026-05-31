---
name: lightning-operator
description: Install and operate the clightning daemon and manage a Lightning routing node
long_description: Install and operate the clightning (Core Lightning) daemon and manage a Lightning routing node with lightning(1). Trigger when the user wants to install or configure lightningd, manage channels at routing scale, set fee policy, rebalance liquidity, score peers, set up alerts, monitor forwarding revenue, or configure the three-user system-mode separation (clightning daemon account, operator shell account, www-data CGI account).
role: [operator]
references: lightning-wallet
---

# lightning-operator

Operate the infrastructure layer of the `lightning(1)` package:
install and manage the `lightningd` daemon, configure the node for
personal-wallet or small-to-medium routing use, and tune fee policy,
rebalancing, and peer scoring.

## When to use

Trigger when the user says any of:

- "Install clightning / lightningd", "set up a Lightning node".
- "Start / stop / restart the daemon".
- "Configure the node for routing", "set up fee policy".
- "Rebalance my channels", "I have too much outbound on one side".
- "Score my peers", "drop underperforming peers".
- "Set up alerts", "notify me when a channel goes offline".
- "Monitor forwarding revenue", "how much did I earn today?".
- "Configure the .well-known/lightning/ API", "set up Lightning Address hosting".
- "Three-user separation", "www-data can't talk to lightningd".
- "Enable Tor", "hide my node IP".
- "System-mode vs user-mode install".

## The two-layer model

`lightning daemon` manages the **process** (install, enable, start,
stop, monitor). `lightning fee` and `lightning rebalance` manage the
**routing policy** layer.

They are independent: the daemon can be running while routing is
passive (personal-wallet mode), and fee policy can be tuned without
restarting the daemon.

## System-mode install and three-user separation (FEAT-183)

System-mode installs run three separate OS accounts:

| Account | Runs | Owns |
|---|---|---|
| `clightning` | `lightningd` daemon | `/var/lib/clightning/` |
| operator (`alice`) | `lightning` verb scripts | wallet repo, secret store |
| `www-data` | Apache + CGI endpoints | web root only |

`www-data` never talks to `lightningd` directly. The bridge is
`sudo -u alice lightning <verb>` inside the CGI scripts. This means
`lightning-cli` is always called as the operator, never as the web
user.

## Workflow recipes

### Install and start the daemon

```sh
lightning daemon install --system        # creates clightning account, installs service
lightning daemon start                   # starts lightningd via systemd
lightning daemon monitor                 # tail the log; wait for "lightningd ready"
lightning unlock                         # interactive passphrase on first start
lightning info                           # confirm node ID, block height, alias
```

### User-mode install (laptop / personal node)

```sh
lightning daemon install                 # user-level service
lightning daemon enable                  # register with launchd / systemd --user
lightning daemon start
```

### Configure basic node settings

```sh
lightning node-config alias "MyNode"
lightning node-config color "FF6600"
lightning node-config fee-base 1000      # msat base fee
lightning node-config fee-ppm 500        # parts-per-million proportional fee
```

### Channel management (routing node)

```sh
lightning peer connect <uri>
lightning channel open <peer-id> 5000000 --push 2500000   # balanced open
lightning channels                       # list with balance, capacity, state
lightning channel close <channel-id>     # cooperative close
lightning channel close <channel-id> --force   # unilateral; costs to_self_delay
```

### Fee policy

```sh
lightning fee list                       # current policy per channel
lightning fee-policy set --base 0 --ppm 200            # global default
lightning fee-policy set <channel-id> --ppm 500        # per-channel override
```

### Rebalancing

```sh
lightning rebalance status              # identify imbalanced channels
lightning rebalance <out-channel> <in-channel> 1000000  # circular payment
```

Keep rebalancing costs below the expected routing revenue for the
balanced capacity — `forward` stats help here.

### Peer scoring and hygiene

```sh
lightning peer score                    # list peers ranked by forwarding performance
lightning peer score --detail <peer-id>
lightning peer disconnect <peer-id>     # drop a non-performing peer
```

### Monitoring forwarding revenue

```sh
lightning forward                       # recent forwards with fees earned
lightning forward --period 30d          # last 30 days
lightning node-health                   # uptime, channel states, balance distribution
```

### Alerts

```sh
lightning alert list                    # active alert rules
lightning alert add channel-offline --notify email:ops@example.com
lightning alert add low-balance --threshold 500000
```

### Enable Tor

```sh
lightning tor status                    # verify Tor connectivity
lightning tor enable                    # configure lightningd to announce .onion address
```

### Set up Lightning Address hosting (.well-known/lightning/)

```sh
lightning daemon install --system        # installs Apache CGI scripts (FEAT-196)
# Then configure Apache vhost to proxy /.well-known/lightning/ to the CGI
# See share/doc/lightning/guides/personal-node.md for the vhost template
```

## Guardrails

- **Never run `lightning-cli` as `www-data`.** The web user reaches
  the operator via `sudo -u <operator> lightning <verb>`; it never
  has direct socket access to `lightningd`.
- **`force-close` costs the `to_self_delay`** (~144 blocks on
  mainnet) and publishes channel state on-chain. Only use it when
  the peer is unresponsive and cooperative close has timed out.
- **Rebalancing fees come out of your own funds.** Always check that
  the circular-payment fee is less than the projected routing revenue
  from the rebalanced capacity before executing.
- **Fee changes take effect immediately.** A high-volume routing
  node may see payment failures during the gossip propagation window
  (~30 min). Change fees during low-traffic hours.
- **System-mode requires `sudo`.** Several `daemon` subcommands
  operate on the `clightning` account. Warn the user before running
  on shared machines.
- **Channel backups (SCB) are in the wallet repo.** Run `lightning
  backup` after every channel open or close. The SCB allows
  force-close recovery but cannot recover in-flight HTLCs.

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `lightning-cli: connection refused` | lightningd not running | `lightning daemon start` |
| `channel open` fails: "not enough funds" | Insufficient on-chain balance | Fund the clightning wallet: `lightning node-funds` |
| Rebalancing fails: "no route" | Channels too depleted on both sides | Find an intermediate peer; open a new channel |
| `www-data` CGI returns 500 | sudo-to-alice bridge misconfigured | Check `/etc/sudoers.d/lightning`; see FEAT-183 |
| Tor: node not reachable via .onion | Tor service not running | `systemctl status tor`; `lightning tor enable` |
| `forward` shows zero fees | Node has no routing channels yet | Open balanced channels to well-connected peers |

## Related skills

- [[lightning-wallet]] — user-facing payment operations (pay, invoice, accounts, liquidity).
- **rpk/bugs** — file and fix bugs the rpk way.
- **rpk/features** — design and ship new features.

## Where to read more

- `man lightning` — full CLI reference.
- `share/doc/lightning/guides/personal-node.md` — end-to-end personal node setup (FEAT-202).
- `share/doc/lightning/guides/routing-node.md` — routing node tuning guide (FEAT-203).
- `share/doc/lightning/standards/cln-overview.md` — 10-minute clightning tour.
- `CLAUDE.md` — package scope, three-user separation, no-shared-lib policy.

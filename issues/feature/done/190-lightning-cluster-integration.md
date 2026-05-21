---
id: FEAT-190
type: feature
priority: medium
status: obsolete
---

# Lightning cluster integration — OBSOLETE, replaced by FEAT-176 + FEAT-196

## Status

**Obsolete.** This ticket originally proposed a
`lightning serve` bash-HTTP server that an Apache instance in
the `nostra124/cluster` stack would `ProxyPass` to. The
cluster integration is no longer in scope: Lightning Address
hosting and the JSON API both run as Python CGI scripts under
Apache's `.well-known/` paths directly, with no extra HTTP
daemon in `lightning`.

See:

- **FEAT-176** — Apache-detected LNURL-pay handler at
  `/.well-known/lnurlp/<user>` (a small Python CGI script).
- **FEAT-196** — JSON API at `/.well-known/lightning/<user>/
  {invoice,send,balance}` (one Python script per endpoint,
  API-key authenticated).

Both ship in-tree under `share/lightning/wellknown/` and an
Apache vhost snippet; the cluster package isn't on the
critical path.

## Why this changed

The original FEAT-190 framing assumed Lightning would expose
its surface over HTTP via a long-running bash daemon, then
let the cluster package proxy it. A simpler shape emerged:
let Apache execute Python CGI directly, with the shell verbs
as the source of truth. That removes:

- the bash HTTP server (`socat` / `busybox httpd`)
- the systemd `--serve` flag on `lightning daemon install`
- the dependency on the cluster package's vhost generator
- the single "bearer token for everything" auth model
  (FEAT-196 has per-account, per-scope API keys)

No code was written against this ticket, so closure is a
documentation move; nothing needs ripping out.

## Action

No implementation required. Leave this ticket in place as a
forwarding pointer for anyone who finds the number in
historical commit messages.

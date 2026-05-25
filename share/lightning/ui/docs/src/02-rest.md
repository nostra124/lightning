# REST API (FEAT-212)

Base path: `/.well-known/lightning/v1`. All authenticated endpoints take
`Authorization: Bearer <api_key|session>`. JSON in, JSON out. Business-
rule failures (overdraft, cap, compliance) return `402`; auth failures
`401`; bad input `400`.

## Accounts

### POST /accounts
Anonymous, rate-limited. Body (optional): `{ "hint": "label",
"invite_code": "…" }`. Returns `{ account_id, api_key, topup_uri,
referrer, limit_sat, overdraft, endpoints }`.

```
curl -X POST https://HOST/.well-known/lightning/v1/accounts \
  -d '{"hint":"pocket"}'
```

### GET /accounts/<id>/balance
Returns `{ balance_sat, limit_sat, overdraft }`.

### GET /accounts/<id>/topup[?sat=N]
Returns a BIP-21 top-up `{ address, uri }` for on-chain deposits.

### POST /accounts/<id>/withdraw
Body `{ "sat": N, "address": "bc1…" }` — submarine-swap out.

### POST /accounts/<id>/pay
Body `{ "target": "lnbc…", "sat": N? }`. Returns
`{ payment_hash, amount_sat, fee_sat, operator_fee_sat, status }`.

### POST /accounts/<id>/recv
Body `{ "sat": N, "description": "…" }` → `{ bolt11, payment_hash }`.

### POST /accounts/<id>/recv-reusable
BOLT-12 offer; `sat` may be `"any"`.

### POST /accounts/<id>/transfer
Body `{ "to": "<id|name>", "sat": N, "note": "…" }` — intra-node move.

### GET /accounts/<id>/referrals
The accounts this one referred + accrued credit.

### POST /accounts/<id>/close
Revoke the key + mark the account closed.

## Commerce

### POST /accounts/<id>/invoice  (FEAT-225)
Commercial invoice with a structured `reference` + optional `terms`
(due date, Skonto, late fee). `GET /accounts/<id>/invoice/<hash>` looks
it up and recomputes the effective amount + paid status.

### standing-orders  (FEAT-226)
`GET/POST /accounts/<id>/standing-orders`, `POST .../<so_id>`
(pause/resume), `DELETE .../<so_id>` (cancel). Recurring push payment.

### mandates  (FEAT-227)
Direct debit. `GET/POST /accounts/<id>/mandates`, `PATCH/DELETE
.../<mid>`, `POST .../<mid>/charge` (merchant, mandate-secret authed),
`POST .../<mid>/pulls/<pid>/approve|deny`.

### charges  (FEAT-228)
Charge lifecycle. `GET/POST /accounts/<id>/charges`, `GET .../<cid>`,
`POST .../<cid>/<action>` where action ∈ hold, release, authorize,
capture, void, refund, installments, pay-installment, dun.

### GET /accounts/<id>/export/tax-data?year=YYYY&base=EUR&format=csv|json
FIFO-matched, fiat-valued transaction data for tax preparation
(FEAT-230). Source data, not a report; not advice.

## Price

### GET /price?base=EUR  (FEAT-229, public)
Latest sat/fiat tick. No auth.

# Certificates

**Nothing in this directory is committed** except this file — see `.gitignore`.
Private keys must never reach a public repository.

Generate locally on Mac 2:

```bash
./infra/mac2-edge/scripts/gen-certs.sh
```

Produces:

| File | Committed? | Purpose |
|---|---|---|
| `rootCA.pem` | no | Local CA. **Copy this to all four Macs** and run `make client-trust`. |
| `app.paradise.test.crt` | no | Leaf certificate nginx serves. |
| `app.paradise.test.key` | no | Private key. Never leaves Mac 2. |

## Why the SAN matters

The leaf certificate carries a Subject Alternative Name covering
`app.paradise.test`, `api.paradise.test`, `localhost` and the edge IP.

Modern curl and every browser ignore the Common Name completely. A CN-only
certificate fails with:

```
curl: (60) SSL: no alternative certificate subject name matches target host name
```

That error is the single most common reason teams give up and add `-k` — which
scores **zero** on the HTTPS section. `gen-certs.sh` refuses to finish if the
SAN does not cover the app domain.

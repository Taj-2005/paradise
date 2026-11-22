# infra/phase2/certs — standby edge certificate (Extension E)

The standby nginx serves the **same** certificate as Mac 2. Copy it here on the
standby Mac (Mac 4 by default) before `make p2-standby-edge`. On Mac 2:

```bash
scp infra/mac2-edge/certs/app.paradise.test.crt \
    infra/mac2-edge/certs/app.paradise.test.key \
    infra/mac2-edge/certs/rootCA.pem \
    <user>@<mac4>:<repo>/infra/phase2/certs/
```

There's no new CA and no re-trusting. Clients connect by name, the SAN covers
`app.paradise.test` / `api.paradise.test`, and the root CA is already trusted on
every Mac from Phase 1.

Everything in this folder except this README is gitignored. **The private key
must never be committed.**

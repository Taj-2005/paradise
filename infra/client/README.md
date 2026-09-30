# Client configuration

Run these on **every** Mac that will make requests — in practice all four,
since Mac 1 and Mac 4 double as test clients (spec §4).

| Script | What it does | When |
|---|---|---|
| `set-dns.sh` | Points this Mac's resolver at Mac 1 | After DNS is up |
| `trust-ca.sh` | Installs the team root CA into the System keychain | After certs exist |
| `reset-dns.sh` | Restores the previous DNS setting | Cleanup / failure demo |

```bash
make client-dns
make client-trust
```

## Order matters

1. Mac 1's dnsmasq must be running before `set-dns.sh`, or you will point this
   machine at a dead resolver and lose internet access too.
2. The certificate must exist on Mac 2 before `trust-ca.sh` can verify it.
   `trust-ca.sh` will still install the CA and tell you to re-run.

## Getting the CA onto the other machines

`gen-certs.sh` writes `rootCA.pem` on Mac 2. Copy it out:

```bash
# from Mac 2
scp infra/mac2-edge/certs/rootCA.pem <user>@<mac1-ip>:~/
scp infra/mac2-edge/certs/rootCA.pem <user>@<mac3-ip>:~/
scp infra/mac2-edge/certs/rootCA.pem <user>@<mac4-ip>:~/
```

Then `make client-trust` on each. `trust-ca.sh` looks in `~/` automatically.

**If you regenerate the certificate on Mac 2 you create a new CA** — every
machine must be re-trusted. Doing this the morning of the demo and forgetting
to redistribute is a classic way to end up reaching for `-k`.

# DNS query and response

**Wireshark display filter:** `dns`

Capture with: `./scripts/capture.sh dns`

> Vague descriptions score 0-1. Name specific IPs, ports, packet
> types, and say what each one proves.

```
Wireshark display filter: dns

The DNS response shows the DNS server at 10.7.27.161 responding to the client 10.7.26.203 over UDP port 53. The response is for an A record query for app.paradise.test and contains the answer app.paradise.test → 10.7.8.155 with a TTL of 4 seconds. This proves that the local DNS server successfully resolved app.paradise.test to 10.7.8.155. The subsequent curl request confirms the same resolution, showing “IPv4: 10.7.8.155” and successfully connecting to 10.7.8.155 on TCP port 443.
```

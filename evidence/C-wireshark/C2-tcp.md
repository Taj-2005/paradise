# TCP three-way handshake

**Wireshark display filter:** `tcp.flags.syn==1`

Capture with: `./scripts/capture.sh tcp`

> Vague descriptions score 0-1. Name specific IPs, ports, packet
> types, and say what each one proves.

```
The TCP three-way handshake was captured between the client 10.7.26.203 and the edge server 10.7.8.155 on TCP port 443. First, the client sends a SYN packet from its ephemeral port to 10.7.8.155:443, requesting a TCP connection. The server then responds with a SYN-ACK packet from 10.7.8.155:443, acknowledging the client's SYN and sending its own SYN. Finally, the client sends an ACK back to 10.7.8.155:443, completing the three-way handshake. This proves that a reliable, connection-oriented TCP connection to the HTTPS service was successfully established before the TLS handshake and HTTP/2 data exchange. The subsequent curl output confirms the connection to 10.7.8.155:443 was successful.
```

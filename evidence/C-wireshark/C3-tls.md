# TLS handshake

**Wireshark display filter:** `tls`

Capture with: `./scripts/capture.sh tls`

> Vague descriptions score 0-1. Name specific IPs, ports, packet
> types, and say what each one proves.

```
Wireshark display filter: tls

The TLS handshake was captured between the client 10.7.26.203 and the Nginx edge server 10.7.8.155 on TCP port 443. After establishing the TCP connection, the client sends a TLS ClientHello offering supported TLS versions, cipher suites, and ALPN protocols (h2 and http/1.1). The server responds with ServerHello, selecting TLS 1.3 and the cipher suite TLS_CHACHA20_POLY1305_SHA256. The server also provides its certificate for app.paradise.test, issued by paradise Local Root CA. Certificate verification succeeds, confirming the server's identity. Both sides exchange Finished messages to complete the secure handshake.

The server selects HTTP/2 through ALPN. After the handshake, HTTP traffic is encrypted and appears as TLS Application Data in Wireshark. HTTP headers and response bodies cannot be read directly without the TLS session keys.

The curl output confirms a successful TLS 1.3 connection and an HTTP/2 200 response from https://app.paradise.test/api/status. The request was handled by Backend B (10.7.18.17:3002) through the Nginx edge server (10.7.8.155). This demonstrates successful TLS encryption, certificate verification, and secure HTTPS communication.
```

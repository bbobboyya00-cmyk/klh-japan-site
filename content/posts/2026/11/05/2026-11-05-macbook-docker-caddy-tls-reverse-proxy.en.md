---
title: "Automated TLS-Enabled Edge Server Configuration using MacBook and Docker Caddy"
slug: "macbook-docker-caddy-tls-reverse-proxy"
date: 2026-11-05T10:44:20+09:00
draft: false
image: ""
description: "Explains the public exposure procedure combining automated certificate issuance and port forwarding using a Caddy reverse proxy in a MacBook and Docker environment."
categories: ["DevOps Logistics"]
tags: ["caddy", "docker-compose", "reverse-proxy", "acme-tls", "port-forwarding", "dns-a-record"]
author: "K-Life Hack"
---

To safely expose local devices externally in an on-premises or edge environment, establishing domain name resolution, router packet routing, and an automated TLS certificate renewal mechanism is essential. Conventional dynamic VirtualHost configurations or certbot-based cron management methods suffer from a rapid increase in configuration complexity as node count grows, posing a risk of service disruptions due to certificate renewal failures.

This article explains an end-to-end architecture that establishes automated HTTPS encrypted communication by deploying Docker and a Caddy reverse proxy on a MacBook host, integrated with public DNS (such as Gabia) and port forwarding.

## Architecture Configuration and Traffic Flow

Requests to public domains are routed to the application layer inside the container in the following order:

```
[Client Browser]
       │
       ▼
[Public DNS Resolution] (Gabia A Record)
       │
       ▼
[Public WAN IP] (ISP Router / Gateway)
       │
       ▼
[Port Forwarding] (External 80/443 -&gt; MacBook LAN IP)
       │
       ▼
[MacBook Host OS] (Home Server)
       │
       ▼
[Caddy Reverse Proxy Container] (Port 80 / 443 / 443 UDP)
       │
       ▼
[Application Container] (Bridge Network: custom-proxy)
```

## 1. Network Infrastructure and Port Forwarding

The MacBook within the local network is assigned a private IPv4 address via DHCP. To allow external traffic to reach the MacBook, port forwarding must be configured on the ISP router (gateway).

### Checking Public WAN IP and Double NAT

Run the following command in the MacBook terminal to obtain the externally exposed public IPv4 address:

```bash
curl ifconfig.me
```

Log into the router management interface and verify that the displayed WAN IP address matches the output of `curl ifconfig.me`.

* <b>Double NAT Note</b>: If the router's WAN IP differs from the `ifconfig.me` result, a Double NAT topology exists where an upstream modem or router is present. In this scenario, external packets will not reach the MacBook unless port forwarding is also configured on the upstream gateway.

### Router Port Forwarding Rules

Add the following forwarding rules in the router management interface:

* <b>HTTP</b>: External Port `80` -&gt; MacBook Private IP / Internal Port `80`
* <b>HTTPS</b>: External Port `443` -&gt; MacBook Private IP / Internal Port `443`

#### Necessity of Opening Port 80

Even if the application exclusively uses HTTPS (443), port `80` must remain open. Caddy automatically retrieves TLS certificates from Let's Encrypt / ZeroSSL using the ACME (Automated Certificate Management Environment) protocol. This is required because the Certificate Authority accesses port `80` of the domain during the HTTP-01 challenge verification process.

## 2. DNS Record Configuration and Propagation Verification

Configure an A record pointing to the obtained public IPv4 address from the management console of your public DNS service (such as Gabia).

### DNS Records to Configure

* Host `@` / Type `A` / Value `[Public IPv4 Address]`
* Host `www` / Type `A` / Value `[Public IPv4 Address]`
* Host `*` / Type `A` / Value `[Public IPv4 Address]` (Wildcard for subdomains)

### Verification of DNS Propagation

Verify whether the configured records have propagated correctly using the `dig` utility:

```bash
# Query using the local default DNS
dig +short your-domain.com A

# Directly query Cloudflare's public DNS (1.1.1.1)
dig @1.1.1.1 your-domain.com A +short
```

If `NXDOMAIN` or `SERVFAIL` is returned, DNS record propagation is not complete. Wait until the response matches the router's public IP address.

## 3. Reverse Proxy Configuration with Docker and Caddy

While Nginx requires combining `certbot` or external timers for TLS certificate acquisition and auto-renewal, Caddy handles certificate requests, verification, and automated renewal natively as a single unit.

### Definition of `docker-compose.yml

```yaml
services:
  caddy:
    image: caddy:2
    container_name: caddy-server
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp" # For HTTP/3 (QUIC) support
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data/caddy:/data
      - ./data/config:/config
    networks:
      - custom-proxy

networks:
  custom-proxy:
    external: true
    name: custom-proxy
```

#### Infrastructure Configuration Notes

1. <b>External Network (`external: true`)</b>:
By manually pre-creating the `custom-proxy` network via CLI, backend containers spawned from other independent `docker-compose.yml` projects can also join the same proxy network.

   ```bash
   docker network create custom-proxy
   ```

2. <b>TLS Data Persistence (`./data/caddy`)</b>:
Obtained certificates, private keys, and ACME account information are saved in the `/data` volume. Deleting this directory forces new certificate issuance upon every container restart, creating a risk of hitting Let's Encrypt duplicate issuance Rate Limits and causing temporary service unavailability.

### `Caddyfile` Creation and Routing Configuration

Create a test `Caddyfile` to verify proxy operations:

```caddyfile
your-domain.com {
    respond "Home Server is running!" 200
}
```

Start the container:

```bash
docker-compose up -d
```

When forwarding to a backend application container in a production environment, configure the `reverse_proxy` directive as follows:

```caddyfile
your-domain.com {
    reverse_proxy my-app:3000
}
```

With this setup, HTTP/HTTPS access to `your-domain.com` is automatically proxied to port `3000` of the `my-app` container on the internal Docker network `custom-proxy`.

## Troubleshooting

### 1. Connection Failure due to Hairpin NAT (NAT Loopback)

<b>Symptom</b>: Access via the domain works normally from external networks (such as mobile cellular connections), but accessing `https://your-domain.com` from a device within the same LAN results in a timeout or connection error.

<b>Cause</b>: If a commercial router does not support Hairpin NAT (NAT Loopback), packets sent by clients inside the LAN to the router's own public IP cannot be looped back and forwarded internally, causing the packets to be dropped.

<b>Resolution and Countermeasures</b>:
* Always perform connection testing from an external network (mobile data communication or tethering).
* For access within the LAN, bypass this issue by implementing a split-DNS configuration where a local DNS server (such as Pi-hole) or hosts file resolves the domain name directly to the MacBook's private IP address.

### 2. System Operational Status and Verification Logs

The following are example output results for network socket status, Docker container status, DNS response, and HTTP response after system deployment:

```text
$ docker ps --format "table {{.Names}}	{{.Status}}	{{.Ports}}"
NAMES          STATUS          PORTS
caddy-server   Up 12 minutes   0.0.0.0:80-&gt;80/tcp, 0.0.0.0:443-&gt;443/tcp, 0.0.0.0:443-&gt;443/udp

$ ss -tulpn | grep -E ':(80|443)'
tcp   LISTEN 0      4096         0.0.0.0:80        0.0.0.0:*    users:(("docker-proxy",pid=14201,fd=4))
tcp   LISTEN 0      4096         0.0.0.0:443       0.0.0.0:*    users:(("docker-proxy",pid=14225,fd=4))
udp   UNCONN 0      0            0.0.0.0:443       0.0.0.0:*    users:(("docker-proxy",pid=14249,fd=4))

$ dig @1.1.1.1 your-domain.com A +short
203.0.113.42

$ curl -I https://your-domain.com
HTTP/2 200 
server: Caddy
content-type: text/plain; charset=utf-8
date: Thu, 05 Nov 2026 10:15:30 GMT
```

## Key Takeaways

* 💡 <b>Necessity of Port 80 in ACME Verification</b>: To achieve TLS automation, port forwarding for port `80` (used for the HTTP-01 challenge) is essential alongside port `443` for HTTPS communication.
* ⚠️ <b>Retention of Data Volumes</b>: To avoid Let's Encrypt rate limits, persistence of Caddy's `/data` directory is critically important.
* 🛠️ <b>Network Isolation Design</b>: Utilizing Docker external networks (`external: true`) enables secure and flexible communication between Caddy and multiple independent service containers.
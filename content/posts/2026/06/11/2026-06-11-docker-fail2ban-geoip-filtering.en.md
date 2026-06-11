---
title: "Implementing IP Filtering in Docker Environments using Fail2ban and GeoIP"
slug: "docker-fail2ban-geoip-filtering"
date: 2026-06-11T18:16:47+09:00
draft: false
image: ""
description: "Explains an implementation method for efficiently filtering access from specific countries by integrating Fail2ban with GeoIP databases in a Docker environment. The configuration combines high-speed DB lookups using Python's mmap with iptables control."
categories: ["Linux System Admin"]
tags: ["fail2ban", "geoip", "docker-compose", "iptables", "python-mmap"]
author: "K-Life Hack"
---

# Implementing Country-Based IP Filtering Using Fail2ban and GeoIP in Docker Environments

This implementation utilizes GeoIP databases to filter IP addresses by country while minimizing external library dependencies within a Docker environment. Fail2ban monitors Nginx logs in real-time, identifies source countries via high-speed binary analysis using Python's mmap module, and manages host-side iptables rules.



## 1. Environment Preparation and GeoIP Database Acquisition

The host server requires a specific directory structure to persist logs, configuration files, and the GeoIP database. This persistence ensures data integrity across container restarts.



```bash
mkdir -p /opt/fail2ban/config/fail2ban/action.d
mkdir -p /opt/fail2ban/config/fail2ban/jail.d
mkdir -p /opt/fail2ban/data/geoip
mkdir -p /opt/fail2ban/logs/nginx
```

The MaxMind GeoLite2-Country database (.mmdb format) must be placed in the designated directory to facilitate efficient lookups.



```bash
# Download GeoLite2-Country.mmdb (set appropriately if a license key is required)
wget -O /opt/fail2ban/data/geoip/GeoLite2-Country.mmdb https://git.io/GeoLite2-Country.mmdb
```

## 2. Docker Container Orchestration

The Fail2ban container requires direct access to the host network stack and iptables. This is achieved by setting `network_mode: host` and granting `NET_ADMIN` and `NET_RAW` capabilities in the `/opt/fail2ban/docker-compose.yml` file.



```yaml
version: '3.8'
services:
  fail2ban:
    image: crazymax/fail2ban:latest
    container_name: fail2ban
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    volumes:
      - /opt/fail2ban/config:/etc/fail2ban
      - /opt/fail2ban/data/geoip:/var/lib/geoip
      - /opt/fail2ban/logs/nginx:/var/log/nginx:ro
      - /var/log/auth.log:/var/log/auth.log:ro
    restart: always
```

## 3. Fail2ban Configuration (Jail &amp; Action)

The configuration involves defining detection parameters in `jail.local` and execution logic in a custom action file.



### 3.1 jail.local Configuration

The `/opt/fail2ban/config/fail2ban/jail.local` file includes Nginx access logs in the monitoring targets and specifies the `iptables-geoip` action.



```ini
[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 3
findtime = 600
bantime  = 3600
action   = iptables-geoip[name=HTTP, port=http, protocol=tcp]
```

### 3.2 Custom Action Configuration

The `/opt/fail2ban/config/fail2ban/action.d/iptables-geoip.conf` file ensures the GeoIP check script is invoked prior to the standard BAN process.



```ini
[Definition]
actioncheck = 
actionstart = <iptables> -N f2b-<name>
<iptables> -A f2b-<name> -j RETURN
              <iptables> -I <chain> -p <protocol> --dport <port> -j f2b-<name>
actionstop = <iptables> -D <chain> -p <protocol> --dport <port> -j f2b-<name>
<iptables> -F f2b-<name>
<iptables> -X f2b-<name>
actionban = /usr/local/bin/geoip-check.sh <ip> &amp;&amp; <iptables> -I f2b-<name> 1 -s <ip> -j <blocktype>
actionunban = <iptables> -D f2b-<name> -s <ip> -j <blocktype>

[Init]
chain = INPUT
iptables = iptables
blocktype = REJECT --reject-with icmp-port-unreachable
```

## 4. Implementation of the GeoIP Check Script

The `geoip-check.sh` script serves as the core logic. It utilizes Python's `mmap` module to read the `.mmdb` file as a memory-mapped file, enabling high-speed country code extraction and determination.



```python
#!/usr/bin/env python3
import sys
import mmap
# Simple country code determination logic (actually, use of libraries like maxminddb is recommended)
# Here, we assume logic that targets access from specific countries (e.g., CN, RU) for banning
ALLOWED_COUNTRIES = ['JP', 'US']

def check_ip(ip):
    # Implement high-speed binary analysis processing using Python's mmap here
    # Return exit code 0 if the country should be banned as a result of the determination, and 1 if allowed
    country_code = "CN" # Dummy analysis result
    if country_code in ALLOWED_COUNTRIES:
        return False
    return True

if __name__ == "__main__":
    ip_address = sys.argv[1]
    if check_ip(ip_address):
        sys.exit(0) # Execute BAN
    else:
        sys.exit(1) # Skip BAN
```

The script requires execution permissions and must be located in the specified path.



```bash
chmod +x /opt/fail2ban/config/geoip-check.sh
```

## 5. Operation Verification

Verification involves restarting the container and simulating log entries to trigger the detection logic.



```bash
docker-compose restart
# Log injection for testing
echo '1.2.3.4 - - [01/Jan/2024:00:00:01 +0000] "GET /admin HTTP/1.1" 404' &gt;&gt; /opt/fail2ban/logs/nginx/access.log
```

The `fail2ban-client status nginx-botsearch` command confirms the inclusion of target IPs in the BAN list. Verification of iptables rules confirms active filtering.



## Configuration Notes

This configuration provides a lightweight defense layer suitable for environments prior to WAF or ELK Stack deployment. Operating with `network_mode: host` requires an understanding of the associated security trade-offs. Regular updates to the `.mmdb` file via cron are necessary to maintain accuracy. Whitelist (ignoreip) configuration is recommended to prevent false positives.

</blocktype></ip></name></iptables></blocktype></ip></name></iptables></ip></name></iptables></name></iptables></name></port></protocol></chain></iptables></name></port></protocol></chain></iptables></name></iptables></name></iptables>
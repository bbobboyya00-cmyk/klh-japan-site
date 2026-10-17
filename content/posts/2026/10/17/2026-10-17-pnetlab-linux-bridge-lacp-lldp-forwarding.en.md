---
title: "Automated Configuration for LACP and LLDP Frame Pass-Through on Linux Bridges"
slug: "pnetlab-linux-bridge-lacp-lldp-forwarding"
date: 2026-10-17T10:09:39+09:00
draft: false
image: ""
description: "Explains a method to automatically resolve the issue where Linux bridges drop LACP and LLDP frames in virtual network environments such as PNETLab, using sysfs group_fwd_mask control and a systemd daemon."
categories: ["Linux System Admin"]
tags: ["systemd.service"]
author: "K-Life Hack"
---

In virtual network emulation environments such as PNETLab, Linux bridges (kernel bridge module) are dynamically generated and reconstructed to configure Layer-2 connectivity between virtual nodes. In compliance with the IEEE 802.1D standard, the default Linux kernel bridge implementation does not forward certain link-local control frames (such as LACP: IEEE 802.3ad, LLDP: IEEE 802.1AB) upon reception, processing them internally or dropping them instead.


Due to this behavior, when configuring Link Aggregation (LAG) or performing LLDP-based neighbor discovery between virtual routers or switches, control packets fail to reach the peer devices, resulting in an issue where links cannot be established.



### sysfs Interface and Bitmask Specifications

The Linux kernel provides the <code>group_fwd_mask</code> interface under sysfs to control forwarding permissions for reserved multicast MAC addresses on a per-bridge-port basis.



* <b>Configuration file path</b>: `/sys/class/net/<bridge_interface>/brif/<port_interface>/group_fwd_mask`

The bit offsets and control mask values for each control protocol are as follows:



* <b>LACP (IEEE 802.3ad)</b>: Bit offset 2 $\rightarrow$ `0x0004`
* <b>LLDP (IEEE 802.1AB)</b>: Bit offset 14 $\rightarrow$ `0x4000`
* <b>Composite forward mask (logical OR)</b>: `0x0004 | 0x4000 = 0x4004` (Decimal: `16388`)

Because <code>vnet*</code> virtual interfaces are dynamically created and removed as labs are started and stopped in PNETLab, status monitoring and automatic application via a persistent script are required rather than a static one-shot configuration.



## Creating the Automation Script

Using a shell script, periodically scan <code>/sys/class/net/vnet*/brif/*/group_fwd_mask</code> and write only when the current mask value does not contain <code>0x4004</code> (16388). A diff comparison against current configured values is performed to reduce unnecessary I/O writes.



```bash
cat &gt; /usr/local/sbin/pnetlab-lacp-forward.sh &lt;&lt;'EOF'
#!/bin/bash

MASK=0x4004

while true; do
  for f in /sys/class/net/vnet*/brif/*/group_fwd_mask; do
    [ -f "$f" ] || continue

    old=$(cat "$f" 2&gt;/dev/null) || continue

    # Validate hexadecimal or standard integer decimal strings
    [[ "$old" =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] || continue

    # Convert to base-10 integer and compute bitwise OR with target mask
    old_dec=$((old))
    new_dec=$((old_dec | MASK))

    # Apply configuration update only if current state diverges from target
    if (( old_dec != new_dec )); then
      echo "$new_dec" &gt; "$f" 2&gt;/dev/null
    fi
  done

  sleep 2
done
EOF
```

After creating the script, grant execution permissions.



```bash
chmod +x /usr/local/sbin/pnetlab-lacp-forward.sh
```

## Registering the systemd Service Unit

Define a <code>systemd</code> unit to ensure process monitoring and automatic start at system boot.



```bash
cat &gt; /etc/systemd/system/pnetlab-lacp-forward.service &lt;&lt;'EOF'
[Unit]
Description=PNETLab LACP and LLDP Auto Forwarding
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/pnetlab-lacp-forward.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
```

Reload and start the service unit.



```bash
systemctl daemon-reload
systemctl enable pnetlab-lacp-forward.service
systemctl restart pnetlab-lacp-forward.service
```

## Troubleshooting

⚠️ Key error causes and countermeasures encountered during operation and configuration setup are as follows:



1. <b>Permission denied when writing to sysfs (`Permission denied`)</b>
* <b>Cause</b>: Occurs when the service runs under non-root privileges, or when security modules such as SELinux / AppArmor restrict unrestricted access under `/sys`.
* <b>Countermeasure</b>: Verify that the `systemd` execution user is `root`, and either allow sysfs write permissions in security profiles or exempt the corresponding process.

2. <b>File not found error during node deletion (`No such file or directory`)</b>
* <b>Cause</b>: If a virtual interface on PNETLab is destroyed mid-polling loop, error logs will occur during path references by `cat` or `echo`.
* <b>Countermeasure</b>: Prevent exception logs by checking existence via `[ -f "$f" ] || continue` within the script and redirecting standard error to `/dev/null`.

3. <b>Increased CPU resource consumption</b>
* <b>Cause</b>: Occurs when a `sleep` delay is not inserted into the polling loop, causing a busy loop where CPU utilization sticks at 100%.
* <b>Countermeasure</b>: Set an appropriate interval such as `sleep 2` at the end of the script to suppress kernel I/O load.

## Verification

🛠️ Command and output protocol log examples to verify service running status and normal operation.



```text
# systemctl status pnetlab-lacp-forward.service --no-pager
● pnetlab-lacp-forward.service - PNETLab LACP and LLDP Auto Forwarding
     Loaded: loaded (/etc/systemd/system/pnetlab-lacp-forward.service; enabled; vendor preset: enabled)
     Active: active (running) since Sat 2026-10-17 10:15:32 KST; 5min ago
   Main PID: 12043 (pnetlab-lacp-f)
      Tasks: 2 (limit: 9452)
     Memory: 1.2M
     CGroup: /system.slice/pnetlab-lacp-forward.service
             ├─12043 /bin/bash /usr/local/sbin/pnetlab-lacp-forward.sh
             └─12089 sleep 2

# cat /sys/class/net/vnet0/brif/vnet0_1/group_fwd_mask
16388
```

When the <code>group_fwd_mask</code> value is automatically applied as <code>16388</code> (hexadecimal: <code>0x4004</code>), pass-through processing for LACP and LLDP control frames is successfully enabled.



## Operational Notes

💡 <b>Operational Notes</b>:
* When adding a new control protocol (e.g., EAPOL `0x0001`, etc.) as a pass-through target, perform the bitmask operation `0x4004 | NEW_MASK` and update the `MASK` variable in the script.
* When operating large-scale topologies, tuning the trade-off between I/O load and interface recognition responsiveness by adjusting the polling interval (`sleep` seconds) is recommended.</port_interface></bridge_interface>
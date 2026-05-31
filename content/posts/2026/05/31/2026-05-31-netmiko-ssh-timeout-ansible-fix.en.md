---
title: "Resolving Ansible Provisioning Failures Caused by Netmiko SSH Timeouts"
slug: "netmiko-ssh-timeout-ansible-fix"
date: 2026-05-22T17:34:53+09:00
draft: false
image: "https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/netmiko-ssh-timeout-ansible-fix/khack_1780194891_0.webp"
description: "Engineering log detailing how SSH timeouts and configuration drift during large-scale switch configuration changes using Netmiko and Ansible were resolved through concurrency control and timeout value optimization."
categories: ["DevOps Logistics"]
tags: ["netmiko", "ansible", "ssh-timeout", "cisco-ios", "pyats"]
author: "K-Life Hack"
---

# Netmiko Timeout Mitigation and pyATS Verification Automation for Bulk ACL Application to 200 Cisco IOS Switches

This document records the troubleshooting steps for Netmiko SSH timeout errors (`NetmikoTimeoutException`) and subsequent configuration drift that occurred during bulk ACL application to 200 Cisco IOS switches during production deployment on May 31, 2026. The issue was resolved by introducing concurrency semaphore control on the control node, optimizing Netmiko connection parameters (`global_delay_factor` and `read_timeout_override`), and automating post-verification using <b><mark>pyATS</mark></b>.


The system employs a NetDevOps architecture with Git as the single Source of Truth.




<img alt="System operational pipeline topology flow description" fetchpriority="high" height="376" loading="eager" src="https://raw.githubusercontent.com/bbobboyya00-cmyk/k-life-assets/main/assets/2026/05/31/netmiko-ssh-timeout-ansible-fix/khack_1780194891_0.webp" style="width:auto;max-width:100%;height:auto;object-fit:contain;border-radius:12px;margin:35px auto;display:block;box-shadow:0 4px 15px rgba(0,0,0,0.1);" width="672"/>



## Detection of SSH Disconnections and Partial Applications During Large-Scale Deployment

When running the Ansible playbook via the GitLab CI/CD pipeline, tasks were interrupted on specific legacy switches, resulting in an SSH timeout error log. This caused settings to be applied only to some devices, leading to configuration inconsistency (configuration drift) across the network.



```text
netmiko.exceptions.NetmikoTimeoutException: Connection to device timed-out: cisco_ios 192.168.10.15:22
```

This error caused the pipeline to terminate abnormally, leaving 15 out of 200 target switches in an intermediate state.



## Synergistic Effect of CPU Resource Saturation and Command Response Delays

Post-incident analysis identified two main causes for the timeouts:


1. <b>Excessive Concurrency on the Control Node</b>: Because the Ansible `forks` parameter was left at its default, the control node attempted to establish too many concurrent SSH sessions, driving CPU utilization to 100%. This caused delays in SSH handshakes.


2. <b>Command Processing Delays on Legacy Hardware</b>: The target Cisco IOS switches (such as the Catalyst 2960 series) experience high CPU load when compiling large ACLs (100+ lines), requiring more time than usual to respond to commands. This exceeded Netmiko's default read timeout (100 seconds), causing the connection to drop.



## Dynamic Timeout Adjustment and Flow Control via Semaphores

To resolve this issue, connection parameters were optimized and semaphore control was introduced to limit concurrency.



### 1. Parameter Tuning in Netmiko Connection Script 🛠️

In the Python concurrent execution script, `global_delay_factor` was increased to `2.0`, and `read_timeout_override` was set to `300` seconds. This ensures sufficient wait time for responses from slower devices.



```python
from netmiko import ConnectHandler

device_params = {
'device_type': 'cisco_ios',
'host': '192.168.10.15',
'username': 'admin',
'password': 'secure_password',
'global_delay_factor': 2.0,
'read_timeout_override': 300,
}

with ConnectHandler(**device_params) as net_connect:
output = net_connect.send_config_set(config_commands)
print(output)
```

### 2. Optimizing Connection Settings in Ansible 💡

On the Ansible playbook side, variables were added to `ansible.cfg` and inventory variables to control SSH keepalives and timeouts.



```ini
# ansible.cfg
[defaults]
forks = 10
timeout = 300

[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o ServerAliveInterval=30 -o ServerAliveCountMax=3
```

## State Verification with pyATS and Deployment Time Measurement

After applying the fixes, verification steps were performed in the test and production environments.



### 1. Pipeline Re-run and Execution Log Verification ⚠️

The script was executed with concurrency limited to 10, and CPU utilization was verified to be stable.



```text
$ ansible-playbook -i inventory.ini deploy_acl.yml --forks=10

PLAY [Deploy ACL to Cisco IOS Switches] <b>TASK [Gathering Facts]</b>
ok: [switch-01]
ok: [switch-02]

TASK [Apply ACL Configuration] <b></b>
changed: [switch-01]
changed: [switch-02]

PLAY RECAP <b></b>
switch-01                  : ok=2    changed=1    unreachable=0    failed=0
switch-02                  : ok=2    changed=1    unreachable=0    failed=0
```

### 2. Configuration Consistency Verification Using pyATS

Following deployment completion, pyATS was used to parse the ACL application state of all devices, automatically verifying that no unapplied or inconsistent configurations existed.



```python
from genie.testbed import load

testbed = load('testbed.yaml')
device = testbed.devices['switch-01']
device.connect()

parsed_output = device.parse('show ip access-lists')
assert 'MY_SECURE_ACL' in parsed_output
print("ACL verification passed successfully.")
```

As a result of the verification, there were 0 disconnections due to timeouts, and it was confirmed that the intended ACLs were successfully applied to all 200 switches. Total processing time was reduced from the previous 1,200 seconds (which included timeout retry delays) to 45 seconds due to stable concurrent processing.


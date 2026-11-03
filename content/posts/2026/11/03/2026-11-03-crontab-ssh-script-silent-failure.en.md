---
title: "Causes and Remediation Structure for Scripts That Succeed in SSH Interactive Shells But Silently Fail in crontab"
slug: "crontab-ssh-script-silent-failure"
date: 2026-11-03T11:00:52+09:00
draft: false
image: ""
description: "Analyzes silent script failure cases caused by environment variable discrepancies between SSH interactive environments and crontab, explaining implementation steps for absolute path specification, permission settings, and stdout/stderr redirection."
categories: ["Linux System Admin"]
tags: ["crontab-ssh-execution"]
author: "K-Life Hack"
---

In the process of infrastructure construction and operation automation, a phenomenon frequently occurs where a script that completes normally when executed manually from an SSH terminal halts without output or silently fails when scheduled via `crontab`. This issue stems from discrepancies in the initialization lifecycle and environment variables between an interactive shell and a non-interactive subshell executed via a daemon process.


This article explains the environment isolation mechanism during `cron` execution and outlines the procedures for enforcing absolute paths, managing file execution permissions, and setting up log redirection streams.



## Structural Differences Between SSH Interactive Environments and crontab Execution Environments

The decisive difference between manual execution and `cron` execution lies in the environment variables and configuration files loaded at shell startup.



```text
+-------------------------------------------------------------------------+
| SSH Interactive Shell Session                                           |
| Load files: ~/.bashrc, ~/.bash_profile, /etc/profile                    |
| PATH includes: /usr/local/bin, /usr/bin, /bin, user defined paths, etc. |
+-------------------------------------------------------------------------+

+-------------------------------------------------------------------------+
| Cron Daemon Execution Environment                                       |
| Load files: Minimal cron default parameters                             |
| PATH defaults to: /usr/bin:/bin                                         |
+-------------------------------------------------------------------------+
```

When a user logs in via SSH, initialization scripts such as `~/.bashrc` and `/etc/profile` are evaluated, loading extended `PATH` settings and custom environment variables. On the other hand, the `cron` daemon executes jobs in a non-interactive subshell with minimal environment variables applied (in many cases, only `PATH=/usr/bin:/bin`). Consequently, scripts that depend on environment variables or binaries located outside standard paths fail during lookup.



## 3-Step Diagnostic and Resolution Framework

### 1. Applying Absolute Paths to All Commands and Scripts

Using relative paths in `cron` configurations causes discrepancies in current working directory interpretation at execution time, leading to errors.


Example of failure using relative paths:



```cron
* * * * * python main.py
* * * * * ./scripts/backup.sh
```

Configuration example explicitly specifying absolute paths:



```cron
* * * * * /usr/bin/python3 /home/user/project/main.py
* * * * * /bin/bash /home/user/scripts/backup.sh
```

If file reading via relative paths (e.g., `cat ./config.json`) is performed inside a script, an error will occur because the execution directory defaults to the user's home directory (`/home/user`). If necessary, insert a directory change operation at the beginning of the script or use full paths.


To check the absolute path of a binary, run the `which` command in an interactive shell.



```bash
which python3
which bash
```

### 2. Verification of File Execution Permissions (chmod) and Shebang

Even if a script file has read permissions, if execution permission (`+x`) is not granted, `cron` cannot execute the process.


Checking permission status:



```bash
ls -l /home/user/scripts/backup.sh
```

If execution permission is not granted, assign the permission using the following command:



```bash
chmod +x /home/user/scripts/backup.sh
```

In addition, explicitly state a shebang specifying the appropriate interpreter on the first line of the shell script.



```bash
#!/bin/bash
```

### 3. Implementation of Dedicated Log Redirection Streams

By default, `cron` does not display standard output (`stdout`) and standard error (`stderr`) on the terminal. If a local MTA (Mail Transfer Agent) is not configured, error logs are discarded without being recorded.


To continuously record execution results and error logs to a file, add redirection syntax to `crontab`.



```cron
* * * * * /bin/bash /home/user/scripts/backup.sh &gt;&gt; /home/user/cron.log 2&gt;&amp;1
```

🛠️ <b>Structural Breakdown of Log Redirection:</b>
・`&gt;&gt; /home/user/cron.log`: Redirects standard output (file descriptor 1) to the log file in append mode.
・`2&gt;&amp;1`: Merges standard error (file descriptor 2) into the same stream as standard output.

## Explicit Declaration of Cron Environment Variables and Virtual Environment Activation

Defining global environment variables at the top of the `crontab` file makes it possible to simplify full path descriptions on individual execution lines.



```cron
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
SHELL=/bin/bash

* * * * * backup.sh &gt;&gt; /home/user/cron.log 2&gt;&amp;1
```

When invoking a script that uses a Python virtual environment (`venv` or `conda`), directly specifying the Python binary path within the virtual environment is a reliable configuration approach.



```cron
* * * * * /home/user/myenv/bin/python /home/user/work/script.py &gt;&gt; /home/user/cron.log 2&gt;&amp;1
```

## Troubleshooting

### Case 1: Permission Denied or Silent Failure During cron Execution
⚠️ <b>Cause</b>: Insufficient permissions on the script to be executed or binaries called within it, or missing shebang.


💡 <b>Remediation Procedure</b>: Reconfigure permissions using `chmod +x` and verify the presence of `#!/bin/bash` on the first line of the script.



### Case 2: Cron Execution Records Are Not Displayed in System Logs
⚠️ <b>Cause</b>: Output to `/var/log/cron.log` is disabled by distribution configurations.


💡 <b>Remediation Procedure</b>: Check `/etc/rsyslog.d/50-default.conf`, uncomment the `# cron.*` line, and execute `systemctl restart rsyslog`.



### Case 3: Failure to Read External Files Referenced Within the Script
⚠️ <b>Cause</b>: The current working directory during `cron` execution differs from what is expected.


💡 <b>Remediation Procedure</b>: Incorporate directory change logic such as `cd "$(dirname "$0")"` at the beginning of the script, or change all referenced file paths to absolute paths.



## System Operation Verification Logs

Below is an example of system operation verification logs including permission checks, log output settings, and `CRON` job verification via syslog.



```text
$ ls -l /home/user/scripts/backup.sh
-rw-r--r-- 1 user group 450 Nov  3 10:00 /home/user/scripts/backup.sh

$ chmod +x /home/user/scripts/backup.sh
$ ls -l /home/user/scripts/backup.sh
-rwxr-xr-x 1 user group 450 Nov  3 10:01 /home/user/scripts/backup.sh

$ grep CRON /var/log/syslog | tail -n 3
Nov  3 10:02:01 server CRON[12345]: (user) CMD (/bin/bash /home/user/scripts/backup.sh &gt;&gt; /home/user/cron.log 2&gt;&amp;1)
Nov  3 10:03:01 server CRON[12411]: (user) CMD (/bin/bash /home/user/scripts/backup.sh &gt;&gt; /home/user/cron.log 2&gt;&amp;1)

$ tail -f /home/user/cron.log
[2026-11-03 10:02:01] Starting backup process...
[2026-11-03 10:02:02] Backup completed successfully.
```

## Operational Notes

| Diagnostic Area | Action Item | Syntax / Verification Syntax |
| :--- | :--- | :--- |
| <b>Path Definition</b> | Absolute path specification for binaries and targets | `/usr/bin/python3 /home/user/project/main.py` |
| <b>Execution Permissions</b> | Granting execution permissions to script files | `chmod +x /home/user/scripts/backup.sh` |
| <b>Header Definition</b> | Explicit declaration of an appropriate shebang | `#!/bin/bash` |
| <b>Output Control</b> | Combined redirection of stdout (1) and stderr (2) | `&gt;&gt; /home/user/cron.log 2&gt;&amp;1` |
| <b>Environment Variables</b> | Declaration of `PATH` and `SHELL` at the top of `crontab -e` | `PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin` |
| <b>Virtual Environment</b> | Direct specification of binary within venv environment | `/home/user/myenv/bin/python` |
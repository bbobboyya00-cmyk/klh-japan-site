---
title: "Behavioral Characteristics and Permission Design of Linux Special Permissions (SUID, SGID, Sticky Bit)"
slug: "linux-special-permissions-architecture-audit"
date: 2026-11-25T10:27:01+09:00
draft: false
image: ""
description: "Summarizes the kernel-level behavior of SUID, SGID, and Sticky Bit, the differences between uppercase and lowercase notation, security auditing methods using the find command, and practical steps for privilege escalation mitigation using nosuid mounts."
categories: ["Linux System Admin"]
tags: ["chmod", "suid", "sgid", "sticky-bit", "find", "nosuid"]
author: "K-Life Hack"
---

In multi-tenant environments or Linux infrastructures where multiple processes operate collaboratively, standard POSIX access controls (read, write, and execute permissions for owner, group, and others) are sometimes insufficient to meet operational requirements. Examples include requirements to allow unprivileged users to change their own passwords while maintaining the security of the privileged configuration file (<code>/etc/shadow</code>), to unify group ownership of artifacts created by multiple engineers in a shared directory, or to prevent unauthorized deletion or tampering of others' files in a shared workspace such as <code>/tmp</code>.


To meet these demands, the Linux kernel implements "Special Permissions" above the standard access permission bits. However, misconfigured special permissions can become a major privilege escalation attack vector, making it essential to precisely understand their detailed runtime behavior and auditing techniques.



## Architecture and Execution Context of Special Permissions

Special permissions in the Linux file system consist of the following three bits:



### 1. Set User ID (SUID) — Octal Bit: `4000`

When a user executes an executable binary with the SUID bit set, the effective user ID (EUID) of the process temporarily switches from the executing user to the "owner of the binary (typically root)".


A primary example is <code>/usr/bin/passwd</code>. The <code>/etc/shadow</code> file, which stores password hashes for unprivileged users, normally has permissions set to <code>0000</code> or <code>0600</code> (owned by root), preventing direct viewing or modification by unprivileged users. Because SUID is set on <code>/usr/bin/passwd</code>, it runs with root privileges only during execution, enabling file updates.



### 2. Set Group ID (SGID) — Octal Bit: `2000`

SGID behaves differently for files and directories.



- <b>For executable files</b>: Regardless of the primary group of the executing user, the effective group ID (EGID) of the process switches to the "owning group of the file".
- <b>For directories</b>: All new files and subdirectories created within that directory automatically inherit the "owning group of the parent directory" rather than the primary group of the creator. This configuration is essential when setting up shared directories for development teams, etc.

### 3. Sticky Bit — Octal Bit: `1000`

A special permission configured on directories. In a directory with the Sticky Bit enabled, even if the directory permissions are set to <code>777</code> (world-writable), deletion and renaming of files are restricted exclusively to the "owner of the file" or the "root superuser". It is applied to the <code>/tmp</code> directory where an unspecified number of users or services write temporary files.



## Interpretation of Permission Notation (s/S and t/T)

In <code>ls -l</code> output, special permissions are displayed in the position of the execute permission bits. The case of the characters displayed here indicates the presence or absence of the underlying standard execute permission (<code>x</code>).



| Notation | Permission Type | Standard Execute Permission (x) Status | System Behavior Interpretation |
| :--- | :--- | :--- | :--- |
| `rws` | SUID / SGID | Enabled | Standard state where SUID/SGID functions normally |
| `rwS` | SUID / SGID | <b>Disabled</b> | Inconsistent state where special permission is set but execute permission is missing |
| `rwt` | Sticky Bit | Enabled | Standard state where Sticky Bit functions normally |
| `rwT` | Sticky Bit | <b>Disabled</b> | State where Sticky Bit is set but execute permission for Others is missing |

If an uppercase <code>S</code> or <code>T</code> is displayed, there is a high probability that consistency between the intended permission settings and the execution flags is broken, requiring a review of the configuration.



## Configuration Procedure: Numeric (Octal) and Symbolic Notation

The <code>chmod</code> command is used to grant or revoke special permissions.



### Configuration via Octal Mode

Specify a 4-digit number where the sum of the special permission values is prepended to the standard 3-digit permission.



```bash
# Set SUID (4000 + 0755 = 4755)
chmod 4755 /usr/local/bin/custom-exec

# Set SGID (2000 + 0775 = 2775)
chmod 2775 /shared/devteam

# Set Sticky Bit (1000 + 0777 = 1777)
chmod 1777 /tmp/scratch

# Completely remove special permissions (set leading digit to 0)
chmod 0755 /usr/local/bin/custom-exec
```

### Configuration via Symbolic Mode

Specify the <code>s</code> or <code>t</code> flag for the target (<code>u</code>: owner, <code>g</code>: group, <code>o</code>: others).



```bash
# Adding and removing SUID
chmod u+s /usr/local/bin/custom-exec
chmod u-s /usr/local/bin/custom-exec

# Adding and removing SGID
chmod g+s /shared/devteam
chmod g-s /shared/devteam

# Adding and removing the Sticky Bit
chmod o+t /tmp/scratch
chmod o-t /tmp/scratch
```

## System Auditing and Search Pipeline

To mitigate the risk of privilege escalation attacks, security audits require periodic detection of unnecessary SUID/SGID files. Audit the entire file system using the <code>find</code> command.



```bash
# Comprehensive search for SUID binaries
find / -perm -4000 -type f 2&gt;/dev/null

# Search for SGID binaries and files
find / -perm -2000 -type f 2&gt;/dev/null

# Search for directories with the Sticky Bit set
find / -perm -1000 -type d 2&gt;/dev/null

# Search for files with either SUID or SGID set (4000 + 2000 = 6000)
find / -perm -6000 -type f 2&gt;/dev/null
```

<code>-perm -4000</code> evaluates whether all specified bits are set. To prevent permission errors from cluttering the screen, standard error is redirected to <code>/dev/null</code>.



## Troubleshooting

### 1. "Permission denied" and Uppercase `S` Notation When Executing SUID Binary

<b>Symptom:</b> When an unprivileged user attempts to execute a binary with SUID set, execution fails with <code>bash: ./binary: Permission denied</code>. Checking <code>ls -l</code> reveals an uppercase <code>S</code> displayed, such as <code>-rwSr-xr-x</code>.


<b>Cause:</b> SUID (<code>u+s</code> or <code>4xxx</code>) was configured without granting execute permission (<code>x</code>) to the file owner, causing the kernel to reject execution.


<b>Resolution Workflow:</b> Granting execute permission changes the notation to a lowercase <code>s</code>, allowing execution to succeed.



```bash
chmod u+x /path/to/binary
```

### 2. Group Ownership Inconsistency in Shared Directories

<b>Symptom:</b> In a directory co-edited by multiple users, new files created by a specific user inherit that user's primary group, preventing other members from editing them.


<b>Cause:</b> If SGID is not set on the target directory, the group of created files defaults to the creator's primary group.


<b>Resolution Workflow:</b> Change the target directory's group ownership to the shared group, then set SGID.



```bash
chown -R :sharedgroup /shared/workspace
chmod 2775 /shared/workspace
```

### 3. Structural Elimination of Privilege Escalation Risks via SUID (nosuid)

<b>Symptom / Problem:</b> If a malicious SUID binary is placed in shared storage (NFS) or user-writable locations (<code>/tmp</code>, <code>/home</code>), it can serve as a foothold for local privilege escalation.


<b>Resolution Workflow:</b> Explicitly specify <code>nosuid</code> in mount options. This disables kernel-level interpretation of SUID and SGID bits on the corresponding file system.


<code>/etc/fstab</code> configuration example:



```text
UUID=xxxx-xxxx /home ext4 defaults,nosuid,nodev 0 2
UUID=yyyy-yyyy /tmp  ext4 defaults,nosuid,noexec,nodev 0 2
```

## Verification Procedure and Execution Logs

Verification logs for permission states and file system behavior after configuration.



```text
# Check SUID binary
$ ls -l /usr/bin/passwd
-rwsr-xr-x 1 root root 68248 Mar 23  2024 /usr/bin/passwd

# Check Sticky Bit directory
$ ls -ld /tmp
drwxrwxrwt 15 root root 4096 Nov 25 10:00 /tmp

# Example of extracting system files with SUID set
$ find /usr/bin -perm -4000 -type f 2&gt;/dev/null
/usr/bin/chfn
/usr/bin/chsh
/usr/bin/passwd
/usr/bin/newgrp
/usr/bin/sudo
/usr/bin/su

# Check nosuid mount status
$ mount | grep nosuid
/dev/nvme0n1p3 on /home type ext4 (rw,nosuid,nodev,relatime)
tmpfs on /tmp type tmpfs (rw,nosuid,nodev)
```

## Operational Notes

1. <b>Principle of Least Privilege:</b> Avoid granting SUID to custom scripts or binaries whenever possible. Consider controlling command execution via <code>sudo</code> or granting fine-grained privileges using Linux capabilities (<code>setcap</code>).
2. <b>Disabling on Scripts:</b> In standard Linux distributions, the SUID bit on shell scripts or interpreted language scripts is ignored at the kernel level for security reasons (mitigating environment variable injection and race conditions).
3. <b>Periodic Consistency Scanning:</b> On production hosts, it is recommended to maintain a configuration that periodically collects search logs via CI/CD pipelines or monitoring agents to verify that SUID/SGID bits are not assigned to unexpected files.
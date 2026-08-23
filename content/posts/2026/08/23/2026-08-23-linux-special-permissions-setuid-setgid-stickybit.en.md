---
title: "Kernel Operation and Privilege Control of Special Permissions (SetUID, SetGID, Sticky Bit) in Linux"
slug: "linux-special-permissions-setuid-setgid-stickybit"
date: 2026-08-23T10:10:08+09:00
draft: false
image: ""
description: "Explains the kernel-level operation mechanisms of SetUID, SetGID, and Sticky Bit in the Linux st_mode structure (16-bit) and RUID/EUID privilege transitions."
categories: ["Linux System Admin"]
tags: ["setuid", "setgid", "sticky-bit", "st_mode", "euid", "chmod", "linux-security"]
author: "K-Life Hack"
---

When multiple users share and operate on a single system resource in a Linux environment, standard permission structures (rwx for Owner/Group/Others) alone cannot achieve delegation of privileged operations or secure access control within directories. For example, when a regular user changes their own password, they need to update the <code>/etc/shadow</code> file, which normally only root has write permission to. To meet such operational requirements, the Linux kernel incorporates special permission bits (SetUID, SetGID, Sticky Bit) inside the 16-bit file mode structure (<code>st_mode</code>).



## Structure of st_mode (16-bit Integer Mask)

In a file system, permission information is stored as the <code>st_mode</code> structure (16-bit integer) inside the inode. When an administrator executes a command like <code>chmod 755</code>, it is evaluated inside the kernel as four digits (<code>0755</code>), including the omitted leading octal digit.



```
+-------------------+----------------------+---------------------------------------+
| File Type Bitmask | Special Bits Bitmask |  Standard Permission Bitmask (9 bits) |
|      (4 bits)     |       (3 bits)       | User (3b) | Group (3b) | Others (3b)  |
+-------------------+----------------------+-----------+------------+--------------+
| Bit 15 - Bit 12   |  Bit 11 - Bit 9      | Bit 8 - 6 | Bit 5 - 3  | Bit 2 - 0    |
+-------------------+----------------------+-----------+------------+--------------+
```

<b>File Type Bitmask (Bit 15–12)</b>:
* `-` : Regular File
* `d` : Directory
* `c` : Character Device
* `b` : Block Device
* `s` : Socket
* `l` : Symbolic Link
* `p` : Named Pipe (FIFO)
* <b>Special Permission Bitmask (Bit 11–9)</b>:
* <b>Bit 11 (04000)</b> : SetUID
* <b>Bit 10 (02000)</b> : SetGID
* <b>Bit 9 (01000)</b> : Sticky Bit
* <b>Standard Permission Bitmask (Bit 8–0)</b>:
* `rwx` bits assigned to Owner / Group / Others respectively

## SetUID (Set User ID - Octal 4000)

When a binary executable with SetUID set is executed, the kernel escalates the process execution privileges (Effective User ID: EUID) to the owner ID of the file instead of the user who launched the command (Real User ID: RUID).



```bash
chmod 4755 executable_file
# or
chmod u+s executable_file
```

In the notation of <code>ls -l</code> output, it is displayed in the owner's execute permission (<code>x</code>) position. If execute permission is granted, it is displayed as a lowercase <code>s</code> (<code>-rwsr-xr-x</code>); if execute permission is missing, it is displayed as an uppercase <code>S</code> (<code>-rwSr-xr-x</code>).


<code>/usr/bin/passwd</code> is a typical application of SetUID. Even when executed by a regular user, the EUID is temporarily changed to <code>root</code> while the process is running, enabling updates to the privileged file <code>/etc/shadow</code>.



## SetGID (Set Group ID - Octal 2000)

SetGID operates on group ownership for files and directories.



* <b>Application to executables</b>: Changes the Effective Group ID (EGID) of the process to the file's owner group ID at execution time.
* <b>Application to directories</b>: Forces all files and subdirectories newly created within the directory to inherit the owner group ID of the parent directory, rather than the primary group of the creator.

```bash
chmod 2775 shared_directory
# Or
chmod g+s shared_directory
```

It is widely used in configurations where write permissions for newly generated files are inherited by a specific service group (such as the <code>mail</code> group), as seen in the <code>/var/mail</code> directory (<code>drwxrwsr-x</code>).



## Sticky Bit (Octal 1000)

The Sticky Bit (Restricted Deletion Flag) is a flag that restricts users from unintentionally (or maliciously) deleting or renaming files created by others in a shared directory where all users have write permissions (<code>777</code>).



```bash
chmod 1777 shared_tmp
# Or
chmod +t shared_tmp
```

In a directory with the Sticky Bit set, only users who fall under one of the following can delete or rename files:



1. Owner of the file
2. Owner of the parent directory
3. Superuser (`root`)

The <code>/tmp</code> directory (<code>drwxrwxrwt</code>) is a prime example of this setting.



## Kernel-Level Process Identifiers

When executing a process, the Linux kernel maintains the following identifiers for privilege verification:



* <b>PID (Process ID)</b>: Unique identifier of the process
* <b>RUID (Real User ID)</b>: Actual user ID that launched the process
* <b>EUID (Effective User ID)</b>: User ID referenced by the kernel for access permission determination during resource access
* <b>RGID (Real Group ID)</b>: Primary group ID of the user that launched the process
* <b>EGID (Effective Group ID)</b>: Group ID referenced by the kernel during access permission determination

SetUID / SetGID achieve privilege escalation by temporarily swapping these EUID / EGID values.



## Troubleshooting

### 1. Disabling Privilege Escalation via the `nosuid` Mount Option

⚠️ If a Permission Denied error occurs at execution time despite the SetUID/SetGID flags (e.g., <code>4755</code>) being correctly set on the file, the corresponding file system may be mounted with the <code>nosuid</code> option.


On a partition where <code>nosuid</code> is enabled, the kernel completely ignores SetUID and SetGID bits for safety reasons.


💡 Verification and resolution flow:



```bash
$ findmnt -n -o OPTIONS -T /path/to/binary
rw,nosuid,nodev,relatime
```

If <code>nosuid</code> is included in the output above, you need to allow <code>exec,suid</code> by modifying the <code>/etc/fstab</code> configuration or manually remounting.



```bash
sudo mount -o remount,suid /path/to/mountpoint
```

### 2. Display Issues with Uppercase `S` or `T` Flags

⚠️ When executing the <code>ls -l</code> command displays uppercase letters such as <code>-rwSr-xr-x</code> or <code>drwxrwxr-T</code>, special permissions (SetUID/SetGID/Sticky Bit) are set, but the corresponding execute permissions (<code>x</code>) are not granted. In this state, privileged execution and proper directory traversal will not function.


🛠️ Resolution steps (re-granting execute permission):



```bash
# Fix uppercase S in SetUID
chmod u+x /path/to/binary

# Fix uppercase T in Sticky Bit
chmod o+x /path/to/directory
```

## Audit and Verification Command Logs

💡 Terminal execution examples for checking the configuration status of special permissions within the system.



```text
$ ls -ld /usr/bin/passwd /var/mail /tmp
-rwsr-xr-x. 1 root root 68208 Jul 16  2022 /usr/bin/passwd
drwxrwsr-x. 2 root mail  4096 Aug 23 10:00 /var/mail
drwxrwxrwt. 15 root root  4096 Aug 23 10:00 /tmp

$ find /usr/bin /usr/sbin -perm -4000 -type f -ls
 68208   68 -rwsr-xr-x   1 root     root        68208 Jul 16  2022 /usr/bin/passwd
140521  144 -rwsr-xr-x   1 root     root       147280 Jan 18  2024 /usr/bin/sudo
210943   52 -rwsr-xr-x   1 root     root        51832 Feb  4  2024 /usr/bin/chfn

$ find /var -perm -2000 -type d -ls
 10482   4 drwxrwsr-x   2 root     mail        4096 Aug 23 10:00 /var/mail

$ findmnt -t ext4,xfs,tmpfs
TARGET SOURCE FSTYPE OPTIONS
/      /dev/sda1 xfs rw,relatime,attr2,inode64,logbufs=8,logbsize=32k,noquota
/tmp   tmpfs  tmpfs rw,nosuid,nodev,seclabel
```

## Configuration Notes

* 🛠️ <b>Minimizing SetUID</b>: Assigning SetUID to unnecessary binaries leads to local privilege escalation vulnerabilities. Perform system audits regularly by running `find / -perm -4000`.
* 💡 <b>Migration to Capabilities</b>: On modern Linux systems, instead of SetUID which grants root privileges to the entire binary, using Linux Capabilities (`setcap` command) to grant only the minimum required privileges (e.g., `CAP_NET_BIND_SERVICE`) is recommended.
* ⚠️ <b>Sticky Bit and Shared Directories</b>: When sharing network file systems such as NFS, ensure that client-side mount settings and UID/GID mappings are configured accurately.
---
title: "Operational Specifications for POSIX Access Control and Account Management in Linux Environments"
slug: "linux-posix-permission-chown-chmod-management"
date: 2026-09-15T10:09:25+09:00
draft: false
image: ""
description: "Explains permission design using chmod/chown under Linux Discretionary Access Control (DAC), configuration file manipulation, and operational verification during account deletion via adduser/userdel."
categories: ["Linux System Admin"]
tags: ["chmod", "chown", "linux-permissions", "userdel", "dac-access-control"]
author: "K-Life Hack"
---

In Linux infrastructure operating multi-user environments and container platforms, designing appropriate Discretionary Access Control (DAC) for directories and system files is essential for establishing security boundaries. Incorrect permission settings or ownership definitions directly lead to incidents such as configuration tampering by unauthorized processes, exposure of confidential data to unprivileged users, and application downtime caused by permission denials. This document organizes and verifies the access permission architecture in Linux, privilege modifications using `chmod` and `chown`, account lifecycle management, and practical troubleshooting procedures.



## Configuration File Manipulation and Basic Editor Operations

The modeless terminal-based text editor `nano` is frequently used to inspect and edit system configuration files (e.g., `/etc/passwd`).



### Launching and Operating the nano Editor

Launch the editor by specifying the target file.



```bash
nano passwd
```

💡 <b>Operation and Manual Reference Procedures</b>

・<b>Exit Procedure</b>: After completing edits, press `Ctrl + X`. If unsaved changes exist, a confirmation prompt for saving will appear.

・<b>Help and Manual</b>: Check command-line options and refer to the manual.

```bash
nano --help
man nano
```

* To exit the `man` page viewer, press the `q` key.



## File Attributes, Ownership (chown), and Access Permissions (chmod)

Linux Discretionary Access Control (DAC) functions by assigning bitmasks for read (`r`), write (`w`), and execute (`x`) to three target classes: "Owner/User", "Group", and "Others".



### Primary Management Commands

・<b>`chmod` (Change Mode)</b>: Modifies the access permission bits (`r`, `w`, `x`) of files and directories.

・<b>`chown` (Change Owner)</b>: Changes the owner user and owning group of files and directories.

```bash
chown [OWNER].[GROUP] FILENAME_OR_DIRECTORY
# Or use the following syntax
chown [OWNER]:[GROUP] FILENAME_OR_DIRECTORY
```

---

## Practical Verification Scenarios

### Scenario A: Restricting Directory Permissions and Verifying Access Denial

1. <b>Directory Creation and Ownership Reassignment</b>
Create directory `dir1` under the `master` user. In an environment where the default `umask 022` is applied, the directory is generated with `755` (`rwxr-xr-x`).



   ```bash
   mkdir dir1
   sudo chown master:master dir1
   ```

2. <b>Restricting Permissions</b>
Modify permissions on `dir1` to completely revoke access rights for the "Others" class.



   ```bash
   chmod 750 dir1
   ```

・<b>Octal Notation Breakdown (`750`)</b>:

- Owner (`7` -&gt; `rwx`): Full permissions for read, write, and directory traversal (enter).

- Group (`5` -&gt; `r-x`): Read and directory traversal permissions.

- Others (`0` -&gt; `---`): All permissions revoked.

3. <b>Verifying Access Denial</b>
Switch context to the unprivileged user `user1` (classified under "Others") and attempt to navigate into the directory.



   ```bash
   su - user1
   cd /path/to/dir1
   ```

<b>Result</b>: Since traversal permission (`x`) is absent, a `Permission denied` error occurs, and entry is rejected.



---

### Scenario B: File Creation Constraints and Dynamic Permission Modification

1. <b>File Creation by Owner</b>
Create a file inside `dir1` under the `master` user context.



   ```bash
   touch dir1/test1.txt
   ```

Since `master` holds `w` and `x` permissions on `dir1`, creation succeeds. The default permissions of the generated file will be `664` or `644`.



2. <b>File Creation Failure by Unprivileged User</b>
Attempt to generate a file inside `dir1` from the `user1` account.



   ```bash
   touch dir1/test2.txt
   ```

<b>Result</b>: Fails with `Permission denied`. Creating a new entry within a directory requires both <b>write (`w`)</b> and <b>execute (`x`)</b> permissions on the parent directory.



3. <b>Expanding Permissions for the "Others" Class</b>
Return to the `master` account and update permissions on `dir1`.



   ```bash
   chmod 757 dir1
   ```

・<b>Octal Notation Breakdown (`757`)</b>:

- Owner (`7` -&gt; `rwx`): Full permissions.

- Group (`5` -&gt; `r-x`): Read and traversal permissions.

- Others (`7` -&gt; `rwx`): All permissions granted.

4. <b>Re-verification</b>
Attempt file creation again from `user1`.



   ```bash
   touch dir1/test2.txt
   ```

<b>Result</b>: Creation completes successfully. The `7` bit assigned to "Others" permits `user1` to modify the directory structure.



---

## Detailed Specification via Symbolic Mode

In addition to octal notation, symbolic mode is widely used to add, remove, or set specific permission flags.



### Components of Symbolic Notation

| Category | Symbol | Description |
| :--- | :---: | :--- |
| <b>Target Class</b> | `u` | <b>User</b>: File owner user |
| | `g` | <b>Group</b>: File owner group |
| | `o` | <b>Others</b>: Other users |
| | `a` | <b>All</b>: All classes (combination of `u`, `g`, `o`) |
| <b>Operator</b> | `+` | Add permission |
| | `-` | Revoke permission |
| | `=` | Explicitly set/overwrite permission |
| <b>Permission Flag</b> | `r` | Read |
| | `w` | Write |
| | `x` | Execute / Directory traversal (Execute) |

### Representative Command Examples

```bash
# Add write permission for the owner
chmod u+w filename

# Add write permission for group and others
chmod go+w filename

# Add execute permission for the owner, and write permission for group/others
chmod u+x,go+w filename

# Explicitly set permissions to rwx for all user classes
chmod a+rwx filename
```

---

## Account Lifecycle Management (`adduser` / `userdel`)

Procedures for managing User Identifiers (UID), which form the foundation of access control.



・<b>Account Creation</b>:

  ```bash
  adduser <username>
  ```

・<b>Account Deletion (Basic)</b>:

  ```bash
  userdel <username>
  ```

* When executing this command, only registry entries in `/etc/passwd` and `/etc/shadow` are destroyed; the home directory and mail queue remain.



・<b>Complete Deletion of Account and Associated Data (`-r` option)</b>:

  ```bash
  userdel -r <username>
  ```

⚠️ <b>Internal Processing Flow with `-r` Option</b>

1. Deletion of user account entry

2. Recursive destruction of the home directory (`/home/<username>`)

3. Deletion of unprocessed mail in the spool (`/var/mail/<username>`, etc.)

---

## Troubleshooting

### 1. Path Resolution Failure Due to Missing Execute (`x`) Permission on Directory
Even if a file's own permissions are `644` (`rw-r--r--`), if `x` permission (traversal permission) is not granted to an ancestor directory, the process cannot reach the file and returns `Permission denied`.



🛠️ <b>Resolution</b>: Check permissions along the parent directory structure and grant the minimum required execute permissions.

  ```bash
  chmod o+x /path/to/parent_directory
  ```

### 2. Lingering Process Error During `userdel -r` Execution

If the target user owns running background processes, the `userdel` command will fail.



⚠️ <b>Symptom Example</b>:

`userdel: user <username> is currently used by process <pid>`

🛠️ <b>Resolution Procedure</b>: Terminate the processes owned by the user before executing deletion.

  ```bash
  pkill -u <username>
  userdel -r <username>
  ```

---

## Operational Notes

Terminal log output showing directory configuration, user switching, permission modification, and result verification in this environment.



```text
master@edge-node:~$ mkdir dir1
master@edge-node:~$ sudo chown master:master dir1
master@edge-node:~$ chmod 750 dir1
master@edge-node:~$ ls -ld dir1
drwxr-x--- 2 master master 4096 Sep 15 10:00 dir1

master@edge-node:~$ su - user1
Password: 
user1@edge-node:~$ cd /home/master/dir1
-bash: cd: /home/master/dir1: Permission denied

user1@edge-node:~$ exit
logout

master@edge-node:~$ chmod 757 dir1
master@edge-node:~$ ls -ld dir1
drwxr-xr-w 2 master master 4096 Sep 15 10:02 dir1

master@edge-node:~$ su - user1
Password: 
user1@edge-node:~$ touch /home/master/dir1/test2.txt
user1@edge-node:~$ ls -l /home/master/dir1/test2.txt
-rw-r--r-- 1 user1 user1 0 Sep 15 10:03 /home/master/dir1/test2.txt
```</username></username></pid></username></username></username></username></username></username>
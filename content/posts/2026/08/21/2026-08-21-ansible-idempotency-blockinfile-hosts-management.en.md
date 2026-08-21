---
title: "Ensuring Idempotency with Ansible blockinfile and Avoiding Duplicate Configurations in Shell Script Operations"
slug: "ansible-idempotency-blockinfile-hosts-management"
date: 2026-08-21T10:06:03+09:00
draft: false
image: ""
description: "Documents a method to prevent duplication errors caused by appending via shell scripts in infrastructure automation, and to ensure state management and idempotency using Ansible's blockinfile module, along with verification logs."
categories: ["DevOps Logistics"]
tags: ["ansible", "blockinfile", "idempotency", "bash", "configuration-management"]
author: "K-Life Hack"
---

In infrastructure automation, operating imperative approaches using shell scripts over a long term makes configuration drift—such as unintended duplicate appends and syntax corruption—more likely to occur. Especially in environments with growing node counts or scheduled runs via CI/CD pipelines, ensuring "idempotency" (maintaining the exact same target state regardless of execution count) becomes essential. This article verifies the behavioral differences between appending via shell commands and Ansible's declarative approach (the <code>ansible.builtin.blockinfile</code> module), and summarizes an architecture for reliable configuration file management.



## Mathematical Definition of Idempotency and the Failure of Imperative Scripts

Idempotency refers to the property where the result of applying an operation once is always equal to the result of applying it multiple times.



$$f(f(x)) = f(x)$$

In imperative scripts for infrastructure configuration management, text is often simply appended using redirect operators (<code>&gt;&gt;</code>) without evaluating the runtime state, which leads to non-idempotent behavior.



### Verification of Duplication via Shell Scripts

As an example, execute a process that appends an inventory group <code>[tester]</code> to <code>/etc/ansible/hosts</code>.



```bash
vagrant@Ansible-Server:~$ sudo bash -c 'echo -e "[tester]
192.168.1.13" &gt;&gt; /etc/ansible/hosts'
vagrant@Ansible-Server:~$ cat /etc/ansible/hosts
[tester]
192.168.1.13
```

When running this command again, the identical block is written redundantly because no state verification is performed.



```bash
vagrant@Ansible-Server:~$ sudo bash -c 'echo -e "[tester]
192.168.1.13" &gt;&gt; /etc/ansible/hosts'
vagrant@Ansible-Server:~$ cat /etc/ansible/hosts
[tester]
192.168.1.13
[tester]
192.168.1.13
```

The existence of multiple identical section groups causes parse errors or unexpected pattern overrides in downstream parser processing, posing an operational risk.



## Implementing Declarative Block Management with Ansible

Ansible defines the desired "target state" and applies updates only when differences exist after comparing against the current state of the target node. When inserting and managing multi-line configuration blocks, use the <code>ansible.builtin.blockinfile</code> module.



### Playbook Definition (`./playbook/Ansible_vim.yml`)

```yaml
- name: Ansible_vim
  hosts: localhost
  gather_facts: true

  tasks:
    - name: Add ansible hosts
      ansible.builtin.blockinfile:
        path: /etc/ansible/hosts
        create: true
        mode: '0644'
        marker: "# {mark} ANSIBLE MANAGED BLOCK"
        block: |
          [tester]
          192.168.1.11
          192.168.1.12
          192.168.1.13
```

#### Role of Configuration Parameters

- `path`: Specifies the file path to update.
- `create`: Allows creating a new file if it does not exist.
- `mode`: Explicitly sets file permissions.
- `marker`: Specifies the delimiter string Ansible uses to identify the managed block (default is `# {mark} ANSIBLE MANAGED BLOCK`).
- `block`: Defines the configuration content to insert as a multi-line literal.

## Execution Verification and State Transition Check

### Initial Run (Applying Diffs)

Execute the Playbook when the specified block does not exist in the target file.



```text
vagrant@Ansible-Server:~$ sudo ansible-playbook ./playbook/Ansible_vim.yml

PLAY [Ansible_vim] *******************************************************************************************************************************************************

TASK [Gathering Facts] ***************************************************************************************************************************************************
ok: [localhost]

TASK [Add ansible hosts] *************************************************************************************************************************************************
changed: [localhost]

PLAY RECAP ***************************************************************************************************************************************************************
localhost                  : ok=2    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

Checking the file contents confirms that the block is inserted enclosed within marker tags.



```text
vagrant@Ansible-Server:~$ cat /etc/ansible/hosts
# BEGIN ANSIBLE MANAGED BLOCK
[tester]
192.168.1.11
192.168.1.12
192.168.1.13
# END ANSIBLE MANAGED BLOCK
```

### Second Run (Demonstrating Idempotency)

Re-run the exact same Playbook.



```text
vagrant@Ansible-Server:~$ sudo ansible-playbook ./playbook/Ansible_vim.yml

PLAY [Ansible_vim] *******************************************************************************************************************************************************

TASK [Gathering Facts] ***************************************************************************************************************************************************
ok: [localhost]

TASK [Add ansible hosts] *************************************************************************************************************************************************
ok: [localhost]

PLAY RECAP ***************************************************************************************************************************************************************
localhost                  : ok=2    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```

The task status becomes <code>ok</code> instead of <code>changed</code>, and <code>changed=0</code> is recorded in the <code>PLAY RECAP</code>. This confirms that Ansible compared the content inside the markers with the Playbook definition, detected no diffs, and skipped disk writes.



## Troubleshooting

### 1. Block Duplication Due to Manual Marker Modification

#### Symptom

If an operator manually edits or deletes <code># BEGIN ANSIBLE MANAGED BLOCK</code> or <code># END ANSIBLE MANAGED BLOCK</code> in the target file, Ansible determines that the managed block does not exist and appends a new managed block at the end, causing duplicate configuration.



#### Remediation Steps

- Do not modify marker lines manually; if changes are needed, centrally manage them by defining custom marker names using the `marker` parameter in the Playbook.
- If duplication occurs, purge the existing block once by specifying `state: absent` before re-applying.

```yaml
- name: Clean up corrupt block
  ansible.builtin.blockinfile:
    path: /etc/ansible/hosts
    marker: "# {mark} ANSIBLE MANAGED BLOCK"
    state: absent
```

### 2. File Access Permission and SELinux Context Denials

#### Symptom

A <code>Permission denied</code> error occurs if the Playbook execution user lacks write permissions to <code>/etc/ansible/hosts</code>, or if temporary file creation is blocked in an environment where SELinux is enabled.



#### Remediation Steps

- Specify `become: true` during Playbook execution to perform privilege escalation, or verify execution permissions.
- Verify that the SELinux context of the file is appropriate.

```bash
vagrant@Ansible-Server:~$ ls -lZ /etc/ansible/hosts
-rw-r--r--. 1 root root system_u:object_r:etc_t:s0 /etc/ansible/hosts
```

## Operational Notes

- It is recommended to use `ansible.builtin.lineinfile` for strict single-line management, and choose either `ansible.builtin.blockinfile` or `ansible.builtin.template` (Jinja2 templates) for cohesive section-level configuration blocks based on the specific use case.
- When integrating into CI/CD pipelines, incorporating dry-run executions with the `--check` flag to periodically verify that unexpected `changed` statuses do not occur enables early detection of configuration drift.
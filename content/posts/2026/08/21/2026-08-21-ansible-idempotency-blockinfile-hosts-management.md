---
title: "Ansible blockinfileによる冪等性の担保とシェルスクリプト運用における設定重複の回避"
slug: "ansible-idempotency-blockinfile-hosts-management"
date: 2026-08-21T10:06:02+09:00
draft: false
image: ""
description: "インフラ運用の自動化においてシェルスクリプト追記による重複障害を防ぎ、Ansibleのblockinfileモジュールを用いて状態管理と冪等性を担保する手法を検証ログとともに記録します。"
categories: ["DevOps Logistics"]
tags: ["ansible", "blockinfile", "idempotency", "bash", "configuration-management"]
author: "K-Life Hack"
---

インフラストラクチャの自動化において、シェルスクリプトによる命令型のアプローチを長期間運用し続けると、意図しない設定の二重追記や構文破壊といった構成ドリフト（Configuration Drift）が発生しやすくなります。特にノード数が増加する環境やCI/CDパイプラインによる定期実行環境では、実行回数に依存せず常に目標状態を同一に維持する「冪等性（Idempotency）」の担保が不可欠となります。本稿では、シェルコマンドによる追記処理とAnsibleの宣言的アプローチ（`ansible.builtin.blockinfile`モジュール）の挙動差を検証し、確実な設定ファイル管理を実現する設計を整理します。

## 冪等性の数理的定義と命令型スクリプトの破綻

冪等性とは、ある操作を1回適用した結果と、複数回適用した結果が常に等しくなる性質を指します。

$$f(f(x)) = f(x)$$

インフラ構成管理における命令型（Imperative）スクリプトでは、実行時の状態判定を行わずにリダイレクト演算子（`&gt;&gt;`）等でテキストを単純追加することが多く、これが非冪等な動作を引き起こします。

### シェルスクリプトによる重複発生の検証

例として、`/etc/ansible/hosts` に対してインベントリグループ `[tester]` を追記する処理を実行します。

```bash
vagrant@Ansible-Server:~$ sudo bash -c 'echo -e "[tester]
192.168.1.13" &gt;&gt; /etc/ansible/hosts'
vagrant@Ansible-Server:~$ cat /etc/ansible/hosts
[tester]
192.168.1.13
```

このコマンドを再度実行した場合、状態の検証が行われないため同一ブロックが重複して書き込まれます。

```bash
vagrant@Ansible-Server:~$ sudo bash -c 'echo -e "[tester]
192.168.1.13" &gt;&gt; /etc/ansible/hosts'
vagrant@Ansible-Server:~$ cat /etc/ansible/hosts
[tester]
192.168.1.13
[tester]
192.168.1.13
```

同一のセクショングループが複数存在することにより、後続のパーサー処理でパースエラーや予期せぬパターンの上書きが発生し、運用上のリスクとなります。

## Ansibleによる宣言的ブロック管理の実装

Ansibleは目的とする「最終状態」を定義し、ターゲットノードの現状と比較した上で差分がある場合のみ更新を適用します。複数行の設定ブロックを挿入・管理する場合、`ansible.builtin.blockinfile` モジュールを使用します。

### Playbook定義 (`./playbook/Ansible_vim.yml`)

```yaml
---
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

#### 設定パラメータの役割

- `path`: 更新対象のファイルパスを指定します。
- `create`: ファイルが存在しない場合に新規作成を許可します。
- `mode`: ファイルのパーミッションを明示的に固定します。
- `marker`: Ansibleが管理対象領域を識別するためのデリミタ文字列を指定します（デフォルトは `# {mark} ANSIBLE MANAGED BLOCK`）。
- `block`: 挿入する設定内容を複数行リテラルで定義します。

## 実行検証と状態遷移の確認

### 初回実行（差分適用）

対象ファイルに指定ブロックが存在しない状態でPlaybookを実行します。

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

ファイル内容を確認すると、マーカータグに囲まれた状態でブロックが挿入されます。

```text
vagrant@Ansible-Server:~$ cat /etc/ansible/hosts
# BEGIN ANSIBLE MANAGED BLOCK
[tester]
192.168.1.11
192.168.1.12
192.168.1.13
# END ANSIBLE MANAGED BLOCK
```

### 2回目実行（冪等性の実証）

全く同じPlaybookを再実行します。

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

タスクステータスは `changed` ではなく `ok` となり、`PLAY RECAP` においても `changed=0` と記録されます。Ansibleがマーカー内のコンテンツとPlaybookの定義を比較し、差分がないことを検知してディスク書き込みをスキップしたことが確認できます。

## Troubleshooting

### 1. マーカーの手動改変によるブロック重複

#### 発生事象

運用者が対象ファイル内の `# BEGIN ANSIBLE MANAGED BLOCK` や `# END ANSIBLE MANAGED BLOCK` を手作業で編集または削除した場合、Ansibleは管理ブロックが存在しないと判定し、末尾に新たな管理ブロックを追加して設定が重複します。

#### 対処手順

- マーカー行は手動で変更せず、変更が必要な場合はPlaybook側の `marker` パラメータでカスタムマーカー名を定義して一元管理します。
- 重複が発生した場合は、一度 `state: absent` を指定して既存ブロックをパージしてから再適用します。

```yaml
- name: Clean up corrupt block
  ansible.builtin.blockinfile:
    path: /etc/ansible/hosts
    marker: "# {mark} ANSIBLE MANAGED BLOCK"
    state: absent
```

### 2. ファイルアクセス権限およびSELinuxコンテキストの拒否

#### 発生事象
Playbookの実行ユーザーが `/etc/ansible/hosts` に対する書き込み権限を持たない場合、あるいはSELinuxが有効な環境でテンポラリファイルの作成がブロックされる場合に `Permission denied` エラーが発生します。

#### 対処手順

- Playbook実行時に `become: true` を指定して昇格を行うか、実行権限を確認します。
- ファイルのSELinuxコンテキストが適切か確認します。

```bash
vagrant@Ansible-Server:~$ ls -lZ /etc/ansible/hosts
-rw-r--r--. 1 root root system_u:object_r:etc_t:s0 /etc/ansible/hosts
```

## Operational Notes

- 単一行の厳密な管理には `ansible.builtin.lineinfile` を検討し、セクション単位のまとまった設定ブロックには `ansible.builtin.blockinfile` または `ansible.builtin.template`（Jinja2テンプレート）を適材適所で使い分ける構成が推奨されます。
- CI/CDパイプラインに組み込む際は、`--check` オプションを付与したDry-run実行を組み込み、想定外の `changed` が発生しないか定期的に検証することで、構成ドリフトを早期に検知可能です。
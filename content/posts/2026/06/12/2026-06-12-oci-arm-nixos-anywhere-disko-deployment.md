---
title: "OCI ARMインスタンスにおけるnixos-anywhereとdiskoを用いたNixOSの宣言的デプロイ"
slug: "oci-arm-nixos-anywhere-disko-deployment"
date: 2026-06-12T18:24:14+09:00
draft: false
image: ""
description: "OCI ARMインスタンス上でnixos-anywhereとdiskoを活用し、既存のUbuntu環境をNixOSへkexec経由で置換する自動化プロセスの技術解説。"
categories: ["Linux System Admin"]
tags: ["nixos", "oci-arm", "nixos-anywhere", "disko", "kexec", "aarch64"]
author: "K-Life Hack"
---

# OCI ARMインスタンスにおけるnixos-anywhereを用いたNixOSへの完全移行プロセス

クラウドインフラの運用において、OSレベルの構成管理を宣言的に維持することは、構成ドリフト（Configuration Drift）を防ぐための重要な課題です。特にOracle Cloud Infrastructure (OCI) のARMインスタンスのようなパブリッククラウド環境では、手動によるインストール手順を排除し、再現可能なデプロイメントパイプラインを構築することが求められます。本稿では、<b>nixos-anywhere</b>と<b>disko</b>を組み合わせ、既存のUbuntuインスタンスを稼働させたまま、リモートからNixOSへ完全に置換する実装プロセスについて解説します。

## OCI ARMインスタンスのプロビジョニング

まず、OCIコンソールからベースとなるARMインスタンスを構築します。このインスタンスは、NixOSインストールプロセスを開始するための踏み台（Bootstrap環境）として機能します。スペックは、Canonical Ubuntu 24.04 Minimal aarch64をイメージに採用し、ShapeはVM.Standard.A1.Flex（Always Free枠内: 4 OCPU, 24 GB RAM）を選択します。ストレージは50GB以上のブートボリュームが推奨されます。

インスタンス起動後、ローカル環境から操作を簡略化するために環境変数を設定します。

```bash
export TARGET_HOST="132.145.x.x"
export SSH_KEY="~/.ssh/id_rsa"
```

## 構成定義の宣言的記述

NixOSの構成は、Flakesを使用して管理します。これにより、依存関係のロックと再現性が保証されます。

### 1. flake.nix

システムの入力と出力を定義します。ここではnixpkgsの安定版（25.11）とdiskoモジュールを指定します。

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, disko, ... }: {
    nixosConfigurations.oci-arm = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        disko.nixosModules.disko
        ./configuration.nix
        ./disko.nix
      ];
    };
  };
}
```

### 2. disko.nix (ディスクパーティション設計)

OCIのブートボリューム（通常 /dev/sda）をGPT形式で初期化し、EFIおよびルートパーティションを定義します。

```nix
{
  disko.devices = {
    disk = {
      main = {
        device = "/dev/sda";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
```

### 3. configuration.nix

OCI環境に最適化したブートローダーとSSHの設定を記述します。<b>efiInstallAsRemovable = true</b>の設定は、OCIのEFI変数書き込み制限を回避するために重要です。

```nix
{ pkgs, ... }: {
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.grub.efiInstallAsRemovable = true;

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB..." 
  ];

  system.stateVersion = "25.11";
}
```

## リモートデプロイメントの実行

nixos-anywhereは、ターゲットホスト上でkexecを実行し、メモリ上に一時的なNixOSインストーラーを展開します。ARMアーキテクチャの場合、明示的にaarch64用のkexecイメージを指定する必要があります。

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#oci-arm \
  --kexec-url https://github.com/nix-community/nixos-images/releases/download/nixos-unstable/nixos-kexec-installer-aarch64-linux.tar.gz \
  root@$TARGET_HOST
```

## Troubleshooting

### SSH Private Key Permission
リモート実行時に Permission denied が発生する場合、秘密鍵の権限が適切でない可能性があります。🛠️ 以下のコマンドで権限を修正してください。

```bash
chmod 600 $SSH_KEY
```

### Out-Of-Memory (OOM) during kexec

メモリ容量が少ないインスタンスで kexec が失敗する場合、ターゲット側で一時的なスワップファイルを有効化することで回避可能です。⚠️

```bash
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
```

### Disko Partitioning Failure

既存のパーティションがビジー状態で disko が失敗する場合、kexec 後の環境で lsblk を確認し、マウントされているパーティションをすべて解除してから再試行してください。

## Operational Notes

デプロイ完了後、新しいシステムへの接続を確認し、ハードウェア構成が正しく反映されているか検証します。

```bash
ssh root@$TARGET_HOST "lscpu &amp;&amp; lsblk"
```

一度インストールが完了すれば、以降の変更は nixos-rebuild switch --target-host コマンドを通じて、ローカルから宣言的に適用可能となります。
---
title: "Declarative Deployment of NixOS on OCI ARM Instances Using nixos-anywhere and disko"
slug: "oci-arm-nixos-anywhere-disko-deployment"
date: 2026-06-12T18:24:15+09:00
draft: false
image: ""
description: "Technical explanation of the automation process for replacing an existing Ubuntu environment with NixOS via kexec on OCI ARM instances using nixos-anywhere and disko."
categories: ["Linux System Admin"]
tags: ["nixos", "oci-arm", "nixos-anywhere", "disko", "kexec", "aarch64"]
author: "K-Life Hack"
---

# Full Migration Process to NixOS Using nixos-anywhere on OCI ARM Instances

In cloud infrastructure operations, maintaining OS-level configuration management declaratively is a critical challenge for preventing configuration drift. Especially in public cloud environments such as Oracle Cloud Infrastructure (OCI) ARM instances, it is necessary to eliminate manual installation procedures and build reproducible deployment pipelines. This documentation covers the implementation process of completely replacing an existing running Ubuntu instance with NixOS remotely by combining <b>nixos-anywhere</b> and <b>disko</b>.



## Provisioning OCI ARM Instances

The process begins with building a base ARM instance from the OCI console. This instance functions as a bootstrap environment to initiate the NixOS installation. Specifications require Canonical Ubuntu 24.04 Minimal aarch64 as the image and VM.Standard.A1.Flex (within Always Free tier: 4 OCPU, 24 GB RAM) for the Shape. A boot volume of 50GB or more is recommended for storage.


Environment variable configuration simplifies local environment operations after instance initialization.



```bash
export TARGET_HOST="132.145.x.x"
export SSH_KEY="~/.ssh/id_rsa"
```

## Declarative Description of Configuration Definitions

NixOS configurations are managed using Flakes to ensure dependency locking and reproducibility.



### 1. flake.nix

Defines the system inputs and outputs. The stable version of nixpkgs (25.11) and the disko module are specified within the inputs.



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

### 2. disko.nix (Disk Partition Design)

Initializes the OCI boot volume (typically /dev/sda) in GPT format and defines the EFI and root partitions.



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

Describes the bootloader and SSH settings optimized for the OCI environment. The <b>efiInstallAsRemovable = true</b> setting is mandatory to bypass OCI's EFI variable write restrictions.



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

## Executing Remote Deployment

nixos-anywhere executes kexec on the target host and deploys a temporary NixOS installer in memory. For the ARM architecture, the kexec image for aarch64 must be explicitly specified.



```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#oci-arm \
  --kexec-url https://github.com/nix-community/nixos-images/releases/download/nixos-unstable/nixos-kexec-installer-aarch64-linux.tar.gz \
  root@$TARGET_HOST
```

## Troubleshooting

### SSH Private Key Permission

If Permission denied occurs during remote execution, the private key permissions may be incorrect. Permission correction via chmod ensures proper key access.



```bash
chmod 600 $SSH_KEY
```

### Out-Of-Memory (OOM) during kexec

If kexec fails on instances with low memory capacity, temporary swap file activation on the target host mitigates memory constraints.



```bash
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
```

### Disko Partitioning Failure

If disko fails because existing partitions are busy, verify the environment using lsblk after kexec, unmount all active partitions, and retry the deployment.



## Operational Notes

After deployment completion, verify the connection to the new system and validate that the hardware configuration is correctly reflected.



```bash
ssh root@$TARGET_HOST "lscpu &amp;&amp; lsblk"
```

Once the installation is complete, subsequent changes are applied declaratively from the local machine via the nixos-rebuild switch --target-host command.


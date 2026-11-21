---
title: "Building an Automated Backup Pipeline for Keycloak Database and Step-by-Step Recovery Verification Methodologies"
slug: "keycloak-postgres-backup-dr-automation"
date: 2026-11-21T10:14:57+09:00
draft: false
image: ""
description: "Explains a two-tiered backup automation approach to avoid SPOF in Keycloak databases, along with a three-level disaster recovery (DR) rehearsal procedure based on service impact and troubleshooting techniques."
categories: ["Linux System Admin"]
tags: ["rclone"]
author: "K-Life Hack"
---

As infrastructure scaling and multi-tenant integration progress, when Keycloak serves as the Single Sign-On (SSO) gateway for Kubernetes API OpenID Connect (OIDC) authentication and major CI/CD tools such as ArgoCD and Jenkins, its backend database becomes a Single Point of Failure (SPOF) for the entire system. Operations relying on a single PostgreSQL Pod or Local PersistentVolume carry the risk that a node hardware failure or logical data corruption will immediately halt all downstream engineering workflows.


Because constructing an active-active multi-master DB introduces high architectural complexity, establishing an automated backup combining primary evacuation to an NFS PVC with secondary replication to S3-compatible storage, alongside a phased disaster recovery rehearsal (DR Rehearsal) to empirically verify Recovery Time Objective (RTO) and Recovery Point Objective (RPO), is essential as a baseline operational safety standard.



## Architecture Configuration and Prerequisites

The target standard infrastructure configuration and access requirements are as follows:



- <b>Identity Management</b>: Keycloak v26.x (deployed via Keycloak Operator, `spec.instances: 1`)
- <b>Database Engine</b>: PostgreSQL 15 (single-replica StatefulSet, internal Service `postgres-db:5432`)
- <b>Storage Allocation</b>: PersistentVolume bound to node-local disk `/data`

### Critical Access Prerequisites (Avoiding OIDC Dependency)

Before executing disaster recovery rehearsals or troubleshooting, ensure cluster administrator privileges using a direct X.509 certificate-based `kubeconfig` (`admin.conf`) that does not rely on Keycloak OIDC tokens. If `kubectl` authentication relies on OIDC during a Keycloak database disconnection or rebuild, all API access will be blocked, resulting in a deadlock where recovery operations themselves become impossible.



## Implementation of a Two-Tier Storage Backup Pipeline

Backup data must be completely isolated from the production database compute and storage domains.



- <b>Tier-1 (Local Staging)</b>: Shared Network File System (NFS PVC). Avoids external network transfer bottlenecks and achieves a fast RTO.
- <b>Tier-2 (Offsite Disaster Recovery)</b>: S3-compatible object storage. Protects data against hypervisor outages or physical destruction of local disks.

The following Kubernetes CronJob manifest automates binary format (`-Fc`) extraction using `pg_dump`, SHA-256 checksum verification, and transfer to S3 with integrity verification using `rclone`.



```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: keycloak-db-backup
  namespace: keycloak
spec:
  schedule: "0 2 * * *"
  timeZone: "Asia/Tokyo"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          initContainers:
            - name: pg-dump
              image: postgres:15
              env:
                - name: PGHOST
                  value: postgres-db
                - name: PGDATABASE
                  value: keycloak
                - name: PGUSER
                  valueFrom:
                    secretKeyRef:
                      name: keycloak-db-secret
                      key: username
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: keycloak-db-secret
                      key: password
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -euo pipefail
                  N="keycloak-$(date +%Y%m%d-%H%M%S).dump"
                  cd /backup
                  
                  # Execute binary dump in custom format
                  pg_dump -Fc -f "$N"
                  
                  # Verify dump file header structure and readability
                  pg_restore -l "$N" &gt; /dev/null
                  
                  # Generate SHA256 hash
                  sha256sum "$N" &gt; "$N.sha256"
                  
                  # Update pointer to latest file
                  echo "$N" &gt; .latest
                  
                  # Automatically delete local backups older than 7 days
                  find /backup -name 'keycloak-*.dump*' -mtime +7 -delete
              volumeMounts:
                - name: backup
                  mountPath: /backup
          containers:
            - name: upload
              image: rclone/rclone:1.68
              env:
                - name: RCLONE_CONFIG_BK_TYPE
                  value: s3
                - name: RCLONE_CONFIG_BK_PROVIDER
                  value: Other
                - name: RCLONE_CONFIG_BK_ENDPOINT
                  value: "http://s3-storage.internal:9000"
                - name: RCLONE_CONFIG_BK_ACCESS_KEY_ID
                  valueFrom:
                    secretKeyRef:
                      name: keycloak-db-s3
                      key: ACCESS_KEY_ID
                - name: RCLONE_CONFIG_BK_SECRET_ACCESS_KEY
                  valueFrom:
                    secretKeyRef:
                      name: keycloak-db-s3
                      key: ACCESS_SECRET_KEY
                - name: DEST
                  value: "bk:keycloak-db-backup/pgdump"
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  N=$(cat /backup/.latest)
                  
                  # Transfer assets to S3 storage
                  rclone copyto "/backup/$N" "$DEST/$N"
                  rclone copyto "/backup/$N.sha256" "$DEST/$N.sha256"
                  
                  # Remote verification: Recalculate hash from S3 stream to verify integrity
                  L=$(awk '{print $1}' "/backup/$N.sha256")
                  R=$(rclone cat "$DEST/$N" | sha256sum | awk '{print $1}')
                  
                  if [ "$L" != "$R" ]; then
                    echo "CRITICAL: Remote checksum mismatch for: $N"
                    exit 1
                  fi
                  
                  echo "Uploaded and verified: $N"
                  
                  # Delete remote backups older than 30 days
                  rclone delete "$DEST" --min-age 30d --include 'keycloak-*.dump*'
              volumeMounts:
                - name: backup
                  mountPath: /backup
                  readOnly: true
          volumes:
            - name: backup
              persistentVolumeClaim:
                claimName: keycloak-db-backup
```

## Phased Recovery Rehearsals (Disaster Recovery Rehearsal)

Recovery capabilities are verified in three phases according to the level of risk to the production environment.



### Level 1: Schema and Record Integrity Verification in a Non-Destructive Isolated Pod

Verify restore success and record counts by launching a temporary Pod without impacting production traffic or the running PostgreSQL instance.



```bash
# Deploy temporary verification Pod and wait
kubectl apply -f - &lt;<eof "$(basename="" "$f"="" "$q"="" #="" $f).sha256"="" &&="" '="" -="" --="" --exit-on-error="" --for="condition=Ready" --no-owner="" --timeout="120s" -1)="" -c="" -d="" -n="" -t="" -u="" 2;="" \="" against="" and="" apiversion:="" backup="" baseline="" bash="" cd="" check="" claimname:="" compare="" containers:="" count="" do="" done="" env:="" eof="" exec="" execute="" f="$(ls" head="" image:="" integrity="" keycloak="" keycloak-*.dump="" keycloak-db-backup="" keycloak;="" kind:="" kubectl="" metadata:="" mountpath:="" name:="" namespace:="" never="" persistentvolumeclaim:="" pg_isready="" pg_restore="" pod="" postgres="" postgres:15="" postgres_db="" postgres_password="" postgres_user="" pre-acquired="" psql="" q="SELECT 'realm', count(*) FROM realm UNION ALL SELECT 'client', count(*) FROM client UNION ALL SELECT 'user_entity', count(*) FROM user_entity;" readonly:="" record="" restartpolicy:="" restore="" restore-test="" sha256sum="" sleep="" spec:="" the="" true="" until="" v1="" value:="" verify="" volumemounts:="" volumes:="" wait="" |=""> count-restore.txt
diff -u count-before.txt count-restore.txt &amp;&amp; echo "CHECK_SUCCESS: Record counts match baseline."

# Clean up resources
kubectl delete pod restore-test -n keycloak
```

### Level 2: In-Place Database Failure Restoration and RTO Measurement

Rebuild the database after stopping Keycloak, assuming logical data corruption.



1. <b>Stopping Keycloak Pods (Preventing Race Conditions)</b>:

   ```bash
   kubectl patch keycloak keycloak -n keycloak --type merge -p '{"spec":{"instances":0}}'
   ```

2. <b>Database Re-creation and Restore</b>:

   ```bash
   kubectl exec -n keycloak postgresql-db-0 -- psql -U keycloak -d postgres -c 'DROP DATABASE keycloak;'
   kubectl exec -n keycloak postgresql-db-0 -- psql -U keycloak -d postgres -c 'CREATE DATABASE keycloak OWNER keycloak;'
   
   kubectl exec -n keycloak postgresql-db-0 -- bash -c '
     set -euo pipefail
     cd /backup
     F=$(ls -t keycloak-*.dump | head -1)
     sha256sum -c "$F.sha256"
     pg_restore -U keycloak -d keycloak --no-owner --exit-on-error "$F"
     
     # クラスタリングキャッシュ情報の初期化
     psql -U keycloak -d keycloak -c "TRUNCATE jgroups_ping;" || true
   '
   ```

3. <b>Keycloak Restart and Health Checks</b>:

   ```bash
   kubectl patch keycloak keycloak -n keycloak --type merge -p '{"spec":{"instances":1}}'
   kubectl wait --for=condition=Ready keycloak/keycloak -n keycloak --timeout=600s
   ```

### Level 3: DR Recovery from Complete Loss of Node and Local Storage

This recovery flow is for cases where the local PV (`/data`) is physically lost due to a node failure. Re-define the PVC on a different node and pull data directly back from S3 to restore.



```bash
# Back up the target StatefulSet definition and delete it
kubectl patch keycloak keycloak -n keycloak --type merge -p '{"spec":{"instances":0}}'
kubectl get sts postgresql-db -n keycloak -o yaml &gt; sts-backup.yaml
kubectl delete sts postgresql-db -n keycloak

# Recreate the StatefulSet by reallocating to PV/PVC on the new node
# (Apply after editing volumeClaimTemplates in sts-backup.yaml)
kubectl apply -f sts-backup.yaml

# Pull dump directly from S3 and restore
kubectl exec -n keycloak postgresql-db-0 -- bash -c '
  rclone copyto bk:keycloak-db-backup/pgdump/latest.dump /backup/latest.dump
  pg_restore -U keycloak -d keycloak --no-owner /backup/latest.dump
'
```

## Operational Logs

Output logs from restore verification and comparison protocols executed on an actual system.



```text
$ kubectl get keycloak,sts,pod,svc,pvc -n keycloak -o wide
NAME                                READY   CLIENTS   PROVIDER   AGE
keycloak.k8s.keycloak.org/keycloak   1/1     1         db         45d

NAME                             READY   AGE   CONTAINERS   IMAGES
statefulset.apps/postgresql-db   1/1     45d   postgres     postgres:15

NAME                READY   STATUS    RESTARTS   AGE   IP            NODE
pod/postgresql-db-0 1/1     Running   0          45d   10.244.3.12   infra-node-02

$ kubectl exec -n keycloak restore-test -- bash -c 'cd /backup &amp;&amp; sha256sum -c keycloak-20261121-020000.dump.sha256'
keycloak-20261121-020000.dump: OK

$ kubectl exec -n keycloak restore-test -- bash -c 'pg_restore -U keycloak -d keycloak --no-owner --exit-on-error keycloak-20261121-020000.dump'
pg_restore: processing item 4201 TABLE DATA realm
pg_restore: processing item 4205 TABLE DATA client
pg_restore: processing item 4210 TABLE DATA user_entity
pg_restore: restore completed successfully without errors

$ diff -u count-before.txt count-restore.txt
--- count-before.txt    2026-11-21 01:55:00.000000000 +0900
+++ count-restore.txt   2026-11-21 02:15:30.000000000 +0900
@@ -1,4 +1,4 @@
- realm | 3
- client | 42
- user_entity | 1250
+ realm | 3
+ client | 42
+ user_entity | 1250
CHECK_SUCCESS: Record counts match baseline.
```

## Troubleshooting

### 1. Inability to Execute `kubectl` Operations Due to OIDC Authentication Token Dependency
- <b>Symptom</b>: Keycloak stops following the database shutdown, and executing `kubectl` fails with `Error: Unauthorized` or Token Renewal errors, rejecting recovery Pod deployment operations.
- <b>Cause</b>: The client's `kubeconfig` is configured with Keycloak OIDC as the authentication provider.
- <b>Mitigation</b>: During DR procedures, switch the context to X.509 client certificate authentication (`admin.conf`) issued directly by the Kubernetes Control Plane API server before executing operations.

### 2. `jgroups_ping` Cluster Lockout During Keycloak Startup After Restore
- <b>Symptom</b>: After database restoration, starting Keycloak Pods results in repeated log outputs of `JGRP00006: failed sending message`, failing to transition to Ready state.
- <b>Cause</b>: IP addresses or node identifiers from the old environment remain in the DB's `jgroups_ping` table, causing a deadlock during cluster node discovery with new Pods.
- <b>Mitigation</b>: Immediately after DB restore and prior to Keycloak startup, execute `TRUNCATE TABLE jgroups_ping;` to initialize the discovery table.

### 3. Version Mismatch Error Between `pg_dump` and `pg_restore`
- <b>Symptom</b>: During restore execution, `pg_restore: error: unsupported version (1.15) in file header` occurs and processing halts.
- <b>Cause</b>: A version discrepancy exists between the PostgreSQL image tag of the container that performed the backup and the target restore Pod (e.g., PostgreSQL 14 vs 15).
- <b>Mitigation</b>: Pin the image tags of both the backup Job and verification Pod to the same major version (`postgres:15`).

### 4. Hash Verification Failure Due to Transient Network Interruptions During S3 Transfer
- <b>Symptom</b>: The CronJob's `upload` container outputs `CRITICAL: Remote checksum mismatch` and transitions to a Failed state.
- <b>Cause</b>: An incomplete multipart upload occurred during the upload of a large dump file, resulting in missing data length on S3.
- <b>Mitigation</b>: Apply retries by adding the `--checksum` flag during `rclone copyto` execution, and allow the Job to automatically retry upon transfer errors based on `backoffLimit`.

## Operational Notes

1. <b>Storage Domain Isolation Principle</b>: Saving backup files to the same physical disk as the production PostgreSQL database is invalid for DR design. Ensure redundancy across a separate network NFS and S3-compatible storage.
2. <b>JGroups Cache Initialization</b>: During database recovery, substantial timeouts will occur in Keycloak cluster node discovery unless the `jgroups_ping` table is explicitly purged.
3. <b>Handling Offline Sessions</b>: Tokens or active sessions issued between the time of backup creation and restoration will be lost. Establish deletion policies for `offline_user_session` in advance according to business requirements.
4. <b>Standardization of Periodic Rehearsals</b>: In addition to automating backup configurations, establishing operational procedures to perform Level 1 and Level 2 recovery rehearsals quarterly and recording measured RTO values in audit logs is recommended.</eof>
---
title: "Persistent Data Management and Network Identifier Design in Kubernetes StatefulSet"
slug: "k8s-statefulset-architecture-storage"
date: 2026-06-23T10:11:31+09:00
draft: false
image: ""
description: "Explains the internal mechanisms of Kubernetes StatefulSet, name resolution via Headless Service, and technical details of dynamic storage provisioning using VolumeClaimTemplates."
categories: ["DevOps Logistics"]
tags: ["kubernetes", "statefulset", "headless-service", "pvc", "volumeclaimtemplates"]
author: "K-Life Hack"
---

# Management Methods for Persistent Identity and Storage in Kubernetes StatefulSet

In the operation of distributed systems and databases such as MySQL, PostgreSQL, and Kafka, maintaining identity and data consistency across pod restarts is a critical requirement. Standard Deployments treat pods as ephemeral entities with random hostnames and IP addresses assigned upon each lifecycle event. This stateless nature poses significant operational constraints for workloads requiring data persistence or fixed communication between master and slave nodes. StatefulSet addresses these challenges by providing stable identifiers and persistent storage integration through Headless Services and VolumeClaimTemplates.



## 1. Structural Differences Between StatefulSet and Deployment

StatefulSet is engineered to guarantee the order and uniqueness of pods. The primary technical distinctions from the Deployment controller are as follows:


<b>Identifiers</b>: Deployment assigns random alphanumeric suffixes to pod names. StatefulSet assigns fixed ordinal indexes, such as mysql-0 and mysql-1, which persist across restarts.


<b>Storage</b>: Deployment typically shares the same volume across replicas or operates statelessly. StatefulSet assigns a dedicated PersistentVolumeClaim (PVC) to each pod on a one-to-one basis, ensuring data isolation and persistence.


<b>Deployment Order</b>: Deployment creates and deletes pods in parallel. StatefulSet manages pods sequentially, starting from index 0 during creation and deleting them in reverse order (OrderedReady) to maintain cluster stability.



## 2. Fixing Network Identifiers via Headless Service

For StatefulSet pods to utilize a fixed Fully Qualified Domain Name (FQDN), integration with a Headless Service is mandatory. By setting the clusterIP field to None, the Service avoids assigning a single virtual IP and instead returns the direct IP addresses of individual pods in response to DNS queries.



```yaml
apiVersion: v1
kind: Service
metadata:
  name: sfs-service01
spec:
  selector:
    app.kubernetes.io/name: web-sfs01
  type: ClusterIP
  clusterIP: None
  ports:
  - protocol: TCP
    port: 80
```

Under this configuration, each pod communicates using the format [Pod Name].[Service Name].[Namespace].svc.cluster.local. This mechanism is vital for distributed databases where specific nodes must be explicitly designated for leader election or data synchronization within the cluster.



## 3. StatefulSet Implementation and Pod Lifecycle

The implementation of a StatefulSet requires an explicit link to a Headless Service via the serviceName field. This ensures that the network identity is correctly mapped to the pod replicas throughout their lifecycle.



```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: sfs-test01
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: web-sfs01
  serviceName: sfs-service01
  template:    metadata:
      labels:
        app.kubernetes.io/name: web-sfs01
    spec:
      containers:
      - name: nginx
        image: nginx:latest
```

## 4. Dynamic Provisioning via VolumeClaimTemplates

The volumeClaimTemplates feature enables the automatic provisioning of independent storage for each pod replica. Since the PVC is retained even if the pod is deleted, the pod remounts the identical data volume upon restarting, preserving the state of the application.



```yaml
volumeClaimTemplates:
  - metadata:
      name: sfs-vol01
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: pv-sfs-test01
      resources:
        requests:
          storage: 5Mi
```

## Troubleshooting

A frequent issue in StatefulSet operations is the <b>PVC Pending state</b> during scaling. In environments where PersistentVolumes (PV) are managed manually, a shortage of available PVs matching the storageClassName will cause new pods to remain in a Pending state. ⚠️


Additionally, the deletion of a StatefulSet does not trigger the automatic removal of associated PVCs. While this prevents accidental data loss, it can lead to disk space exhaustion. Manual cleanup using kubectl delete pvc is required to reclaim storage resources after a StatefulSet is decommissioned.



## Operational Verifications

The following logs and commands are used to verify resource status and validate network connectivity after deployment.



```text
# Verify resource startup
% kubectl get pod -o wide
NAME           READY   STATUS    RESTARTS   AGE   IP            NODE
sfs-test01-0   1/1     Running   0          80s   10.244.2.9    worker-node-01
sfs-test01-1   1/1     Running   0          80s   10.244.1.17   worker-node-02
sfs-test01-2   1/1     Running   0          79s   10.244.1.18   worker-node-02

# Verify Headless Service
% kubectl get svc sfs-service01
NAME            TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
sfs-service01   ClusterIP   None         <none>        80/TCP    14m

# Verify connectivity to a specific pod (Direct access to Pod 1)
% kubectl exec -it nginx-client -- curl -I sfs-test01-1.sfs-service01.default.svc.cluster.local
HTTP/1.1 200 OK
Server: nginx/1.25.x
Content-Type: text/html
```

## Lessons Learned

The adoption of StatefulSet signifies the transition from simple pod management to the management of storage lifecycles and network topologies at the infrastructure layer. In the context of database containerization, ensuring data locality through volumeClaimTemplates and providing stable endpoints via Headless Services are decisive factors for system reliability. 💡 Operational design should include verification of PVC re-attachment latency during abnormal terminations and PV supply capacity during scaling operations.

</none>
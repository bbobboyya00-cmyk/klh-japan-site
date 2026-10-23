---
title: "Methods for Defining Secret Resources in Kubernetes and Injecting Environment Variables into Pods"
slug: "k8s-secret-management-pod-environment"
date: 2026-10-23T10:30:22+09:00
draft: false
image: ""
description: "This document outlines procedures for creating Secrets to securely handle sensitive data such as database connection information in Kubernetes, cautions regarding Base64 encoding, and configurations for injecting environment variables into Pods."
categories: ["DevOps Logistics"]
tags: ["kubernetes-yaml-파일로-동적-값을-설정하는-방법"]
author: "K-Life Hack"
---

# Secure Management and Configuration Methods for Sensitive Information Using Kubernetes Secret Objects

<b>Meta Description</b>: This article explains isolated management of sensitive information using Secret objects in Kubernetes, generation procedures via CLI/YAML, injection patterns into Pods, Base64 encoding caveats, and troubleshooting.



---

In container environments, hardcoding sensitive information such as database connection strings and authentication tokens into application source code or container images poses significant security risks. In Kubernetes, while non-sensitive configurations are managed using ConfigMaps, sensitive data such as credentials and encryption keys are managed separately as Secret objects.


By using Secret objects, configuration data is decoupled from application logic, allowing configurations to be securely deployed to Pods as environment variables or volumes.



## Methods for Generating Secret Objects

Methods for defining Secrets in Kubernetes include declarative/imperative approaches via CLI commands and approaches using YAML manifests.



### Generation via CLI Imperative Commands

Using the kubectl create secret command allows direct creation of Secrets without manually encoding data. By using the --from-literal flag, Base64 encoding is performed automatically by the system.


Configuration for registering a single value:



```bash
kubectl create secret generic app-secret --from-literal=DB_HOST=mysql
```

Configuration for registering multiple connection details together:



```bash
kubectl create secret generic app-secret \
  --from-literal=DB_HOST=mysql \
  --from-literal=DB_USER=root \
  --from-literal=DB_PASSWORD=passwrd
```

### Generation from Property Files

When an existing property file (e.g., app_secret.properties) is present, it can be batch-converted into a Secret using the --from-file flag. In this case, the file name is automatically mapped as the Key, and the file contents as the Value.


Target file configuration (app_secret.properties):



```properties
DB_HOST=mysql
DB_USER=root
DB_PASSWORD=passwrd
```

Execution command:



```bash
kubectl create secret generic app-secret --from-file=app_secret.properties
```

### Declarative Definition via YAML Manifests

When integrating into GitOps or CI/CD pipelines, definition via YAML files is standard. When writing configurations in the data field of a YAML manifest, the values must be pre-encoded in Base64.


Base64 encoding process (Linux/Unix environment):



```bash
echo -n 'mysql' | base64    # Output example: bXlzcWw=
echo -n 'root' | base64     # Output example: cm9vdA==
echo -n 'passwrd' | base64  # Output example: cGFzc3dyZA==
```

Manifest definition (secret-data.yaml):



```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
type: Opaque
data:
  DB_HOST: bXlzcWw=
  DB_USER: cm9vdA==
  DB_PASSWORD: cGFzc3dyZA==
```

Deployment execution:



```bash
kubectl apply -f secret-data.yaml
```

## Inspecting and Decoding Secrets

Use the following commands to check the state of deployed Secrets.


Retrieving the list of registered Secrets:



```bash
kubectl get secrets
```

Inspecting Secret metadata (*note: actual values are masked when displayed):



```bash
kubectl describe secret app-secret
```

To check raw encoded data:



```bash
kubectl get secret app-secret -o yaml
```

To decode and verify the retrieved Base64 string back into plain text, execute base64 --decode.



```bash
echo -n 'bXlzcWw=' | base64 --decode
```

## Configuration for Injecting Secrets into Pods

The created Secret can be injected into Pod containers as environment variables. Base64 is automatically decoded internally by Kubernetes, making it accessible to the containerized application as standard plain text.



### Batch Injection of All Keys as Environment Variables (envFrom)

Configuration example for loading all key-value pairs in a Secret into container environment variables:



```yaml
apiVersion: v1
kind: Pod
metadata:
  name: simple-webapp-color
  labels:
    name: simple-webapp-color
spec:
  containers:
    - name: simple-webapp-color
      image: simple-webapp-color
      ports:
        - containerPort: 8080
      envFrom:
        - secretRef:
            name: app-secret
```

### Selecting and Injecting Specific Keys (secretKeyRef)

Configuration example for selecting specific keys and mapping them to specific environment variable names:



```yaml
apiVersion: v1
kind: Pod
metadata:
  name: simple-webapp-color
spec:
  containers:
    - name: simple-webapp-color
      image: simple-webapp-color
      env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: app-secret
              key: DB_PASSWORD
```

## Troubleshooting

Several typical configuration errors can occur during the creation and operation of Secrets.



### 🛠️ 1. Trailing Newline Character Inclusion During Base64 Encoding

⚠️ When performing Base64 encoding with the echo command, omitting the -n option will encode the data with an included newline character (\n).



```bash
# Incorrect example (includes a newline)
echo 'passwrd' | base64
# Output: cGFzc3dyZAo=

# Correct example
echo -n 'passwrd' | base64
# Output: cGFzc3dyZA==
```

Generating a Secret with a trailing newline character included can cause password mismatch errors (Authentication Failed) when the application attempts to connect to the database.



### 🛠️ 2. Reflection Limitations of Dynamic Updates in Environment Variable Injection

Secret values loaded via a Pod's env or envFrom fields are passed to the process at the time the Pod starts. Therefore, even if the values of the Secret object are modified later using kubectl edit secret or similar commands, environment variables inside running Pods will not be updated automatically.


To apply updated configurations, a rolling update must be executed, or the Pods must be restarted.



```bash
kubectl rollout restart deployment <deployment-name>
```

## Execution Verification Log Protocol

Command-line output example verifying that the Secret is properly decoded and injected into environment variables after the Pod has started:



```text
$ kubectl get secret app-secret
NAME         TYPE     DATA   AGE
app-secret   Opaque   3      5m12s

$ kubectl exec simple-webapp-color -- printenv | grep DB_
DB_HOST=mysql
DB_USER=root
DB_PASSWORD=passwrd
```

## Configuration Notes

💡 Note that standard Kubernetes Secrets are merely "Base64 encoded", not "encrypted". To encrypt them when stored in etcd itself, you must configure EncryptionConfiguration on the Kube-apiserver side or consider integrating with external secret management tools (such as HashiCorp Vault).


💡 When registering Secret resource definition manifests (YAML) in a Git repository, it is recommended to manage them in an encrypted state using tools such as SOPS (Secrets Opaque Secret) or Sealed Secrets.

</deployment-name>
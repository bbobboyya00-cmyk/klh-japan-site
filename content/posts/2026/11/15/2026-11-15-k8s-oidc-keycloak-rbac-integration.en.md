---
title: "Kubernetes OIDC Authentication and RBAC Integration Design via Keycloak Identity Broker"
slug: "k8s-oidc-keycloak-rbac-integration"
date: 2026-11-15T11:52:04+09:00
draft: false
image: ""
description: "This document details the design procedures and troubleshooting steps for configuring Keycloak as an OIDC identity broker to decouple direct binding to the Kubernetes API server while establishing fine-grained RBAC based on group claims."
categories: ["Backend Architecture"]
tags: ["jwt-authentication-filter"]
author: "K-Life Hack"
---

In Kubernetes cluster operations, organizational growth demands single sign-on (SSO) integration between <code>kubectl</code> and multiple existing Identity Providers (such as Azure AD or Authentik). However, architectures that directly bind the <code>kube-apiserver</code> of each control plane to an upstream IdP cause IdP schema changes or tenant migrations to directly trigger reconfigurations across all clusters, leading to configuration sprawl and increased operational overhead.


To address this issue, an architecture is established that introduces Keycloak as an intermediate OpenID Connect (OIDC) identity broker, decoupling the authentication infrastructure from the control plane. This article outlines the procedure from configuring <code>kube-apiserver</code> OIDC flags to transparent group claim parsing, applying fine-grained RBAC policies, and verification steps.



## 1. Control Plane kube-apiserver OIDC Integration Configuration

To validate JWT tokens on the Kubernetes API server, add the OIDC authentication parameters to <code>/etc/kubernetes/manifests/kube-apiserver.yaml</code> on all control plane nodes. Updating the static Pod manifest will automatically restart the <code>kube-apiserver</code> Pod.



```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --oidc-issuer-url=https://keycloak.example.local/realms/kubernetes
    - --oidc-client-id=kubernetes
    - --oidc-username-claim=preferred_username
    - --oidc-groups-claim=groups
    - --oidc-ca-file=/etc/kubernetes/pki/keycloak-ca.crt
```

If Keycloak is operated under an internal private Certificate Authority (CA), the corresponding CA certificate must be placed at <code>/etc/kubernetes/pki/keycloak-ca.crt</code> on all control plane nodes. If the certificate path is incorrect, the <code>kube-apiserver</code> initialization process will halt.



## 2. Upstream Group Claim Propagation Configuration

To prevent manual dual management of user groups in Keycloak, group information issued by the upstream IdP is passed directly through to the JWT. Configuration must be synchronized across three layers.



### Layer 1: Upstream IdP Group Serialization (Authentik Example)

Define a custom scope expression on the upstream IdP to sanitize group attributes into a comma-separated string or array format.



```python
return ",".join([group.name for group in request.user.ak_groups.all()])
```

### Layer 2: Keycloak Identity Provider Scope Configuration

In the Keycloak Admin Console, navigate to <code>Identity Providers</code> -&gt; select the relevant Provider -&gt; <code>Advanced Settings</code> -&gt; <code>Scopes</code> and specify the following:



```text
profile email groups
```

### Layer 3: Keycloak Client Protocol Mapper Configuration

Add a Mapper under the <code>kubernetes</code> client settings to convert the incoming <code>groups</code> attribute to the outgoing JWT <code>groups</code> claim (JSON Array format).



## 3. Client-Side Authentication and Token Verification via kubelogin

On terminals operating in headless environments or via command-line interface, perform authentication via OAuth 2.0 Device Code Flow using the <code>kubelogin</code> plugin.



```bash
# Install and place the binary
curl -LO https://github.com/int128/kubelogin/releases/latest/download/kubelogin_linux_amd64.zip
unzip kubelogin_linux_amd64.zip
sudo mv kubelogin /usr/local/bin/kubectl-oidc_login
```

Execute token retrieval and payload decoding verification using the Device Code Flow.



```bash
kubectl oidc-login get-token \
  --oidc-issuer-url=https://keycloak.example.local/realms/kubernetes \
  --oidc-client-id=kubernetes \
  --oidc-client-secret=<client_secret> \
  --oidc-extra-scope=groups \
  --certificate-authority=./keycloak-ca.crt \
  --grant-type=device-code \
  | jq -r '.status.token' | cut -d. -f2 | base64 -d 2&gt;/dev/null \
  | jq '{preferred_username, groups}'
```

Expected extracted result:



```json
{
  "preferred_username": "john.doe@example.com",
  "groups": [
    "k8s-dev"
  ]
}
```

## 4. Fine-Grained RBAC Policy Definition

Access permissions are segregated based on the acquired <code>groups</code> claim. This design adopts a two-layer structure: <code>k8s-admin</code> (full privileges) and <code>k8s-dev</code> (read-only access restricted to specific namespaces and Node read access).



### 4.1 ClusterRoleBinding for Cluster Administrators

```bash
kubectl create clusterrolebinding oidc-k8s-admin \
  --clusterrole=cluster-admin \
  --group=k8s-admin
```

### 4.2 Namespace-Restricted Role / RoleBinding for Developers

Manifest granting read-only permissions exclusively within the development namespace <code>team-a</code>.



```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: namespace-viewer
  namespace: team-a
rules:
- apiGroups: ["", "apps", "batch"]
  resources: ["*"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: k8s-dev-viewer
  namespace: team-a
subjects:
- kind: Group
  name: k8s-dev
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: namespace-viewer
  apiGroup: rbac.authorization.k8s.io
```

### 4.3 Node Resource Read Permission Segregation for Developers

Because <code>Node</code> is a non-namespaced resource, a cluster-level <code>ClusterRole</code> and <code>ClusterRoleBinding</code> are required.



```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-viewer
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: k8s-dev-node-viewer
subjects:
- kind: Group
  name: k8s-dev
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: node-viewer
  apiGroup: rbac.authorization.k8s.io
```

## 5. Client Kubeconfig Configuration and Auditing via SelfSubjectAccessReview

To maintain automatic authentication on developer workstations, configure <code>kubeconfig</code> using the Exec credential plugin format.



```bash
# 1. Register cluster connection configuration
kubectl config set-cluster my-k8s \
  --server=https://api.k8s.example.local:6443 \
  --certificate-authority=./cluster-ca.crt

# 2. Configure exec credential plugin
kubectl config set-credentials oidc-user \
  --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://keycloak.example.local/realms/kubernetes \
  --exec-arg=--oidc-client-id=kubernetes \
  --exec-arg=--oidc-extra-scope=groups \
  --exec-arg=--grant-type=device-code

# 3. Bind context
kubectl config set-context my-k8s --cluster=my-k8s --user=oidc-user
kubectl config use-context my-k8s
```

Verify permission evaluation behavior using the <code>SelfSubjectAccessReview</code> API.



```bash
curl -sk https://api.k8s.example.local:6443/apis/authorization.k8s.io/v1/selfsubjectaccessreviews \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "apiVersion": "authorization.k8s.io/v1",
    "kind": "SelfSubjectAccessReview",
    "spec": {
      "resourceAttributes": {
        "namespace": "kube-system",
        "verb": "get",
        "resource": "pods"
      }
    }
  }' | jq '.status.allowed'
```

## Troubleshooting

Common failure patterns and their solutions during identity broker configuration are summarized below.



### 1. Infinite Redirect Loop Behind a Reverse Proxy

This occurs in environments where TLS is terminated at a load balancer or reverse proxy, causing Keycloak to fail to recognize proxy headers, treat requests as HTTP context, and strip Secure cookie attributes. When using the Gateway API, inject the <code>X-Forwarded-Proto</code> header using an <code>HTTPRoute</code> resource.



```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: keycloak-route
  namespace: keycloak
spec:
  rules:
  - filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
        - name: X-Forwarded-Proto
          value: https
        - name: X-Forwarded-Port
          value: "443"
```

### 2. The groups Claim in the Token is null

This is caused by missing the <code>groups</code> scope in the request, or an array conversion mismatch in the Keycloak protocol mapper. Either join group names into a string on the Authentik side before sending, or enable the <code>Multivalued</code> option in Keycloak's Mapper settings.



### 3. PKIX Path Building Failed Error

This occurs during upstream IdP certificate verification when intermediate CA certificates are not registered in the Keycloak truststore. The issuing root or intermediate CA certificate must be imported into Keycloak instead of the server certificate.



### Operational Verification Protocol Logs

Example log outputs for Pod health and API response verification on a control plane node.



```text
$ kubectl get pod -n kube-system -l component=kube-apiserver
NAME                                         READY   STATUS    RESTARTS   AGE
kube-apiserver-control-plane-01              1/1     Running   0          4m12s

$ curl -skI https://api.k8s.example.local:6443/livez
HTTP/2 200 
content-type: text/plain; charset=utf-8
x-content-type-options: nosniff
date: Sun, 15 Nov 2026 10:15:30 GMT
```

## Operational Notes

💡 <b>Architectural Decoupling</b>: By deploying Keycloak as an intermediate broker, zero reconfiguration is required on the Kubernetes control plane side even when migrating upstream IdPs.


⚠️ <b>Claim Propagation Consistency</b>: For successful <code>groups</code> claim propagation, the scope definition on the IdP side, the protocol mapping in Keycloak, and the flag definitions in <code>kube-apiserver</code> must match precisely across all three locations.


🛠️ <b>Explicit Segregation of Cluster-Scoped Resources</b>: Read permissions for non-namespaced cluster resources such as <code>Node</code> strictly require explicit definitions of <code>ClusterRoleBinding</code> rather than namespace-specific <code>Role</code> objects.

</client_secret>
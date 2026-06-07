---
title: "Designing Alert Control and SMTP Integration with Prometheus and Alertmanager"
slug: "prometheus-alertmanager-smtp-routing"
date: 2026-06-07T14:07:57+09:00
draft: false
image: ""
description: "This article explains the separation of Prometheus evaluation and Alertmanager routing, control mechanisms to prevent alert storms, and technical solutions for TLS configuration on Port 465 when integrating with Naver SMTP."
categories: ["DevOps Logistics"]
tags: ["prometheus", "alertmanager", "smtp-configuration", "alert-routing", "monitoring-infrastructure"]
author: "K-Life Hack"
---

# Advancing Monitoring and Notification Infrastructure with Prometheus and Alertmanager: Decoupled Design of Anomaly Detection and Notification Control

In infrastructure monitoring, anomaly detection and notification control are design domains that should be clearly separated. This article explains the decoupled architecture of Prometheus alert evaluation and Alertmanager notification routing, control features to suppress alert storms, and the implementation specifications of notification paths using Naver SMTP.



## 1. Decoupled Architecture of Evaluation and Routing

In the monitoring pipeline, Prometheus and Alertmanager divide responsibilities as follows. This separation is based on the Single Responsibility Principle.



| Component | Role | Specific Processing | Output |
| :--- | :--- | :--- | :--- |
| <b>Prometheus</b> | <b>Evaluation Engine</b> | Evaluates rules defined in `rule_files` at each evaluation interval (e.g., 30 seconds). | Generates alerts in the "firing" state when conditions are met and sends them to Alertmanager via HTTP POST. |
| <b>Alertmanager</b> | <b>Routing Engine</b> | Applies grouping, inhibition, and silence processing to received alerts. | Delivers organized notifications to external notification channels (Email, Slack, etc.). |

💡 <b>Why Separation is Necessary</b>


1. <b>Engine Specialization</b>: Prometheus specializes in read/write performance as a time-series database (TSDB). By eliminating external network protocols, retry logic, rate limiting, and state management (such as SMTP or Webhook integration), the stability of the core engine is guaranteed.


2. <b>Ensuring High Availability</b>: It becomes possible to aggregate and send alerts from multiple Prometheus servers to a redundant Alertmanager cluster, eliminating single points of failure (SPOF) in the notification path.



---

## 2. Alert Rule Components and State Transitions

Alert rules in Prometheus are defined in YAML format. Example of a rule definition to detect GPU temperature rise:



```yaml
- alert: GpuHighTemperature
  expr: gpu_temperature_celsius &gt; 80
  for: 5m
  labels:
    severity: warning
    component: gpu
  annotations:
    summary: "GPU temp on {{ $labels.host }}/{{ $labels.gpu }} = {{ $value }}°C"
    description: |
      GPU {{ $labels.gpu }} on {{ $labels.host }} has been &gt; 80°C for 5 minutes.
      Threshold: 80°C / Critical: 85°C.
      Check: nvidia-smi -q -d TEMPERATURE
```

The functions of the core parameters are as follows:



* <b>`expr`</b>: The PromQL expression that serves as the evaluation condition. If this expression returns a result (time-series data), the alert condition is considered met.
* <b>`for`</b>: The waiting time from when the condition is met until the alert actually transitions to the "firing" state. This prevents false positives caused by temporary spikes.
* <b>`labels`</b>: Metadata attached to the alert. Used as criteria for routing and grouping in Alertmanager.
* <b>`annotations`</b>: Templates used for notification text. Dynamic information can be embedded using variables such as `{{ $labels.host }}` and `{{ $value }}`.

Due to the presence of the `for` parameter, the alert state transition lifecycle transitions through the following three states:



```
                  [ expr がデータを返した時 ]
  +------------+  --------------------&gt;  +------------+
  |  inactive  |                         |  pending   |
  +------------+  &lt;--------------------  +------------+
        ^         [ expr の結果が空になった時 ]    |
        |                                      | [ 'for' で指定した時間が経過 ]
        |                                      v
        |                                +------------+
        +--------------------------------|   firing   |
              [ expr の結果が空になった時 ]     +------------+
                (RESOLVED 通知の送信)
```

* <b>`inactive`</b>: Normal state. The PromQL evaluation result is empty.
* <b>`pending`</b>: Anomaly detected, but the period specified by `for` has not elapsed yet (under validation). Notifications are not sent at this stage.
* <b>`firing`</b>: The anomalous state has persisted, and the notification is confirmed. Alerts are forwarded to Alertmanager. Once the condition is resolved, a `RESOLVED` notification is automatically sent.

---

## 3. Three Control Features to Suppress Alert Storms

When a large-scale failure occurs, an "alert storm" where a massive volume of notifications is sent simultaneously increases the cognitive load on operators and leads to critical failures being overlooked. Alertmanager provides three control features to prevent this.



### ① Grouping (`group_by`)

Aggregates similar alerts into a single notification. For example, if multiple components on the same host trigger warnings simultaneously, they are grouped and notified per host rather than individually.



```yaml
route:
  group_by: ['alertname', 'severity']
  group_wait: 30s        # 最初のアラート受信後、バッファリングする時間
  group_interval: 5m     # 同一グループ内の新規アラートを通知するまでの間隔
```

### ② Inhibition (`inhibit_rules`)

Suppresses notifications for related "dependent alerts" when a specific "trigger alert" has already occurred. For example, if the host itself is down (`HostDown`), monitoring alerts for individual processes or GPUs on that host are unnecessary, so their notifications are muted.



```yaml
inhibit_rules:
  - source_matchers: [alertname="HostDown"]
    target_matchers: [severity=~"warning|info"]
    equal: ['host']
```

The inhibition rule is applied only when the labels specified in `equal` (in this case, `host`) match.



### ③ Resend Control (`repeat_interval`)

Controls the interval for repeating the same notification for unresolved alerts. This reduces the risk of alerts being left unaddressed while preventing frequent resending.



```yaml
route:
  repeat_interval: 4h    # 解決していないアラートの再送間隔
```

---

## 4. Port 465 Behavior and Countermeasures in Naver SMTP Integration

When using Naver SMTP (`smtp.naver.com`) as a notification path, attention must be paid to specific behaviors in protocol negotiation.


⚠️ <b>Port 465 (Implicit SSL) Connection Issue</b>


Naver SMTP supports Port 465 (implicit SSL/TLS) and Port 587 (explicit STARTTLS). By default, Alertmanager attempts to send a STARTTLS command at the start of the connection. However, since Port 465 requires an SSL handshake from the very beginning of the connection, if Alertmanager sends STARTTLS, a protocol mismatch occurs, causing the connection to hang or fail with a `connection unexpectedly closed` error.


🛠️ <b>Solution</b>


Explicitly specify `smtp_require_tls: false` in the Alertmanager configuration. This skips sending STARTTLS, and the implicit SSL connection on Port 465 is successfully established. Additionally, for authentication, you must use a 16-digit "App Password" generated from Naver's security settings instead of your regular login password.



---

## 5. Configuration File for Implementation (`alertmanager.yml`)

Practical Alertmanager configuration file incorporating the alert controls and Naver SMTP integration:



```yaml
global:
  resolve_timeout: 5m
  smtp_smarthost: 'smtp.naver.com:465'
  smtp_from: 'neogle@naver.com'
  smtp_auth_username: 'neogle@naver.com'
  smtp_auth_password: 'YOUR_16_DIGIT_APP_PASSWORD'
  smtp_require_tls: false

route:
  receiver: 'default-email'
  group_by: ['alertname', 'severity']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    - matchers:
        - severity="critical"
      receiver: 'critical-email'
      repeat_interval: 1h

    - matchers:
        - severity="info"
      repeat_interval: 24h

inhibit_rules:
  - source_matchers: [alertname="HostDown"]
    target_matchers: [severity=~"warning|info"]
    equal: ['host']

  - source_matchers: [alertname="GpuCriticalTemp"]
    target_matchers: [alertname="GpuHighTemperature"]
    equal: ['host', 'gpu']

receivers:
  - name: 'default-email'
    email_configs:
      - to: 'neogle@naver.com'
        send_resolved: true

  - name: 'critical-email'
    email_configs:
      - to: 'neogle@naver.com'
        send_resolved: true
        headers:
          Subject: '🚨 [CRITICAL] {{ .CommonLabels.alertname }} on {{ .CommonLabels.host }}'
```

---

## 6. Troubleshooting Guide

| Issue | Probable Cause | Solution |
| :--- | :--- | :--- |
| Alert conditions are met but no notification is sent | The time specified in `for` has not elapsed, or it matches an inhibition rule (`inhibit_rules`). | Check if the target alert is in the `pending` state in the Prometheus Web UI. Also, verify if a higher-level alert (such as `HostDown`) has been triggered on the same host. |
| `connection unexpectedly closed` occurs during SMTP connection | Attempting to use STARTTLS on Port 465. | Verify if `smtp_require_tls: false` is configured. |
| SMTP authentication error occurs | The regular login password is used, or the App Password has expired. | Verify that the POP3/SMTP usage setting is enabled in Naver's mail settings, and regenerate and apply a new 16-digit App Password. |

---

## Configuration Notes

The most critical aspect of alert design is that "every alert must lead to a concrete action for the recipient." Notifications that do not require action not only lead to operations team fatigue but also delay the detection of truly critical failures.


By properly combining the grouping, inhibition, and resend controls demonstrated in this article, it is possible to build a highly reliable monitoring and notification infrastructure with minimized noise. Please tune each interval value and inhibition condition step-by-step according to the requirements and operational structure of your actual environment.


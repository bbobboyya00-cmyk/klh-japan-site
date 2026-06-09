---
title: "Implementation of Performance Improvement and Automation for NAS-Google Drive Synchronization Using rclone"
slug: "rclone-gdrive-api-performance-optimization"
date: 2026-06-09T10:06:48+09:00
draft: false
image: ""
description: "A technical note on implementing a dedicated OAuth client ID and 2-hour cycle synchronization automation via Windows Task Scheduler to resolve transfer speed degradation caused by rclone's default API limits."
categories: ["Linux System Admin"]
tags: ["rclone", "google-drive-api", "nas-synchronization", "windows-task-scheduler", "bisync"]
author: "K-Life Hack"
---

In the synchronization operation between NAS and Google Drive (Google Workspace Shared Drive), a serious performance bottleneck was identified from operational data after the initial setup. This article describes the process of introducing a dedicated API key and optimizing the synchronization cycle to improve transfer speeds and eliminate synchronization delays.

## 1. Current Status Analysis and Issue Identification

As a result of conducting an operational test for approximately two weeks in an environment synchronizing 1.1 TB of ipTIME NAS data to Google Drive, the following two constraints were identified.


<b>Stagnant Transfer Speeds</b>: Despite being in a gigabit network environment, the speed during rclone copy execution hovered around 1 MB/s to 3 MB/s. Especially in directories containing tens of thousands of small files, it took a significant amount of time to complete synchronization.


<b>Business Impact due to Sync Delays</b>: With the initially configured schedule of "once a day (2:00 AM)," documents created in the morning were not reflected in the cloud until the following day, leading to situations where users requiring immediacy manually transferred files.



## 2. Technical Root Cause: Shared API Quota Limits

In rclone's default configuration, the "Global Default OAuth Client ID" shared by users worldwide is used. Google APIs have per-second and per-day request limits (quotas) set for each client ID, and using a shared ID easily leads to reaching these limits due to the influence of other users.


When limits are reached, Google returns errors such as `API rate exceeded` or `userRateLimitExceeded`, and rclone enters a backoff (waiting) state. This is the direct cause of the extreme drop in effective throughput. To resolve this issue, it is necessary to issue an organization-specific OAuth client ID/secret in the Google Cloud Console to secure a dedicated quota.



## 3. Issuing and Configuring a Dedicated API Key

### 3.1 Configuration in Google Cloud Console

<b>Project Creation</b>: Create a new project (e.g., rclone-sync-project) in the Google Cloud Console (https://console.cloud.google.com).


<b>Enabling the API</b>: Search for and enable "Google Drive API" from "APIs &amp; Services &gt; Library".


<b>OAuth Consent Screen Configuration</b>: Set the user type to "Internal" on the "OAuth consent screen". This restricts usage to users within the Google Workspace domain and avoids token expiration issues.


<b>Creating Credentials</b>: Select "Credentials &gt; Create Credentials &gt; OAuth client ID". Specify "Desktop app" as the application type.


<b>Saving the ID and Secret</b>: Record the generated "Client ID" and "Client Secret" in a secure location.



### 3.2 Updating rclone Configuration

Apply the new credentials to the existing remote configuration.



```ini
[gdrive]
type = drive
client_id = your_own_client_id.apps.googleusercontent.com
client_secret = your_own_client_secret
scope = drive
```

## 4. Optimization of Synchronization Automation (2-Hour Cycle)

Considering the balance between data freshness and system load, the synchronization frequency is set to a 2-hour cycle. The bisync command, which maintains bidirectional consistency, is adopted for synchronization.



### 4.1 Creating the Synchronization Batch File

Configure the following script as C:\rclone\sync.bat. By applying the dedicated API key, throttling is less likely to occur even if --transfers (number of concurrent transfers) is increased to 8.



```bat
@echo off
rclone bisync C:\nas_data gdrive:shared_drive --transfers 8 --log-file C:\rclone\rclone.log --verbose
```

### 4.2 Windows Task Scheduler Configuration

<b>General</b>: Select "Run whether user is logged on or not" and "Run with highest privileges".


<b>Triggers</b>: Set to run daily, repeat task every "2 hours", for a duration of "1 day".


<b>Actions</b>: Specify C:\rclone\sync.bat and enter C:\rclone in "Start in (optional)".


<b>Settings</b>: Set "If the task is already running, then the following rule applies" to "Do not start a new instance" to prevent overlapping processes.



## 5. Post-Implementation Performance Comparison

| Metric | Phase 1 (Default API + Once a Day) | Phase 2 (Dedicated API + 2-Hour Cycle) |
| :--- | :--- | :--- |
| <b>Average Transfer Speed</b> | 1–3 MB/s | 15–30 MB/s |
| <b>Sync Delay (Max)</b> | 24 hours | 2 hours |
| <b>Throttling Occurrence</b> | Frequent | Almost resolved |
| <b>System Load</b> | Concentrated at midnight (high burst) | Distributed execution (low load) |

## Operational Notes

<b>Token Expiration</b>: If the OAuth consent screen is in the "External" and "Testing" state, the token will expire in 7 days. Be sure to verify that it is in the "Internal" or "In production" state.


<b>Log Management</b>: Log output via --log-file is mandatory. It serves as the sole diagnostic means when synchronization errors or conflicts occur.


<b>bisync Characteristics</b>: Since bisync checks path consistency during the initial run, it takes time only for the first execution in large directories. Once in stable operation, it scans only the changed deltas, completing in a few minutes.


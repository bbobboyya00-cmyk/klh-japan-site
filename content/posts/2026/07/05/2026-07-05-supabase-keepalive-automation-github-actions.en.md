---
title: "Implementing GitHub Actions Automation to Prevent Supabase Free Plan Project Pausing"
slug: "supabase-keepalive-automation-github-actions"
date: 2026-07-05T10:12:17+09:00
draft: false
image: ""
description: "This article explains the implementation steps and security considerations for health monitoring using periodic REST API requests via GitHub Actions to avoid automatic pausing of Supabase Free Plan projects due to 7 days of inactivity."
categories: ["DevOps Logistics"]
tags: ["supabase", "github-actions", "cron", "rest-api", "devops"]
author: "K-Life Hack"
---

# Health Monitoring Configuration via GitHub Actions to Avoid Automatic Pausing of Supabase Free Plan

In the Supabase Free Plan, projects are automatically paused if no activity is detected for 7 consecutive days, hindering development continuity and prototype operations. Manual resumption from the dashboard results in API downtime. This infrastructure configuration resets the inactivity timer by sending a REST API request every 5 days using GitHub Actions scheduled execution.



## Configuration Architecture and Security Requirements

This automation stack operates within a private repository to protect API keys. GitHub Actions Free Tier provides 2,000 minutes of execution time per month, sufficient for lightweight curl operations.



### 1. Credential Management via GitHub Secrets

Register environment variables in <b>Settings &gt; Secrets and variables &gt; Actions</b>. Enter raw strings without quotes.


<b>SUPABASE_URL_1</b>: Project REST endpoint (e.g., https://[PROJECT_ID].supabase.co)


<b>SUPABASE_KEY_1</b>: anon (anonymous) public API key


⚠️ <b>Security Note:</b> Use the <b>anon</b> key for authentication. The <b>service_role</b> key possesses permissions to bypass Row Level Security (RLS), creating unnecessary security risks for health monitoring.



## Workflow Implementation

The configuration for <b>.github/workflows/keepalive.yml</b> includes <b>workflow_dispatch</b> for manual testing.



```yaml
name: Supabase Keep Alive

on:
  schedule:
    - cron: '0 0 */5 * *' # Runs at midnight every 5 days
  workflow_dispatch: # Allow manual execution

jobs:
  keepalive:
    runs-on: ubuntu-latest
    steps:
      - name: Ping Supabase Project
        run: |
          curl -s "${{ secrets.SUPABASE_URL_1 }}/rest/v1/" \
          -H "apikey: ${{ secrets.SUPABASE_KEY_1 }}" \
          -H "Authorization: Bearer ${{ secrets.SUPABASE_KEY_1 }}"
```

## Cron Syntax Analysis and Execution Interval Optimization

The execution interval is set to 5 days (<b>*/5</b>) to provide a margin against the 7-day threshold. POSIX standard cron syntax controls the timing.


<b>0 0 */5 * *</b>: Executes at 00:00 every 5 days. Actual execution may be delayed by GitHub Actions runner load, which is acceptable for this use case.



## Troubleshooting

1. <b>401 Unauthorized</b>: Occurs if <b>SUPABASE_KEY_1</b> is incorrect or the <b>apikey</b> header is missing. Verify Secret values for trailing spaces or line breaks.


2. <b>404 Not Found</b>: Ensure <b>/rest/v1/</b> is appended to <b>SUPABASE_URL_1</b>. Inaccurate endpoints may fail to trigger activity counts.


3. <b>Workflow not triggering</b>: Scheduled workflows may be disabled if the repository has no commits for an extended period. Re-enable the workflow manually or configure periodic dummy commits.



## Operational Verification Logs

The protocol log indicates successful request completion. HTTP status 200 OK or a JSON response containing schema information confirms activity registration.



```text
Run curl -s "***" -H "apikey: ***" -H "Authorization: Bearer ***"
{
  "swagger": "2.0",
  "info": {
    "title": "PostgREST API",
    "description": "Standard REST interface for any PostgreSQL database"
  },
  "host": "your-project.supabase.co",
  "basePath": "/",
  "schemes": ["https"]
}

Process completed with exit code 0
```

## Operational Notes

This method assists operation within Free Plan limits. For production environments or mission-critical services, upgrading to the Pro Plan is recommended to disable automatic pausing. Periodically monitor execution logs and track changes in API key expiration or endpoints.


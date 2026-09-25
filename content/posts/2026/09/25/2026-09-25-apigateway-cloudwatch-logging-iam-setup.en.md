---
title: "Structural Resolution and IAM Role Design for API Gateway CloudWatch Execution Logs Not Being Output"
slug: "apigateway-cloudwatch-logging-iam-setup"
date: 2026-09-25T10:14:36+09:00
draft: false
image: ""
description: "Explains the reasons why execution logs are not output to CloudWatch Logs even when enabled in API Gateway stage settings, the procedure for linking account-level IAM roles, and troubleshooting methods for 401/403 errors."
categories: ["Backend Architecture"]
tags: ["api-gateway"]
author: "K-Life Hack"
---

In API Gateway operations, issues where log groups or log streams are not generated in CloudWatch Logs despite enabling Execution Logs in the stage settings occur frequently. This is because the API Gateway log output architecture is managed across a two-layer lifecycle: 'stage-level settings' and 'account-level permissions (IAM roles)'.


No matter how detailed the log output enabled at the stage level is, if the IAM role that allows the API Gateway service itself to write to CloudWatch Logs in the AWS account is not registered in the global settings, the logs will be silently dropped internally. This article demystifies this privilege separation mechanism and explains the IAM role design and troubleshooting procedures for safely and reliably collecting logs.



---

## The Two-Layer Architecture of Log Output in API Gateway

Log writing from API Gateway to CloudWatch Logs is controlled by the following two independent control planes.



1. <b>Account-Level Settings (Identity &amp; Access Boundary)</b>
Defines the IAM role for the API Gateway service (`apigateway.amazonaws.com`) to obtain temporary security credentials (`sts:AssumeRole`) and call the CloudWatch Logs API in the target AWS account and region.
2. <b>Stage-Level Settings (Configuration Scope)</b>
Defines whether to output logs, the log level (`INFO` / `ERROR`), detailed metrics collection, and the enablement of data tracing (recording request/response payloads) for a specific API stage.

Only when both of these settings are in place will the log stream be successfully generated.



```
[ Step 1: Create IAM Role ] 
       │ (Trust Relationship: apigateway.amazonaws.com)
       ▼
[ Step 2: Register Role ARN in API Gateway Account Settings ]
       │ (Grant global log write permissions to API Gateway)
       ▼
[ Step 3: Enable Execution Logging in API Stage Settings ]
       │ (Define log level, metrics, and tracing)
       ▼
[ Step 4: Send Request from Client to API Endpoint ]
       │
       ▼
[ Step 5: Verify Log Events in CloudWatch Logs ]
         (Log Group Name: API-Gateway-Execution-Logs_<api-id>/<stage>)
```

---

## 1. Creating and Defining Policies for the CloudWatch Writing IAM Role

For API Gateway to create log groups in CloudWatch Logs, provision log streams, and upload log events, an IAM role with the appropriate trust relationship and policies is required.



### Trust Policy Definition

Configure the API Gateway service principal to be able to assume this role.



```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "apigateway.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Permissions Policy Definition

Based on the principle of least privilege, the following three actions are required. Attach the AWS managed policy `AmazonAPIGatewayPushToCloudWatchLogs` or create an equivalent custom policy.



* `logs:CreateLogGroup`: Permission to automatically generate a log group if it does not exist
* `logs:CreateLogStream`: Permission to generate a new stream within the log group
* `logs:PutLogEvents`: Permission to batch upload log events

---

## 2. Associating the IAM Role ARN with Account Settings

Register the ARN of the created IAM role (e.g., `arn:aws:iam::123456789012:role/apigw-cloudwatch-logging-role`) in the global settings for each region of API Gateway.



### Verifying and Updating Settings via AWS CLI

In addition to configuring via the Management Console, you can apply and verify account settings using the AWS CLI.



```bash
# Associate the IAM role ARN with the account settings
aws apigateway update-account \
  --patch-operations op='replace',path='/cloudwatchRoleArn',value='arn:aws:iam::123456789012:role/apigw-cloudwatch-logging-role' \
  --region us-east-1
```

---

## 3. Enabling Execution Logs at the Stage Level

After completing the account-level permission settings, enable log output in the stage settings of the target API.



* <b>Log Level</b>: Select `INFO` (records all execution paths) or `ERROR` (records only runtime errors). `INFO` is recommended during troubleshooting.
* <b>Detailed Metrics</b>: When enabled, metrics such as latency and request counts are sent to CloudWatch Metrics.
* <b>Full Request/Response Data Logs (Data Trace)</b>: When enabled, all HTTP request/response bodies and headers are recorded. However, because there is a risk of exposing authentication tokens or personally identifiable information (PII) in the logs in production environments, it is recommended to disable this except for temporary debugging purposes.

---

## 4. Troubleshooting

This is the diagnostic flow when logs are not output even after completing the settings, or when specific HTTP errors occur during API calls.



### Common Friction Points and Solutions

* <b>Trust Relationship Mismatch</b>: If the service principal in the IAM role's trust policy is set to `lambda.amazonaws.com` or `ec2.amazonaws.com`, API Gateway cannot assume the role, and log output will fail. Ensure that it is set to `apigateway.amazonaws.com`.
* <b>Inter-region Mismatch</b>: API Gateway account settings (CloudWatch Logs Role ARN) are independent for each region. Verify that the role ARN is registered in the settings for the same region where the API is deployed.

### Log Analysis Matrix for 401 / 403 Errors

Once execution logs are enabled, when a `401 Unauthorized` or `403 Forbidden` is returned to a client, you can identify in chronological order which phase the request was rejected.



| Error Cause | Key Signature in Logs | Points to Verify |
| :--- | :--- | :--- |
| <b>Missing Authentication Header</b> | `Unauthorized request` / `Missing Authentication Token` | Whether the client is correctly sending the `Authorization` header or custom headers. |
| <b>Custom Authorizer Failure</b> | `Execution failed due to configuration error: Authorizer...` | Syntax errors in the IAM policy returned by the Lambda authorizer, or runtime errors within Lambda itself. |
| <b>API Key Mismatch</b> | `Forbidden` / `Invalid API Key` | Whether `API Key Required` is set to `true` in the method settings, and whether the `x-api-key` header is associated with an active usage plan. |
| <b>Denial by Resource Policy</b> | `Access Denied` / `Explicit Deny` | Whether the source IP address or VPC endpoint is targeted for denial in the API Gateway resource policy. |

### Verification Logs During Normal Operation (Terminal Output Example)

Verify whether the settings are correctly applied using the AWS CLI.



```text
$ aws apigateway get-account --region us-east-1
{
    "cloudwatchRoleArn": "arn:aws:iam::123456789012:role/apigw-cloudwatch-logging-role",
    "throttleSettings": {
        "burstLimit": 5000,
        "rateLimit": 10000.0
    }
}

$ aws iam get-role --role-name apigw-cloudwatch-logging-role --query 'Role.AssumeRolePolicyDocument'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "apigateway.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}

$ aws logs describe-log-groups --log-group-name-prefix "API-Gateway-Execution-Logs" --region us-east-1 --query 'logGroups[0].logGroupName'
"API-Gateway-Execution-Logs_abc123xyz/prod"
```

---

## Operational Notes

* <b>Data Privacy Protection</b>: Avoid enabling 'Full Request/Response Data Logs' in production environments. Session tokens, API keys, and personal information will be recorded in plaintext in CloudWatch Logs, which can lead to violations of security compliance standards (such as GDPR, PCI-DSS, etc.).
* <b>Log Retention Period</b>: The default retention period for CloudWatch log groups automatically generated by API Gateway is 'Never Expire'. To prevent storage costs from ballooning, it is recommended to establish operational rules to explicitly set a retention period (e.g., 30 to 90 days) after the log group is created.
* <b>Leveraging Metrics Filters</b>: To avoid increased costs from full log scans, when monitoring the frequency of specific status codes (`4XX` / `5XX`), it is efficient to define CloudWatch metrics filters and configure alerts.</stage></api-id>
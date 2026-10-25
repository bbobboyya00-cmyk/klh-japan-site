---
title: "Spring Boot CI Pipeline Construction with GitHub Actions: Merge Conflicts and Failure Analysis"
slug: "github-actions-ci-pipeline-diagnostics-merge-resolution"
date: 2026-10-25T10:35:56+09:00
draft: false
image: ""
description: "Explains how to construct a Spring Boot CI pipeline using GitHub Actions, along with failure analysis techniques such as handling workflow file displacement issues during merge conflicts and collecting test failure artifacts."
categories: ["DevOps Logistics"]
tags: ["github-actions", "gradle", "ci-cd", "git-merge", "spring-boot"]
author: "K-Life Hack"
---

In the software development process, relying solely on local test execution to apply changes risks introducing unstable code into the target branch. Particularly under concurrent development with multiple team members, there is a constant risk that the CI/CD pipeline will fail to trigger correctly due to complex Git branch structures or misconfigurations during conflict resolution.


This article describes how to build an automated build and test verification pipeline for a Spring Boot project using GitHub Actions, as well as the workflow file path displacement issue that occurred during merge conflict resolution and the diagnostic artifact collection mechanism for test failures.



## Basic Structure of GitHub Actions and Declarative Pipeline Design

Automated processes (Workflows) executed in GitHub Actions are defined by YAML declaration files placed in a specific directory within the repository. Because the execution engine runs on ephemeral virtual machine containers, dependency setup and execution steps must be explicitly defined without omissions.



### Strict Directory Structure Conventions

GitHub Actions pipeline definition files must strictly be placed at the following path:



```text
.github/workflows/ci.yml
```

If a file is placed outside this path structure (e.g., <code>docs/ci.yml</code> or <code>.github/ci.yml</code>), GitHub's event detection engine will not recognize it as a workflow definition.



### Implementation Example of a Spring Boot CI Workflow

Below is a standard workflow configuration triggered by code pushes to the <code>main</code> branch and pull requests, executing Gradle builds and tests.



```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-24.04

    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Provision Temurin JDK 21
        uses: actions/setup-java@v4
        with:
          distribution: 'temurin'
          java-version: '21'

      - name: Set Executable Permission for Gradle Wrapper
        run: chmod +x ./gradlew

      - name: Execute Automated Unit Tests
        run: ./gradlew test

      - name: Preserve Test Failure Artifacts
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: test-report
          path: build/reports/tests/test/
          if-no-files-found: warn
```

## Merge Conflicts and Recovery from Workflow Path Displacement

While working on a feature branch (<code>lab/ci</code>), if changes are introduced concurrently on the remote <code>main</code> branch, a merge conflict will occur on the Pull Request.



### Conflict Resolution and File Path Inconsistency

Fetch the latest remote status in the local environment and execute the merge.



```bash
git switch lab/ci
git fetch cicd
git merge cicd/main
```

When executing this merge operation (Git 3-way merge <code>ort</code> strategy), the upstream branch's commit history may unexpectedly cause <code>.github/workflows/ci.yml</code> to be moved (renamed) to <code>docs/ci.yml</code>.


Once the file is moved to the <code>docs/</code> directory, subsequent push events will no longer trigger GitHub Actions. To resolve this state, Git commands must be used to restore the file placement to the correct directory.



```bash
# Move from incorrect path to the standard directory structure
git mv docs/ci.yml .github/workflows/ci.yml

# Commit changes and push to the remote branch
git commit -m "fix: restore workflow definition path"
git push cicd lab/ci
```

## Separation of Structural Mergeability and Application Verification Status

On the Pull Request diagnostic screen, the following two statuses must be clearly distinguished and interpreted:


1. <b>Git Structural Mergeability (Merge Conflict Status)</b>: Indicates whether the commit tree can be merged at the text level. When <code>No conflicts with base branch</code> is displayed, Git's file merging itself completes successfully.


2. <b>CI Status Checks (Status Checks)</b>: Indicates whether the application build and unit tests succeeded. In the case of <code>All checks have failed</code>, even if it is mergeable at the Git level, the code is in a broken state.


If Branch Protection Rules are not configured, the Merge button remains clickable in the GitHub UI even when tests fail. To make CI function effectively as a quality gate, configuring successful status checks as a mandatory condition for merging is required.



## Troubleshooting

### 1. Workflow does not run and displays "No workflow runs found"

⚠️ <b>Cause</b>: The workflow file placement path is outside <code>.github/workflows/</code>, or there is an indentation syntax error in the YAML file.


🛠️ <b>Solution</b>: Verify whether the file path is under <code>.github/workflows/*.yml</code>. Also verify that the indentation hierarchy (based on 2 spaces) for <code>jobs</code> and <code>steps</code> is correct.



### 2. Unable to identify detailed causes from console logs on Gradle test failures

⚠️ <b>Cause</b>: Standard output logs from Gradle alone may not fully output details of fragmented assertion failures or configuration file loading errors.


🛠️ <b>Solution</b>: Configure <code>actions/upload-artifact@v4</code> with the <code>if: failure()</code> condition to save HTML test reports inside <code>build/reports/tests/test/</code> as artifacts. This allows inspecting detailed stack traces in a browser upon pipeline failures.



### 3. Push to remote rejected due to secret leak warnings

⚠️ <b>Cause</b>: Files such as <code>.env</code>, hardcoded API keys, or private keys are included in the Git commit history.


🛠️ <b>Solution</b>: Remove the secret information from the codebase and add the target file pattern to <code>.gitignore</code>. If secrets were included in past commit history, immediately revoke and reissue the credentials, and migrate them to a secure store such as <code>GitHub Actions Secrets</code>.



## Terminal Log for Verification

Example terminal output during the normalization of pipeline placement and verification of build operations in the local environment.



```text
$ git status
On branch lab/ci
Your branch is up to date with 'cicd/lab/ci'.

nothing to commit, working tree clean

$ ls -la .github/workflows/
total 12
drwxr-xr-x 1 runner 1049000     0 Oct 25 10:15 .
drwxr-xr-x 1 runner 1049000     0 Oct 25 10:15 ..
-rw-r--r-- 1 runner 1049000   824 Oct 25 10:15 ci.yml

$ ./gradlew test
BUILD SUCCESSFUL in 8s
4 actionable tasks: 4 executed
```

## Lessons Learned

💡 <b>1. Non-equivalence of Git Merge Success and Application Health</b>: Even if a merge completes without text conflicts, it does not imply that builds or tests will pass successfully. Automated verification via CI pipelines is indispensable.


💡 <b>2. Compliance with Configuration File Placement Conventions</b>: In automation tools such as GitHub Actions, specific directory structures (<code>.github/workflows/</code>) serve as execution prerequisites; caution is required regarding file movements during branch operations.


💡 <b>3. Retention of Failure Diagnostic Artifacts</b>: To reduce root cause investigation costs during pipeline failures, it is effective to configure the setup to properly save diagnostic files, such as test reports, rather than simply failing with an error.


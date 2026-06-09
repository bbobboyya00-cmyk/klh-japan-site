---
title: "Workflow Automation Using Custom Commands and Skills in Claude Code"
slug: "claude-code-custom-commands-skills"
date: 2026-06-06T14:12:53+09:00
draft: false
image: ""
description: "This article explains how to build and operate custom slash commands and autonomous Skills to automate repetitive prompt inputs in Claude Code."
categories: ["DevOps Logistics"]
tags: ["claude-code", "custom-commands", "agent-skills", "yaml-frontmatter", "workflow-automation"]
author: "K-Life Hack"
---

# Custom Command and Skill Design in Claude Code: Automating Development Workflows

When introducing Claude Code into daily development workflows, repeatedly entering complex prompts causes a drop in work efficiency and leads to input errors. Manually instructing code reviews that comply with team standard rules or checking for specific security vulnerabilities every time is inefficient. By codifying these boilerplate prompts as version-controlled assets and registering them as slash commands (/commands) or autonomously executable "Skills," you can automate the development process. This article explains how to implement and design these features.



## 1. Basics of Custom Slash Commands

The simplest automation method is to define custom slash commands using Markdown files. The file name is registered directly as the command name (e.g., `/review-pr` for `review-pr.md`). Custom commands can be placed in either a project-specific scope or a global scope across the user's environment.



*   <b>Project-specific scope:</b> Saved in `.claude/commands/` directly under the project root.
*   <b>Global scope:</b> Saved in `~/.claude/commands/` under the user's home directory.

Implementation of a custom command to retrieve Pull Request diffs and perform a review:



```markdown
---
description: Review PR differences and provide suggestions for improvement
---
!git diff main...HEAD
Review the differences above and review them from the following perspectives:
1. Performance Concerns
2. security vulnerability
3. compliance with coding conventions
```

After saving this file, typing `/` in a Claude Code interactive session will display `/review-pr` in the completion suggestions. Execution with arguments:



```bash
/review-pr
```

This eliminates the hassle of manually retrieving diffs and pasting prompts.



## 2. Advanced Command Features: Arguments, Namespaces, and Frontmatter

To achieve more flexible automation, custom commands support dynamic arguments, organization via namespaces, and metadata configuration using YAML frontmatter.


<b>Dynamic Arguments ($ARGUMENTS)</b>: The `$ARGUMENTS` placeholder captures any text entered after the slash command. For example, if you run `/fix-issue 1234`, you can define it to be processed internally as "Find and fix issue #1234".


<b>Namespaces (Subdirectories)</b>: When the number of commands increases, you can organize them by creating subdirectories. A file placed in `.claude/commands/frontend/component.md` is executed via the namespace path:



```bash
/frontend/component "Button"
```

<b>Control via YAML Frontmatter</b>: By adding YAML frontmatter to the beginning of a Markdown file, you can control the execution environment, the model used, and access permissions to tools.


```yaml
---
description—Automatically generates a commit message
argument-hint—Additional contexts (optional)
allowed-tools:
  - shell
model: claude-3-5-haiku-latest
---
<git_diff>
!git diff --cached
</git_diff>

Generate a commit message in Conventional Commits format based on the differences above.
$ARGUMENTS
```

The specifications of the main parameters are as follows. `description` indicates the purpose of the command, and `allowed-tools` restricts the tools permitted to run. In the `model` specification, specifying <b>haiku</b> for lightweight tasks such as commit message generation can improve response speed and suppress token consumption. The backtick syntax starting with an exclamation mark (`!`) executes a command in the local shell and directly injects its output into the prompt.



## 3. Extending to Skills

With updates to Claude Code, custom commands and "Skills" have been organized into an integrated execution framework. Both `.claude/commands/review.md` and `.claude/skills/review/SKILL.md` are registered as the `/review` command, but the Skill format is recommended for new implementations. If the same name exists, the Skill takes precedence.


Skills are managed as folder-level assets and have the structure `.claude/skills/<name>/SKILL.md`. They support Autonomous Triggering, allowing Claude to automatically launch a Skill based on context without the user explicitly executing a command. Additionally, because of the folder structure, they have the advantage of being able to bundle related documents and templates.</name>


```markdown
---
description: Scan for project security vulnerabilities and provide remediation proposals
disable-model-invocation: true
---
Static analysis of the project-wide source code for vulnerabilities in OWASP Top 10.
```

💡 <b>Important Parameters</b>: `description` is a semantic description that serves as a trigger for autonomous execution. Claude analyzes this description to determine the application scenario. `disable-model-invocation: true` is used to prevent autonomous execution and restrict it to manual execution only for processes with side effects, such as infrastructure changes or database operations.



## 4. Architectural Comparison: Distinguishing CLAUDE.md and Commands/Skills

| Item | CLAUDE.md | Slash Commands &amp; Skills |
| :--- | :--- | :--- |
| <b>Essential Role</b> | Persistent guidelines, rules, and context | Executable procedures and workflows |
| <b>Application Timing</b> | Always applied across all tasks | Explicit invocation or specific context |
| <b>Concrete Examples</b> | Coding conventions, architectural patterns | Code reviews, deployment procedures |
| <b>Positioning</b> | Team development handbook | Executable automation macros |

## 5. Practical Example: Building a Pipeline from Review to Fix

Automating code reviews specialized for a specific technology stack is effective for maintaining quality. Implementation of a custom code review Skill for a Flutter project:


```markdown
---
description: Review code based on Flutter best practices
model: claude-3-5-sonnet-latest
---
Examine the code from the Flutter/Dart perspective below:
- Widget hypertrophy (need extraction)
- Appropriate use of state management such as Riverpod
- const modifier deficiency
- Asynchronous exception handling
```

As an execution flow, you can build a pipeline where you first run `/flutter-review lib/src/features/` to retrieve issues, and then apply fixes using commands like `/fix`. This automates consistent quality control.



## 6. Considerations in Command and Skill Design

*   <b>Description Optimization</b>: For Skills that allow autonomous execution, place clear trigger keywords at the beginning of the `description` to suppress model misjudgments.
*   <b>Thorough Safety Measures</b>: ⚠️ If the process includes destructive operations that affect the system, always set `disable-model-invocation: true` to force manual execution.
*   <b>Leveraging Lightweight Models</b>: 🛠️ For tasks that do not require complex reasoning, specify `model: haiku` to improve execution speed and reduce costs.
*   <b>Version Control</b>: Include the `.claude/` directory in your Git repository to share automation workflows across the entire team.
*   <b>Suppressing Token Consumption</b>: Consolidating instructions into structured command files prevents the context window from becoming congested during sessions.

## Key Takeaways

*   <b>Efficiency via Commands</b>: Save frequently used prompts in `.claude/commands/` to execute them instantly with arguments.
*   <b>Dynamic Context</b>: You can leverage shell execution result injection via the `!` syntax and dynamic processing via `$ARGUMENTS`.
*   <b>Autonomous Skills</b>: You can define Skills that can be automatically launched based on context using `.claude/skills/`.
*   <b>Separation of Concerns</b>: Maintain a clean configuration by defining persistent rules in `CLAUDE.md` and execution procedures in commands or Skills.
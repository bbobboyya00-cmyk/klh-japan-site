---
title: "Design of Asynchronous Task Processing Infrastructure in AI Studio: Scalable Educational Content Generation Architecture with Celery and Redis"
slug: "classkit-ai-studio-celery-redis-architecture"
date: 2026-06-02T11:08:01+09:00
draft: false
image: ""
description: "This article explains the design of an asynchronous architecture combining FastAPI, Redis, and Celery to achieve load balancing for speech synthesis and image generation in AI Studio, as well as improving fault tolerance in external API integration using exponential backoff."
categories: ["Backend Architecture"]
tags: ["celery", "redis", "fastapi", "asynchronous-processing", "exponential-backoff", "postgresql-jsonb"]
author: "K-Life Hack"
---

## 1. Design Philosophy and Technical Background of AI Studio

ClassKit AI Studio is an integrated environment that generates slides, AI voices, and interactive learning content based on text and lecture outlines provided by instructors. While the initial roadmap aimed for "100% full automation," prototype validation revealed two major constraints: exponential increases in external API costs and a decrease in immersion due to a lack of educational context.


To address these challenges, the architecture was pivoted to a "Smart Assembly" model, defining AI not as a sole creator but as an assistant responsible for advanced scaffolding. This simultaneously achieves infrastructure cost optimization and improved educational quality.



## 2. Overview of Asynchronous Processing Architecture

Processes such as AI-based speech synthesis and image generation require computation times ranging from several seconds to about a minute per request. Processing these heavy tasks synchronously on the main FastAPI server would degrade overall system latency and fatally impact availability. To eliminate this risk, the following distributed asynchronous processing stack is employed:



- <b>API Layer (FastAPI)</b>: Receives user requests and immediately returns a Task ID (receipt number).
- <b>Message Broker (Redis)</b>: Manages the task queue and decouples communication between the API server and workers.
- <b>Worker Pool (Celery)</b>: Fetches tasks from Redis and executes the actual AI processing in the background.

```python
# tasks.py (Celery Worker Implementation)
from celery import Celery
from time import sleep

app = Celery('ai_studio', broker='redis://localhost:6379/0')

@app.task(bind=True, max_retries=5)
def generate_ai_narration(self, text, voice_id):
    try:
        # Simulation of request to external API
        result = call_external_tts_api(text, voice_id)
        return result
    except Exception as exc:
        # Retry logic with exponential backoff
        # 2^retry_count * delay
        raise self.retry(exc=exc, countdown=2 ** self.request.retries)
```

## 3. Ensuring Fault Tolerance with Exponential Backoff

To handle external API instability and network timeouts, an exponential backoff algorithm is implemented instead of simple retries. This prevents requests from concentrating in a short period during external server congestion, ensuring opportunities for recovery.



- <b>Retry Strategy</b>: Doubles the wait time after each failure (e.g., 2s, 4s, 8s).
- <b>Benefits</b>: Resolves errors caused by temporary bottlenecks without the user being aware, maintaining overall infrastructure stability.

## 4. Component Management Utilizing PostgreSQL jsonb

AI Studio provides 11 types of interactive learning components. To avoid frequent schema changes, these are stored in a single table using the PostgreSQL <b>jsonb</b> type. This allows for expansion without database downtime when adding new learning formats.



| Component Name | Technical Role |
| :--- | :--- |
| REVIEW | Summary card generation for the previous section |
| QUIZ | Multiple-choice/short-answer quizzes with auto-grading |
| ROLEPLAY | Virtual conversation simulation of business scenarios by AI |
| SHADOWING | Pronunciation training via voice waveform analysis |
| PRONUNCIATION | AI analysis and feedback on user-recorded data |

```sql
CREATE TABLE learning_components (
    id UUID PRIMARY KEY,
    slide_id UUID REFERENCES slides(id),
    component_type VARCHAR(50),
    payload JSONB, -- Stores configuration values unique to each component
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
```

## 5. Cost-Performance Optimization Strategy

To maintain a sustainable fee structure for instructors, the following optimizations were implemented on the infrastructure side.



- <b>Engine Selection</b>: Instead of using the most expensive API by default, comparative analysis was conducted to identify the "sweet spot" balancing quality and unit price.
- <b>Simulation</b>: Final decisions on API integration were made based on virtual billing simulations and traffic forecasts. This minimizes overhead while maximizing the quality of generated assets.

## 6. Future Challenges and Roadmap

While the current AI Studio ensures backend robustness, the frontend logic has become bloated as the UI grows more complex. Specifically, modules exceeding 700 lines of script exist, making refactoring for improved maintainability an urgent task.


Additionally, solving issues stemming from browser security protocols, such as the authentication cookie loss bug (logout failure) that occurred during custom domain implementation, is a goal for the next phase.



## Key Takeaways

- <b>Asynchronous Decoupling</b>: Separation of FastAPI and Celery/Redis maintains low latency of under 0.1 seconds even during heavy AI processing.
- <b>Smart Assembly</b>: Transition from full automation to an AI-guided assembly method balances educational quality and cost efficiency.
- <b>Flexible Data Design</b>: Adoption of <b>jsonb</b> allows for the expansion of 11 diverse learning components without schema changes.
- <b>Resilience</b>: Implementation of exponential backoff improves system robustness against unstable external API behavior.
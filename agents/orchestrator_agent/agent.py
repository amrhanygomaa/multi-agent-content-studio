import os
from dotenv import load_dotenv

# Ensure environment variables are loaded
load_dotenv()

from google.adk.agents import SequentialAgent, LoopAgent, ParallelAgent, LlmAgent
from google.adk.tools import preload_memory_tool
MODEL_NAME = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
MAX_IMPROVEMENT_ITERATIONS = int(os.getenv("MAX_IMPROVEMENT_ITERATIONS", "2"))
from common.retry import GENERATE_CONTENT_CONFIG

from .callbacks import (
    before_agent_callback,
    after_agent_callback,
    before_model_callback,
    after_model_callback,
)
from agents.topic_research_agent.agent import topic_research_agent
from agents.content_drafter_agent.agent import content_drafter_agent
from agents.quality_checker_agent.agent import quality_checker_agent
from agents.content_improver_agent.agent import content_improver_agent
from agents.blog_post_writer_agent.agent import blog_post_writer_agent
from agents.social_media_creator_agent.agent import social_media_creator_agent
from agents.email_newsletter_writer_agent.agent import email_newsletter_writer_agent
from agents.seo_metadata_agent.agent import seo_metadata_agent
from agents.content_analyzer_agent.agent import content_analyzer_agent


# --- Section 6: Sequential — Research and Draft ---
research_and_draft_workflow = SequentialAgent(
    name="research_and_draft_workflow",
    sub_agents=[topic_research_agent, content_drafter_agent],
)

# --- Section 7: Loop — Quality Improvement ---
quality_improvement_loop = LoopAgent(
    name="quality_improvement_loop",
    sub_agents=[quality_checker_agent, content_improver_agent],
    max_iterations=MAX_IMPROVEMENT_ITERATIONS
)

# --- Section 8: Parallel — Multi-Channel Content Creation ---
parallel_content_creation = ParallelAgent(
    name="parallel_content_creation",
    sub_agents=[
        blog_post_writer_agent,
        social_media_creator_agent,
        email_newsletter_writer_agent,
        seo_metadata_agent,
    ]
)

# --- Section 9: Full Content Workflow ---
full_content_workflow = SequentialAgent(
    name="full_content_workflow",
    sub_agents=[
        research_and_draft_workflow,
        quality_improvement_loop,
        parallel_content_creation,
    ],
)

# --- Section 10: The Orchestrator ---
orchestrator_agent = LlmAgent(
    name="orchestrator_agent",
    model=MODEL_NAME,
    instruction="""
    You are the Content Creation Studio orchestrator. Delegate tasks to specialists.

    Past conversations from long-term memory are automatically loaded before each turn.
    Use this context to provide continuity across sessions.

    - For FULL content creation (topic research -> draft -> improve -> multi-channel content),
      transfer to `full_content_workflow`. Pass the complete user request with topic,
      audience, tone, and keywords.

    - For ANALYZING existing text (readability, word count, hashtags),
      transfer to `content_analyzer_agent`.

    Always delegate to the appropriate agent.
    """,
    sub_agents=[full_content_workflow, content_analyzer_agent],
    generate_content_config=GENERATE_CONTENT_CONFIG,
)

# root_agent is used by `adk web` and the Runner
root_agent = orchestrator_agent
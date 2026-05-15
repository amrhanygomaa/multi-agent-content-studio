"""Shared callbacks reused across agents."""

from datetime import datetime, timezone
from typing import Optional

from google.adk.agents.callback_context import CallbackContext
from google.genai import types


def inject_current_date(callback_context: CallbackContext) -> Optional[types.Content]:
    """Write today's UTC date into session state if not already present.

    Idempotent: the first agent to run in a session populates `current_date`,
    every subsequent agent finds it already there and skips. Attached as
    `before_agent_callback` on every agent that references {{current_date}}
    so each agent works in isolation (e.g. when tested with `adk web`)
    even before the orchestrator is built.
    """
    if "current_date" not in callback_context.state:
        callback_context.state["current_date"] = (
            datetime.now(timezone.utc).date().isoformat()
        )
    return None

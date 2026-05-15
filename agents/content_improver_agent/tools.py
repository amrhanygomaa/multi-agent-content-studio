from google.adk.tools import ToolContext

QUALITY_THRESHOLD_MET = "QUALITY_THRESHOLD_MET"


def exit_loop(tool_context: ToolContext):
    """Terminates the improvement loop when quality meets threshold."""
    print(f"🔧 Tool: Quality approved. Terminating loop...")
    tool_context.actions.escalate = True
    return {"result": "Quality threshold met. Content approved."}

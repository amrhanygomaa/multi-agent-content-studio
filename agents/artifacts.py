"""Artifact tools for saving, listing, and loading session content."""

from google.genai import types


async def save_content_artifact(tool_context, filename: str, content: str) -> dict:
    """Saves generated content as a versioned artifact."""
    artifact = types.Part.from_text(text=content)
    version = await tool_context.save_artifact(filename=filename, artifact=artifact)
    return {"filename": filename, "version": version}


async def list_content_artifacts(tool_context) -> list:
    """Lists all artifact filenames saved in the current session."""
    return await tool_context.list_artifacts()


async def load_content_artifact(tool_context, filename: str) -> str:
    """Loads a previously saved artifact by filename."""
    artifact = await tool_context.load_artifact(filename=filename)
    if artifact and artifact.text:
        return artifact.text
    return f"Artifact '{filename}' not found."

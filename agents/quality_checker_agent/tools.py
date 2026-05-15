from google.adk.tools import ToolContext

QUALITY_THRESHOLD_MET = "QUALITY_THRESHOLD_MET"


def calculate_content_quality_score(
    word_count: int,
    readability_score: float,
    has_headings: bool,
    has_conclusion: bool
) -> dict:
    """Calculates overall content quality score based on multiple factors."""
    print(f"🔧 Tool: Calculating quality score...")
    if word_count < 500:
        word_score = 30
    elif word_count < 800:
        word_score = 60
    elif word_count <= 2000:
        word_score = 100
    else:
        word_score = 80

    read_score = min(100, readability_score * 1.5) if readability_score > 0 else 40

    structure_score = 0
    if has_headings:
        structure_score += 50
    if has_conclusion:
        structure_score += 50

    overall_score = (word_score * 0.3) + (read_score * 0.3) + (structure_score * 0.4)

    result = {
        "overall_score": round(overall_score, 2),
        "word_count": word_count,
        "meets_threshold": overall_score >= 70
    }
    print(f"   Result: {result['overall_score']}/100 (Threshold: {'MET' if result['meets_threshold'] else 'NOT MET'})")
    return result

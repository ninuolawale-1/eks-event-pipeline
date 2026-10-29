from datetime import UTC, datetime, timedelta

from enrich import RiskConfig, RiskScorer

BASE = datetime(2026, 10, 29, 15, 0, tzinfo=UTC)


def event(offset_s=0, user="grace.kim", ip="10.1.2.3", outcome="success", **extra):
    e = {
        "event_id": f"id-{offset_s}-{user}",
        "timestamp": (BASE + timedelta(seconds=offset_s)).isoformat(),
        "user": user,
        "source_ip": ip,
        "outcome": outcome,
    }
    e.update(extra)
    return e


def test_normal_login_is_clean():
    result = RiskScorer().score(event())
    assert result["risk_score"] == 0
    assert result["risk_reasons"] == []
    assert result["suspicious"] is False
    assert result["event_time"] == BASE.isoformat()


def test_repeated_failures_are_noted_but_not_flagged():
    scorer = RiskScorer()
    result = None
    for i in range(6):
        result = scorer.score(event(i, ip="45.6.7.8", outcome="failure"))
    assert result["risk_reasons"] == ["repeated_failures"]
    assert result["suspicious"] is False


def test_brute_force_is_flagged():
    scorer = RiskScorer()
    result = None
    for i in range(12):
        result = scorer.score(event(i, ip="45.6.7.8", outcome="failure"))
    assert result["risk_reasons"] == ["brute_force"]
    assert result["suspicious"] is True


def test_success_after_failures():
    scorer = RiskScorer()
    for i in range(6):
        scorer.score(event(i, ip="45.6.7.8", outcome="failure"))
    result = scorer.score(event(10, ip="45.6.7.8", outcome="success"))
    assert "success_after_failures" in result["risk_reasons"]
    assert result["suspicious"] is True


def test_failures_outside_window_expire():
    scorer = RiskScorer(RiskConfig(window_seconds=60))
    for i in range(6):
        scorer.score(event(i, ip="45.6.7.8", outcome="failure"))
    result = scorer.score(event(600, ip="45.6.7.8", outcome="failure"))
    assert result["risk_reasons"] == []


def test_ips_are_tracked_independently():
    scorer = RiskScorer()
    for i in range(12):
        scorer.score(event(i, ip="45.6.7.8", outcome="failure"))
    result = scorer.score(event(13, ip="10.9.9.9", outcome="failure"))
    assert result["risk_reasons"] == []

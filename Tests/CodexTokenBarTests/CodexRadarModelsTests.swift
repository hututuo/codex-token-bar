import XCTest
@testable import CodexTokenBar

final class CodexRadarModelsTests: XCTestCase {
    func testDecodesCurrentStatusPredictionIQAndQuotaRows() throws {
        let data = Data(Self.sampleJSON.utf8)

        let snapshot = try JSONDecoder.codexRadar.decode(CodexRadarSnapshot.self, from: data)

        XCTAssertEqual(snapshot.recommendedAction, "wait")
        XCTAssertEqual(snapshot.window.message, "当前没有开启的速蹬窗口")
        XCTAssertEqual(snapshot.prediction.probability24hPercent, 13)
        XCTAssertEqual(snapshot.prediction.probability48hPercent, 30)
        XCTAssertEqual(snapshot.modelIQ.latest.modelDisplayName, "GPT-5.5 xhigh")
        XCTAssertEqual(snapshot.modelIQ.latest.scoreDisplayText, "IQ 125")
        XCTAssertEqual(snapshot.modelIQ.comparisonRows.map(\.label), [
            "GPT-5.5 xhigh",
            "GPT-5.5 high",
            "GPT-5.5 medium",
            "GPT-5.4 xhigh"
        ])
        XCTAssertEqual(snapshot.modelIQ.quotaRadar?.rowsForDisplay.map(\.tier), [
            "Plus",
            "5x Pro",
            "20x Pro"
        ])
        XCTAssertEqual(snapshot.modelIQ.quotaRadar?.rowsForDisplay.first?.fiveHourDisplayText, "$13.83")
        XCTAssertEqual(snapshot.modelIQ.quotaRadar?.trend.last?.fiveHour20x, 276.66)
        XCTAssertEqual(snapshot.codexEnvironment.roleCounts["market_motive"], 38)
    }

    func testReaderDecodesPayloadFromInjectedTransport() async throws {
        let reader = LiveCodexRadarReader(
            transport: { _ in
                (Data(Self.sampleJSON.utf8), HTTPURLResponse(
                    url: URL(string: "https://codexradar.com/current.json")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!)
            }
        )

        let snapshot = try await reader.readRadar()

        XCTAssertEqual(snapshot.schemaVersion, "2.0")
        XCTAssertEqual(snapshot.modelIQ.quotaRadar?.basisWindowLabel, "7d")
    }

    func testParsesRSSFeedItemsForDetailHistory() throws {
        let items = try CodexRadarFeedParser.parse(Data(Self.sampleRSS.utf8))

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.title, "权益记录：Codex 用量限制已重置")
        XCTAssertEqual(items.first?.guid, "codex-speed-window-2026-06-17-codex-close")
        XCTAssertEqual(items.first?.pubDate, "Wed, 17 Jun 2026 21:25:51 GMT")
        XCTAssertTrue(items.first?.description.contains("Codex 用量限制已重置") == true)
        XCTAssertEqual(items.last?.title, "速蹬窗口开启：500 万用户庆祝重置")
    }

    private static let sampleJSON = """
    {
      "schema_version": "2.0",
      "service": "codex-reset-radar",
      "monitored_at": "2026-06-23T08:51:28.710622+08:00",
      "timezone": "Asia/Shanghai",
      "window_open": false,
      "status": "none",
      "recommended_action": "wait",
      "window": {
        "open": false,
        "status": "none",
        "action": "wait",
        "message": "当前没有开启的速蹬窗口",
        "title": "Codex 用量限制重置",
        "scope": "Codex 用户",
        "opened_at": null,
        "closed_at": "2026-06-18T08:10:10+08:00",
        "source_url": "https://x.com/thsottiaux/status/2067399435009622521"
      },
      "prediction": {
        "level": "medium_low",
        "probability_24h": 0.13,
        "probability_48h": 0.3,
        "expected_window": "未来 24-48 小时",
        "summary": "没有官方窗口或长时未补偿事故，不能给高概率。",
        "summary_en": "No official window or long uncompensated incident is present.",
        "positive_signals": ["Tibo/Sam/OpenAI 在过去 24 小时集中推广 Codex"],
        "negative_signals": ["official_window_review 已确认没有 Tibo/Sam/OpenAI 官方 reset 窗口"],
        "updated_at": "2026-06-23T08:51:28.347260+08:00"
      },
      "tibo_presence": {
        "schema_version": "1.0",
        "mode": "inferred",
        "timezone": "Europe/Paris",
        "location_label_zh": "法国 / CET",
        "location_label_en": "France / CET",
        "probability": 0.9,
        "confidence": "high",
        "evidence_summary_zh": "公开发帖称自己在法国。",
        "evidence_summary_en": "Public country-level post.",
        "source_urls": ["https://x.com/thsottiaux/status/2067064381855187231"],
        "should_display": true,
        "safety_note_zh": "仅基于公开发帖做国家/时区级推测。",
        "safety_note_en": "Coarse public context only.",
        "updated_at": "2026-06-23T00:51:42.550781Z",
        "observed_at": "2026-06-22T23:55:37Z",
        "stale_at": "2026-06-24T00:55:37Z",
        "observations_considered": 40
      },
      "recent_windows": [],
      "links": {
        "html": "https://codexradar.com/",
        "rss": "https://codexradar.com/feed.xml"
      },
      "model_iq": {
        "latest": {
          "date": "2026-06-23",
          "score": 125.0,
          "status": "green",
          "passed": 10,
          "tasks": 12,
          "invalid": 0,
          "total_tokens": 41602755,
          "input_tokens": 41238081,
          "cached_input_tokens": 39315328,
          "output_tokens": 364674,
          "wall_seconds": 2757,
          "wall_time_human": "46分钟",
          "model": "gpt-5.5",
          "reasoning_effort": "xhigh",
          "valid_tasks": 12,
          "cost_usd": 40.211649
        },
        "recent_days": [
          {
            "date": "2026-06-22-pm",
            "score": 50.0,
            "status": "red",
            "passed": 4,
            "tasks": 12,
            "invalid": 0,
            "total_tokens": 44515136,
            "input_tokens": 44137718,
            "cached_input_tokens": 41759360,
            "output_tokens": 377418,
            "wall_seconds": 3261,
            "wall_time_human": "54分钟"
          },
          {
            "date": "2026-06-23",
            "score": 125.0,
            "status": "green",
            "passed": 10,
            "tasks": 12,
            "invalid": 0,
            "total_tokens": 41602755,
            "input_tokens": 41238081,
            "cached_input_tokens": 39315328,
            "output_tokens": 364674,
            "wall_seconds": 2757,
            "wall_time_human": "46分钟"
          }
        ],
        "comparisons": {
          "gpt_55_high": {
            "label": "GPT-5.5 high",
            "model": "gpt-5.5",
            "reasoning_effort": "high",
            "latest": {
              "date": "2026-06-23",
              "score": 87.5,
              "status": "yellow",
              "passed": 7,
              "tasks": 12,
              "invalid": 0,
              "total_tokens": 30939960,
              "input_tokens": 30702185,
              "cached_input_tokens": 28715776,
              "output_tokens": 237775,
              "wall_seconds": 3049,
              "wall_time_human": "51分钟",
              "model": "gpt-5.5",
              "reasoning_effort": "high",
              "valid_tasks": 12,
              "cost_usd": 31.423183
            },
            "recent_days": []
          },
          "gpt_55_medium": {
            "label": "GPT-5.5 medium",
            "model": "gpt-5.5",
            "reasoning_effort": "medium",
            "latest": {
              "date": "2026-06-23",
              "score": 87.5,
              "status": "yellow",
              "passed": 7,
              "tasks": 12,
              "invalid": 0,
              "total_tokens": 21077844,
              "input_tokens": 20910298,
              "cached_input_tokens": 19402496,
              "output_tokens": 167546,
              "wall_seconds": 1252,
              "wall_time_human": "21分钟",
              "model": "gpt-5.5",
              "reasoning_effort": "medium",
              "valid_tasks": 12,
              "cost_usd": 22.266638
            },
            "recent_days": []
          },
          "gpt_54_xhigh": {
            "label": "GPT-5.4 xhigh",
            "model": "gpt-5.4",
            "reasoning_effort": "xhigh",
            "latest": {
              "date": "2026-06-23",
              "score": 87.5,
              "status": "yellow",
              "passed": 7,
              "tasks": 12,
              "invalid": 0,
              "total_tokens": 42712526,
              "input_tokens": 42238309,
              "cached_input_tokens": 40140288,
              "output_tokens": 474217,
              "wall_seconds": 3836,
              "wall_time_human": "1小时4分",
              "model": "gpt-5.4",
              "reasoning_effort": "xhigh",
              "valid_tasks": 12,
              "cost_usd": 22.393379
            },
            "recent_days": []
          }
        },
        "quota_calibration": {
          "schema_version": "1.0",
          "date": "2026-06-23",
          "source": "model-iq-deepswe-12-v1-4configs-pool16-20260623",
          "status": "valid",
          "primary_window": "primary_5h",
          "global_concurrency": 16,
          "checked_at_before": "2026-06-23T05:30:25Z",
          "checked_at_after": "2026-06-23T06:34:28Z",
          "tasks": 48,
          "valid_tasks": 48,
          "cost_usd": 116.194986,
          "total_tokens": 136899968,
          "windows": {}
        },
        "quota_radar": {
          "date": "2026-06-23",
          "source": "model-iq-deepswe-12-v1-4configs-pool16-20260623",
          "updated_at": "2026-06-23T06:34:28Z",
          "basis_date": "2026-06-23",
          "cost_usd": 116.194986,
          "total_tokens": 136899968,
          "basis_window": "secondary_7d",
          "basis_window_label": "7d",
          "adjusted_delta": 7,
          "raw_delta": 7,
          "offset": 0,
          "rate": 16.5993,
          "rows": [
            {
              "tier": "20x Pro",
              "basis": "measured 7d",
              "five_h": 276.66,
              "seven_d": 1659.93
            },
            {
              "tier": "5x Pro",
              "basis": "model /4",
              "five_h": 69.17,
              "seven_d": 414.98
            },
            {
              "tier": "Plus",
              "basis": "model /20",
              "five_h": 13.83,
              "seven_d": 83.0
            }
          ],
          "trend": [
            {
              "date": "2026-06-22",
              "source": "model-iq-deepswe-12-v1-4configs-pool16-20260622",
              "updated_at": "2026-06-22T01:55:40Z",
              "five_h_20x": 303.36,
              "seven_d_20x": 1820.16,
              "five_h_5x": 75.84,
              "five_h_plus": 15.17,
              "basis_window": "primary_5h",
              "basis_window_label": "5h",
              "rate": 3.0336,
              "raw_delta": 39,
              "adjusted_delta": 38,
              "offset": 1,
              "cost_usd": 115.278007,
              "total_tokens": 133628889
            },
            {
              "date": "2026-06-23",
              "source": "model-iq-deepswe-12-v1-4configs-pool16-20260623",
              "updated_at": "2026-06-23T06:34:28Z",
              "five_h_20x": 276.66,
              "seven_d_20x": 1659.93,
              "five_h_5x": 69.17,
              "five_h_plus": 13.83,
              "basis_window": "secondary_7d",
              "basis_window_label": "7d",
              "rate": 16.5993,
              "raw_delta": 7,
              "adjusted_delta": 7,
              "offset": 0,
              "cost_usd": 116.194986,
              "total_tokens": 136899968
            }
          ]
        },
        "quota_check": {
          "schema_version": "1.0",
          "date": "2026-06-23",
          "source": "manual_quota_check",
          "status": "failed",
          "checked_at": "2026-06-23T05:29:31Z",
          "plan_type": null,
          "rate_limit_reset_credits_available_count": null,
          "limit_reached": null,
          "allowed": null,
          "windows": {}
        }
      },
      "codex_environment": {
        "schema_version": "1.0",
        "type": "codex_environment",
        "updated_at": "2026-06-23T08:51:28.347260+08:00",
        "status_incidents_24h": 0,
        "official_updates_24h": 12,
        "community_mentions_24h": 48,
        "issue_or_limit_anomalies_24h": 10,
        "complaint_pressure": "medium",
        "reset_card": {
          "probability_24h": 0.13,
          "probability_48h": 0.3,
          "level": "medium_low",
          "status": "prediction_only",
          "note": "Email and RSS should be reserved for confirmed official card grants or benefit events."
        },
        "official_news": [],
        "status_incidents": [],
        "complaint_examples": [],
        "role_counts": {
          "market_motive": 38,
          "issue_or_limit_anomaly": 10
        }
      }
    }
    """

    private static let sampleRSS = """
    <?xml version='1.0' encoding='utf-8'?>
    <rss version="2.0">
      <channel>
        <title>Codex 雷达</title>
        <link>https://codexradar.com/</link>
        <description>只发布 Codex 速蹬窗口开启和关闭提醒。</description>
        <language>zh-CN</language>
        <ttl>10</ttl>
        <item>
          <title>权益记录：Codex 用量限制已重置</title>
          <link>https://codexradar.com/#codex-speed-window-2026-06-17-codex</link>
          <guid isPermaLink="false">codex-speed-window-2026-06-17-codex-close</guid>
          <pubDate>Wed, 17 Jun 2026 21:25:51 GMT</pubDate>
          <description>Codex 用量限制已重置。确认依据：用户确认已到账。</description>
        </item>
        <item>
          <title>速蹬窗口开启：500 万用户庆祝重置</title>
          <link>https://codexradar.com/#codex-speed-window-2026-05-31-500</link>
          <guid isPermaLink="false">codex-speed-window-2026-05-31-500-open</guid>
          <pubDate>Sun, 31 May 2026 05:59:10 GMT</pubDate>
          <description>发现有效重置预告，速蹬窗口开启。</description>
        </item>
      </channel>
    </rss>
    """
}

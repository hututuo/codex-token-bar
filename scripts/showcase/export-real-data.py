#!/usr/bin/env python3
"""Export an allowlisted, read-only local statistics snapshot for the showcase.

Run only with the data owner's permission to publish the resulting statistics.
No conversation bodies, credentials, paths, routing or authentication fields
are copied. Usage comes from the app's committed canonical aggregate tables.
"""
from pathlib import Path
from datetime import datetime, timezone, timedelta
from zoneinfo import ZoneInfo
from collections import defaultdict
import argparse
import hashlib
import json
import math
import sqlite3
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--capture-directory', type=Path, required=True)
parser.add_argument('--codex-home', type=Path, required=True)
parser.add_argument('--support-directory', type=Path, required=True)
args = parser.parse_args()
capture = args.capture_directory
home = args.codex_home.resolve()
support = args.support_directory
now = time.time()
tz = ZoneInfo('Asia/Shanghai')
today = datetime.fromtimestamp(now, tz).date()
day_start = datetime.combine(today, datetime.min.time(), tz).timestamp()
iso = lambda value: datetime.fromtimestamp(value, timezone.utc).isoformat().replace('+00:00', 'Z')

def readonly(path):
    connection = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)
    connection.row_factory = sqlite3.Row
    connection.execute('PRAGMA query_only=ON')
    connection.execute('BEGIN')
    return connection

digest = hashlib.sha256(str(home).encode()).hexdigest()
index_path = support / 'CodexTokenBarSwift/exact-usage-history-v1' / (digest + '.sqlite')
index = readonly(index_path)
numeric = ['input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_output_tokens', 'total_tokens', 'calls']
camel = ['inputTokens', 'cachedInputTokens', 'outputTokens', 'reasoningOutputTokens', 'totalTokens', 'calls']
columns = ','.join('COALESCE(SUM(' + name + '),0) AS ' + name for name in numeric)

def breakdown(row):
    return {key: int(row[name] or 0) for name, key in zip(numeric, camel)}

total = breakdown(index.execute('SELECT ' + columns + ' FROM dashboard_source_totals').fetchone())
today_total = breakdown(index.execute('SELECT ' + columns + ' FROM dashboard_5m WHERE bucket_start>=? AND bucket_start<=?', (day_start, now)).fetchone())
models = [{'model': row['model'] or None, 'breakdown': breakdown(row)} for row in index.execute('SELECT model,' + columns + ' FROM dashboard_5m WHERE bucket_start>=? AND bucket_start<=? GROUP BY model ORDER BY SUM(total_tokens) DESC', (day_start, now))]

# Only this account/limit's observed history; no synthetic quota curve.
quota_db = readonly(support / 'CodexTokenBar/quota-history.sqlite')
last = quota_db.execute('SELECT * FROM quota_snapshots ORDER BY created_at DESC LIMIT 1').fetchone()
history = list(quota_db.execute('SELECT created_at,five_hour_used_percent,seven_day_used_percent,five_hour_resets_at,seven_day_resets_at FROM quota_snapshots WHERE account_key=? AND created_at>=? AND created_at<=? ORDER BY created_at', (last['account_key'], now - 366 * 86400, now)))

def quota_points(step):
    grouped = defaultdict(list)
    for row in history:
        grouped[int(row['created_at'] // step) * step].append(row)
    return grouped

def quota_at(rows, key):
    values = [1 - row[key] / 100 for row in rows if row[key] is not None]
    return sum(values) / len(values) if values else None

def points(count, step):
    first = int(now // step) * step - (count - 1) * step
    grouped = defaultdict(list)
    for row in index.execute('SELECT CAST(bucket_start/? AS INTEGER)*? AS at,model,' + columns + ' FROM dashboard_5m WHERE bucket_start>=? AND bucket_start<=? GROUP BY at,model ORDER BY at', (step, step, first, now)):
        grouped[int(row['at'])].append(row)
    q = quota_points(step)
    result = []
    for i in range(count):
        at = first + i * step
        parts = grouped[at]
        totals = {name: sum(int(row[name] or 0) for row in parts) for name in numeric}
        row = {'label': iso(at), 'startUnix': at, 'tokens': totals['total_tokens'], 'calls': totals['calls'],
               'inputTokens': totals['input_tokens'], 'cachedInputTokens': totals['cached_input_tokens'],
               'outputTokens': totals['output_tokens'],
               'cacheHitRate': totals['cached_input_tokens'] / totals['input_tokens'] if totals['input_tokens'] else None,
               'fiveHourRemainingPercent': quota_at(q[at], 'five_hour_used_percent'),
               'sevenDayRemainingPercent': quota_at(q[at], 'seven_day_used_percent'),
               'modelBreakdowns': [{'model': p['model'] or None, 'breakdown': breakdown(p)} for p in parts]}
        for label, field in [('fiveHour', 'five_hour_resets_at'), ('sevenDay', 'seven_day_resets_at')]:
            anchor = next((r[field] for r in reversed(q[at]) if r[field]), None)
            if anchor is not None:
                row[label + 'CycleId'] = label + ':' + str(int(anchor))
        result.append(row)
    return result

recent = {'recentUsage24h': points(288, 300), 'recentUsage7d': points(168, 3600), 'recentUsage30d': points(120, 21600)}
first_day = today - timedelta(days=364)
daily = defaultdict(list)
for row in index.execute("SELECT date(bucket_start,'unixepoch','+8 hours') AS day,model," + columns + " FROM dashboard_5m WHERE bucket_start>=? AND bucket_start<=? GROUP BY day,model ORDER BY day", (datetime.combine(first_day, datetime.min.time(), tz).timestamp(), now)):
    daily[row['day']].append(row)
days = []
for offset in range(365):
    date = (first_day + timedelta(days=offset)).isoformat()
    rows = daily[date]
    inp = sum(row['input_tokens'] for row in rows)
    days.append({'date': date, 'tokens': sum(row['total_tokens'] for row in rows), 'calls': sum(row['calls'] for row in rows),
                 'cacheHitRate': sum(row['cached_input_tokens'] for row in rows) / inp if inp else None,
                 'fiveHourRemainingPercent': None, 'sevenDayRemainingPercent': None,
                 'modelBreakdowns': [{'model': row['model'] or None, 'breakdown': breakdown(row)} for row in rows]})

speed_path = max((support / 'CodexTokenBar').glob('body-speed-*.sqlite'), key=lambda p: p.stat().st_mtime)
speed_db = readonly(speed_path)
recent_samples = list(speed_db.execute('SELECT payload_json,included FROM speed_samples WHERE ended_at<=? AND ended_at>=? ORDER BY ended_at DESC', (now, now - 1800)))
older_samples = list(speed_db.execute('SELECT payload_json,included FROM speed_samples WHERE ended_at<? ORDER BY ended_at DESC LIMIT 50', (now - 1800,)))
raw_samples = recent_samples + older_samples
allowed_sample_keys = {'id','threadID','turnID','itemID','model','startedAt','endedAt','outputTokens','outputCharacters','outputBytes','chunkCount','durationSeconds','tokensPerSecond','confidence','source','measurementKind','tokenizer','bodyPhase','networkWarning'}
samples = []
qualified = []
for row in raw_samples:
    raw = json.loads(row['payload_json'])
    sample = {key.replace('ID', 'Id'): value for key, value in raw.items() if key in allowed_sample_keys}
    if sample.get('measurementKind') != 'completed_body':
        continue
    samples.append(sample)
    if row['included'] and sample.get('model') not in ['', 'unknown', None]:
        qualified.append(sample)

def summaries(seconds, latest=False):
    grouped = defaultdict(list)
    for sample in qualified:
        if now - seconds <= sample['endedAt'] <= now:
            grouped[sample['model']].append(sample)
    result = []
    for model, parts in grouped.items():
        parts.sort(key=lambda s: (-s['endedAt'], s['id']))
        if latest:
            parts = parts[:1]
        tokens = sum(s['outputTokens'] for s in parts)
        duration = sum(s['durationSeconds'] for s in parts)
        result.append({'model': model, 'tokensPerSecond': tokens / duration, 'sampleCount': len(parts), 'qualifiedSampleCount': len(parts),
                       'outputTokens': tokens, 'durationSeconds': duration, 'confidence': 'high' if duration >= 5 else 'medium',
                       'lastMeasuredAt': max(s['endedAt'] for s in parts)})
    return sorted(result, key=lambda s: (-s['lastMeasuredAt'], s['model']))

running = json.loads((capture / 'local-running-capture.json').read_text())
state = readonly(home / 'state_5.sqlite')
ids = {s['threadId'] for s in samples[:50]}
threads = []
for thread_id in sorted(ids):
    row = state.execute('SELECT id,title,name,updated_at FROM threads WHERE id=?', (thread_id,)).fetchone()
    if row:
        # Codex's `title` can hold the full first prompt. `name` is its actual
        # sidebar title; never publish that prompt as a display-name fallback.
        threads.append({'id': row['id'], 'title': row['name'] or '未命名会话', 'updatedAt': iso(row['updated_at']), 'subtitle': '本机历史会话'})

raw_quota = json.loads((capture / 'local-quota-capture.json').read_text())
rpc = raw_quota['quota']
limit = rpc.get('rateLimitsByLimitId', {}).get('codex') or rpc['rateLimits']
windows = {w['windowDurationMins']: w for w in [limit.get('primary'), limit.get('secondary')] if w}
def quota_window(label, minutes):
    w = windows.get(minutes)
    return {'label': label, 'availability': 'measured' if w else 'absent', 'remainingPercent': max(0, 1-w['usedPercent']/100) if w else None,
            'usedPercent': w['usedPercent']/100 if w else None, 'resetsAt': iso(w['resetsAt']) if w and w.get('resetsAt') else '', 'resetsAtUnix': w.get('resetsAt') if w else None}
account = raw_quota.get('account', {}).get('account') or {}
quota = {'updatedAt': iso(raw_quota['capturedAt']), 'account': {'displayName': (account.get('email') or '本机账号').split('@')[0], 'planLabel': (limit.get('planType') or '').upper()},
         'quota': {'fiveHour': quota_window('5h', 300), 'sevenDay': quota_window('7d', 10080),
                   'resetCredit': {'availableCount': rpc.get('rateLimitResetCredits', {}).get('availableCount', 0), 'credits': [], 'status': 'Codex 返回的可用数量', 'updatedAt': iso(raw_quota['capturedAt'])},
                   'paceLabel': ''}, 'warnings': [], 'diagnostics': []}

result = {'capturedAt': iso(now), 'capturedAtUnix': now, 'timezone': 'Asia/Shanghai',
          'dataKind': 'owner-authorized local statistics snapshot', 'total': total, 'today': today_total, 'models': models,
          'recent': recent, 'days': days, 'samples': samples[:50], 'modelSpeeds15m': summaries(900), 'modelSpeeds30m': summaries(1800),
          'latestModelSpeeds30m': summaries(1800, True), 'runningThreads': running, 'threads': threads, 'quota': quota,
          'officialRadarRaw': json.loads((capture / 'real-radar-official.json').read_text()),
          'crowdRadarRaw': json.loads((capture / 'real-radar-crowd.json').read_text()),
          'usageDataUpdatedAt': iso(index.execute('SELECT MAX(last_timestamp) FROM dashboard_source_totals').fetchone()[0]),
          'activityRate': None, 'activityRateNote': '瞬时活动速率未持久化，快照不虚构读数'}
destination = capture / 'local-statistics-export.json'
destination.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':'), allow_nan=False) + '\n')
print(json.dumps({'file': str(destination), 'bytes': destination.stat().st_size, 'totalTokens': total['totalTokens'], 'todayTokens': today_total['totalTokens'],
                  'todayCalls': today_total['calls'], 'samples': len(samples[:50]), 'models30m': len(result['modelSpeeds30m']), 'running': running['total'],
                  'dailyTodayMatches': days[-1]['tokens'] == today_total['totalTokens'], 'sourceUpdatedAt': result['usageDataUpdatedAt']}, ensure_ascii=False))

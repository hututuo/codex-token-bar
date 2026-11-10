-- Read-only response projection shared by Swift and Rust. Physical event IDs,
-- payloads, revisions and checkpoints remain untouched. Apply time/client
-- filters to effective_client_usage_events, AFTER merging all observations.
WITH client_usage_observations AS MATERIALIZED (
    SELECT client,event_id,session_id,model,timestamp,input_tokens,output_tokens,
           cache_read_tokens,cache_write_tokens,reasoning_tokens,
           CASE WHEN client IN ('claudeDesktop','claudeCode')
                     AND length(event_id)=135 AND substr(event_id,1,3)='v1:'
                     AND substr(event_id,68,4)=':id:'
                     AND substr(event_id,4,64) NOT GLOB '*[^0-9a-f]*'
                     AND substr(event_id,72,64) NOT GLOB '*[^0-9a-f]*'
                THEN substr(event_id,72,64) END AS response_id,
           CASE WHEN typeof(payload)='text' AND length(CAST(payload AS BLOB))<=65536
                THEN CASE WHEN json_valid(payload)
                     THEN CASE WHEN json_type(payload,'$.cacheWrite5mTokens')='integer'
                                    AND json_extract(payload,'$.cacheWrite5mTokens') BETWEEN 0 AND 1000000000000
                               THEN json_extract(payload,'$.cacheWrite5mTokens') END END END AS cache_write_5m_tokens,
           CASE WHEN typeof(payload)='text' AND length(CAST(payload AS BLOB))<=65536
                THEN CASE WHEN json_valid(payload)
                     THEN CASE WHEN json_type(payload,'$.cacheWrite1hTokens')='integer'
                                    AND json_extract(payload,'$.cacheWrite1hTokens') BETWEEN 0 AND 1000000000000
                               THEN json_extract(payload,'$.cacheWrite1hTokens') END END END AS cache_write_1h_tokens
    FROM client_usage_events
), claude_response_observations AS (
    SELECT *,
           FIRST_VALUE(event_id) OVER response AS owner_event_id,
           FIRST_VALUE(session_id) OVER response AS owner_session_id,
           MAX(timestamp) OVER response AS merged_timestamp,
           MAX(input_tokens) OVER response AS merged_input,
           MAX(output_tokens) OVER response AS merged_output,
           MAX(cache_read_tokens) OVER response AS merged_read,
           MAX(cache_write_tokens) OVER response AS merged_write,
           MAX(reasoning_tokens) OVER response AS merged_reasoning
    FROM client_usage_observations WHERE response_id IS NOT NULL
    -- Raw model and client identities are billing/source boundaries. Never
    -- merge aliases, Fast variants, different clients or fallback identities.
    WINDOW response AS (PARTITION BY client,model,response_id ORDER BY event_id
                        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
), claude_response_ranked AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY client,model,response_id
        ORDER BY CASE WHEN cache_write_tokens=merged_write
                           AND cache_write_5m_tokens<=merged_write
                           AND cache_write_1h_tokens=merged_write-cache_write_5m_tokens
                      THEN 0 ELSE 1 END,
                 timestamp DESC,event_id
    ) AS observation_rank
    FROM claude_response_observations
), effective_client_usage_events AS (
    -- Select one coherent TTL pair from an observation of the merged total;
    -- never MAX the two lifetime counters independently. Null stays unknown.
    -- Owner is deterministic, not a claim about the original/fork parent.
    SELECT client,owner_event_id AS event_id,owner_session_id AS session_id,model,
           merged_timestamp AS timestamp,merged_input AS input_tokens,
           merged_output AS output_tokens,merged_read AS cache_read_tokens,
           merged_write AS cache_write_tokens,merged_reasoning AS reasoning_tokens,
           cache_write_5m_tokens,cache_write_1h_tokens
    FROM claude_response_ranked WHERE observation_rank=1
    UNION ALL
    SELECT client,event_id,session_id,model,timestamp,input_tokens,output_tokens,
           cache_read_tokens,cache_write_tokens,reasoning_tokens,
           cache_write_5m_tokens,cache_write_1h_tokens
    FROM client_usage_observations WHERE response_id IS NULL
)

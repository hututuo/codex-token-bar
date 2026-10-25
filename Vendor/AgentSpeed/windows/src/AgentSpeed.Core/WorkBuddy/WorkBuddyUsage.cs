using System.Text.Json;
using AgentSpeed.Core.Parsing;

namespace AgentSpeed.Core.WorkBuddy;

/// <summary>
/// The two usage records of one model call (METRICS 4.9 Tokens): agents-core's <c>providerData.usage</c> and the
/// service's OpenAI-style <c>providerData.rawUsage</c>, combined field by field with <c>max</c>.
/// </summary>
internal struct WorkBuddyUsage
{
    public bool HasCore;
    public long InputTokens;
    public long OutputTokens;

    /// <summary>Σ <c>inputTokensDetails[].cached_tokens</c>.</summary>
    public long DetailCached;

    /// <summary>Σ <c>outputTokensDetails[].reasoning_tokens</c>.</summary>
    public long DetailReasoning;

    public bool HasRaw;
    public long PromptTokens;
    public long CompletionTokens;
    public long CompletionReasoning;

    // The candidates of a "first value above 0" rule: null unless the field is a finite number above 0.
    public long? CacheReadInput;
    public long? PromptDetailsCached;
    public long? PromptCacheHit;
    public long? CacheCreationInput;
    public long? PromptCacheWrite;

    /// <summary>
    /// Input includes cache reads and writes (the OpenAI convention); DeepSeek's <c>prompt_cache_miss_tokens</c> are
    /// uncached input and never a cache write.
    /// </summary>
    public readonly TokenCounts Normalize()
    {
        var cached = Math.Max(DetailCached, CacheReadInput ?? PromptDetailsCached ?? PromptCacheHit ?? 0);
        var write = CacheCreationInput ?? PromptCacheWrite ?? 0;
        var input = Math.Max(Math.Max(InputTokens, PromptTokens), JsonScan.SaturatingAdd(cached, write));
        return new TokenCounts(
            input,
            cached,
            write,
            Math.Max(OutputTokens, CompletionTokens),
            Math.Max(DetailReasoning, CompletionReasoning));
    }

    /// <summary><c>providerData.usage</c> is missing or not an object (a later duplicate key replaces an earlier one).</summary>
    public void ClearCore()
    {
        HasCore = false;
        InputTokens = OutputTokens = DetailCached = DetailReasoning = 0;
    }

    /// <summary><c>providerData.rawUsage</c> is missing or not an object.</summary>
    public void ClearRaw()
    {
        HasRaw = false;
        PromptTokens = CompletionTokens = CompletionReasoning = 0;
        CacheReadInput = PromptDetailsCached = PromptCacheHit = CacheCreationInput = PromptCacheWrite = null;
    }

    /// <summary>Reads <c>providerData.usage</c>; the reader is on its object and ends on its EndObject.</summary>
    public void ReadCore(ref Utf8JsonReader reader)
    {
        ClearCore();
        HasCore = true;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("inputTokens"u8))
            {
                reader.Read();
                InputTokens = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("outputTokens"u8))
            {
                reader.Read();
                OutputTokens = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("inputTokensDetails"u8))
            {
                reader.Read();
                DetailCached = SumDetails(ref reader, "cached_tokens"u8);
            }
            else if (reader.ValueTextEquals("outputTokensDetails"u8))
            {
                reader.Read();
                DetailReasoning = SumDetails(ref reader, "reasoning_tokens"u8);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }
    }

    /// <summary>Reads <c>providerData.rawUsage</c>; the reader is on its object and ends on its EndObject.</summary>
    public void ReadRaw(ref Utf8JsonReader reader)
    {
        ClearRaw();
        HasRaw = true;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            if (reader.ValueTextEquals("prompt_tokens"u8))
            {
                reader.Read();
                PromptTokens = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("completion_tokens"u8))
            {
                reader.Read();
                CompletionTokens = JsonScan.ReadCount(ref reader);
            }
            else if (reader.ValueTextEquals("prompt_tokens_details"u8))
            {
                reader.Read();
                PromptDetailsCached = null;
                if (reader.TokenType == JsonTokenType.StartObject)
                {
                    PromptDetailsCached = ReadField(ref reader, "cached_tokens"u8, positive: true);
                }

                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("completion_tokens_details"u8))
            {
                reader.Read();
                CompletionReasoning = 0;
                if (reader.TokenType == JsonTokenType.StartObject)
                {
                    CompletionReasoning = ReadField(ref reader, "reasoning_tokens"u8, positive: false) ?? 0;
                }

                JsonScan.SkipValue(ref reader);
            }
            else if (reader.ValueTextEquals("cache_read_input_tokens"u8))
            {
                reader.Read();
                CacheReadInput = ReadPositive(ref reader);
            }
            else if (reader.ValueTextEquals("prompt_cache_hit_tokens"u8))
            {
                reader.Read();
                PromptCacheHit = ReadPositive(ref reader);
            }
            else if (reader.ValueTextEquals("cache_creation_input_tokens"u8))
            {
                reader.Read();
                CacheCreationInput = ReadPositive(ref reader);
            }
            else if (reader.ValueTextEquals("prompt_cache_write_tokens"u8))
            {
                reader.Read();
                PromptCacheWrite = ReadPositive(ref reader);
            }
            else
            {
                reader.Read();
                JsonScan.SkipValue(ref reader);
            }
        }
    }

    /// <summary>
    /// Σ of one counter over agents-core's detail entries: an array of objects, or a single object; anything else is 0.
    /// The reader is on the value and ends on its last token.
    /// </summary>
    private static long SumDetails(ref Utf8JsonReader reader, ReadOnlySpan<byte> field)
    {
        if (reader.TokenType == JsonTokenType.StartObject)
        {
            return ReadField(ref reader, field, positive: false) ?? 0;
        }

        if (reader.TokenType != JsonTokenType.StartArray)
        {
            JsonScan.SkipValue(ref reader);
            return 0;
        }

        long sum = 0;
        while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
        {
            if (reader.TokenType == JsonTokenType.StartObject)
            {
                sum = JsonScan.SaturatingAdd(sum, ReadField(ref reader, field, positive: false) ?? 0);
            }
            else
            {
                JsonScan.SkipValue(ref reader);
            }
        }

        return sum;
    }

    // The last occurrence of one field of an object, as a count or as a "first above 0" candidate. The reader is on the
    // object and ends on its EndObject.
    private static long? ReadField(ref Utf8JsonReader reader, ReadOnlySpan<byte> field, bool positive)
    {
        long? value = positive ? null : 0;
        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var wanted = reader.ValueTextEquals(field);
            reader.Read();
            if (!wanted)
            {
                JsonScan.SkipValue(ref reader);
            }
            else
            {
                value = positive ? ReadPositive(ref reader) : JsonScan.ReadCount(ref reader);
            }
        }

        return value;
    }

    /// <summary>A finite number above 0, truncated like a count (a value below 1 counts as 0); null for anything else.</summary>
    private static long? ReadPositive(ref Utf8JsonReader reader)
    {
        if (reader.TokenType != JsonTokenType.Number)
        {
            JsonScan.SkipValue(ref reader);
            return null;
        }

        if (reader.TryGetInt64(out var whole))
        {
            return whole > 0 ? TokenCounts.Clamp(whole) : null;
        }

        return reader.TryGetDouble(out var real) && double.IsFinite(real) && real > 0
            ? (real >= TokenCounts.MaxValue ? TokenCounts.MaxValue : (long)real)
            : null;
    }
}

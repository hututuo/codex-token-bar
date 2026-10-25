using System.Buffers;
using System.Text;
using System.Text.Json;

namespace AgentSpeed.Core.Gemini;

/// <summary>
/// Python <c>str.strip()</c> semantics, which the reference implementation uses: unlike
/// <see cref="char.IsWhiteSpace(char)"/> they also treat U+001C..U+001F as whitespace.
/// </summary>
internal static class GeminiText
{
    public static bool IsSpace(int codePoint) => codePoint switch
    {
        >= 0x09 and <= 0x0D => true,
        >= 0x1C and <= 0x20 => true,
        0x85 or 0xA0 or 0x1680 => true,
        >= 0x2000 and <= 0x200A => true,
        0x2028 or 0x2029 or 0x202F or 0x205F or 0x3000 => true,
        _ => false,
    };

    public static ReadOnlySpan<char> Strip(ReadOnlySpan<char> text)
    {
        var start = 0;
        while (start < text.Length && IsSpace(text[start]))
        {
            start++;
        }

        var end = text.Length;
        while (end > start && IsSpace(text[end - 1]))
        {
            end--;
        }

        return text[start..end];
    }

    /// <summary><c>bool(value.strip())</c> for the string token the reader is on, without decoding it.</summary>
    public static bool HasVisibleText(ref Utf8JsonReader reader) =>
        reader.TokenType == JsonTokenType.String && HasVisibleText(reader.ValueSpan, reader.ValueIsEscaped);

    /// <summary>True when the raw JSON string contents hold a code point that is not whitespace.</summary>
    public static bool HasVisibleText(ReadOnlySpan<byte> raw, bool escaped)
    {
        var i = 0;
        while (i < raw.Length)
        {
            var b = raw[i];
            if (escaped && b == '\\')
            {
                if (i + 1 >= raw.Length)
                {
                    return true;
                }

                switch (raw[i + 1])
                {
                    case (byte)'n' or (byte)'t' or (byte)'r' or (byte)'f':
                        i += 2;
                        continue;
                    case (byte)'u' when i + 6 <= raw.Length && TryHex4(raw.Slice(i + 2, 4), out var unit):
                        // Surrogates are never whitespace, so a pair needs no decoding.
                        if (!IsSpace(unit))
                        {
                            return true;
                        }

                        i += 6;
                        continue;
                    default:
                        return true;
                }
            }

            if (b < 0x80)
            {
                if (!IsSpace(b))
                {
                    return true;
                }

                i++;
                continue;
            }

            if (Rune.DecodeFromUtf8(raw[i..], out var rune, out var consumed) != OperationStatus.Done || !IsSpace(rune.Value))
            {
                return true;
            }

            i += consumed;
        }

        return false;
    }

    private static bool TryHex4(ReadOnlySpan<byte> digits, out int value)
    {
        value = 0;
        foreach (var d in digits)
        {
            var nibble = d switch
            {
                >= (byte)'0' and <= (byte)'9' => d - '0',
                >= (byte)'a' and <= (byte)'f' => d - 'a' + 10,
                >= (byte)'A' and <= (byte)'F' => d - 'A' + 10,
                _ => -1,
            };
            if (nibble < 0)
            {
                return false;
            }

            value = (value << 4) | nibble;
        }

        return true;
    }
}

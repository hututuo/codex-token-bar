using System.Buffers.Binary;
using System.Text;

namespace AgentSpeed.Core.Antigravity;

/// <summary>Raised for a blob that breaks the wire format (METRICS 4.8); the whole blob counts as one malformed line.</summary>
internal sealed class ProtoFormatException(string message) : Exception(message);

/// <summary>One top-level field: its number, wire type, and the varint or fixed value or the payload's position.</summary>
internal readonly record struct ProtoField(long Number, int Wire, ulong Value, int Start, int Length);

/// <summary>
/// The top-level fields of one protobuf message, decoded by a small walker without a protobuf library (METRICS 4.8).
/// Unknown fields of every valid wire type are skipped; field number 0, groups (wire types 3 and 4), wire types 6 and
/// 7, varints longer than 10 bytes and fields running past the buffer make the message malformed. Nested messages are
/// decoded only when read, so a malformed field nobody reads does not matter.
/// </summary>
internal readonly ref struct ProtoMessage
{
    public const int WireVarint = 0;
    public const int WireFixed64 = 1;
    public const int WireLength = 2;
    public const int WireFixed32 = 5;

    private const int MaxVarintBytes = 10;

    private readonly ReadOnlySpan<byte> _data;
    private readonly ProtoField[] _fields;

    private ProtoMessage(ReadOnlySpan<byte> data, ProtoField[] fields)
    {
        _data = data;
        _fields = fields;
    }

    public int Count => _fields.Length;

    /// <exception cref="ProtoFormatException">The buffer is not a well-formed message.</exception>
    public static ProtoMessage Parse(ReadOnlySpan<byte> data)
    {
        var fields = new List<ProtoField>();
        var position = 0;
        while (position < data.Length)
        {
            var key = ReadVarint(data, ref position);
            var number = key >> 3;
            var wire = (int)(key & 7);
            if (number == 0)
            {
                throw new ProtoFormatException("field number 0");
            }

            var known = number <= long.MaxValue ? (long)number : -1;
            switch (wire)
            {
                case WireVarint:
                    fields.Add(new ProtoField(known, wire, ReadVarint(data, ref position), 0, 0));
                    break;
                case WireFixed64 or WireFixed32:
                    var size = wire == WireFixed64 ? 8 : 4;
                    if (data.Length - position < size)
                    {
                        throw new ProtoFormatException("truncated fixed field");
                    }

                    var value = size == 8
                        ? BinaryPrimitives.ReadUInt64LittleEndian(data[position..])
                        : BinaryPrimitives.ReadUInt32LittleEndian(data[position..]);
                    fields.Add(new ProtoField(known, wire, value, position, size));
                    position += size;
                    break;
                case WireLength:
                    var length = ReadVarint(data, ref position);
                    if (length > (ulong)(data.Length - position))
                    {
                        throw new ProtoFormatException("truncated length-delimited field");
                    }

                    fields.Add(new ProtoField(known, wire, length, position, (int)length));
                    position += (int)length;
                    break;
                default:
                    throw new ProtoFormatException("unsupported wire type " + wire);
            }
        }

        return new ProtoMessage(data, [.. fields]);
    }

    /// <summary>Unsigned 64-bit; a missing field is 0 (proto3 default). The last occurrence wins.</summary>
    public ulong UInt(int number) => Last(number, WireVarint) is { } field ? field.Value : 0;

    /// <summary>The varint reinterpreted as signed 64-bit (<c>int32</c>, <c>int64</c>, enums).</summary>
    public long Int(int number) => unchecked((long)UInt(number));

    /// <summary>UTF-8 text (invalid sequences become U+FFFD); empty when missing.</summary>
    public string String(int number, bool first = false) =>
        (first ? First(number, WireLength) : Last(number, WireLength)) is { Length: > 0 } field
            ? Encoding.UTF8.GetString(_data.Slice(field.Start, field.Length))
            : string.Empty;

    /// <summary>Every length-delimited occurrence decoded as text, in order (repeated strings).</summary>
    public List<string> Strings(int number)
    {
        var values = new List<string>();
        foreach (var field in _fields)
        {
            if (field.Number == number && field.Wire == WireLength)
            {
                values.Add(Encoding.UTF8.GetString(_data.Slice(field.Start, field.Length)));
            }
        }

        return values;
    }

    public bool Has(int number, int wire) => Last(number, wire) is not null;

    /// <summary>The nested message (last occurrence, or first); false when absent.</summary>
    /// <exception cref="ProtoFormatException">The nested message is malformed.</exception>
    public bool TryMessage(int number, out ProtoMessage message, bool first = false)
    {
        if ((first ? First(number, WireLength) : Last(number, WireLength)) is { } field)
        {
            message = Parse(_data.Slice(field.Start, field.Length));
            return true;
        }

        message = default;
        return false;
    }

    /// <summary>
    /// A <c>google.protobuf.Timestamp</c>: valid when <c>seconds &gt; 0</c>, then <c>seconds * 1000 + nanos div 10^6</c>
    /// (nanos outside 0 … 999 999 999 count as 0).
    /// </summary>
    public long? Timestamp(int number)
    {
        if (!TryMessage(number, out var timestamp))
        {
            return null;
        }

        var seconds = timestamp.Int(1);
        var nanos = timestamp.Int(2);
        var fraction = nanos is >= 0 and <= 999_999_999 ? nanos / 1_000_000 : 0;
        if (seconds <= 0 || seconds > (long.MaxValue - fraction) / 1000)
        {
            return null;
        }

        return seconds * 1000 + fraction;
    }

    /// <summary>A repeated unsigned scalar, packed (wire type 2) or unpacked (wire type 0), in order.</summary>
    /// <exception cref="ProtoFormatException">A packed payload is malformed.</exception>
    public List<ulong> RepeatedUInt(int number)
    {
        var values = new List<ulong>();
        foreach (var field in _fields)
        {
            if (field.Number != number)
            {
                continue;
            }

            if (field.Wire == WireVarint)
            {
                values.Add(field.Value);
            }
            else if (field.Wire == WireLength)
            {
                var packed = _data.Slice(field.Start, field.Length);
                var position = 0;
                while (position < packed.Length)
                {
                    values.Add(ReadVarint(packed, ref position));
                }
            }
        }

        return values;
    }

    private ProtoField? Last(int number, int wire)
    {
        for (var i = _fields.Length - 1; i >= 0; i--)
        {
            if (_fields[i].Number == number && _fields[i].Wire == wire)
            {
                return _fields[i];
            }
        }

        return null;
    }

    private ProtoField? First(int number, int wire)
    {
        foreach (var field in _fields)
        {
            if (field.Number == number && field.Wire == wire)
            {
                return field;
            }
        }

        return null;
    }

    /// <summary>At most 10 bytes, 7 bits each, least significant group first; bits above 64 are dropped.</summary>
    internal static ulong ReadVarint(ReadOnlySpan<byte> data, ref int position)
    {
        ulong result = 0;
        for (var i = 0; i < MaxVarintBytes; i++)
        {
            if (position >= data.Length)
            {
                throw new ProtoFormatException("truncated varint");
            }

            var b = data[position++];
            result |= (ulong)(b & 0x7F) << (7 * i);
            if ((b & 0x80) == 0)
            {
                return result;
            }
        }

        throw new ProtoFormatException("varint longer than 10 bytes");
    }
}

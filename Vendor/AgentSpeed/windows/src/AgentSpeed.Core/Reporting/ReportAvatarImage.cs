using System.Buffers.Binary;

namespace AgentSpeed.Core.Reporting;

public readonly record struct ReportImageSize(int Width, int Height, bool Png);

public static class ReportAvatarImage
{
    public const int MaxInputBytes = 10 * 1024 * 1024;
    public const int MaxPngBytes = 512 * 1024;
    public const int Size = 256;
    private static bool Dimensions(int width, int height) => width is > 0 and <= 8192 && height is > 0 and <= 8192
        && (long)width * height <= 16_000_000;

    public static ReportImageSize? ReadHeader(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > MaxInputBytes) return null;
        if (bytes.Length >= 33 && bytes[..8].SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) return ReadPng(bytes);
        if (bytes.Length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return null;
        var at = 2;
        while (at < bytes.Length - 3)
        {
            if (bytes[at++] != 0xff) return null;
            while (at < bytes.Length && bytes[at] == 0xff) at++;
            if (at >= bytes.Length) return null;
            var marker = bytes[at++];
            if (marker is 0xd9 or 0xda || at + 2 > bytes.Length) return null;
            if (marker is 0x01 or >= 0xd0 and <= 0xd7) continue;
            var length = BinaryPrimitives.ReadUInt16BigEndian(bytes.Slice(at, 2));
            if (length < 2 || at > bytes.Length - length) return null;
            if (marker is 0xc0 or 0xc1 or 0xc2)
            {
                if (length < 8) return null;
                var height = BinaryPrimitives.ReadUInt16BigEndian(bytes.Slice(at + 3, 2));
                var width = BinaryPrimitives.ReadUInt16BigEndian(bytes.Slice(at + 5, 2));
                return Dimensions(width, height) ? new(width, height, false) : null;
            }
            at += length;
        }
        return null;
    }

    public static bool IsUpload(ReadOnlySpan<byte> png) => png.Length <= MaxPngBytes
        && ReadHeader(png) is { Png: true, Width: Size, Height: Size };

    private static ReportImageSize? ReadPng(ReadOnlySpan<byte> bytes)
    {
        if (BinaryPrimitives.ReadUInt32BigEndian(bytes.Slice(8, 4)) != 13 || !bytes.Slice(12, 4).SequenceEqual("IHDR"u8)) return null;
        var width = BinaryPrimitives.ReadInt32BigEndian(bytes.Slice(16, 4));
        var height = BinaryPrimitives.ReadInt32BigEndian(bytes.Slice(20, 4));
        if (!Dimensions(width, height)) return null;
        var at = 8;
        var image = false;
        while (at <= bytes.Length - 12)
        {
            var length = BinaryPrimitives.ReadUInt32BigEndian(bytes.Slice(at, 4));
            if (length > (uint)(bytes.Length - at - 12)) return null;
            var kind = bytes.Slice(at + 4, 4);
            if (kind.SequenceEqual("acTL"u8) || kind.SequenceEqual("fcTL"u8) || kind.SequenceEqual("fdAT"u8)
                || (at > 8 && kind.SequenceEqual("IHDR"u8))) return null;
            if (kind.SequenceEqual("IDAT"u8)) image = true;
            at += (int)length + 12;
            if (kind.SequenceEqual("IEND"u8)) return length == 0 && image && at == bytes.Length ? new(width, height, true) : null;
        }
        return null;
    }
}

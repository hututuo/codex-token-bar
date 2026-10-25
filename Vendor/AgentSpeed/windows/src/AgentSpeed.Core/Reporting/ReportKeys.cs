using System.Numerics;
using System.Security.Cryptography;
using System.Text.Json;

namespace AgentSpeed.Core.Reporting;

/// <summary>
/// Signs the canonical string of a request (REPORTING 5.1): ES256 over the message bytes, 64-byte <c>r ‖ s</c>. The app's
/// device keys live in its key store; tests use <see cref="SoftwareReportSigner"/>.
/// </summary>
public interface IReportSigner
{
    ReportPublicKey PublicKey { get; }

    /// <exception cref="CryptographicException">The key cannot be used.</exception>
    byte[] Sign(ReadOnlySpan<byte> message);
}

/// <summary>A P-256 public key: the 32-byte big-endian affine coordinates (REPORTING 4.1).</summary>
public sealed class ReportPublicKey : IEquatable<ReportPublicKey>
{
    private static readonly BigInteger Prime = Parse("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF");
    private static readonly BigInteger Order = Parse("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551");
    private static readonly BigInteger CurveB = Parse("5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B");

    private readonly byte[] _x;
    private readonly byte[] _y;

    private ReportPublicKey(byte[] x, byte[] y)
    {
        _x = x;
        _y = y;
    }

    public ReadOnlySpan<byte> X => _x;

    public ReadOnlySpan<byte> Y => _y;

    /// <summary>From the two 32-byte coordinates; null when they are not below p or the point is not on P-256.</summary>
    public static ReportPublicKey? FromCoordinates(ReadOnlySpan<byte> x, ReadOnlySpan<byte> y)
    {
        if (x.Length != 32 || y.Length != 32)
        {
            return null;
        }

        var bx = Unsigned(x);
        var by = Unsigned(y);
        if (bx >= Prime || by >= Prime)
        {
            return null;
        }

        var left = by * by % Prime;
        var right = ((bx * bx % Prime * bx - 3 * bx + CurveB) % Prime + Prime) % Prime;
        return left == right ? new ReportPublicKey(x.ToArray(), y.ToArray()) : null;
    }

    public static ReportPublicKey? FromParameters(ECParameters parameters) =>
        parameters.Q.X is { } x && parameters.Q.Y is { } y ? FromCoordinates(x, y) : null;

    /// <summary>The JSON Web Key sent in registrations and rotations.</summary>
    public ReportJson Jwk => ReportJson.Object(
        ("kty", ReportJson.Of("EC")), ("crv", ReportJson.Of("P-256")),
        ("x", ReportJson.Of(Base64Url.Encode(_x))), ("y", ReportJson.Of(Base64Url.Encode(_y))));

    /// <summary>RFC 7638 thumbprint (base64url of SHA-256 over the required members in lexicographic order).</summary>
    public string Thumbprint
    {
        get
        {
            var members = $"{{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"{Base64Url.Encode(_x)}\",\"y\":\"{Base64Url.Encode(_y)}\"}}";
            return Base64Url.Encode(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(members)));
        }
    }

    /// <summary>The first 8 characters of the thumbprint (DESIGN 11, <c>report.device.fingerprint</c>).</summary>
    public string Fingerprint => Thumbprint[..8];

    /// <summary>REPORTING 4.1: kty EC, crv P-256, canonical 43-character coordinates below p, on the curve, no <c>d</c>.</summary>
    public static ReportPublicKey? ParseJwk(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object
            || !TryString(value, "kty", out var kty) || kty != "EC"
            || !TryString(value, "crv", out var crv) || crv != "P-256"
            || value.TryGetProperty("d", out _)
            || !TryString(value, "x", out var xText) || !TryString(value, "y", out var yText)
            || xText.Length != 43 || yText.Length != 43
            || Base64Url.Decode(xText) is not { Length: 32 } x || Base64Url.Decode(yText) is not { Length: 32 } y)
        {
            return null;
        }

        return FromCoordinates(x, y);
    }

    /// <summary>ES256 verification over the message; both forms of <c>s</c> verify (REPORTING 5.1).</summary>
    public bool Verify(ReadOnlySpan<byte> message, ReadOnlySpan<byte> signature)
    {
        if (signature.Length != 64 || !InScalarRange(signature[..32]) || !InScalarRange(signature[32..]))
        {
            return false;
        }

        try
        {
            using var key = ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new ECPoint { X = _x, Y = _y } });
            return key.VerifyData(message, signature, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        }
        catch (CryptographicException)
        {
            return false;
        }
    }

    public bool Equals(ReportPublicKey? other) => other is not null && _x.AsSpan().SequenceEqual(other._x) && _y.AsSpan().SequenceEqual(other._y);

    public override bool Equals(object? obj) => obj is ReportPublicKey other && Equals(other);

    public override int GetHashCode() => HashCode.Combine(_x[0], _x[31], _y[0], _y[31]);

    private static bool InScalarRange(ReadOnlySpan<byte> value)
    {
        var scalar = Unsigned(value);
        return scalar >= 1 && scalar < Order;
    }

    private static BigInteger Unsigned(ReadOnlySpan<byte> bigEndian) => new(bigEndian, isUnsigned: true, isBigEndian: true);

    private static BigInteger Parse(string hex) => new(Convert.FromHexString(hex), isUnsigned: true, isBigEndian: true);

    private static bool TryString(JsonElement element, string name, out string value)
    {
        value = string.Empty;
        if (!element.TryGetProperty(name, out var property) || property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = property.GetString() ?? string.Empty;
        return true;
    }
}

/// <summary>A software P-256 key held in memory: tests, and the app's key store once it has unprotected a stored key.</summary>
public sealed class SoftwareReportSigner : IReportSigner, IDisposable
{
    private readonly ECDsa _key;

    public SoftwareReportSigner()
        : this(ECDsa.Create(ECCurve.NamedCurves.nistP256))
    {
    }

    /// <param name="key">A P-256 private key; the signer takes ownership.</param>
    public SoftwareReportSigner(ECDsa key)
    {
        _key = key;
        PublicKey = ReportPublicKey.FromParameters(key.ExportParameters(includePrivateParameters: false))
            ?? throw new CryptographicException("The key is not a P-256 key.");
    }

    public ReportPublicKey PublicKey { get; }

    /// <summary>A key from its 32-byte private scalar (test vectors).</summary>
    public static SoftwareReportSigner FromPrivateScalar(ReadOnlySpan<byte> d)
    {
        var key = ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, D = d.ToArray() });
        return new SoftwareReportSigner(key);
    }

    /// <summary>A key from its PKCS#8 encoding (DESIGN 11, Storage on Windows).</summary>
    public static SoftwareReportSigner FromPkcs8(ReadOnlySpan<byte> pkcs8)
    {
        var key = ECDsa.Create();
        try
        {
            key.ImportPkcs8PrivateKey(pkcs8, out _);
            if (key.KeySize != 256)
            {
                throw new CryptographicException("The key is not a P-256 key.");
            }

            return new SoftwareReportSigner(key);
        }
        catch
        {
            key.Dispose();
            throw;
        }
    }

    public byte[] ExportPkcs8() => _key.ExportPkcs8PrivateKey();

    public byte[] Sign(ReadOnlySpan<byte> message) =>
        _key.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);

    public void Dispose() => _key.Dispose();
}

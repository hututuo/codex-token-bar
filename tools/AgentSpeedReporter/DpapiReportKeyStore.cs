using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Runtime.Versioning;
using System.Text.Json;
using AgentSpeed.Core.Reporting;

namespace CodexTokenBar.AgentSpeedReporter;

[SupportedOSPlatform("windows")]
internal sealed class DpapiReportKeyStore
{
    private const int UiForbidden = 0x1;
    private const int MaxIdentityBytes = 4096;
    private readonly string _directory;

    public DpapiReportKeyStore(string directory)
    {
        _directory = directory;
    }

    public static DpapiReportKeyStore Standard()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(local))
        {
            throw new CryptographicException("key_store_unavailable");
        }

        return new DpapiReportKeyStore(Path.Combine(local, "CodexTokenBar", "AgentSpeedReporting"));
    }

    public (PersistedIdentity Identity, SoftwareReportSigner Signer) LoadOrCreate()
    {
        Directory.CreateDirectory(_directory);
        var stored = ReadIdentity();
        if (stored is not null && ReportCanonical.IsDeviceId(stored.DeviceId)
            && LoadKey(stored.DeviceId) is { } existing)
        {
            return (stored, existing);
        }

        var identity = new PersistedIdentity(ReportCanonical.NewUuid(), null, null);
        var signer = new SoftwareReportSigner();
        var encoded = signer.ExportPkcs8();
        try
        {
            WriteAtomic(KeyPath(identity.DeviceId), Protect(encoded, Entropy(identity.DeviceId)));
            WriteIdentity(identity);
            return (identity, signer);
        }
        catch
        {
            signer.Dispose();
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encoded);
        }
    }

    public void WriteIdentity(PersistedIdentity identity)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(identity);
        if (bytes.Length > MaxIdentityBytes)
        {
            throw new IOException("identity_too_large");
        }

        WriteAtomic(Path.Combine(_directory, "identity.json"), bytes);
    }

    private PersistedIdentity? ReadIdentity()
    {
        try
        {
            var path = Path.Combine(_directory, "identity.json");
            var info = new FileInfo(path);
            if (!info.Exists || info.Length is <= 0 or > MaxIdentityBytes)
            {
                return null;
            }

            var bytes = File.ReadAllBytes(path);
            try
            {
                return JsonSerializer.Deserialize<PersistedIdentity>(bytes);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(bytes);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    private SoftwareReportSigner? LoadKey(string deviceId)
    {
        byte[]? encoded = null;
        try
        {
            var path = KeyPath(deviceId);
            var info = new FileInfo(path);
            if (!info.Exists || info.Length is <= 0 or > 16_384)
            {
                return null;
            }

            var protectedBytes = File.ReadAllBytes(path);
            try
            {
                encoded = Unprotect(protectedBytes, Entropy(deviceId));
            }
            finally
            {
                CryptographicOperations.ZeroMemory(protectedBytes);
            }

            return SoftwareReportSigner.FromPkcs8(encoded);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException)
        {
            return null;
        }
        finally
        {
            if (encoded is not null)
            {
                CryptographicOperations.ZeroMemory(encoded);
            }
        }
    }

    private string KeyPath(string deviceId)
    {
        if (!ReportCanonical.IsDeviceId(deviceId))
        {
            throw new CryptographicException("invalid_device_id");
        }

        return Path.Combine(_directory, $"{deviceId}.key.dpapi");
    }

    private static byte[] Entropy(string deviceId) => Convert.FromHexString(deviceId.Replace("-", string.Empty, StringComparison.Ordinal));

    private static void WriteAtomic(string path, byte[] data)
    {
        var directory = Path.GetDirectoryName(path) ?? throw new IOException("key_store_unavailable");
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Guid.NewGuid():N}.tmp");
        try
        {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                file.Write(data);
                file.Flush(flushToDisk: true);
            }

            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            try
            {
                File.Delete(temporary);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private static byte[] Protect(byte[] input, byte[] entropy) => Transform(input, entropy, protect: true);

    private static byte[] Unprotect(byte[] input, byte[] entropy) => Transform(input, entropy, protect: false);

    private static byte[] Transform(byte[] input, byte[] entropy, bool protect)
    {
        var inputPointer = Marshal.AllocHGlobal(input.Length);
        var entropyPointer = Marshal.AllocHGlobal(entropy.Length);
        IntPtr outputPointer = IntPtr.Zero;
        try
        {
            Marshal.Copy(input, 0, inputPointer, input.Length);
            Marshal.Copy(entropy, 0, entropyPointer, entropy.Length);
            var inputBlob = new DataBlob(input.Length, inputPointer);
            var entropyBlob = new DataBlob(entropy.Length, entropyPointer);
            DataBlob output;
            var succeeded = protect
                ? CryptProtectData(ref inputBlob, null, ref entropyBlob, IntPtr.Zero, IntPtr.Zero, UiForbidden, out output)
                : CryptUnprotectData(ref inputBlob, IntPtr.Zero, ref entropyBlob, IntPtr.Zero, IntPtr.Zero, UiForbidden, out output);
            if (!succeeded)
            {
                throw new CryptographicException(Marshal.GetLastWin32Error());
            }

            outputPointer = output.Data;
            var bytes = new byte[output.Length];
            Marshal.Copy(output.Data, bytes, 0, bytes.Length);
            return bytes;
        }
        finally
        {
            Marshal.FreeHGlobal(inputPointer);
            Marshal.FreeHGlobal(entropyPointer);
            if (outputPointer != IntPtr.Zero)
            {
                _ = LocalFree(outputPointer);
            }

            CryptographicOperations.ZeroMemory(entropy);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct DataBlob(int length, IntPtr data)
    {
        public readonly int Length = length;
        public readonly IntPtr Data = data;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob input, string? description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob output);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}

internal sealed record PersistedIdentity(string DeviceId, string? RegisteredUsername, string? ProfileUrl);

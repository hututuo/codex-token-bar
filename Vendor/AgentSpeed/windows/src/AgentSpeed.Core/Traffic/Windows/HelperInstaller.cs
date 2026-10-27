using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using AgentSpeed.Core.Traffic.Helper;
using Microsoft.Win32.SafeHandles;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>The result of an elevated helper install or removal.</summary>
public enum HelperInstallOutcome
{
    Done,

    /// <summary>The UAC prompt was declined; nothing changed (<c>traffic.helper.cancelled</c>).</summary>
    Cancelled,

    /// <summary>The elevated helper refused: hash mismatch, insecure install folder, invalid arguments (exit code 1).</summary>
    Refused,

    /// <summary>Anything else: staging, elevation or the elevated step failed (exit code 2 or an error here).</summary>
    Failed,
}

/// <param name="Win32Error">The Win32 error behind <see cref="HelperInstallOutcome.Failed"/>, else 0.</param>
/// <param name="Message">An English diagnostic for the log (no user data).</param>
public sealed record HelperInstallResult(HelperInstallOutcome Outcome, int Win32Error, string Message);

/// <summary>
/// Installs, updates and removes the helper through one elevated run of the helper binary itself (WINDOWS-SERVICE 5):
/// the bytes are staged in a new private folder under <c>%LOCALAPPDATA%\AgentSpeed\helper-staging</c>, checked against
/// their SHA-256, started with <c>runas</c> (one UAC prompt), and the staging folder is deleted afterwards.
/// </summary>
[SupportedOSPlatform("windows")]
public static class HelperInstaller
{
    /// <summary>Keep a read-only, read-sharing handle on the staged file while it runs, so it cannot be swapped.</summary>
    internal static readonly bool HoldStagedFile = true;

    private const string StagingFolderName = "helper-staging";
    private const int MaxHelperBytes = 64 * 1024 * 1024;
    private static readonly TimeSpan StaleStaging = TimeSpan.FromHours(1);

    /// <summary>The current user's SID string (the <c>--user</c> argument); null when it cannot be read.</summary>
    public static string? CurrentUserSid() => HelperServiceControl.CurrentUserSid();

    /// <summary>
    /// Installs or updates the helper and, when done, starts the service. <paramref name="sha256Hex"/> is the embedded
    /// hash of <paramref name="helper"/>; <paramref name="ownerWindow"/> owns the UAC prompt (0 for none). Cancelling
    /// only stops waiting (<see cref="OperationCanceledException"/>); a started elevated step runs to its end.
    /// </summary>
    public static Task<HelperInstallResult> InstallAsync(
        ReadOnlyMemory<byte> helper, string sha256Hex, nint ownerWindow, CancellationToken cancellationToken = default) =>
        RunAsync(helper, sha256Hex, ownerWindow, install: true, cancellationToken);

    /// <summary>Removes this user from the helper's allowed users (and the helper itself when no one is left).</summary>
    public static Task<HelperInstallResult> RemoveAsync(
        ReadOnlyMemory<byte> helper, string sha256Hex, nint ownerWindow, CancellationToken cancellationToken = default) =>
        RunAsync(helper, sha256Hex, ownerWindow, install: false, cancellationToken);

    private static Task<HelperInstallResult> RunAsync(
        ReadOnlyMemory<byte> helper, string sha256Hex, nint ownerWindow, bool install, CancellationToken cancellationToken)
    {
        if (!TryNormalizeSid(CurrentUserSid(), out var user))
        {
            return Task.FromResult(Failed(0, "The current user's SID could not be read."));
        }

        if (!TryParseHash(sha256Hex, out var expected))
        {
            return Task.FromResult(Failed(0, "The helper hash is not 64 hexadecimal characters."));
        }

        if (helper.Length is 0 or > MaxHelperBytes || !HashMatches(helper.Span, expected))
        {
            return Task.FromResult(new HelperInstallResult(HelperInstallOutcome.Refused, 0, "The helper does not match its embedded hash."));
        }

        string folder;
        FileStream? hold;
        try
        {
            folder = Stage(helper.Span, expected, user, out hold);
        }
        catch (CryptographicException)
        {
            return Task.FromResult(new HelperInstallResult(HelperInstallOutcome.Refused, 0, "The staged helper does not match its hash."));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return Task.FromResult(Failed(ex.HResult & 0xFFFF, "The helper could not be staged."));
        }

        var arguments = install
            ? $"install --user {user} --sha256 {Convert.ToHexStringLower(expected)}"
            : $"remove --user {user}";
        var completion = new TaskCompletionSource<HelperInstallResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                HelperInstallResult result;
                try
                {
                    // The working directory is System32, never the user-writable staging folder.
                    result = Elevate(Path.Combine(folder, HelperProtocol.ExecutableName), Environment.SystemDirectory, arguments, ownerWindow);
                }
                finally
                {
                    hold?.Dispose();
                    DeleteStaging(folder);
                }

                if (install && result.Outcome == HelperInstallOutcome.Done)
                {
                    var error = HelperServiceControl.Start();
                    result = error == 0 ? result : result with { Message = $"Installed; the service did not start (error {error})." };
                }

                completion.TrySetResult(result);
            }
            catch (Exception ex)
            {
                completion.TrySetException(ex);
            }
        })
        {
            IsBackground = true,
            Name = "Traffic helper elevation",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return completion.Task.WaitAsync(cancellationToken);
    }

    private static unsafe HelperInstallResult Elevate(string file, string directory, string arguments, nint ownerWindow)
    {
        fixed (char* verb = "runas", path = file, parameters = arguments, folder = directory)
        {
            var info = new HelperNative.ShellExecuteInfo
            {
                Size = (uint)sizeof(HelperNative.ShellExecuteInfo),
                Mask = HelperNative.SeeMaskNoCloseProcess | HelperNative.SeeMaskNoAsync | HelperNative.SeeMaskFlagNoUi,
                Window = ownerWindow,
                Verb = verb,
                File = path,
                Parameters = parameters,
                Directory = folder,
                Show = HelperNative.SwHide,
            };
            if (!HelperNative.ShellExecuteEx(&info))
            {
                var error = Marshal.GetLastPInvokeError();
                return error == HelperNative.ErrorCancelled
                    ? new HelperInstallResult(HelperInstallOutcome.Cancelled, 0, "The elevation prompt was declined.")
                    : Failed(error, "The elevated helper could not be started.");
            }

            if (info.Process == 0)
            {
                return Failed(0, "The elevated helper gave no process handle.");
            }

            using var process = new SafeProcessHandle(info.Process, ownsHandle: true);
            HelperNative.WaitForSingleObject(process, HelperNative.Infinite);
            if (!HelperNative.GetExitCodeProcess(process, out var code))
            {
                return Failed(Marshal.GetLastPInvokeError(), "The elevated helper's exit code could not be read.");
            }

            return code switch
            {
                (uint)HelperExitCode.Ok => new HelperInstallResult(HelperInstallOutcome.Done, 0, "Done."),
                (uint)HelperExitCode.Refused => new HelperInstallResult(HelperInstallOutcome.Refused, 0, "The elevated helper refused (exit code 1)."),
                _ => Failed(0, $"The elevated helper failed (exit code {code})."),
            };
        }
    }

    /// <summary>
    /// Writes the helper into a new folder that only this user, SYSTEM and Administrators can open (protected DACL) and
    /// verifies what is on disk; returns the folder.
    /// </summary>
    private static string Stage(ReadOnlySpan<byte> helper, byte[] expected, string user, out FileStream? hold)
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrEmpty(local))
        {
            throw new IOException("No local application data folder.");
        }

        var root = Path.Combine(local, "AgentSpeed", StagingFolderName);
        Directory.CreateDirectory(root);
        RemoveStale(root);
        var folder = Path.Combine(root, Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)));
        if (Path.Exists(folder))
        {
            throw new IOException("The staging folder already exists.");
        }

        var security = new DirectorySecurity();
        security.SetSecurityDescriptorSddlForm($"O:{user}D:P(A;OICI;FA;;;{user})(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)");
        new DirectoryInfo(folder).Create(security);
        var file = Path.Combine(folder, HelperProtocol.ExecutableName);
        try
        {
            using (var output = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                output.Write(helper);
                output.Flush(flushToDisk: true);
            }

            FileStream? input = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read);
            try
            {
                if (input.Length != helper.Length || !HashMatches(input, expected))
                {
                    throw new CryptographicException("The staged helper does not match its hash.");
                }

                input.Position = 0;
                if (HoldStagedFile)
                {
                    hold = input;
                    input = null;
                    return folder;
                }

                hold = null;
                return folder;
            }
            finally
            {
                input?.Dispose();
            }
        }
        catch
        {
            DeleteStaging(folder);
            throw;
        }
    }

    private static bool HashMatches(ReadOnlySpan<byte> data, byte[] expected)
    {
        Span<byte> actual = stackalloc byte[SHA256.HashSizeInBytes];
        SHA256.HashData(data, actual);
        return CryptographicOperations.FixedTimeEquals(actual, expected);
    }

    private static bool HashMatches(Stream data, byte[] expected)
    {
        Span<byte> actual = stackalloc byte[SHA256.HashSizeInBytes];
        SHA256.HashData(data, actual);
        return CryptographicOperations.FixedTimeEquals(actual, expected);
    }

    internal static bool TryParseHash(string? text, out byte[] hash)
    {
        hash = [];
        if (text is not { Length: SHA256.HashSizeInBytes * 2 } || !IsHex(text))
        {
            return false;
        }

        hash = Convert.FromHexString(text);
        return true;
    }

    private static bool IsHex(ReadOnlySpan<char> text)
    {
        foreach (var ch in text)
        {
            if (!char.IsAsciiHexDigit(ch))
            {
                return false;
            }
        }

        return true;
    }

    private static bool TryNormalizeSid(string? text, out string sid)
    {
        sid = "";
        if (string.IsNullOrEmpty(text))
        {
            return false;
        }

        try
        {
            sid = new SecurityIdentifier(text).Value;
            return true;
        }
        catch (ArgumentException)
        {
            return false;
        }
    }

    /// <summary>Best effort: folders of earlier runs that could not be deleted (a crash, an image still mapped).</summary>
    private static void RemoveStale(string root)
    {
        try
        {
            foreach (var directory in new DirectoryInfo(root).EnumerateDirectories())
            {
                if (directory.Name.Length == 32 && IsHex(directory.Name)
                    && (directory.Attributes & FileAttributes.ReparsePoint) == 0
                    && DateTime.UtcNow - directory.LastWriteTimeUtc > StaleStaging)
                {
                    DeleteStaging(directory.FullName, attempts: 1);
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static void DeleteStaging(string folder, int attempts = 10)
    {
        for (var attempt = 0; attempt < attempts; attempt++)
        {
            try
            {
                var file = Path.Combine(folder, HelperProtocol.ExecutableName);
                if (File.Exists(file))
                {
                    File.Delete(file);
                }

                if (Directory.Exists(folder))
                {
                    Directory.Delete(folder);
                }

                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                if (attempt + 1 < attempts)
                {
                    Thread.Sleep(100);
                }
            }
        }
    }

    private static HelperInstallResult Failed(int error, string message) => new(HelperInstallOutcome.Failed, error, message);
}

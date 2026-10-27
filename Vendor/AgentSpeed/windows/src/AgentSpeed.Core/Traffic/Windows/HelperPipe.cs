using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using AgentSpeed.Core.Traffic.Helper;
using Microsoft.Win32.SafeHandles;

namespace AgentSpeed.Core.Traffic.Windows;

/// <summary>
/// The client end of <c>\\.\pipe\AgentSpeed.Traffic</c>: opened with identification-level SQOS (the server can never
/// impersonate the user), overlapped I/O with a 2 s deadline per read or write; a timed-out operation is cancelled and
/// waited for before its buffer is released.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed unsafe class HelperPipe : IHelperTransport, IDisposable
{
    public const int TimeoutMs = 2000;

    private readonly SafeFileHandle _handle;
    private readonly SafeWaitHandle _event;
    private NativeOverlapped* _overlapped;

    private HelperPipe(SafeFileHandle handle, SafeWaitHandle completion, NativeOverlapped* overlapped)
    {
        _handle = handle;
        _event = completion;
        _overlapped = overlapped;
    }

    public SafeFileHandle Handle => _handle;

    /// <summary>Opens the pipe; 0 with <paramref name="pipe"/>, or the Win32 error.</summary>
    public static int Open(out HelperPipe? pipe)
    {
        pipe = null;
        var handle = HelperNative.CreateFile(
            HelperProtocol.PipePath,
            HelperNative.PipeAccess,
            0,
            0,
            HelperNative.OpenExisting,
            HelperNative.FileFlagOverlapped | HelperNative.SecuritySqosPresent | HelperNative.SecurityIdentification,
            0);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastPInvokeError();
            handle.Dispose();
            return error;
        }

        var completion = HelperNative.CreateEvent(0, manualReset: true, initialState: false, 0);
        if (completion.IsInvalid)
        {
            var error = Marshal.GetLastPInvokeError();
            completion.Dispose();
            handle.Dispose();
            return error;
        }

        var overlapped = (NativeOverlapped*)NativeMemory.AllocZeroed((nuint)sizeof(NativeOverlapped));
        pipe = new HelperPipe(handle, completion, overlapped);
        return 0;
    }

    public int Write(ReadOnlySpan<byte> data)
    {
        fixed (byte* start = data)
        {
            return Transfer(write: true, start, data.Length);
        }
    }

    public int ReadExactly(Span<byte> data)
    {
        fixed (byte* start = data)
        {
            return Transfer(write: false, start, data.Length);
        }
    }

    public void Dispose()
    {
        _handle.Dispose();
        _event.Dispose();
        if (_overlapped is not null)
        {
            NativeMemory.Free(_overlapped);
            _overlapped = null;
        }
    }

    private int Transfer(bool write, byte* start, int length)
    {
        var deadline = Environment.TickCount64 + TimeoutMs;
        var done = 0;
        while (done < length)
        {
            var error = Once(write, start + done, length - done, deadline, out var count);
            if (error != 0)
            {
                return error;
            }

            done += count;
        }

        return 0;
    }

    private int Once(bool write, byte* buffer, int length, long deadline, out int transferred)
    {
        transferred = 0;
        if (_overlapped is null || _handle.IsClosed)
        {
            return HelperNative.ErrorInvalidHandle;
        }

        *_overlapped = default;
        _overlapped->EventHandle = _event.DangerousGetHandle();
        HelperNative.ResetEvent(_event);
        var started = write
            ? HelperNative.WriteFile(_handle, buffer, (uint)length, null, _overlapped)
            : HelperNative.ReadFile(_handle, buffer, (uint)length, null, _overlapped);
        if (!started)
        {
            var error = Marshal.GetLastPInvokeError();
            if (error != HelperNative.ErrorIoPending)
            {
                return error;
            }

            var remaining = Math.Max(0, deadline - Environment.TickCount64);
            if (HelperNative.WaitForSingleObject(_event, (uint)remaining) != HelperNative.WaitObject0)
            {
                HelperNative.CancelIoEx(_handle, _overlapped);
                HelperNative.GetOverlappedResult(_handle, _overlapped, out _, wait: true);
                return HelperNative.ErrorTimeout;
            }
        }

        if (!HelperNative.GetOverlappedResult(_handle, _overlapped, out var count, wait: false))
        {
            return Marshal.GetLastPInvokeError();
        }

        if (count == 0 || count > (uint)length)
        {
            return HelperNative.ErrorBrokenPipe;
        }

        transferred = (int)count;
        return 0;
    }
}

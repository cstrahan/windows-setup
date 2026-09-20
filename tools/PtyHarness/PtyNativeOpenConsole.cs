// Starts a pseudo console hosted by a console host we choose, rather than by the one
// CreatePseudoConsole picks.
//
// Why bother: CreatePseudoConsole goes to the machine's inbox conhost, and on Windows 10 that one
// has no mouse plumbing at all. Windows Terminal doesn't use it either — it ships OpenConsole.exe
// and launches that as its pty host, which is why applications get mouse there and not here. This
// is winconpty's recipe (terminal/src/winconpty/winconpty.cpp), reduced to what the harness needs:
//
//   1. open \Device\ConDrv\Server, the console IPC endpoint, inheritable;
//   2. open its \Reference child, which is what PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE takes;
//   3. spawn the host: OpenConsole.exe --headless --width W --height H --signal 0x.. --server 0x..
//      with exactly four handles inherited (server, our two pipe ends, its signal pipe end);
//   4. start the application with the reference handle as the pseudo console attribute.
//
// Resizing goes down the signal pipe as a packet rather than through ResizePseudoConsole, because
// that API only knows about consoles the kernel32 path created.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace PtyHarness
{
    public class HostedPty
    {
        public IntPtr ReferenceHandle;   // the pseudo console, for the child's attribute list
        public IntPtr ServerHandle;
        public IntPtr SignalPipe;        // resize and friends go here
        public IntPtr HostProcess;       // the console host itself
        public int HostProcessId;
        public IntPtr PseudoConsole;     // a PseudoConsole struct, which is what an HPCON points at
        public IntPtr ProcessHandle;     // the application
        public int ProcessId;
        public FileStream Input;
        public FileStream Output;
    }

    public static class OpenConsoleHost
    {
        const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        const uint STARTF_USESTDHANDLES = 0x00000100;
        static readonly IntPtr PROC_THREAD_ATTRIBUTE_HANDLE_LIST = (IntPtr)0x00020002;
        static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;
        const ushort PTY_SIGNAL_RESIZE_WINDOW = 8;

        // NtOpenFile's object attributes, for reaching the NT namespace where the console device
        // lives. There is no Win32 way to open \Device\ConDrv\Server.
        [StructLayout(LayoutKind.Sequential)]
        struct UNICODE_STRING
        {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct OBJECT_ATTRIBUTES
        {
            public int Length;
            public IntPtr RootDirectory;
            public IntPtr ObjectName;
            public uint Attributes;
            public IntPtr SecurityDescriptor;
            public IntPtr SecurityQualityOfService;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IO_STATUS_BLOCK
        {
            public IntPtr Status;
            public IntPtr Information;
        }

        [DllImport("ntdll.dll")]
        static extern int NtOpenFile(out IntPtr handle, uint desiredAccess, ref OBJECT_ATTRIBUTES objectAttributes,
            out IO_STATUS_BLOCK ioStatusBlock, uint shareAccess, uint openOptions);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CreatePipe(out IntPtr readPipe, out IntPtr writePipe, IntPtr attributes, int size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool WriteFile(IntPtr handle, byte[] buffer, uint toWrite, out uint written, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool InitializeProcThreadAttributeList(IntPtr attributeList, int attributeCount, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool UpdateProcThreadAttribute(IntPtr attributeList, uint flags, IntPtr attribute, IntPtr value,
            IntPtr size, IntPtr previousValue, IntPtr returnSize);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern void DeleteProcThreadAttributeList(IntPtr attributeList);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool CreateProcessW(string applicationName, string commandLine, IntPtr processAttributes,
            IntPtr threadAttributes, bool inheritHandles, uint creationFlags, IntPtr environment,
            string currentDirectory, ref STARTUPINFOEX startupInfo, out PROCESS_INFORMATION processInformation);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        static IntPtr OpenDevice(string name, uint desiredAccess, IntPtr parent, bool inheritable, uint openOptions)
        {
            const uint OBJ_INHERIT = 0x00000002;
            const uint OBJ_CASE_INSENSITIVE = 0x00000040;
            const uint FILE_SHARE_ALL = 0x00000007;   // read | write | delete

            var buffer = Marshal.StringToHGlobalUni(name);
            try
            {
                var unicodeString = new UNICODE_STRING
                {
                    Length = (ushort)(name.Length * 2),
                    MaximumLength = (ushort)(name.Length * 2 + 2),
                    Buffer = buffer,
                };
                var namePointer = Marshal.AllocHGlobal(Marshal.SizeOf<UNICODE_STRING>());
                try
                {
                    Marshal.StructureToPtr(unicodeString, namePointer, false);
                    var attributes = new OBJECT_ATTRIBUTES
                    {
                        Length = Marshal.SizeOf<OBJECT_ATTRIBUTES>(),
                        RootDirectory = parent,
                        ObjectName = namePointer,
                        Attributes = OBJ_CASE_INSENSITIVE | (inheritable ? OBJ_INHERIT : 0),
                        SecurityDescriptor = IntPtr.Zero,
                        SecurityQualityOfService = IntPtr.Zero,
                    };
                    IO_STATUS_BLOCK status;
                    IntPtr handle;
                    int result = NtOpenFile(out handle, desiredAccess, ref attributes, out status, FILE_SHARE_ALL, openOptions);
                    if (result != 0)
                    {
                        throw new Win32Exception("NtOpenFile(" + name + ") failed: NTSTATUS 0x" + result.ToString("x8"));
                    }
                    return handle;
                }
                finally
                {
                    Marshal.FreeHGlobal(namePointer);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static HostedPty Start(string hostPath, string commandLine, string workingDirectory, short columns, short rows)
        {
            const uint GENERIC_READ = 0x80000000;
            const uint GENERIC_WRITE = 0x40000000;
            const uint GENERIC_ALL = 0x10000000;
            const uint SYNCHRONIZE = 0x00100000;
            const uint FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
            const uint HANDLE_FLAG_INHERIT = 0x00000001;

            Action<string> trace = m => { if (Environment.GetEnvironmentVariable("PTYHARNESS_TRACE") == "1") { Console.Error.WriteLine("[pty] " + m); Console.Error.Flush(); } };
            var pty = new HostedPty();

            // The console server, and the reference that hands it to a client.
            trace("opening server device");
            pty.ServerHandle = OpenDevice(@"\Device\ConDrv\Server", GENERIC_ALL, IntPtr.Zero, true, 0);
            trace("server=" + pty.ServerHandle.ToInt64().ToString("x") + "; opening reference");
            pty.ReferenceHandle = OpenDevice(@"\Reference", GENERIC_READ | GENERIC_WRITE | SYNCHRONIZE,
                pty.ServerHandle, false, FILE_SYNCHRONOUS_IO_NONALERT);

            trace("reference=" + pty.ReferenceHandle.ToInt64().ToString("x") + "; creating pipes");
            IntPtr inputRead, inputWrite, outputRead, outputWrite, signalRead, signalWrite;
            if (!CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0) ||
                !CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0) ||
                !CreatePipe(out signalRead, out signalWrite, IntPtr.Zero, 0))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe failed");
            }
            // The host reads the signal pipe and our two pipe ends, so those must cross into it.
            foreach (var handle in new[] { inputRead, outputWrite, signalRead })
            {
                if (!SetHandleInformation(handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "SetHandleInformation failed");
                }
            }

            trace("pipes ready; building host command");
            var hostCommand = string.Format(
                "\"{0}\" --headless --width {1} --height {2} --signal 0x{3:x} --server 0x{4:x}",
                hostPath, columns, rows, signalRead.ToInt64(), pty.ServerHandle.ToInt64());

            // Exactly four handles, as winconpty does: anything else the process happens to hold
            // must not leak into the host.
            var inherited = new[] { pty.ServerHandle, inputRead, outputWrite, signalRead };
            var hostInfo = new STARTUPINFOEX();
            hostInfo.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();
            hostInfo.StartupInfo.hStdInput = inputRead;
            hostInfo.StartupInfo.hStdOutput = outputWrite;
            hostInfo.StartupInfo.hStdError = outputWrite;
            hostInfo.StartupInfo.dwFlags = (int)STARTF_USESTDHANDLES;

            trace("command: " + hostCommand);
            var handleList = Marshal.AllocHGlobal(inherited.Length * IntPtr.Size);
            PROCESS_INFORMATION hostProcess;
            IntPtr hostAttributes = IntPtr.Zero;
            try
            {
                Marshal.Copy(Array.ConvertAll(inherited, h => h), 0, handleList, inherited.Length);
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                hostAttributes = Marshal.AllocHGlobal(size);
                if (!InitializeProcThreadAttributeList(hostAttributes, 1, 0, ref size))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "InitializeProcThreadAttributeList (host) failed");
                }
                if (!UpdateProcThreadAttribute(hostAttributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handleList,
                        (IntPtr)(inherited.Length * IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateProcThreadAttribute (handle list) failed");
                }
                hostInfo.lpAttributeList = hostAttributes;

                trace("attribute list ready; calling CreateProcess for the host");
                if (!CreateProcessW(hostPath, hostCommand, IntPtr.Zero, IntPtr.Zero, true,
                        EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, null, ref hostInfo, out hostProcess))
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new Win32Exception(error, "starting the console host failed (error " + error + ": " +
                        new Win32Exception(error).Message + "): " + hostCommand);
                }
            }
            finally
            {
                if (hostAttributes != IntPtr.Zero) { DeleteProcThreadAttributeList(hostAttributes); Marshal.FreeHGlobal(hostAttributes); }
                Marshal.FreeHGlobal(handleList);
            }
            trace("host started, pid " + hostProcess.dwProcessId);
            CloseHandle(hostProcess.hThread);
            pty.HostProcess = hostProcess.hProcess;
            pty.HostProcessId = hostProcess.dwProcessId;
            pty.SignalPipe = signalWrite;

            // Our ends of the pipes; the host has its own copies now.
            CloseHandle(inputRead);
            CloseHandle(outputWrite);
            CloseHandle(signalRead);
            pty.Input = new FileStream(new SafeFileHandle(inputWrite, true), FileAccess.Write);
            pty.Output = new FileStream(new SafeFileHandle(outputRead, true), FileAccess.Read);

            // And finally the application itself, attached to that console.
            var childInfo = new STARTUPINFOEX();
            childInfo.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();
            IntPtr childAttributes = IntPtr.Zero;
            PROCESS_INFORMATION childProcess;
            try
            {
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                childAttributes = Marshal.AllocHGlobal(size);
                if (!InitializeProcThreadAttributeList(childAttributes, 1, 0, ref size))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "InitializeProcThreadAttributeList (child) failed");
                }
                // The attribute takes an HPCON, and the OS reads the PseudoConsole struct behind
                // it to find the reference handle. Handing it a bare handle makes it dereference
                // a bogus pointer, which crashes the caller rather than failing. Layout is
                // winconpty's: { hSignal, hPtyReference, hConPtyProcess }.
                pty.PseudoConsole = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(pty.PseudoConsole, 0, pty.SignalPipe);
                Marshal.WriteIntPtr(pty.PseudoConsole, IntPtr.Size, pty.ReferenceHandle);
                Marshal.WriteIntPtr(pty.PseudoConsole, IntPtr.Size * 2, pty.HostProcess);
                trace("pseudo console struct at " + pty.PseudoConsole.ToInt64().ToString("x"));
                if (!UpdateProcThreadAttribute(childAttributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                        pty.PseudoConsole, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateProcThreadAttribute (pseudoconsole) failed");
                }
                childInfo.lpAttributeList = childAttributes;
                var mutable = new string(commandLine.ToCharArray());
                if (!CreateProcessW(null, mutable, IntPtr.Zero, IntPtr.Zero, false,
                        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, IntPtr.Zero,
                        string.IsNullOrEmpty(workingDirectory) ? null : workingDirectory,
                        ref childInfo, out childProcess))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess failed for: " + commandLine);
                }
            }
            finally
            {
                if (childAttributes != IntPtr.Zero) { DeleteProcThreadAttributeList(childAttributes); Marshal.FreeHGlobal(childAttributes); }
            }
            CloseHandle(childProcess.hThread);
            pty.ProcessHandle = childProcess.hProcess;
            pty.ProcessId = childProcess.dwProcessId;
            return pty;
        }

        public static void Resize(HostedPty pty, short columns, short rows)
        {
            // PTY_SIGNAL_RESIZE_WINDOW, then width and height, as three little-endian words.
            var packet = new byte[6];
            BitConverter.GetBytes(PTY_SIGNAL_RESIZE_WINDOW).CopyTo(packet, 0);
            BitConverter.GetBytes((ushort)columns).CopyTo(packet, 2);
            BitConverter.GetBytes((ushort)rows).CopyTo(packet, 4);
            uint written;
            if (!WriteFile(pty.SignalPipe, packet, (uint)packet.Length, out written, IntPtr.Zero))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "writing the resize signal failed");
            }
        }

        public static bool HasExited(HostedPty pty)
        {
            uint code;
            if (!GetExitCodeProcess(pty.ProcessHandle, out code)) { return true; }
            const uint STILL_ACTIVE = 259;
            return code != STILL_ACTIVE;
        }

        public static void Stop(HostedPty pty)
        {
            if (pty == null) { return; }
            // Closing the signal pipe and the reference is how the host is told to wind down.
            foreach (var handle in new[] { pty.SignalPipe, pty.ReferenceHandle, pty.ServerHandle })
            {
                if (handle != IntPtr.Zero) { CloseHandle(handle); }
            }
            pty.SignalPipe = pty.ReferenceHandle = pty.ServerHandle = IntPtr.Zero;
            try { if (pty.Input != null) { pty.Input.Dispose(); } } catch { }
            try { if (pty.Output != null) { pty.Output.Dispose(); } } catch { }
            foreach (var process in new[] { pty.ProcessHandle, pty.HostProcess })
            {
                if (process == IntPtr.Zero) { continue; }
                uint code;
                if (GetExitCodeProcess(process, out code) && code == 259) { TerminateProcess(process, 1); }
                CloseHandle(process);
            }
            pty.ProcessHandle = pty.HostProcess = IntPtr.Zero;
            if (pty.PseudoConsole != IntPtr.Zero) { Marshal.FreeHGlobal(pty.PseudoConsole); pty.PseudoConsole = IntPtr.Zero; }
        }
    }
}

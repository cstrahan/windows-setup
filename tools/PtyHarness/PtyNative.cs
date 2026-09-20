using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace PtyHarness {
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD { public short X; public short Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb;
        public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize;
        public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

    /// A running program and the pseudo console it is attached to.
    public class PtyProcess {
        public IntPtr PseudoConsole;
        public IntPtr ProcessHandle;
        public int ProcessId;
        /// What the program reads as its input.
        public FileStream Input;
        /// What the program writes: a VT stream, for a terminal emulator to interpret.
        public FileStream Output;
    }

    public static class Native {
        const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        // The attribute that hands a pseudo console to a child process.
        static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CreatePipe(out IntPtr readPipe, out IntPtr writePipe, IntPtr attributes, int size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern int CreatePseudoConsole(COORD size, IntPtr input, IntPtr output, uint flags, out IntPtr pseudoConsole);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern int ResizePseudoConsole(IntPtr pseudoConsole, COORD size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern void ClosePseudoConsole(IntPtr pseudoConsole);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool InitializeProcThreadAttributeList(IntPtr attributeList, int attributeCount, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool UpdateProcThreadAttribute(IntPtr attributeList, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnSize);
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

        public static PtyProcess Start(string commandLine, string workingDirectory, short columns, short rows) {
            IntPtr inputRead, inputWrite, outputRead, outputWrite;
            if (!CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe (input) failed");
            }
            if (!CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe (output) failed");
            }

            IntPtr pseudoConsole;
            int hr = CreatePseudoConsole(new COORD { X = columns, Y = rows }, inputRead, outputWrite, 0, out pseudoConsole);
            // The pseudo console keeps its own duplicates of the ends it was given.
            CloseHandle(inputRead);
            CloseHandle(outputWrite);
            if (hr != 0) { throw new Win32Exception(hr, "CreatePseudoConsole failed"); }

            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);   // asks for the size
            IntPtr attributes = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "InitializeProcThreadAttributeList failed");
            }
            if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pseudoConsole,
                    (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateProcThreadAttribute failed");
            }

            var startupInfo = new STARTUPINFOEX();
            startupInfo.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();
            startupInfo.lpAttributeList = attributes;

            PROCESS_INFORMATION processInformation;
            // CreateProcess may modify the command line, so hand it a copy it can scribble on.
            var mutable = new string(commandLine.ToCharArray());
            bool started = CreateProcessW(null, mutable, IntPtr.Zero, IntPtr.Zero, false,
                EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, IntPtr.Zero,
                string.IsNullOrEmpty(workingDirectory) ? null : workingDirectory,
                ref startupInfo, out processInformation);
            int error = Marshal.GetLastWin32Error();
            DeleteProcThreadAttributeList(attributes);
            Marshal.FreeHGlobal(attributes);
            if (!started) {
                ClosePseudoConsole(pseudoConsole);
                throw new Win32Exception(error, "CreateProcess failed for: " + commandLine);
            }
            CloseHandle(processInformation.hThread);

            return new PtyProcess {
                PseudoConsole = pseudoConsole,
                ProcessHandle = processInformation.hProcess,
                ProcessId = processInformation.dwProcessId,
                Input = new FileStream(new SafeFileHandle(inputWrite, true), FileAccess.Write),
                Output = new FileStream(new SafeFileHandle(outputRead, true), FileAccess.Read),
            };
        }

        public static void Resize(PtyProcess pty, short columns, short rows) {
            int hr = ResizePseudoConsole(pty.PseudoConsole, new COORD { X = columns, Y = rows });
            if (hr != 0) { throw new Win32Exception(hr, "ResizePseudoConsole failed"); }
        }

        public static bool HasExited(PtyProcess pty) {
            uint code;
            if (!GetExitCodeProcess(pty.ProcessHandle, out code)) { return true; }
            const uint STILL_ACTIVE = 259;
            return code != STILL_ACTIVE;
        }

        public static void Stop(PtyProcess pty) {
            if (pty == null) { return; }
            // Closing the pseudo console tells the program its terminal is gone, which is how a
            // shell is asked to leave; terminate anything that stays.
            if (pty.PseudoConsole != IntPtr.Zero) { ClosePseudoConsole(pty.PseudoConsole); pty.PseudoConsole = IntPtr.Zero; }
            try { if (pty.Input != null) { pty.Input.Dispose(); } } catch { }
            try { if (pty.Output != null) { pty.Output.Dispose(); } } catch { }
            if (pty.ProcessHandle != IntPtr.Zero) {
                if (!HasExited(pty)) { TerminateProcess(pty.ProcessHandle, 1); }
                CloseHandle(pty.ProcessHandle);
                pty.ProcessHandle = IntPtr.Zero;
            }
        }
    }
}

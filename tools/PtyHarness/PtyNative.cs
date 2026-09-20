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
        /// Which library owns PseudoConsole, since it has to be resized and closed by the same one.
        public bool UsesConptyDll;
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

        // The same three from the redistributable console host. kernel32's versions bind to the
        // machine's own conhost, which on Windows 10 is far too old to forward mouse; these bind
        // to the OpenConsole.exe sitting next to conpty.dll. The names differ because the package
        // exports them under their own prefix (inc/conpty.h). PtyNative.ps1 loads the library from
        // lib\ before any of these are called, which is what lets a bare name resolve here.
        [DllImport("conpty.dll", SetLastError = true)]
        static extern int ConptyCreatePseudoConsole(COORD size, IntPtr input, IntPtr output, uint flags, out IntPtr pseudoConsole);
        [DllImport("conpty.dll", SetLastError = true)]
        static extern int ConptyResizePseudoConsole(IntPtr pseudoConsole, COORD size);
        [DllImport("conpty.dll", SetLastError = true)]
        static extern void ConptyClosePseudoConsole(IntPtr pseudoConsole);
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

        public static PtyProcess Start(string commandLine, string workingDirectory, short columns, short rows, bool useConptyDll) {
            IntPtr inputRead, inputWrite, outputRead, outputWrite;
            if (!CreatePipe(out inputRead, out inputWrite, IntPtr.Zero, 0)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe (input) failed");
            }
            if (!CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreatePipe (output) failed");
            }

            IntPtr pseudoConsole;
            var consoleSize = new COORD { X = columns, Y = rows };
            int hr = useConptyDll
                ? ConptyCreatePseudoConsole(consoleSize, inputRead, outputWrite, 0, out pseudoConsole)
                : CreatePseudoConsole(consoleSize, inputRead, outputWrite, 0, out pseudoConsole);
            // The pseudo console keeps its own duplicates of the ends it was given.
            CloseHandle(inputRead);
            CloseHandle(outputWrite);
            if (hr != 0) {
                throw new Win32Exception(hr, (useConptyDll ? "ConptyCreatePseudoConsole" : "CreatePseudoConsole") + " failed");
            }

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
                Close(pseudoConsole, useConptyDll);
                throw new Win32Exception(error, "CreateProcess failed for: " + commandLine);
            }
            CloseHandle(processInformation.hThread);

            return new PtyProcess {
                PseudoConsole = pseudoConsole,
                UsesConptyDll = useConptyDll,
                ProcessHandle = processInformation.hProcess,
                ProcessId = processInformation.dwProcessId,
                Input = new FileStream(new SafeFileHandle(inputWrite, true), FileAccess.Write),
                Output = new FileStream(new SafeFileHandle(outputRead, true), FileAccess.Read),
            };
        }

        public static void Resize(PtyProcess pty, short columns, short rows) {
            var size = new COORD { X = columns, Y = rows };
            int hr = pty.UsesConptyDll
                ? ConptyResizePseudoConsole(pty.PseudoConsole, size)
                : ResizePseudoConsole(pty.PseudoConsole, size);
            if (hr != 0) { throw new Win32Exception(hr, "ResizePseudoConsole failed"); }
        }

        static void Close(IntPtr pseudoConsole, bool useConptyDll) {
            if (useConptyDll) { ConptyClosePseudoConsole(pseudoConsole); } else { ClosePseudoConsole(pseudoConsole); }
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
            if (pty.PseudoConsole != IntPtr.Zero) { Close(pty.PseudoConsole, pty.UsesConptyDll); pty.PseudoConsole = IntPtr.Zero; }
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

// Collects what the terminal wants written back to the pty.
//
// Applications ask the terminal questions — primary device attributes, XTVERSION, size and mode
// reports — and libghostty hands the answers to a callback. Two things put that callback here
// rather than in PowerShell:
//
//   - a callback is a function pointer, which in WebAssembly is an index into the module's
//     function table. The module has no imports, so nothing can be linked the usual way, but
//     wasmtime will put a host function into the exported table and libghostty then calls it
//     like any other;
//   - the callback must reach wasm memory through Caller. Going through the Memory object
//     re-enters the store from inside a wasm call, and Caller is a ByRef-like type, which
//     PowerShell cannot use at all.
//
// Replies are queued rather than written straight to the pty: this runs inside a vt_write, and
// the host drains the queue afterwards.
using System;
using Wasmtime;

namespace PtyHarness
{
    public class GhosttyReplySink
    {
        byte[] _pending = new byte[0];

        /// Matches GhosttyTerminalWritePtyFn: (terminal, userdata, data, len), all i32 in wasm32.
        /// The signature must match exactly. A mismatch is not a trap you can catch: the process
        /// dies silently, which is also what happens if the function pointer itself is wrong.
        public void WritePty(Caller caller, int terminal, int userdata, int data, int length)
        {
            if (length <= 0) { return; }
            Span<byte> span;
            if (!caller.TryGetMemorySpan("memory", data, length, out span)) { return; }
            // No lock: this runs inside the host's own vt_write, on the one thread that owns the
            // emulator, and the same thread drains it afterwards.
            var combined = new byte[_pending.Length + length];
            Array.Copy(_pending, combined, _pending.Length);
            span.CopyTo(new Span<byte>(combined, _pending.Length, length));
            _pending = combined;
        }

        public Function CreateFunction(Store store)
        {
            return Function.FromCallback(store, (CallerAction<int, int, int, int>)WritePty);
        }

        /// Everything queued since the last call, as one block of bytes for the pty.
        public byte[] Take()
        {
            var taken = _pending;
            _pending = new byte[0];
            return taken;
        }
    }
}

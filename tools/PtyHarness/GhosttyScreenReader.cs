// Reads the viewport out of libghostty-vt with its colours and attributes intact.
//
// The formatter gives text (and VT or HTML), but an assertion like "the error line is red" wants
// structure, and that means walking cells. This is in C# rather than PowerShell for one reason:
// a 100x30 screen is 3000 cells and each one needs a handful of calls into wasm. From C# that is
// milliseconds; from PowerShell, with a ScriptMethod and a ValueBox[] per call, it is not.
//
// The path through libghostty is the render state: it snapshots a terminal's viewport into
// memory of its own, which is exactly the viewport/scrollback split the text screen has to work
// for by counting scrolled-off rows. Cells are then read through a row iterator and a row-cells
// iterator, both of which are "populate this handle I already made" rather than "return me one" -
// so the out-parameter is a pointer to a cell holding the handle, never the handle itself. (Get
// that wrong in wasm and the process dies without a trap; see the README.)
using System;
using System.Collections.Generic;
using System.Text;
using Wasmtime;

namespace PtyHarness
{
    /// A colour as the application set it, with the palette already resolved.
    public class GhosttyColor
    {
        /// "Default" (the application set none), "Palette" or "Rgb".
        public string Kind;
        /// The palette index when Kind is "Palette", otherwise -1.
        public int Index = -1;
        public int R, G, B;
        public string Hex;

        public static GhosttyColor Make(string kind, int index, int r, int g, int b)
        {
            var color = new GhosttyColor { Kind = kind, Index = index, R = r, G = g, B = b };
            color.Hex = string.Format("#{0:x2}{1:x2}{2:x2}", r, g, b);
            return color;
        }
    }

    /// A stretch of cells that share every attribute.
    public class GhosttyRun
    {
        /// Zero-based column where the run starts.
        public int Column;
        public string Text;
        /// As the application wrote it: Kind is "Default" where it set nothing.
        public GhosttyColor Foreground;
        public GhosttyColor Background;
        /// What you would see: the terminal's defaults filled in, and inverse applied.
        public GhosttyColor EffectiveForeground;
        public GhosttyColor EffectiveBackground;
        public bool Bold, Italic, Faint, Blink, Inverse, Invisible, Strikethrough, Overline;
        /// "None", "Single", "Double", "Curly", "Dotted" or "Dashed".
        public string Underline;
        public GhosttyColor UnderlineColor;
    }

    public class GhosttyStyledRow
    {
        /// Zero-based row within the viewport.
        public int Y;
        public GhosttyRun[] Runs;
    }

    public class GhosttyScreen
    {
        public GhosttyStyledRow[] Rows;
        /// The terminal's default foreground and background, which Effective* fall back to.
        public GhosttyColor Foreground;
        public GhosttyColor Background;
    }

    public class GhosttyScreenReader
    {
        // GhosttyRenderStateData
        const int DATA_COLS = 1;
        const int DATA_ROW_ITERATOR = 4;
        const int DATA_COLORS = 19;
        // GhosttyRenderStateRowData
        const int ROW_DATA_CELLS = 3;
        // GhosttyRenderStateRowCellsData
        const int CELL_STYLE = 2;
        const int CELL_BG_COLOR = 5;
        const int CELL_FG_COLOR = 6;
        const int CELL_HAS_STYLING = 8;
        const int CELL_GRAPHEMES_UTF8 = 9;

        // GhosttyRenderStateColors: size@0, background@4, foreground@7, cursor@10,
        // cursor_has_value@13, palette[256]@14. 784 bytes in all.
        const int COLORS_SIZE = 784;
        const int COLORS_PALETTE = 14;

        // GhosttyStyle: 72 bytes, fg_color@8, bg_color@24, underline_color@40, the eight flags at
        // 56..63, underline@64. A GhosttyStyleColor is { i32 tag@0; union value@8 }, where the
        // value is a palette index or three bytes of RGB.
        const int STYLE_SIZE = 72;

        static readonly string[] Underlines = { "None", "Single", "Double", "Curly", "Dotted", "Dashed" };

        readonly Memory _memory;
        readonly Func<int, int> _alloc;
        readonly Action<int, int> _free;
        readonly Func<int> _allocOpaque;
        readonly Action<int> _freeOpaque;
        readonly Func<int, int, int> _stateNew;          // (allocator, out) -> result
        readonly Func<int, int, int> _stateUpdate;       // (state, terminal) -> result
        readonly Func<int, int, int, int> _stateGet;     // (state, data, out) -> result
        readonly Func<int, int, int> _iteratorNew;       // (allocator, out) -> result
        readonly Func<int, int> _iteratorNext;           // (iterator) -> bool
        readonly Func<int, int, int, int> _rowGet;       // (iterator, data, out) -> result
        readonly Func<int, int, int> _cellsNew;          // (allocator, out) -> result
        readonly Func<int, int, int> _cellsSelect;       // (cells, x) -> result
        readonly Func<int, int, int, int> _cellsGet;     // (cells, data, out) -> result
        readonly Action<int> _stateFree, _iteratorFree, _cellsFree;

        readonly int _state, _iterator, _cells;
        // One scratch block, reused: wasm addresses stay valid when linear memory grows, so this
        // is allocated once for the life of the terminal.
        readonly int _scratch, _colors;
        const int SCRATCH_SIZE = 256;
        const int OFF_STYLE = 0;        // 72
        const int OFF_RGB = 72;         // 3, shared by the fg and bg queries
        const int OFF_FLAG = 80;        // 1
        const int OFF_BUFFER = 84;      // GhosttyBuffer { ptr, cap, len }
        const int OFF_TEXT = 96;        // the buffer's own storage
        const int TEXT_CAPACITY = 128;
        const int OFF_OUT = 240;        // a spare i32

        public GhosttyScreenReader(Instance instance)
        {
            _memory = instance.GetMemory("memory");
            _alloc = instance.GetFunction<int, int>("ghostty_wasm_alloc");
            _free = instance.GetAction<int, int>("ghostty_wasm_free");
            _allocOpaque = instance.GetFunction<int>("ghostty_wasm_alloc_opaque");
            _freeOpaque = instance.GetAction<int>("ghostty_wasm_free_opaque");
            _stateNew = instance.GetFunction<int, int, int>("ghostty_render_state_new");
            _stateUpdate = instance.GetFunction<int, int, int>("ghostty_render_state_update");
            _stateGet = instance.GetFunction<int, int, int, int>("ghostty_render_state_get");
            _iteratorNew = instance.GetFunction<int, int, int>("ghostty_render_state_row_iterator_new");
            _iteratorNext = instance.GetFunction<int, int>("ghostty_render_state_row_iterator_next");
            _rowGet = instance.GetFunction<int, int, int, int>("ghostty_render_state_row_get");
            _cellsNew = instance.GetFunction<int, int, int>("ghostty_render_state_row_cells_new");
            _cellsSelect = instance.GetFunction<int, int, int>("ghostty_render_state_row_cells_select");
            _cellsGet = instance.GetFunction<int, int, int, int>("ghostty_render_state_row_cells_get");
            _stateFree = instance.GetAction<int>("ghostty_render_state_free");
            _iteratorFree = instance.GetAction<int>("ghostty_render_state_row_iterator_free");
            _cellsFree = instance.GetAction<int>("ghostty_render_state_row_cells_free");

            if (_alloc == null || _stateNew == null || _cellsGet == null)
            {
                throw new InvalidOperationException(
                    "this libghostty-vt build has no render state API; styles need one that exports ghostty_render_state_*");
            }

            _scratch = _alloc(SCRATCH_SIZE);
            _colors = _alloc(COLORS_SIZE);
            _state = Create(_stateNew, "ghostty_render_state_new");
            _iterator = Create(_iteratorNew, "ghostty_render_state_row_iterator_new");
            _cells = Create(_cellsNew, "ghostty_render_state_row_cells_new");
        }

        public void Dispose()
        {
            _cellsFree(_cells);
            _iteratorFree(_iterator);
            _stateFree(_state);
            _free(_colors, COLORS_SIZE);
            _free(_scratch, SCRATCH_SIZE);
        }

        int Create(Func<int, int, int> make, string what)
        {
            var slot = _allocOpaque();
            try
            {
                Check(make(0, slot), what);
                return _memory.ReadInt32(slot);
            }
            finally { _freeOpaque(slot); }
        }

        static void Check(int result, string what)
        {
            if (result != 0) { throw new InvalidOperationException(what + " failed: libghostty-vt result " + result); }
        }

        /// Snapshots the terminal's viewport and returns it as rows of styled runs.
        ///
        /// When row is not negative, only that row is read; everything else is the same.
        public GhosttyScreen Read(int terminal, int row)
        {
            Check(_stateUpdate(_state, terminal), "ghostty_render_state_update");

            // The colours struct is sized: tell it how big ours is before asking.
            _memory.WriteInt32(_colors, COLORS_SIZE);
            Check(_stateGet(_state, DATA_COLORS, _colors), "ghostty_render_state_get(COLORS)");
            var background = ReadRgb(_colors + 4, "Default", -1);
            var foreground = ReadRgb(_colors + 7, "Default", -1);

            Check(_stateGet(_state, DATA_COLS, _scratch + OFF_OUT), "ghostty_render_state_get(COLS)");
            var columns = _memory.ReadInt32(_scratch + OFF_OUT) & 0xFFFF;

            // The iterator is populated in place, so the out-parameter is a pointer to a cell
            // holding its handle.
            _memory.WriteInt32(_scratch + OFF_OUT, _iterator);
            Check(_stateGet(_state, DATA_ROW_ITERATOR, _scratch + OFF_OUT), "ghostty_render_state_get(ROW_ITERATOR)");

            var rows = new List<GhosttyStyledRow>();
            var y = 0;
            while (_iteratorNext(_iterator) != 0)
            {
                var thisY = y++;
                if (row >= 0 && thisY != row) { continue; }
                _memory.WriteInt32(_scratch + OFF_OUT, _cells);
                Check(_rowGet(_iterator, ROW_DATA_CELLS, _scratch + OFF_OUT), "ghostty_render_state_row_get(CELLS)");
                rows.Add(new GhosttyStyledRow { Y = thisY, Runs = ReadRow(columns, foreground, background) });
                if (row >= 0) { break; }
            }

            return new GhosttyScreen { Rows = rows.ToArray(), Foreground = foreground, Background = background };
        }

        GhosttyRun[] ReadRow(int columns, GhosttyColor defaultForeground, GhosttyColor defaultBackground)
        {
            var runs = new List<GhosttyRun>();
            GhosttyRun current = null;
            var text = new StringBuilder();

            for (var x = 0; x < columns; x++)
            {
                if (_cellsSelect(_cells, x) != 0) { break; }
                var cell = ReadCell(defaultForeground, defaultBackground);
                if (current != null && SameStyle(current, cell.Item1))
                {
                    text.Append(cell.Item2);
                    continue;
                }
                if (current != null) { current.Text = text.ToString(); runs.Add(current); }
                current = cell.Item1;
                current.Column = x;
                text.Clear();
                text.Append(cell.Item2);
            }
            if (current != null) { current.Text = text.ToString(); runs.Add(current); }

            // Drop the trailing blanks that carry no styling: a row of ten characters shouldn't
            // come back with ninety spaces after it. A coloured background reaching the edge is
            // not blank in this sense and survives, and so does trailing space the application
            // deliberately styled.
            while (runs.Count > 0)
            {
                var last = runs[runs.Count - 1];
                if (!IsPlain(last)) { break; }
                var trimmed = last.Text.TrimEnd();
                if (trimmed.Length == last.Text.Length) { break; }
                if (trimmed.Length == 0) { runs.RemoveAt(runs.Count - 1); continue; }
                last.Text = trimmed;
                break;
            }
            return runs.ToArray();
        }

        static bool IsPlain(GhosttyRun run)
        {
            return run.Foreground.Kind == "Default" && run.Background.Kind == "Default" &&
                   !run.Bold && !run.Italic && !run.Faint && !run.Blink && !run.Inverse &&
                   !run.Invisible && !run.Strikethrough && !run.Overline && run.Underline == "None";
        }

        static bool SameStyle(GhosttyRun a, GhosttyRun b)
        {
            return a.Bold == b.Bold && a.Italic == b.Italic && a.Faint == b.Faint &&
                   a.Blink == b.Blink && a.Inverse == b.Inverse && a.Invisible == b.Invisible &&
                   a.Strikethrough == b.Strikethrough && a.Overline == b.Overline &&
                   a.Underline == b.Underline &&
                   SameColor(a.Foreground, b.Foreground) && SameColor(a.Background, b.Background) &&
                   SameColor(a.UnderlineColor, b.UnderlineColor);
        }

        static bool SameColor(GhosttyColor a, GhosttyColor b)
        {
            return a.Kind == b.Kind && a.Index == b.Index && a.R == b.R && a.G == b.G && a.B == b.B;
        }

        Tuple<GhosttyRun, string> ReadCell(GhosttyColor defaultForeground, GhosttyColor defaultBackground)
        {
            var run = new GhosttyRun();

            _memory.WriteInt32(_scratch + OFF_FLAG, 0);
            Check(_cellsGet(_cells, CELL_HAS_STYLING, _scratch + OFF_FLAG), "row_cells_get(HAS_STYLING)");
            var styled = _memory.ReadByte(_scratch + OFF_FLAG) != 0;

            if (styled)
            {
                Check(_cellsGet(_cells, CELL_STYLE, _scratch + OFF_STYLE), "row_cells_get(STYLE)");
                var style = _scratch + OFF_STYLE;
                run.Bold = _memory.ReadByte(style + 56) != 0;
                run.Italic = _memory.ReadByte(style + 57) != 0;
                run.Faint = _memory.ReadByte(style + 58) != 0;
                run.Blink = _memory.ReadByte(style + 59) != 0;
                run.Inverse = _memory.ReadByte(style + 60) != 0;
                run.Invisible = _memory.ReadByte(style + 61) != 0;
                run.Strikethrough = _memory.ReadByte(style + 62) != 0;
                run.Overline = _memory.ReadByte(style + 63) != 0;
                var underline = _memory.ReadInt32(style + 64);
                run.Underline = underline >= 0 && underline < Underlines.Length ? Underlines[underline] : "None";
                run.Foreground = ReadStyleColor(style + 8, defaultForeground);
                run.Background = ReadStyleColor(style + 24, defaultBackground);
                run.UnderlineColor = ReadStyleColor(style + 40, defaultForeground);
            }
            else
            {
                run.Underline = "None";
                run.Foreground = GhosttyColor.Make("Default", -1, defaultForeground.R, defaultForeground.G, defaultForeground.B);
                run.Background = GhosttyColor.Make("Default", -1, defaultBackground.R, defaultBackground.G, defaultBackground.B);
                run.UnderlineColor = run.Foreground;
            }

            // The resolved colours: the palette is looked up for us, and a cell whose background
            // came from its content tag (a bare coloured cell, no style) is covered too. Either
            // returns INVALID_VALUE when the application set no colour, which is not an error.
            var effectiveForeground = defaultForeground;
            if (_cellsGet(_cells, CELL_FG_COLOR, _scratch + OFF_RGB) == 0)
            {
                effectiveForeground = ReadRgb(_scratch + OFF_RGB, run.Foreground.Kind, run.Foreground.Index);
            }
            var effectiveBackground = defaultBackground;
            if (_cellsGet(_cells, CELL_BG_COLOR, _scratch + OFF_RGB) == 0)
            {
                effectiveBackground = ReadRgb(_scratch + OFF_RGB, run.Background.Kind, run.Background.Index);
                // A cell can carry a background through its content tag with no style at all.
                if (run.Background.Kind == "Default") { run.Background = effectiveBackground; }
            }

            // Inverse is what a highlighted row usually is, so resolve it rather than making
            // every test think about it.
            run.EffectiveForeground = run.Inverse ? effectiveBackground : effectiveForeground;
            run.EffectiveBackground = run.Inverse ? effectiveForeground : effectiveBackground;

            return Tuple.Create(run, ReadText());
        }

        /// The cell's grapheme cluster as text. A cell with no text is a space: that is what it
        /// looks like, and it keeps runs aligned with columns.
        string ReadText()
        {
            _memory.WriteInt32(_scratch + OFF_BUFFER, _scratch + OFF_TEXT);
            _memory.WriteInt32(_scratch + OFF_BUFFER + 4, TEXT_CAPACITY);
            _memory.WriteInt32(_scratch + OFF_BUFFER + 8, 0);
            if (_cellsGet(_cells, CELL_GRAPHEMES_UTF8, _scratch + OFF_BUFFER) != 0) { return " "; }
            var length = _memory.ReadInt32(_scratch + OFF_BUFFER + 8);
            if (length <= 0 || length > TEXT_CAPACITY) { return " "; }
            return _memory.ReadString(_scratch + OFF_TEXT, length, Encoding.UTF8);
        }

        /// A colour out of a GhosttyStyle. Kind "Default" means the application set none, and
        /// then the RGB is the terminal's own default, so Hex is still what you would see.
        GhosttyColor ReadStyleColor(int address, GhosttyColor fallback)
        {
            var tag = _memory.ReadInt32(address);
            if (tag == 1)
            {
                var index = _memory.ReadByte(address + 8) & 0xFF;
                var entry = _colors + COLORS_PALETTE + index * 3;
                return ReadRgb(entry, "Palette", index);
            }
            if (tag == 2) { return ReadRgb(address + 8, "Rgb", -1); }
            return GhosttyColor.Make("Default", -1, fallback.R, fallback.G, fallback.B);
        }

        GhosttyColor ReadRgb(int address, string kind, int index)
        {
            return GhosttyColor.Make(kind, index,
                _memory.ReadByte(address) & 0xFF,
                _memory.ReadByte(address + 1) & 0xFF,
                _memory.ReadByte(address + 2) & 0xFF);
        }

    }
}

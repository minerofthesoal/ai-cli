# ============================================================================
# MODULE: 16-gui.sh
# GUI v5 — split-pane TUI with mouse, AI extensions
# Source lines 4732-5979 of main-v2.7.3
# ============================================================================

cmd_gui() {
  [[ -z "$PYTHON" ]] && { err "Python 3.10+ required for GUI"; _gui_fallback; return; }

  local gui_script; gui_script=$(mktemp /tmp/ai_gui_XXXX.py)
  local cli_bin; cli_bin=$(command -v ai 2>/dev/null || echo "$0")
  local theme="${GUI_THEME:-dark}"
  local ext_dir="${EXTENSIONS_DIR:-$HOME/.config/ai-cli/extensions}"

  cat > "$gui_script" << 'GUIEOF'
#!/usr/bin/env python3
"""AI CLI v2.7.3 — GUI v5.2: split-pane, structured settings editor, extensions, aliases"""
import sys, os, curses, subprocess, threading, time, textwrap, json, glob, shutil

CLI      = sys.argv[1] if len(sys.argv) > 1 else "ai"
THEME_NAME = sys.argv[2] if len(sys.argv) > 2 else "dark"
EXT_DIR  = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/.config/ai-cli/extensions")

# ── Themes ────────────────────────────────────────────────────────────────────
THEMES = {
    "dark":     {"bg":0,   "fg":7,   "accent":6,   "accent2":2,  "warn":3,   "err":1,  "dim":8,  "sel_bg":4,  "sel_fg":15, "border":6,  "title":14, "hdr_bg":17, "hdr_fg":15, "sidebar":236, "content":235, "edit_bg":22,  "edit_fg":10},
    "light":    {"bg":15,  "fg":0,   "accent":4,   "accent2":2,  "warn":3,   "err":1,  "dim":8,  "sel_bg":6,  "sel_fg":0,  "border":4,  "title":4,  "hdr_bg":21, "hdr_fg":15, "sidebar":254, "content":255, "edit_bg":194, "edit_fg":22},
    "hacker":   {"bg":0,   "fg":2,   "accent":10,  "accent2":2,  "warn":11,  "err":9,  "dim":8,  "sel_bg":2,  "sel_fg":0,  "border":2,  "title":10, "hdr_bg":22, "hdr_fg":10, "sidebar":232, "content":233, "edit_bg":22,  "edit_fg":10},
    "matrix":   {"bg":0,   "fg":10,  "accent":2,   "accent2":10, "warn":11,  "err":9,  "dim":8,  "sel_bg":10, "sel_fg":0,  "border":10, "title":10, "hdr_bg":22, "hdr_fg":10, "sidebar":232, "content":233, "edit_bg":28,  "edit_fg":10},
    "ocean":    {"bg":17,  "fg":14,  "accent":12,  "accent2":6,  "warn":11,  "err":9,  "dim":8,  "sel_bg":12, "sel_fg":0,  "border":6,  "title":14, "hdr_bg":18, "hdr_fg":14, "sidebar":17,  "content":16,  "edit_bg":23,  "edit_fg":14},
    "solarized":{"bg":234, "fg":136, "accent":37,  "accent2":64, "warn":136, "err":160,"dim":240,"sel_bg":33, "sel_fg":15, "border":37, "title":136,"hdr_bg":33, "hdr_fg":15, "sidebar":235, "content":236, "edit_bg":22,  "edit_fg":64},
    "nord":     {"bg":236, "fg":153, "accent":67,  "accent2":108,"warn":179, "err":131,"dim":242,"sel_bg":67, "sel_fg":15, "border":67, "title":153,"hdr_bg":67, "hdr_fg":15, "sidebar":237, "content":238, "edit_bg":23,  "edit_fg":108},
    "gruvbox":  {"bg":235, "fg":223, "accent":214, "accent2":142,"warn":214, "err":167,"dim":243,"sel_bg":214,"sel_fg":235,"border":214,"title":214,"hdr_bg":214,"hdr_fg":235,"sidebar":236, "content":237, "edit_bg":100, "edit_fg":214},
    "dracula":  {"bg":236, "fg":253, "accent":141, "accent2":84, "warn":228, "err":203,"dim":245,"sel_bg":141,"sel_fg":236,"border":141,"title":141,"hdr_bg":141,"hdr_fg":236,"sidebar":237, "content":238, "edit_bg":22,  "edit_fg":84},
}
T = THEMES.get(THEME_NAME, THEMES["dark"])

# ── Color pair IDs ────────────────────────────────────────────────────────────
CP_NORMAL   = 1
CP_ACCENT   = 2
CP_ACCENT2  = 3
CP_WARN     = 4
CP_ERR      = 5
CP_DIM      = 6
CP_SEL      = 7
CP_BORDER   = 8
CP_TITLE    = 9
CP_USER     = 10
CP_AI       = 11
CP_SYS      = 12
CP_HDR      = 13
CP_SIDEBAR  = 14
CP_CONTENT  = 15
CP_EDIT     = 16
CP_SEL_ACT  = 17   # selected+active (being edited)
CP_TICK     = 18   # checkmark / status OK
CP_HBDR     = 19   # horizontal divider

def init_colors():
    curses.start_color()
    curses.use_default_colors()

    def bg(k): return T[k] if T[k] > 0 else -1
    def pair(n, fg, bgk):
        curses.init_pair(n, fg, bg(bgk) if isinstance(bgk, str) else (bgk if bgk > 0 else -1))

    pair(CP_NORMAL,  T["fg"],      "bg")
    pair(CP_ACCENT,  T["accent"],  "bg")
    pair(CP_ACCENT2, T["accent2"], "bg")
    pair(CP_WARN,    T["warn"],    "bg")
    pair(CP_ERR,     T["err"],     "bg")
    pair(CP_DIM,     T["dim"],     "bg")
    pair(CP_SEL,     T["sel_fg"],  "sel_bg")
    pair(CP_BORDER,  T["border"],  "bg")
    pair(CP_TITLE,   T["title"],   "bg")
    pair(CP_USER,    12,           "bg")
    pair(CP_AI,      T["accent2"], "bg")
    pair(CP_SYS,     T["dim"],     "bg")
    curses.init_pair(CP_HDR,     T["hdr_fg"],  T["hdr_bg"])
    curses.init_pair(CP_SIDEBAR, T["fg"],      T["sidebar"])
    curses.init_pair(CP_CONTENT, T["fg"],      T["content"])
    curses.init_pair(CP_EDIT,    T["edit_fg"], T["edit_bg"])
    curses.init_pair(CP_SEL_ACT, T["sel_fg"],  T["edit_bg"])
    pair(CP_TICK,    T["accent2"], "bg")
    pair(CP_HBDR,    T["border"],  "bg")

# ── Safe add / draw utils ──────────────────────────────────────────────────────
def safe_add(win, y, x, text, attr=0):
    h, w = win.getmaxyx()
    if y < 0 or y >= h or x < 0: return
    available = w - x - 1
    if available <= 0: return
    try: win.addstr(y, x, str(text)[:available], attr)
    except curses.error: pass

def fill_line(win, y, x, w, attr=0, char=' '):
    for i in range(w):
        try: win.addch(y, x + i, ord(char), attr)
        except curses.error: pass

def draw_hline(win, y, x, w, char='─', attr=0):
    for i in range(w):
        try: win.addch(y, x + i, ord(char), attr)
        except curses.error: pass

def draw_vline(win, y, x, h, attr=0):
    for i in range(h):
        try: win.addch(y + i, x, curses.ACS_VLINE, attr)
        except curses.error: pass

def draw_panel(win, y, x, h, w, title="", border_cp=CP_BORDER, title_cp=CP_TITLE, fill_cp=None):
    """Draw a styled panel with optional fill. v5 style: uses ╔ ╗ ╚ ╝ ═ ║"""
    b = curses.color_pair(border_cp)
    try:
        # Corners
        win.addch(y,     x,     ord('╔'), b)
        win.addch(y,     x+w-1, ord('╗'), b)
        win.addch(y+h-1, x,     ord('╚'), b)
        win.addch(y+h-1, x+w-1, ord('╝'), b)
        # Edges
        for i in range(1, w-1): win.addch(y,     x+i, ord('═'), b)
        for i in range(1, w-1): win.addch(y+h-1, x+i, ord('═'), b)
        for i in range(1, h-1): win.addch(y+i,   x,   ord('║'), b)
        for i in range(1, h-1): win.addch(y+i, x+w-1, ord('║'), b)
        # Fill interior
        if fill_cp is not None:
            fa = curses.color_pair(fill_cp)
            for fy in range(1, h-1):
                fill_line(win, y+fy, x+1, w-2, fa)
        # Title
        if title:
            t = f" {title} "
            tx = x + max(1, (w - len(t)) // 2)
            safe_add(win, y, tx, t, curses.color_pair(title_cp) | curses.A_BOLD)
    except curses.error: pass

def run_ai(*args, timeout=60):
    try:
        r = subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout)
        return (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired: return "[timeout]"
    except Exception as e: return f"[error: {e}]"

def wrap_text(text, width):
    lines = []
    for para in str(text).splitlines():
        if para.strip() == "": lines.append("")
        else: lines.extend(textwrap.wrap(para, max(1, width)) or [""])
    return lines

# ── Inline single-line editor ──────────────────────────────────────────────────
def input_line(stdscr, y, x, w, prompt="", prefill="", cp=CP_EDIT):
    """Inline editor returning text or None on Esc. Supports full cursor movement."""
    curses.curs_set(1)
    buf = list(str(prefill))
    cur = len(buf)
    ea  = curses.color_pair(cp) | curses.A_BOLD
    pa  = curses.color_pair(CP_ACCENT) | curses.A_BOLD
    while True:
        safe_add(stdscr, y, x, prompt, pa)
        px = x + len(prompt)
        fw = max(1, w - len(prompt) - 1)
        txt = ''.join(buf)
        if cur >= fw:
            vis  = txt[cur - fw + 1: cur + 1]
            vcur = fw - 1
        else:
            vis  = txt[:fw]
            vcur = cur
        safe_add(stdscr, y, px, vis.ljust(fw), ea)
        try: stdscr.move(y, px + vcur)
        except: pass
        stdscr.refresh()
        ch = stdscr.getch()
        if ch in (10, 13):
            curses.curs_set(0)
            return ''.join(buf)
        elif ch == 27:
            curses.curs_set(0)
            return None
        elif ch in (curses.KEY_BACKSPACE, 127, 8):
            if cur > 0: buf.pop(cur - 1); cur -= 1
        elif ch == curses.KEY_DC:
            if cur < len(buf): buf.pop(cur)
        elif ch == curses.KEY_LEFT:  cur = max(0, cur - 1)
        elif ch == curses.KEY_RIGHT: cur = min(len(buf), cur + 1)
        elif ch == curses.KEY_HOME:  cur = 0
        elif ch == curses.KEY_END:   cur = len(buf)
        elif 32 <= ch <= 126:
            buf.insert(cur, chr(ch)); cur += 1

# ── Multi-line editor dialog ───────────────────────────────────────────────────
def input_multiline(stdscr, title="Edit", prefill=""):
    """Full-screen multiline editor. Returns text or None on Esc."""
    h, w = stdscr.getmaxyx()
    buf  = [list(l) for l in prefill.splitlines()] or [[]]
    cy, cx = 0, 0
    curses.curs_set(1)
    scroll = 0

    def clamp():
        nonlocal cy, cx
        cy = max(0, min(cy, len(buf) - 1))
        cx = max(0, min(cx, len(buf[cy])))

    while True:
        stdscr.erase()
        draw_panel(stdscr, 0, 0, h, w, title, CP_ACCENT, CP_TITLE, CP_CONTENT)
        safe_add(stdscr, h-1, 0, " Ctrl+S / F2=save  Esc=cancel  Ctrl+N=new line ".ljust(w),
                 curses.color_pair(CP_HDR))
        inner_h = h - 2
        inner_w = w - 2
        visible = inner_h
        if cy < scroll:    scroll = cy
        if cy >= scroll + visible: scroll = cy - visible + 1
        for iy in range(visible):
            bi = iy + scroll
            if bi >= len(buf): break
            line = ''.join(buf[bi])
            attr = curses.color_pair(CP_CONTENT)
            if bi == cy: attr = curses.color_pair(CP_EDIT)
            safe_add(stdscr, 1 + iy, 1, line[:inner_w].ljust(inner_w), attr)
        try: stdscr.move(1 + cy - scroll, 1 + min(cx, inner_w - 1))
        except: pass
        stdscr.refresh()
        ch = stdscr.getch()
        if ch == 27:
            curses.curs_set(0); return None
        elif ch in (curses.KEY_F2,) or ch == 19:  # F2 or Ctrl+S
            curses.curs_set(0)
            return '\n'.join(''.join(r) for r in buf)
        elif ch == 14:  # Ctrl+N  — new line
            rest = buf[cy][cx:]
            buf[cy] = buf[cy][:cx]
            buf.insert(cy + 1, rest)
            cy += 1; cx = 0
        elif ch in (10, 13):
            rest = buf[cy][cx:]
            buf[cy] = buf[cy][:cx]
            buf.insert(cy + 1, rest)
            cy += 1; cx = 0
        elif ch in (curses.KEY_BACKSPACE, 127, 8):
            if cx > 0:
                buf[cy].pop(cx - 1); cx -= 1
            elif cy > 0:
                cx = len(buf[cy - 1])
                buf[cy - 1].extend(buf[cy])
                buf.pop(cy); cy -= 1
        elif ch == curses.KEY_DC:
            if cx < len(buf[cy]): buf[cy].pop(cx)
            elif cy < len(buf) - 1:
                buf[cy].extend(buf[cy + 1]); buf.pop(cy + 1)
        elif ch == curses.KEY_UP:   cy -= 1; clamp()
        elif ch == curses.KEY_DOWN: cy += 1; clamp()
        elif ch == curses.KEY_LEFT:
            if cx > 0: cx -= 1
            elif cy > 0: cy -= 1; cx = len(buf[cy])
        elif ch == curses.KEY_RIGHT:
            if cx < len(buf[cy]): cx += 1
            elif cy < len(buf) - 1: cy += 1; cx = 0
        elif ch == curses.KEY_HOME: cx = 0
        elif ch == curses.KEY_END:  cx = len(buf[cy])
        elif ch == curses.KEY_PPAGE: cy = max(0, cy - (visible - 1)); clamp()
        elif ch == curses.KEY_NPAGE: cy = min(len(buf) - 1, cy + visible - 1); clamp()
        elif 32 <= ch <= 126:
            buf[cy].insert(cx, chr(ch)); cx += 1

# ── Sidebar menu ──────────────────────────────────────────────────────────────
class Sidebar:
    """Left-side navigation menu for v5 split layout."""
    def __init__(self, sections):
        # sections: list of (header, [(label, value, editable_hint), ...])
        self.sections  = sections
        self._flat     = []   # (display_str, value, is_header, editable_hint)
        for hdr, items in sections:
            self._flat.append((hdr, None, True, ""))
            for label, val, hint in items:
                self._flat.append((label, val, False, hint))
        self.idx    = 1 if len(self._flat) > 1 else 0
        self.offset = 0
        self._skip_to_item()
        # Render bounds
        self._ry = 0; self._rx = 0; self._rh = 0; self._rw = 0

    def _skip_to_item(self):
        """Ensure idx points to a non-header item."""
        for _ in range(len(self._flat)):
            if self.idx >= len(self._flat): self.idx = 0
            if not self._flat[self.idx][2]: break
            self.idx += 1

    def current(self):
        if 0 <= self.idx < len(self._flat):
            return self._flat[self.idx]
        return ("", None, False, "")

    def draw(self, win, y, x, h, w):
        self._ry = y; self._rx = x; self._rh = h; self._rw = w
        draw_panel(win, y, x, h, w, "⚙ Menu", CP_BORDER, CP_TITLE, CP_SIDEBAR)
        visible = h - 2
        if self.idx < self.offset: self.offset = self.idx
        if self.idx >= self.offset + visible: self.offset = self.idx - visible + 1

        for i in range(visible):
            ri = i + self.offset
            if ri >= len(self._flat): break
            label, val, is_hdr, hint = self._flat[ri]
            row_y = y + 1 + i
            if is_hdr:
                # Section header — dimmed, uppercase, no-select
                txt = f" ─ {label.upper()} "
                safe_add(win, row_y, x + 1, txt[:w-2], curses.color_pair(CP_DIM) | curses.A_BOLD)
            elif ri == self.idx:
                # Selected item
                txt = f" ▶ {label}"
                fill_line(win, row_y, x + 1, w - 2, curses.color_pair(CP_SEL))
                safe_add(win, row_y, x + 1, txt[:w-2], curses.color_pair(CP_SEL) | curses.A_BOLD)
                if hint:
                    h_txt = hint[:w-2-len(txt)-1]
                    safe_add(win, row_y, x + 1 + len(txt), f" {h_txt}", curses.color_pair(CP_SEL))
            else:
                txt = f"   {label}"
                fill_line(win, row_y, x + 1, w - 2, curses.color_pair(CP_SIDEBAR))
                safe_add(win, row_y, x + 1, txt[:w-2], curses.color_pair(CP_SIDEBAR))

        # Scrollbar
        total_items = sum(1 for _, _, h2, _ in self._flat if not h2)
        if total_items > visible:
            bar_y = y + 1 + min(visible - 1, int(self.idx / max(1, len(self._flat)-1) * (visible-1)))
            try: win.addch(bar_y, x + w - 1, ord('▌'), curses.color_pair(CP_ACCENT))
            except: pass

    def handle_click(self, cy, cx):
        """Returns (value, do_edit) or (None, False)."""
        y, x, h, w = self._ry, self._rx, self._rh, self._rw
        if cy < y+1 or cy >= y+h-1 or cx < x+1 or cx >= x+w-1: return None, False
        ri = (cy - (y + 1)) + self.offset
        if ri < 0 or ri >= len(self._flat): return None, False
        label, val, is_hdr, hint = self._flat[ri]
        if is_hdr: return None, False
        if ri == self.idx:
            return val, True   # second click → activate/edit
        else:
            self.idx = ri
            return None, False

    def handle_key(self, ch):
        """Returns (value, do_edit) or (None, False)."""
        if ch == curses.KEY_UP:
            self.idx -= 1
            while self.idx > 0 and self._flat[self.idx][2]: self.idx -= 1
            if self._flat[self.idx][2]: self.idx += 1
        elif ch == curses.KEY_DOWN:
            self.idx += 1
            while self.idx < len(self._flat) - 1 and self._flat[self.idx][2]: self.idx += 1
        elif ch == curses.KEY_PPAGE:
            self.idx = max(1, self.idx - 8); self._skip_to_item()
        elif ch == curses.KEY_NPAGE:
            self.idx = min(len(self._flat)-1, self.idx + 8); self._skip_to_item()
        elif ch == curses.KEY_HOME: self.idx = 1; self._skip_to_item()
        elif ch == curses.KEY_END:  self.idx = len(self._flat) - 1
        elif ch in (10, 13):  # Enter → activate
            label, val, is_hdr, hint = self.current()
            return val, True
        elif ch in (ord(' '),):  # Space → also activate (like Enter)
            label, val, is_hdr, hint = self.current()
            return val, True
        self.idx = max(0, min(self.idx, len(self._flat) - 1))
        return None, False

# ── Content panel ──────────────────────────────────────────────────────────────
class ContentPanel:
    """Right-side content pane: output pager + edit mode."""
    def __init__(self):
        self.lines   = ["Welcome to AI CLI v2.7.3 — GUI v5.2",
                        "─" * 40,
                        "Use the sidebar to navigate.",
                        "Enter or click an item to activate it.",
                        "Settings: each value is individually editable.",
                        "",
                        "Keyboard shortcuts:",
                        "  ↑↓ PgUp/Dn  Navigate sidebar",
                        "  Enter/Space Activate selected item",
                        "  Tab         Focus sidebar/content",
                        "  F1 / ?      Help",
                        "  Ctrl+Q      Quit",
                        "  F5          Refresh",
                        "  /           Quick search",
                        ]
        self.scroll = 0
        self.title  = "AI CLI v2.7.3 GUI v5.2"
        # For edit in place
        self.edit_mode   = False
        self.edit_key    = ""
        self.edit_val    = ""
        # Bounds
        self._ry = 0; self._rx = 0; self._rh = 0; self._rw = 0

    def show(self, text, title="Output"):
        self.lines  = wrap_text(text, 9999)
        self.scroll = 0
        self.title  = title

    def draw(self, win, y, x, h, w, focused=True):
        self._ry = y; self._rx = x; self._rh = h; self._rw = w
        bdr = CP_ACCENT if focused else CP_BORDER
        draw_panel(win, y, x, h, w, f" {self.title} ", bdr, CP_TITLE, CP_CONTENT)
        inner_w = w - 2
        visible = h - 2
        max_sc  = max(0, len(self.lines) - visible)
        self.scroll = min(self.scroll, max_sc)

        for i in range(visible):
            li = i + self.scroll
            if li >= len(self.lines): break
            raw = self.lines[li]
            attr = curses.color_pair(CP_CONTENT)
            # Syntax highlight hints
            if raw.startswith("##") or raw.startswith("══"):
                attr = curses.color_pair(CP_TITLE) | curses.A_BOLD
            elif raw.startswith("#") or raw.startswith("─"):
                attr = curses.color_pair(CP_ACCENT) | curses.A_BOLD
            elif raw.startswith("  ") and ":" in raw:
                attr = curses.color_pair(CP_DIM)
            safe_add(win, y + 1 + i, x + 1, raw[:inner_w].ljust(inner_w), attr)

        # Scrollbar
        if len(self.lines) > visible:
            pct = int(self.scroll / max(1, max_sc) * 100)
            safe_add(win, y + h - 1, x + w - 8, f" {pct:3d}% ", curses.color_pair(CP_DIM))
            bar_row = y + 1 + int(self.scroll / max(1, max_sc) * (visible - 1))
            for r in range(y + 1, y + h - 1):
                ch_bar = '█' if r == bar_row else '░'
                try: win.addch(r, x + w - 1, ord(ch_bar),
                               curses.color_pair(CP_ACCENT if r == bar_row else CP_DIM))
                except: pass

    def scroll_up(self, n=3):   self.scroll = max(0, self.scroll - n)
    def scroll_down(self, n=3): self.scroll += n

    def handle_key(self, ch):
        if ch == curses.KEY_UP:      self.scroll_up(1)
        elif ch == curses.KEY_DOWN:  self.scroll_down(1)
        elif ch == curses.KEY_PPAGE: self.scroll_up(10)
        elif ch == curses.KEY_NPAGE: self.scroll_down(10)
        elif ch == curses.KEY_HOME:  self.scroll = 0
        elif ch == curses.KEY_END:   self.scroll = 999999

# ── Chat panel ────────────────────────────────────────────────────────────────
class ChatPanel:
    def __init__(self):
        self.messages = []
        self.input    = ""
        self.scroll   = 0
        self.thinking = False
        self._lock    = threading.Lock()

    def add(self, role, text):
        with self._lock: self.messages.append((role, text))

    def ask_async(self, prompt, on_done):
        self.thinking = True
        def worker():
            resp = run_ai("ask", prompt, timeout=120)
            self.add("AI", resp if resp else "[No response]")
            self.thinking = False
            on_done()
        threading.Thread(target=worker, daemon=True).start()

    def draw(self, win, y, x, h, w):
        draw_panel(win, y, x, h, w, "💬 Chat", CP_ACCENT, CP_TITLE, CP_CONTENT)
        inner_w = w - 2
        rendered = []
        with self._lock: msgs = list(self.messages)
        all_lines = []
        for role, text in msgs:
            if role == "You":
                prefix = "You  ▶ "
                cp = CP_USER
            elif role == "AI":
                prefix = "AI   ◀ "
                cp = CP_AI
            else:
                prefix = "      "
                cp = CP_SYS
            for i, wl in enumerate(wrap_text(text, inner_w - len(prefix) - 1)):
                all_lines.append((f"{prefix if i==0 else ' '*len(prefix)}{wl}", cp))
            all_lines.append(("", CP_NORMAL))

        visible = h - 4
        if self.scroll == 0 or self.scroll > len(all_lines) - visible:
            self.scroll = max(0, len(all_lines) - visible)
        for i in range(visible):
            li = i + self.scroll
            if li >= len(all_lines): break
            text2, cp = all_lines[li]
            safe_add(win, y + 1 + i, x + 1, text2[:inner_w], curses.color_pair(cp))
        if self.thinking:
            dots = "." * (int(time.time() * 2) % 4)
            safe_add(win, y + h - 3, x + 1,
                     f" AI is thinking{dots:<4}".ljust(inner_w),
                     curses.color_pair(CP_WARN) | curses.A_BOLD)
        draw_hline(win, y + h - 2, x + 1, inner_w, '─', curses.color_pair(CP_HBDR))
        inp_display = self.input[:inner_w - 4]
        safe_add(win, y + h - 1, x + 1, f" ▷ {inp_display}", curses.color_pair(CP_ACCENT))

    def handle_input(self, ch):
        if ch in (curses.KEY_BACKSPACE, 127, 8): self.input = self.input[:-1]
        elif ch in (10, 13): return "submit"
        elif ch == curses.KEY_PPAGE: self.scroll = max(0, self.scroll - 5)
        elif ch == curses.KEY_NPAGE: self.scroll += 5
        elif 32 <= ch <= 126: self.input += chr(ch)
        return True

# ── Extension helpers ──────────────────────────────────────────────────────────
def list_extensions():
    """Return list of (name, path, enabled) for installed extensions."""
    if not os.path.isdir(EXT_DIR): return []
    result = []
    for d in sorted(os.listdir(EXT_DIR)):
        full = os.path.join(EXT_DIR, d)
        if not os.path.isdir(full): continue
        mf = os.path.join(full, "manifest.json")
        enabled = os.path.exists(os.path.join(full, ".enabled"))
        name = d
        if os.path.exists(mf):
            try:
                with open(mf) as f: meta = json.load(f)
                name = meta.get("name", d)
            except: pass
        result.append((name, full, enabled))
    return result

# ── Main App ──────────────────────────────────────────────────────────────────
class App:
    SIDEBAR_W = 28   # left sidebar width

    MENU_SECTIONS = [
        ("CHAT & ASK", [
            ("💬 Chat",              "chat",        ""),
            ("❓ Ask (one-shot)",     "ask",         ""),
            ("🏆 Multi-AI Arena",     "multiai",     ""),
            ("🔍 Web Search",         "websearch",   ""),
        ]),
        ("MEDIA & VISION", [
            ("🖼  Imagine (image)",   "imagine",     ""),
            ("👁  Vision",            "vision",      ""),
            ("🔊 Audio",              "audio",       ""),
            ("📹 Video",              "video",       ""),
        ]),
        ("CANVAS & CODE", [
            ("🖊  Canvas v2",         "canvas",      ""),
            ("🐙 GitHub",             "github",      ""),
            ("📄 Research Papers",   "papers",      ""),
        ]),
        ("MODELS & TRAINING", [
            ("🤖 Models",             "models",      ""),
            ("🧠 TTM (179M)",         "ttm",         ""),
            ("🧠 MTM (0.61B)",        "mtm",         ""),
            ("🧠 Mtm (1.075B)",       "mmtm",        ""),
            ("📊 Datasets",           "datasets",    ""),
            ("🔁 RLHF",              "rlhf",        ""),
        ]),
        ("EXTENSIONS", [
            ("🧩 Manage Extensions", "ext_list",    "[e]dit"),
            ("➕ Create Extension",  "ext_create",  ""),
            ("📦 Load .aipack",      "ext_load",    ""),
            ("🔎 Locate Extensions", "ext_locate",  ""),
            ("🦊 Install Firefox Ext","firefox_ext", ""),
        ]),
        ("ALIASES & TOOLS", [
            ("🔗 Aliases",           "aliases",     "[e]dit"),
            ("💻 Error Codes",       "errcodes",    ""),
        ]),
        ("SYSTEM", [
            ("⚙  Settings",          "settings",    "[e]dit"),
            ("ℹ  Status",            "status",      ""),
            ("🎨 Change Theme",       "theme",       ""),
            ("🚪 Quit",              "quit",        ""),
        ]),
    ]

    THEME_MENU = [(t.capitalize(), t) for t in THEMES.keys()]

    def __init__(self, stdscr):
        self.stdscr  = stdscr
        self.sidebar = Sidebar([(h, [(l, v, e) for l, v, e in items])
                                for h, items in self.MENU_SECTIONS])
        self.content = ContentPanel()
        self.chat    = ChatPanel()
        self.mode    = "normal"   # normal | chat | search
        self.focus   = "sidebar"  # sidebar | content
        self.status  = ""
        self._search_buf = ""
        # Status bar rotating tip
        self._tip_idx = 0
        self._tips    = [
            "↑↓ navigate  Enter/Space=activate  Tab=switch focus  Ctrl+Q=quit",
            "Click item once to select, again to activate  •  F1=help  ?=help",
            "Editable items show [edit] hint  •  Press Enter to open inline editor",
            "Extensions: create, load, locate .aipack files  •  Firefox sidebar support",
        ]

    def dims(self): return self.stdscr.getmaxyx()

    def _draw_header(self, h, w):
        ver_str = "AI CLI v2.7.3  GUI v5.2"
        mode_str = f"[{THEME_NAME.upper()}]  {self.mode.upper()}"
        bar = f"  {ver_str}  │  {mode_str}  │  focus:{self.focus}  "
        safe_add(self.stdscr, 0, 0, bar.ljust(w), curses.color_pair(CP_HDR) | curses.A_BOLD)
        # Right-align hint
        hint = "Ctrl+Q=quit  F1=help"
        safe_add(self.stdscr, 0, max(0, w - len(hint) - 1), hint,
                 curses.color_pair(CP_HDR))

    def _draw_statusbar(self, h, w):
        tip = self._tips[int(time.time() / 5) % len(self._tips)]
        bar = f" {self.status or tip} "
        safe_add(self.stdscr, h - 1, 0, bar.ljust(w), curses.color_pair(CP_HDR))
        # Current item hint on right
        _, val, _, hint = self.sidebar.current()
        if hint:
            rhs = f" {hint} "
            safe_add(self.stdscr, h - 1, max(0, w - len(rhs) - 1), rhs,
                     curses.color_pair(CP_ACCENT) | curses.A_BOLD)

    def _draw_normal(self, h, w):
        sw = min(self.SIDEBAR_W, w // 3)
        cw = w - sw
        cy2 = h - 2
        # Sidebar
        self.sidebar.draw(self.stdscr, 1, 0, cy2, sw)
        # Vertical divider
        bdr_a = curses.color_pair(CP_BORDER)
        for r in range(1, cy2 + 1):
            try: self.stdscr.addch(r, sw, ord('║'), bdr_a)
            except: pass
        # Content
        self.content.draw(self.stdscr, 1, sw, cy2, cw, focused=(self.focus == "content"))

    def _draw_chat_mode(self, h, w):
        self.chat.draw(self.stdscr, 1, 0, h - 2, w)

    # ── Search bar ────────────────────────────────────────────────────────────
    def _start_search(self, h, w):
        self.mode = "search"
        self._search_buf = ""
        result = input_line(self.stdscr, h - 1, 0, w, "/", cp=CP_EDIT)
        self.mode = "normal"
        if result:
            self._search_items(result)

    def _search_items(self, query):
        q = query.lower()
        matches = []
        for _, items in self.MENU_SECTIONS:
            for label, val, hint in items:
                if q in label.lower() or q in val.lower():
                    matches.append(f"  ▶  [{val}] {label}")
        if matches:
            self.content.show("\n".join(matches), f"Search: {query}")
        else:
            self.content.show(f"No results for: {query}", "Search")

    # ── Action dispatcher ─────────────────────────────────────────────────────
    def do_action(self, action):
        h, w = self.dims()
        self.status = ""

        if action == "quit": return False

        elif action == "chat":
            self.mode = "chat"
            if not self.chat.messages:
                self.chat.add("sys", "Chat mode  •  Type a message and press Enter  •  /quit=menu  /clear=clear  /help")

        elif action == "ask":
            q = input_line(self.stdscr, h // 2, 2, w - 4, "Ask ▶ ", cp=CP_EDIT)
            if q:
                self.status = "Thinking…"
                self._redraw()
                result = run_ai("ask", q)
                self.content.show(result, f"Answer: {q[:40]}")

        elif action == "imagine":
            q = input_line(self.stdscr, h // 2, 2, w - 4, "Image prompt ▶ ", cp=CP_EDIT)
            if q:
                self.status = "Generating…"
                self._redraw()
                result = run_ai("imagine", q)
                self.content.show(result, "Image Generation")

        elif action == "vision":
            p = input_line(self.stdscr, h // 2 - 1, 2, w - 4, "Image path  ▶ ", cp=CP_EDIT)
            if p:
                q = input_line(self.stdscr, h // 2 + 1, 2, w - 4, "Question    ▶ ", cp=CP_EDIT)
                if q:
                    self.status = "Analyzing…"
                    self._redraw()
                    result = run_ai("vision", p, q)
                    self.content.show(result, "Vision")

        elif action == "audio":
            result = run_ai("audio", "help")
            self.content.show(result, "Audio Help")

        elif action == "video":
            result = run_ai("video", "help")
            self.content.show(result, "Video Help")

        elif action == "canvas":
            result = run_ai("canvas-v2", "help")
            self.content.show(result, "Canvas v2 Help")

        elif action == "models":
            self.status = "Loading models…"
            self._redraw()
            result = run_ai("models")
            self.content.show(result, "Downloaded Models")

        elif action == "ttm":
            result = run_ai("ttm")
            self.content.show(result, "TTM — Tiny Model (179M)")

        elif action == "mtm":
            result = run_ai("mtm")
            self.content.show(result, "MTM — Mini Model (0.61B)")

        elif action == "mmtm":
            result = run_ai("Mtm")
            self.content.show(result, "Mtm — Medium Model (1.075B)")

        elif action == "datasets":
            result = run_ai("dataset", "list")
            self.content.show(result or "(no datasets)", "Datasets")

        elif action == "rlhf":
            result = run_ai("rlhf", "status")
            self.content.show(result, "RLHF Status")

        elif action == "multiai":
            topic = input_line(self.stdscr, h // 2 - 1, 2, w - 4, "Topic  ▶ ", cp=CP_EDIT)
            if topic:
                mode2 = input_line(self.stdscr, h // 2 + 1, 2, w - 4, "Mode (debate/collab/ensemble) ▶ ", cp=CP_EDIT) or "debate"
                self.status = "Multi-AI running…"
                self._redraw()
                result = run_ai("multiai", mode2, topic, timeout=180)
                self.content.show(result, f"Multi-AI {mode2.capitalize()}")

        elif action == "websearch":
            q = input_line(self.stdscr, h // 2, 2, w - 4, "Search ▶ ", cp=CP_EDIT)
            if q:
                self.status = "Searching…"
                self._redraw()
                result = run_ai("websearch", q)
                self.content.show(result, f"Web: {q[:40]}")

        elif action == "github":
            sub = input_line(self.stdscr, h // 2 - 1, 2, w - 4, "GitHub cmd ▶ (status/commit/push/log) ", cp=CP_EDIT) or "status"
            if sub in ("commit",):
                msg = input_line(self.stdscr, h // 2 + 1, 2, w - 4, "Commit msg ▶ ", cp=CP_EDIT) or "Auto-commit"
                result = run_ai("github", sub, msg)
            else:
                result = run_ai("github", sub)
            self.content.show(result, f"GitHub: {sub}")

        elif action == "papers":
            q = input_line(self.stdscr, h // 2, 2, w - 4, "Search papers ▶ ", cp=CP_EDIT)
            if q:
                self.status = "Searching papers…"
                self._redraw()
                result = run_ai("papers", "search", q)
                self.content.show(result, f"Papers: {q[:40]}")

        elif action == "status":
            self.status = "Loading status…"
            self._redraw()
            result = run_ai("status")
            self.content.show(result, "System Status")

        elif action == "settings":
            self.status = "Loading settings…"
            self._redraw()
            self._open_settings_editor()

        elif action == "theme":
            chosen = self._run_inline_menu("🎨 Select Theme", self.THEME_MENU)
            if chosen:
                run_ai("config", "gui_theme", chosen)
                self.content.show(f"Theme set to: {chosen}\nRestart GUI to apply.", "Theme Changed")

        # ── Extensions ─────────────────────────────────────────────────────
        elif action == "ext_list":
            exts = list_extensions()
            if not exts:
                self.content.show("No extensions installed.\nUse 'Create Extension' or 'Load .aipack' to add one.", "Extensions")
            else:
                lines = ["Installed Extensions\n" + "─"*40]
                for name, path, enabled in exts:
                    status2 = "✓ enabled" if enabled else "✗ disabled"
                    lines.append(f"  {status2}  {name}")
                    lines.append(f"            {path}")
                    lines.append("")
                self.content.show("\n".join(lines), "Extensions")

        elif action == "ext_create":
            name = input_line(self.stdscr, h // 2 - 2, 2, w - 4, "Extension name ▶ ", cp=CP_EDIT)
            if name:
                desc = input_line(self.stdscr, h // 2, 2, w - 4, "Description   ▶ ", cp=CP_EDIT) or ""
                result = run_ai("extension", "create", name, desc or name)
                self.content.show(result, f"Created: {name}")

        elif action == "ext_load":
            path = input_line(self.stdscr, h // 2, 2, w - 4, ".aipack path  ▶ ", cp=CP_EDIT)
            if path:
                path = os.path.expanduser(path.strip())
                result = run_ai("extension", "load", path)
                self.content.show(result, "Load Extension")

        elif action == "ext_locate":
            result = run_ai("extension", "locate")
            self.content.show(result, "Extension Locations")

        elif action == "firefox_ext":
            self.status = "Installing Firefox extension…"
            self._redraw()
            result = run_ai("install-firefox-ext")
            self.content.show(result, "Firefox LLM Sidebar Extension")

        # ── Aliases & Tools (v5.2) ──────────────────────────────────────────
        elif action == "aliases":
            result = run_ai("alias", "list")
            self.content.show(result, "Aliases (ai alias list)")
            # Inline editor for new alias
            h2, w2 = self.dims()
            name = input_line(self.stdscr, h2 - 4, 2, w2 - 4,
                              "New alias name (blank=skip) ▶ ", cp=CP_EDIT)
            if name and name.strip():
                cmd_str = input_line(self.stdscr, h2 - 3, 2, w2 - 4,
                                     f"Command for '{name}' ▶ ", cp=CP_EDIT)
                if cmd_str:
                    r2 = run_ai("alias", "set", name.strip(), cmd_str.strip())
                    self.content.show(r2 + "\n\n" + run_ai("alias", "list"),
                                      "Aliases (updated)")

        elif action == "errcodes":
            result = run_ai("error-codes")
            self.content.show(result, "Error Code Reference")

        else:
            self.content.show(f"Action '{action}' not mapped in GUI.\nRun: ai {action}", action)

        self.status = ""
        return True

    def _run_inline_menu(self, title, items):
        """Blocking centered submenu. items: [(label, value)]"""
        h, w = self.dims()
        mw = min(44, w - 4)
        mh = min(len(items) + 2, h - 4)
        mx = (w - mw) // 2
        my = max(1, (h - mh) // 2)
        menu = Sidebar([("", [(l, v, "") for l, v in items])])
        while True:
            self.stdscr.erase()
            self._draw_header(h, w)
            draw_panel(self.stdscr, my, mx, mh, mw, title, CP_ACCENT, CP_TITLE, CP_SIDEBAR)
            visible = mh - 2
            for i in range(visible):
                ri = i + menu.offset
                if ri >= len(menu._flat): break
                label, val, is_hdr, _ = menu._flat[ri]
                if is_hdr: continue
                row_y = my + 1 + i
                if ri == menu.idx:
                    fill_line(self.stdscr, row_y, mx + 1, mw - 2, curses.color_pair(CP_SEL))
                    safe_add(self.stdscr, row_y, mx + 2, f"▶ {label}"[:mw-3], curses.color_pair(CP_SEL) | curses.A_BOLD)
                else:
                    fill_line(self.stdscr, row_y, mx + 1, mw - 2, curses.color_pair(CP_SIDEBAR))
                    safe_add(self.stdscr, row_y, mx + 2, f"  {label}"[:mw-3], curses.color_pair(CP_SIDEBAR))
            safe_add(self.stdscr, h - 1, 0, " Enter=select  Esc=cancel ".ljust(w), curses.color_pair(CP_HDR))
            self.stdscr.refresh()
            ch = self.stdscr.getch()
            if ch == 27: return None
            if ch == curses.KEY_MOUSE:
                try:
                    _, bx, by, _, bstate = curses.getmouse()
                    if bstate & (curses.BUTTON1_CLICKED | curses.BUTTON1_DOUBLE_CLICKED):
                        val2, do_act = menu.handle_click(by, bx)
                        if do_act and val2: return val2
                except curses.error: pass
                continue
            val2, do_act = menu.handle_key(ch)
            if do_act and val2: return val2

    def _redraw(self):
        h, w = self.dims()
        self.stdscr.erase()
        self._draw_header(h, w)
        if self.mode == "chat":
            self._draw_chat_mode(h, w)
        else:
            self._draw_normal(h, w)
        self._draw_statusbar(h, w)
        self.stdscr.refresh()

    # ── Settings editor (v5.1) ────────────────────────────────────────────────
    # Editable keys — only these can be changed from the GUI
    _EDITABLE_SETTINGS = [
        ("ACTIVE_BACKEND",       "Active backend",          "openai|claude|gemini|gguf|pytorch|hf"),
        ("ACTIVE_MODEL",         "Active model",            "model name or path"),
        ("API_HOST",             "API server host",         "127.0.0.1 or 0.0.0.0"),
        ("API_PORT",             "API server port",         "8080"),
        ("API_KEY",              "API server key",          "bearer token (leave blank = open)"),
        ("API_CORS",             "API CORS enabled",        "1 or 0"),
        ("GUI_THEME",            "GUI theme",               "dark|light|hacker|matrix|ocean|nord|gruvbox|dracula|solarized"),
        ("CONTEXT_SIZE",         "Context window size",     "4096"),
        ("THREADS",              "CPU threads",             "number"),
        ("GPU_LAYERS",           "GPU offload layers",      "0 = CPU only"),
        ("TEMPERATURE",          "Default temperature",     "0.0–2.0"),
        ("MAX_TOKENS",           "Default max tokens",      "512–8192"),
        ("RCLICK_ENABLED",       "Right-click enabled",     "1 or 0"),
        ("RCLICK_KEYBIND",       "Right-click keybind",     "e.g. Super+Shift+a"),
        ("API_SHARE_ENABLED",    "Share server enabled",    "1 or 0"),
        ("API_SHARE_PORT",       "Share server port",       "8080"),
        ("API_SHARE_RATE_LIMIT", "Share rate limit",        "requests/min per key"),
    ]

    def _open_settings_editor(self):
        """GUI v5.2: structured settings editor — only editable keys shown."""
        h, w = self.dims()
        # Load current config values
        cfg_raw = run_ai("config")
        # Parse KEY=VALUE lines from config output
        current_vals = {}
        for line in cfg_raw.splitlines():
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                k, _, v = line.partition('=')
                current_vals[k.strip()] = v.strip().strip('"\'')

        # Build a Sidebar menu of editable settings
        items = []
        for key, label, hint in self._EDITABLE_SETTINGS:
            val = current_vals.get(key, "")
            display = f"{label}"
            items.append((display, key, f"={val}" if val else ""))

        menu = Sidebar([("EDITABLE SETTINGS", [(l, v, h2) for l, v, h2 in items])])

        sw = min(36, w // 2)
        cw = w - sw

        while True:
            self.stdscr.erase()
            self._draw_header(h, w)

            # Left: settings list
            menu.draw(self.stdscr, 1, 0, h - 2, sw)

            # Right: current value + hint
            _, key, _ = menu.current()[:3]
            if key:
                cur_val = current_vals.get(key, "")
                _, label, vhint = next((e for e in self._EDITABLE_SETTINGS if e[0] == key),
                                       (key, key, ""))
                lines = [
                    f"Setting:  {label}",
                    f"Key:      {key}",
                    f"Value:    {cur_val or '(not set)'}",
                    "",
                    f"Valid:    {vhint}",
                    "",
                    "Press Enter to edit this value.",
                    "Press Esc to go back.",
                ]
                draw_panel(self.stdscr, 1, sw, h - 2, cw, " Setting Detail ", CP_BORDER, CP_TITLE, CP_CONTENT)
                for i, ln in enumerate(lines):
                    attr = curses.color_pair(CP_CONTENT)
                    if i == 0: attr = curses.color_pair(CP_TITLE) | curses.A_BOLD
                    elif i == 2: attr = curses.color_pair(CP_ACCENT) | curses.A_BOLD
                    safe_add(self.stdscr, 2 + i, sw + 2, ln[:cw - 3], attr)
            else:
                draw_panel(self.stdscr, 1, sw, h - 2, cw, " Setting Detail ", CP_BORDER, CP_TITLE, CP_CONTENT)

            safe_add(self.stdscr, h - 1, 0,
                     " ↑↓=navigate  Enter=edit  Esc=back ".ljust(w),
                     curses.color_pair(CP_HDR))
            self.stdscr.refresh()

            ch = self.stdscr.getch()
            if ch == 27 or ch == ord('q'): break
            if ch == curses.KEY_MOUSE:
                try:
                    _, bx, by, _, bstate = curses.getmouse()
                    if bstate & (curses.BUTTON1_CLICKED | curses.BUTTON1_DOUBLE_CLICKED):
                        val2, do_edit = menu.handle_click(by, bx)
                        if do_edit and val2:
                            ch = 10  # treat as Enter
                except curses.error: pass

            if ch in (10, 13):
                # Edit the selected key
                _, key, _ = menu.current()[:3]
                if key:
                    cur_val = current_vals.get(key, "")
                    _, label, _ = next((e for e in self._EDITABLE_SETTINGS if e[0] == key),
                                       (key, key, ""))
                    new_val = input_line(self.stdscr, h // 2, 2, w - 4,
                                        f"{label} ▶ ", prefill=cur_val, cp=CP_EDIT)
                    if new_val is not None and new_val != cur_val:
                        run_ai("config", key.lower(), new_val)
                        current_vals[key] = new_val
                        # Refresh hint column in sidebar
                        for i, f_item in enumerate(menu._flat):
                            if f_item[1] == key:
                                lbl, val_k, is_hdr, _h = f_item
                                menu._flat[i] = (lbl, val_k, is_hdr, f"={new_val}")
                                break
                        self.status = f"Saved {key}={new_val}"
            else:
                menu.handle_key(ch)

        self.content.show(run_ai("config"), "Settings")
        self.status = ""

    # ── Mouse ─────────────────────────────────────────────────────────────────
    def _handle_mouse(self, my, mx, dbl):
        h, w = self.dims()
        sw = min(self.SIDEBAR_W, w // 3)
        if self.mode == "chat": return True
        if mx < sw:
            # Sidebar click
            self.focus = "sidebar"
            val, do_act = self.sidebar.handle_click(my, mx)
            if do_act and val:
                if not self.do_action(val): return False
        elif mx == sw:
            self.focus = "content"
        else:
            self.focus = "content"
            # Scroll clicks in content area
            cy2 = h - 2
            oy, ox, oh, ow = 1, sw, cy2, w - sw
            visible = oh - 2
            max_sc = max(0, len(self.content.lines) - visible)
            if mx == w - 1 and oy + 1 <= my < oy + oh - 1:
                rel = my - (oy + 1)
                self.content.scroll = int(rel / max(1, oh - 3) * max_sc)
            elif oy + 1 <= my < oy + oh - 1:
                if my < oy + oh // 2: self.content.scroll_up(3)
                else: self.content.scroll_down(3)
        return True

    # ── Main loop ─────────────────────────────────────────────────────────────
    def run(self):
        self.stdscr.nodelay(False)
        self.stdscr.keypad(True)
        curses.curs_set(0)
        init_colors()

        while True:
            h, w = self.dims()
            self.stdscr.erase()
            self._draw_header(h, w)
            if self.mode == "chat":
                self._draw_chat_mode(h, w)
            else:
                self._draw_normal(h, w)
            self._draw_statusbar(h, w)
            self.stdscr.refresh()

            ch = self.stdscr.getch()

            # ── Mouse ──────────────────────────────────────────────────────────
            if ch == curses.KEY_MOUSE:
                try:
                    _, mx, my, _, bstate = curses.getmouse()
                    dbl = bool(bstate & curses.BUTTON1_DOUBLE_CLICKED)
                    if bstate & (curses.BUTTON1_CLICKED | curses.BUTTON1_DOUBLE_CLICKED):
                        if not self._handle_mouse(my, mx, dbl): break
                    elif bstate & curses.BUTTON4_PRESSED:  # wheel up
                        if self.focus == "content": self.content.scroll_up()
                        elif self.focus == "sidebar": self.sidebar.handle_key(curses.KEY_UP)
                        elif self.mode == "chat": self.chat.scroll = max(0, self.chat.scroll - 3)
                    elif bstate & curses.BUTTON5_PRESSED:  # wheel down
                        if self.focus == "content": self.content.scroll_down()
                        elif self.focus == "sidebar": self.sidebar.handle_key(curses.KEY_DOWN)
                        elif self.mode == "chat": self.chat.scroll += 3
                except curses.error: pass
                continue

            # ── Global keys ────────────────────────────────────────────────────
            if ch == 17:    # Ctrl+Q
                break
            elif ch in (curses.KEY_F1, ord('?')):
                self.content.show(
                    "AI CLI v2.7.3 — GUI v5.2  Keyboard & Mouse Guide\n"
                    "═" * 46 + "\n"
                    "\nGlobal:\n"
                    "  Ctrl+Q          Quit\n"
                    "  Tab             Toggle sidebar/content focus\n"
                    "  F1 / ?          This help screen\n"
                    "  F5              Refresh view\n"
                    "  /               Quick search (filter menu)\n"
                    "\nSidebar (left panel):\n"
                    "  ↑↓              Navigate items\n"
                    "  PgUp/PgDn       Jump 8 items\n"
                    "  Home/End        First/last item\n"
                    "  Enter / Space   Activate selected item\n"
                    "  Left-click ×1   Select item\n"
                    "  Left-click ×2   Activate item\n"
                    "  Scroll wheel    Navigate up/down\n"
                    "\nContent panel (right):\n"
                    "  ↑↓ PgUp/PgDn   Scroll output\n"
                    "  Home/End        Jump to top/bottom\n"
                    "  Scroll wheel    Scroll (3 lines)\n"
                    "  Click right edge Seek scroll position\n"
                    "\nChat mode:\n"
                    "  Type + Enter    Send message\n"
                    "  Backspace       Delete char\n"
                    "  PgUp/Dn        Scroll history\n"
                    "  /quit           Return to menu\n"
                    "  /clear          Clear chat\n"
                    "  /help           Chat commands\n"
                    "\nSettings (v5.1):\n"
                    "  ↑↓              Navigate editable settings\n"
                    "  Enter           Edit selected setting value\n"
                    "  Esc             Go back\n"
                    "  Only editable keys are shown — read-only info is not displayed\n"
                    "\nInline editor:\n"
                    "  Arrow keys      Move cursor\n"
                    "  Enter           Confirm (single-line)\n"
                    "  Ctrl+S / F2     Save (multiline)\n"
                    "  Esc             Cancel\n"
                    "\nExtensions:\n"
                    "  Create          Scaffold new .aipack extension\n"
                    "  Load            Install from .aipack file\n"
                    "  Locate          List all + file paths\n"
                    "  Firefox Ext     Install LLM sidebar in Firefox\n",
                    "Help — GUI v5.2"
                )
                self.focus = "content"
                continue
            elif ch == curses.KEY_F5:
                pass   # just redraw
            elif ch == ord('\t'):
                self.focus = "content" if self.focus == "sidebar" else "sidebar"
                continue
            elif ch == ord('/') and self.mode != "chat":
                self._start_search(h, w)
                continue

            # ── Mode-specific keys ─────────────────────────────────────────────
            if self.mode == "chat":
                if self.chat.thinking: continue
                result = self.chat.handle_input(ch)
                if result == "submit" and self.chat.input.strip():
                    msg = self.chat.input.strip()
                    self.chat.input = ""
                    if msg.startswith("/quit"):
                        self.mode = "normal"
                    elif msg.startswith("/clear"):
                        self.chat.messages = []
                    elif msg.startswith("/help"):
                        self.chat.add("sys", "Commands: /quit /clear /help")
                    else:
                        self.chat.add("You", msg)
                        self.chat.ask_async(msg, lambda: None)
            elif self.focus == "sidebar":
                if ch in (ord('q'), ord('Q'), 27) and self.mode != "chat":
                    break
                val, do_act = self.sidebar.handle_key(ch)
                if do_act and val:
                    if not self.do_action(val): break
                    self.focus = "content"
            elif self.focus == "content":
                if ch in (ord('q'), ord('Q'), 27):
                    self.focus = "sidebar"
                else:
                    self.content.handle_key(ch)

def main(stdscr):
    curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
    try:
        app = App(stdscr)
        app.run()
    except KeyboardInterrupt:
        pass

curses.wrapper(main)
GUIEOF

  info "Launching GUI v5.2 (split-pane, structured settings, edit-on-select, aliases panel)..."
  "$PYTHON" "$gui_script" "$cli_bin" "$theme" "$ext_dir"
  local rc=$?
  rm -f "$gui_script"
  [[ $rc -ne 0 ]] && _gui_fallback
}

_gui_fallback() {
  # Text-mode fallback when Python/curses unavailable
  while true; do
    echo ""
    hdr "═══ AI CLI v${VERSION} — Main Menu (GUI v5.1 text mode) ═══"
    local items=(
      "Chat (interactive)"       "Ask a question"
      "Imagine (image gen)"      "Vision (image→text)"
      "Audio"                    "Video"
      "Canvas v2"                "Models / Download"
      "TTM (Tiny ~179M)"         "MTM (Mini ~0.61B)"
      "Mtm (Medium ~1.075B)"     "Datasets"
      "RLHF"                     "Multi-AI Arena"
      "Web Search"               "GitHub"
      "Research Papers"          "Settings / Config"
      "Status"                   "Extensions"
      "Install Firefox Ext"      "Quit"
    )
    for i in "${!items[@]}"; do
      printf "  ${B}%2d.${R} %s\n" "$(( i+1 ))" "${items[$i]}"
    done
    echo ""
    read -rp "Choose [1-${#items[@]}]: " choice
    case "$choice" in
      1)  cmd_chat_interactive ;;
      2)  read -rp "Question: " q; dispatch_ask "$q" ;;
      3)  read -rp "Prompt: " p; cmd_imagine "$p" ;;
      4)  read -rp "Image path: " img; read -rp "Question: " q; cmd_vision "$img" "$q" ;;
      5)  cmd_audio ;;
      6)  cmd_video ;;
      7)  cmd_canvas_v2 help ;;
      8)  cmd_list_models; echo ""; read -rp "Download #: " n; [[ -n "$n" ]] && cmd_recommended download "$n" ;;
      9)  cmd_ttm ;;
      10) cmd_mtm ;;
      11) cmd_Mtm ;;
      12) cmd_dataset list ;;
      13) cmd_rlhf status ;;
      14) read -rp "Topic: " q; read -rp "Mode (debate/collab): " m; cmd_multiai "${m:-debate}" "$q" ;;
      15) read -rp "Search: " q; cmd_websearch "$q" ;;
      16) cmd_github help ;;
      17) cmd_papers help ;;
      18) cmd_config ;;
      19) cmd_status ;;
      20) cmd_extension list ;;
      21) cmd_install_firefox_ext ;;
      22|q|Q|"") break ;;
      *) warn "Invalid choice" ;;
    esac
  done
}


# ════════════════════════════════════════════════════════════════════════════════
#  BUILTIN TOOLS

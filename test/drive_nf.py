#!/usr/bin/env python
"""Render test/sample.md to a PNG via nvim-mcp PTY mode, but rasterized with a
Nerd Font so the glyphs show. Reliable (no macOS screencapture needed).

Run:  uv run --project ~/.local/share/nvim-mcp python test/drive_nf.py
"""
import os
import sys

sys.path.insert(0, os.path.expanduser("~/.local/share/nvim-mcp"))

# Monkeypatch the font loader BEFORE importing tools, so PNG rendering uses a
# Nerd Font (Menlo, the default, lacks the glyphs).
from PIL import ImageFont  # noqa: E402
from nvim_mcp import rendering  # noqa: E402

NERD = os.path.expanduser("~/Library/Fonts/HackNerdFontMono-Regular.ttf")
_orig = rendering._load_font


def _load_nerd(size: int = 14):
    try:
        return ImageFont.truetype(NERD, size)
    except Exception:
        return _orig(size)


rendering._load_font = _load_nerd

from nvim_mcp import tools  # noqa: E402

PLUGIN = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(PLUGIN, "test", "sample.md")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(PLUGIN, "test", "render_nf.png")
ROWS = int(sys.argv[3]) if len(sys.argv) > 3 else 50


def main():
    print(tools.nvim_start(
        clean=True, rows=ROWS, cols=82,
        args=["--cmd", f"set runtimepath+={PLUGIN}", "--cmd", "set termguicolors"],
    ))
    try:
        tools.nvim_execute("set termguicolors background=dark")
        tools.nvim_execute(f"edit {SAMPLE}")
        tools.nvim_execute("set filetype=markdown")
        tools.nvim_execute("call cursor(2, 1)")
        print("SHOT:", tools.nvim_screenshot(OUT))
        print(tools.nvim_get_messages())
    finally:
        tools.nvim_stop()


if __name__ == "__main__":
    main()

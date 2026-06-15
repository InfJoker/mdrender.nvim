#!/usr/bin/env python
"""Drive nvim inside a REAL kitty window via nvim-mcp terminal mode and
screenshot it. This exercises true GPU rendering (real Nerd-Font glyphs and,
optionally, inline images).

Run with:  uv run --project ~/.local/share/nvim-mcp python test/drive_kitty.py
"""
import os
import sys
import time

sys.path.insert(0, os.path.expanduser("~/.local/share/nvim-mcp"))
from nvim_mcp import tools  # noqa: E402

PLUGIN = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLE = os.path.join(PLUGIN, "test", "sample.md")
OUT = os.path.join(PLUGIN, "test", "render_kitty.png")


def main():
    print(tools.nvim_start(
        clean=True,
        terminal="kitty",
        rows=44,
        cols=90,
        args=["--cmd", f"set runtimepath+={PLUGIN}", "--cmd", "set termguicolors"],
    ))
    try:
        print(tools.nvim_execute("set termguicolors background=dark"))
        print(tools.nvim_execute(f"edit {SAMPLE}"))
        print(tools.nvim_execute("set filetype=markdown"))
        print(tools.nvim_lua("return require('mdrender')._command({'status'})"))
        print(tools.nvim_execute("call cursor(2, 1)"))
        # Force the real terminal to paint, then let it settle before capture.
        print(tools.nvim_send_keys("<C-l>"))  # redraw
        print(tools.nvim_execute("redraw!"))
        time.sleep(1.5)
        print("SHOT:", tools.nvim_screenshot(OUT))
        print("MESSAGES:\n", tools.nvim_get_messages())
    finally:
        print(tools.nvim_stop())


if __name__ == "__main__":
    main()

#!/usr/bin/env python
"""Drive nvim via nvim-mcp (PTY mode) to render test/sample.md and screenshot it.

Run with:  uv run --project ~/.local/share/nvim-mcp python test/drive.py
"""
import os
import sys

# Make the nvim_mcp package importable.
sys.path.insert(0, os.path.expanduser("~/.local/share/nvim-mcp"))

from nvim_mcp import tools  # noqa: E402

PLUGIN = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLE = os.path.join(PLUGIN, "test", "sample.md")
OUT = os.path.join(PLUGIN, "test", "render.png")


def main():
    # Start clean nvim with our plugin dir on the runtimepath. --clean skips the
    # user's config; --cmd adds our plugin so plugin/mdrender.lua is sourced.
    print(tools.nvim_start(
        clean=True,
        rows=44,
        cols=90,
        args=["--cmd", f"set runtimepath+={PLUGIN}", "--cmd", "set termguicolors"],
    ))
    try:
        # true color + a dark background so the palette shows.
        print(tools.nvim_execute("set termguicolors background=dark"))
        print(tools.nvim_execute(f"edit {SAMPLE}"))
        # Make sure filetype + plugin attach happened.
        print(tools.nvim_execute("set filetype=markdown"))
        print(tools.nvim_lua("return require('mdrender')._command({'status'})"))
        # Park the cursor on a blank line so no content line is 'revealed'.
        print(tools.nvim_execute("call cursor(2, 1)"))
        print("SHOT:", tools.nvim_screenshot(OUT))
        print("BUFFER STATE:")
        print(tools.nvim_get_state())
        msgs = tools.nvim_get_messages()
        print("MESSAGES:\n", msgs)
    finally:
        print(tools.nvim_stop())


if __name__ == "__main__":
    main()

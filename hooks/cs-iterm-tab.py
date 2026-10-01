#!/usr/bin/env python3
# ABOUTME: Titles the iTerm tab showing a tmux window (iTerm's tmux integration) after the cs sessions in its panes.
# ABOUTME: cs runs it in the background on every title claim; iTerm's Python API is the only way to set that tab's title.
"""Usage: cs-iterm-tab.py <tmux window id, e.g. @12>

Reads the window's pane claims (the @cs_session pane option) from the tmux
server in $TMUX and sets the title of the one iTerm tab that shows exactly
that window's panes to "cs: a | b", in pane order. Setting it also renames
the tmux window to the same text.

Failures (no iterm2 module, iTerm not running, the API disabled) are raised
as they are: cs discards this script's output and never waits on it.
"""

import signal
import subprocess
import sys

import iterm2

# A hung API connection must not leave the process behind.
BUDGET_SECONDS = 3
# A claim landing between a title's read and its set leaves the set stale;
# each attempt re-reads the claims and sets again until they agree.
ATTEMPTS = 3


def _tmux(*args: str) -> str:
    return subprocess.run(["tmux", *args], capture_output=True, text=True, check=True,
                          stdin=subprocess.DEVNULL).stdout


def window_title(window: str) -> str:
    """'cs: a | b' from the window's pane claims in pane order; '' when none."""
    names: list[str] = []
    for line in _tmux("list-panes", "-t", window, "-F", "#{@cs_session}").splitlines():
        if line and line not in names:
            names.append(line)
    return "cs: " + " | ".join(names) if names else ""


def window_panes(window: str) -> set[str]:
    """The window's pane numbers, as iTerm reports them (no '%')."""
    return {line.lstrip("%") for line in _tmux("list-panes", "-t", window, "-F", "#{pane_id}").splitlines()}


async def _tab_showing(app, window: str):
    """The one tab showing exactly this window's panes, else None.

    Window numbers are per tmux server and iTerm can attach several, so the
    window number alone can name another server's tab; two tabs that both
    match leave it unknown which one is ours.
    """
    number = window.lstrip("@")
    panes = window_panes(window)
    matches = []
    for terminal_window in app.terminal_windows:
        for tab in terminal_window.tabs:
            if str(tab.tmux_window_id) != number:
                continue
            tab_panes = {str(await session.async_get_variable("tmuxWindowPane")) for session in tab.sessions}
            if tab_panes == panes:
                matches.append(tab)
    return matches[0] if len(matches) == 1 else None


async def _title_tab(connection, window: str) -> None:
    tab = await _tab_showing(await iterm2.async_get_app(connection), window)
    if tab is None:
        return
    for _ in range(ATTEMPTS):
        title = window_title(window)
        # An empty title clears iTerm's and renames the tmux window to nothing.
        if not title:
            return
        await tab.async_set_title(title)
        if window_title(window) == title:
            return


def main() -> None:
    if len(sys.argv) != 2 or not sys.argv[1].startswith("@"):
        sys.exit(f"usage: {sys.argv[0]} <tmux window id, e.g. @12>; got {sys.argv[1:]}")
    window = sys.argv[1]
    signal.alarm(BUDGET_SECONDS)
    iterm2.run_until_complete(lambda connection: _title_tab(connection, window))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# ABOUTME: Titles the iTerm tab showing a tmux window (iTerm's tmux integration) after the ags sessions in its panes.
# ABOUTME: ags runs it in the background on every title claim; iTerm's Python API is the only way to set that tab's title.
"""Usage: cs-iterm-tab.py <tmux window id, e.g. @12>

Reads the window's pane claims (the @cs_session pane option) from the tmux
server in $TMUX and sets the title of the iTerm tab showing that window to
"ags: a | b", in pane order. Setting it also renames the tmux window to the
same text.

Failures (no iterm2 module, iTerm not running, the API disabled) are raised
as they are: ags discards this script's output and never waits on it.
"""

import signal
import subprocess
import sys

# A hung API connection or tmux call must not leave the process behind.
BUDGET_SECONDS = 3
TMUX_SECONDS = 2
# A claim landing between a title's read and its set leaves the set stale;
# each attempt re-reads the claims and sets again until they agree.
ATTEMPTS = 3
# Identifies a tmux server: asked of ours directly and of each server iTerm
# is attached to through that attachment.
SERVER_FORMAT = "#{pid} #{socket_path}"


def _tmux(*args: str) -> str:
    return subprocess.run(["tmux", *args], capture_output=True, text=True, check=True,
                          stdin=subprocess.DEVNULL, timeout=TMUX_SECONDS).stdout


def window_title(window: str) -> str:
    """'ags: a | b' from the window's pane claims in pane order; '' when none."""
    names: list[str] = []
    for line in _tmux("list-panes", "-t", window, "-F", "#{@cs_session}").splitlines():
        if line and line not in names:
            names.append(line)
    return "ags: " + " | ".join(names) if names else ""


def release_window(window: str) -> None:
    """The state ags leaves a window in once no ags session claims it: setting
    the tab title renamed the window, and a rename turns automatic-rename off."""
    for option in ("automatic-rename", "allow-rename", "allow-set-title"):
        subprocess.run(["tmux", "set-window-option", "-t", window, option, "on"],
                       capture_output=True, stdin=subprocess.DEVNULL, timeout=TMUX_SECONDS)


async def _tab_showing(iterm2, connection, window: str):
    """The one tab showing this window of this tmux server, else None.

    Window ids are per server and iTerm can attach several servers, so a tab
    counts only when the attachment it belongs to answers for the same server
    as $TMUX. Two such tabs leave it unknown which one is ours.
    """
    server = _tmux("display-message", "-p", SERVER_FORMAT).strip()
    ours = set()
    for attachment in await iterm2.async_get_tmux_connections(connection):
        reply = await attachment.async_send_command(f"display-message -p '{SERVER_FORMAT}'")
        if reply.strip() == server:
            ours.add(attachment.connection_id)
    number = window.lstrip("@")
    app = await iterm2.async_get_app(connection)
    matches = [tab for terminal_window in app.terminal_windows for tab in terminal_window.tabs
               if tab.tmux_connection_id in ours and str(tab.tmux_window_id) == number]
    return matches[0] if len(matches) == 1 else None


async def _title_tab(iterm2, connection, window: str) -> None:
    tab = await _tab_showing(iterm2, connection, window)
    if tab is None:
        return
    for _ in range(ATTEMPTS):
        title = window_title(window)
        # An empty title clears iTerm's and renames the tmux window to nothing.
        if not title:
            return
        await tab.async_set_title(title)
        now = window_title(window)
        if now == title:
            return
        # The last claim left while the title was set: undo the rename's lock.
        if not now:
            release_window(window)
            return


def main() -> None:
    if len(sys.argv) != 2 or not sys.argv[1].startswith("@"):
        sys.exit(f"usage: {sys.argv[0]} <tmux window id, e.g. @12>; got {sys.argv[1:]}")
    window = sys.argv[1]
    signal.alarm(BUDGET_SECONDS)
    import iterm2
    iterm2.run_until_complete(lambda connection: _title_tab(iterm2, connection, window))


if __name__ == "__main__":
    main()

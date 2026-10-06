"""Screenshot the Jujutsu block's graph for a repo with a fork and a merge; requires a desktop session.

Usage: python3 tests/graphshot.py [ROOT]

ROOT is the plugin source to install (default: this checkout), e.g. a `jj workspace add -r @-`
of the previous change for a before/after comparison. Runs `jj log` (the lens, jj's layout) and
opens the Jujutsu block (its own layout), and writes under ROOT `.dev/shots/live/lens.png`,
`graph.png` (the window with the block) and `graph-crop.png` (the block's graph column),
printing how many curved corners and junction dots each drew.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
TERN = os.environ.get("TERN", "/Applications/Tern.app/Contents/MacOS/tern")
SHOTS = ROOT / ".dev/shots"
LENS = ".sf-block[data-role='lens.plugin.jj.log']"
SURFACE = ".sf-main[data-surface='plugin.jj.changes']"

with tempfile.TemporaryDirectory(prefix="tern-jj-graph-", dir="/tmp") as temporary:
    work = Path(temporary)
    repo = work / "repo"
    config = work / "config"
    config.mkdir()
    (config / "settings.json").write_bytes((ROOT / "dev/settings.json").read_bytes())
    env = dict(os.environ, TERN_CONFIG_DIR=str(config),
               TERN_DAEMON_SOCKET=str(work / "daemon.sock"),
               STENCIL_LOG_DIR=str(ROOT / ".dev/graphshot-logs"),
               ZDOTDIR=str(ROOT / "dev/zsh"))
    env.pop("JJ_PAGER", None)

    def jj(*args):
        subprocess.run(["jj", *args], cwd=repo, env=env, check=True, capture_output=True)

    # @  top / ○ merge / ├─╮ / │ ○ left 2 / │ ○ left / ○ │ right / ├─╯ / │ ○ side / ├─╯ / ○ base
    subprocess.run(["jj", "git", "init", "--no-colocate", str(repo)], check=True, env=env,
                   capture_output=True)
    jj("describe", "-m", "base")
    jj("new", "-m", "left")
    jj("new", "-m", "left 2")
    jj("new", "@--", "-m", "right")
    jj("new", "@", "description(glob:'left 2*')", "-m", "merge")
    jj("new", "description(glob:'base*')", "-m", "side")
    jj("new", "description(glob:'merge*')", "-m", "top")

    package = work / "package"
    package.mkdir()
    for name in ("plugin.toml", "host.luau", "changes.luau", "graph.luau", "loglens.luau",
                 "window.luau", "jj.css"):
        (package / name).write_bytes((ROOT / name).read_bytes())
    subprocess.run([TERN, "plugin", "install", str(package)], check=True, env=env,
                   capture_output=True)
    control = str(work / "control.sock")

    def ctl(command):
        result = subprocess.run([TERN, "ctl", "--control", control, command],
                                env=env, text=True, capture_output=True, timeout=40)
        reply = json.loads(result.stdout)
        assert result.returncode == 0 and reply["ok"], reply
        return reply

    def wait_for(path, process, what):
        deadline = time.monotonic() + 30
        while not Path(path).exists():
            assert process.poll() is None, f"{what} exited"
            assert time.monotonic() < deadline, f"{what} did not open its socket"
            time.sleep(0.1)

    daemon = subprocess.Popen([TERN, "daemon"], env=env, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    window = None
    try:
        wait_for(env["TERN_DAEMON_SOCKET"], daemon, "Daemon")
        window = subprocess.Popen([TERN, "--control", control, "--out", str(SHOTS), str(repo)],
                                  env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(control, window, "Tern")
        ctl("ready")
        ctl('run "jj log"')
        deadline = time.monotonic() + 20
        while not any("merge" in n.get("text", "") for n in ctl(f"tree {LENS}")["nodes"]):
            if time.monotonic() > deadline:
                pane = ctl("state")["focused"]
                capture = subprocess.run([TERN, "capture", str(pane["id"]), "--surfaces"], env=env,
                                         text=True, capture_output=True)
                raise AssertionError(f"the jj log lens did not render: {pane.get('last')}\n{capture.stdout}")
            time.sleep(0.2)
        print("lens corners", len(ctl(f"tree {LENS} .jj-k")["nodes"]))
        time.sleep(0.5)
        lens = ctl("shot lens")["png"]
        ctl("key alt+cmd+j")
        deadline = time.monotonic() + 20
        while not any("merge" in n.get("text", "") for n in ctl(f"tree {SURFACE} .jj-r")["nodes"]):
            assert time.monotonic() < deadline, "the block did not list the changes"
            time.sleep(0.2)
        for name, selector in (("corners", ".jj-k"), ("junction dots", ".jj-j")):
            print(name, len(ctl(f"tree {SURFACE} {selector}")["nodes"]))
        time.sleep(0.5)
        png = ctl("shot graph")["png"]
    finally:
        if window is not None and window.poll() is None:
            window.terminate()
            window.wait(timeout=15)
        if daemon.poll() is None:
            daemon.terminate()
            daemon.wait(timeout=15)

# The graph column of the default 2560×1600 window, with the block in the right half.
crop = str(Path(png).with_name("graph-crop.png"))
subprocess.run(["sips", "-c", "420", "180", "--cropOffset", "300", "1580", png, "--out", crop],
               check=True, capture_output=True)
print(lens)
print(png)
print(crop)

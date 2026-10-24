#!/usr/bin/env python3
"""Merge Plannotator configuration as the container user after mounts are ready."""
import json
import os
from pathlib import Path
import shlex
import tempfile

import tomlkit


COMMAND = "/usr/local/bin/plannotator"


def normalize_plannotator_hooks(groups):
    if not isinstance(groups, list):
        raise ValueError("Codex Stop hooks must be a list")
    found = False
    for group in groups:
        for hook in group.get("hooks", []):
            if hook.get("type") == "command" and "plannotator" in hook.get("command", ""):
                command = hook["command"].strip()
                try:
                    words = shlex.split(command)
                except ValueError:
                    words = []  # Preserve custom shell syntax verbatim.
                if len(words) == 1 and (words[0] == "plannotator" or (
                        words[0].startswith("/") and Path(words[0]).name == "plannotator")):
                    hook["command"] = COMMAND
                    hook["timeout"] = 345600
                found = True
    return found


def write_changed(path, content):
    if path.exists() and path.read_text() == content:
        return
    # Resolve symlinks so a user-configured link is not replaced by a regular file.
    target = path.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=target.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(content)
            stream.flush()
            if target.exists():
                temporary.chmod(target.stat().st_mode & 0o777)
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)


def configure(codex_home):
    config_path = codex_home / "config.toml"
    hooks_path = codex_home / "hooks.json"
    config = tomlkit.parse(config_path.read_text() if config_path.exists() else "")
    hooks = json.loads(hooks_path.read_text()) if hooks_path.exists() else {}
    original_hooks = json.dumps(hooks)
    # Parse and validate both files before changing either. Preserve custom hooks.
    json_hooks = hooks.get("hooks", {})
    inline_hooks = config.get("hooks", {})
    configured = normalize_plannotator_hooks(json_hooks.get("Stop", []))
    configured = normalize_plannotator_hooks(inline_hooks.get("Stop", [])) or configured
    features = config.setdefault("features", tomlkit.table())
    features.pop("codex_hooks", None)  # Deprecated alias can conflict with hooks.
    features["hooks"] = True
    hook = {"hooks": [{"type": "command", "command": COMMAND, "timeout": 345600}]}
    write_hooks = False
    if not configured:
        if "hooks" in config:
            # Stay with the user's chosen inline representation.
            config["hooks"].setdefault("Stop", []).append(hook)
        else:
            hooks["hooks"] = json_hooks
            json_hooks.setdefault("Stop", []).append(hook)
            write_hooks = True
    config_text = tomlkit.dumps(config)
    tomlkit.parse(config_text)
    if write_hooks or (configured and json.dumps(hooks) != original_hooks):
        write_changed(hooks_path, json.dumps(hooks, indent=2) + "\n")
    write_changed(config_path, config_text)


if __name__ == "__main__":
    configure(Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex"))

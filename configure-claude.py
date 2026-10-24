#!/usr/bin/env python3
"""Merge Plannotator's Claude Code hooks as the container user after mounts are ready."""
import copy
import json
import os
from pathlib import Path
import tempfile


COMMAND = "/usr/local/bin/plannotator"
# The hooks of Plannotator's Claude Code plugin (apps/hook/hooks/hooks.json),
# using the installed binary's absolute path.
HOOKS = {
    "PreToolUse": {"matcher": "EnterPlanMode", "hooks": [
        {"type": "command", "command": f"{COMMAND} improve-context", "timeout": 5}]},
    "PermissionRequest": {"matcher": "ExitPlanMode", "hooks": [
        {"type": "command", "command": COMMAND, "timeout": 345600}]},
}


def has_plannotator(groups, matcher):
    if not isinstance(groups, list) or not all(isinstance(g, dict) for g in groups):
        raise ValueError("Claude hook events must be lists of hook groups")
    return any(group.get("matcher") == matcher and any(
        "plannotator" in hook.get("command", "") for hook in group.get("hooks", []))
        for group in groups)


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


def configure(claude_home):
    settings_path = claude_home / "settings.json"
    settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
    if not isinstance(settings, dict) or not isinstance(settings.get("hooks", {}), dict):
        raise ValueError("Claude settings and their hooks must be JSON objects")
    hooks = settings.get("hooks", {})
    # Validate every event before changing anything. Preserve custom hooks.
    missing = [event for event, group in HOOKS.items()
               if not has_plannotator(hooks.get(event, []), group["matcher"])]
    if not missing:
        return
    settings["hooks"] = hooks
    for event in missing:
        hooks.setdefault(event, []).append(copy.deepcopy(HOOKS[event]))
    write_changed(settings_path, json.dumps(settings, indent=2) + "\n")


if __name__ == "__main__":
    configure(Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude"))

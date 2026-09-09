#!/usr/bin/env python3
"""Rewire OpenDeck Teams/Zoom profiles onto Call Bridge."""
from __future__ import annotations

import json
import shutil
from copy import deepcopy
from pathlib import Path

PLUGIN = "com.craigbell.callbridge.sdPlugin"
ICON = f"plugins/{PLUGIN}/icons"
ZOOM_ICON = f"{ICON}/zoom"
DEVICE = "99-355499441494-293S"

VOL_DOWN = (
    "osascript -e 'set vol to output volume of (get volume settings)' "
    "-e 'set n to vol - 10' -e 'if n < 0 then set n to 0' "
    "-e 'set volume output volume n'"
)
VOL_UP = (
    "osascript -e 'set vol to output volume of (get volume settings)' "
    "-e 'set n to vol + 10' -e 'if n > 100 then set n to 100' "
    "-e 'set volume output volume n'"
)

NAME_TO_UUID = {
    "Background blur": "com.craigbell.callbridge.toggleblur",
    "Camera": "com.craigbell.callbridge.togglecamera",
    "Leave": "com.craigbell.callbridge.leave",
    "Mute": "com.craigbell.callbridge.togglemute",
    "Raise hand": "com.craigbell.callbridge.togglehand",
    "React: Applause": "com.craigbell.callbridge.react.applause",
    "React: Laugh": "com.craigbell.callbridge.react.laugh",
    "React: Like": "com.craigbell.callbridge.react.like",
    "React: Love": "com.craigbell.callbridge.react.love",
    "React: Wow": "com.craigbell.callbridge.react.wow",
}

# Idle/disconnected slots use the live artwork, not the grey "plugin offline" set.
UUID_ICONS = {
    "com.craigbell.callbridge.togglemute": (
        f"{ICON}/toggleMute/actions/ToggleMute@2x.png",
        [
            f"{ICON}/toggleMute/states/Unmute@2x.png",
            f"{ICON}/toggleMute/states/Mute@2x.png",
            f"{ICON}/toggleMute/states/Unmute@2x.png",
        ],
        2,
    ),
    "com.craigbell.callbridge.togglecamera": (
        f"{ICON}/toggleVideo/actions/ToggleCamera@2x.png",
        [
            f"{ICON}/toggleVideo/states/CameraOn@2x.png",
            f"{ICON}/toggleVideo/states/CameraOff@2x.png",
            f"{ICON}/toggleVideo/states/CameraOn@2x.png",
        ],
        2,
    ),
    "com.craigbell.callbridge.leave": (
        f"{ICON}/leave/actions/LeaveCall@2x.png",
        [
            f"{ICON}/leave/states/LeaveCall@2x.png",
            f"{ICON}/leave/states/LeaveCall@2x.png",
        ],
        1,
    ),
    "com.craigbell.callbridge.togglehand": (
        f"{ICON}/toggleHand/actions/ToggleHand@2x.png",
        [
            f"{ICON}/toggleHand/states/HandDown@2x.png",
            f"{ICON}/toggleHand/states/HandDown@2x.png",
            f"{ICON}/toggleHand/states/HandUp@2x.png",
        ],
        1,
    ),
    "com.craigbell.callbridge.toggleblur": (
        f"{ICON}/toggleBlur/actions/ToggleBlur@2x.png",
        [
            f"{ICON}/toggleBlur/states/BlurOff@2x.png",
            f"{ICON}/toggleBlur/states/BlurOff@2x.png",
            f"{ICON}/toggleBlur/states/BlurOn@2x.png",
        ],
        1,
    ),
    "com.craigbell.callbridge.react.applause": (
        f"{ICON}/reactApplause/actions/Reaction-Applause@2x.png",
        [
            f"{ICON}/reactApplause/states/Reaction-Applause@2x.png",
            f"{ICON}/reactApplause/states/Reaction-Applause@2x.png",
        ],
        1,
    ),
    "com.craigbell.callbridge.react.laugh": (
        f"{ICON}/reactLaugh/actions/Reaction-Laugh@2x.png",
        [
            f"{ICON}/reactLaugh/states/Reaction-Laugh@2x.png",
            f"{ICON}/reactLaugh/states/Reaction-Laugh@2x.png",
        ],
        1,
    ),
    "com.craigbell.callbridge.react.like": (
        f"{ICON}/reactLike/actions/Reaction-Like@2x.png",
        [
            f"{ICON}/reactLike/states/Reaction-Like@2x.png",
            f"{ICON}/reactLike/states/Reaction-Like@2x.png",
        ],
        1,
    ),
    "com.craigbell.callbridge.react.love": (
        f"{ICON}/reactLove/actions/Reaction-Love@2x.png",
        [
            f"{ICON}/reactLove/states/Reaction-Love@2x.png",
            f"{ICON}/reactLove/states/Reaction-Love@2x.png",
        ],
        1,
    ),
    "com.craigbell.callbridge.react.wow": (
        f"{ICON}/reactWow/actions/Reaction-Wow@2x.png",
        [
            f"{ICON}/reactWow/states/Reaction-Wow@2x.png",
            f"{ICON}/reactWow/states/Reaction-Wow@2x.png",
        ],
        1,
    ),
}

ZOOM_SWAP = {
    f"{ICON}/toggleMute/": f"{ZOOM_ICON}/toggleMute/",
    f"{ICON}/toggleVideo/": f"{ZOOM_ICON}/toggleVideo/",
    f"{ICON}/leave/": f"{ZOOM_ICON}/leave/",
    f"{ICON}/toggleHand/": f"{ZOOM_ICON}/toggleHand/",
}


def state_template(image: str) -> dict:
    return {
        "alignment": "middle",
        "background_colour": "#000000",
        "colour": "#FFFFFF",
        "family": "Liberation Sans",
        "image": image,
        "name": "",
        "show": False,
        "size": 16,
        "stroke_colour": "#000000",
        "stroke_size": 3,
        "style": "Regular",
        "text": "",
        "underline": False,
    }


def rewire_key(key: dict) -> dict:
    action = key.get("action") or {}
    name = action.get("name")
    uuid = NAME_TO_UUID.get(name)
    if not uuid:
        return key
    icon, images, current = UUID_ICONS[uuid]
    states = [state_template(img) for img in images]
    action = dict(action)
    action.update(
        {
            "plugin": PLUGIN,
            "uuid": uuid,
            "property_inspector": "",
            "icon": icon,
            "disable_automatic_states": True,
            "states": states,
            "supported_in_multi_actions": uuid.endswith("leave") or ".react." in uuid,
        }
    )
    out = dict(key)
    out["action"] = action
    out["settings"] = {}
    out["states"] = deepcopy(states)
    out["current_state"] = current
    return out


def zoomify_image(path: str) -> str:
    for old, new in ZOOM_SWAP.items():
        if path.startswith(old):
            return path.replace(old, new, 1)
    return path


def zoomify_key(key: dict | None) -> dict | None:
    if not key:
        return key
    uuid = (key.get("action") or {}).get("uuid", "")
    if uuid == "com.craigbell.callbridge.toggleblur":
        return None
    if uuid.startswith("com.craigbell.callbridge.") and "react." not in uuid:
        out = deepcopy(key)
        action = out["action"]
        action["icon"] = zoomify_image(action.get("icon") or "")
        for collection in (action.get("states") or [], out.get("states") or []):
            for state in collection:
                if "image" in state:
                    state["image"] = zoomify_image(state["image"])
        return out
    return key


def fix_volume_key(key: dict | None, up: bool) -> dict | None:
    if not key:
        return key
    action = key.get("action") or {}
    if action.get("uuid") != "com.amansprojects.starterpack.runcommand":
        return key
    out = deepcopy(key)
    image = f"{ICON}/volume/{'up' if up else 'down'}@2x.png"
    out["settings"] = {
        "down": VOL_UP if up else VOL_DOWN,
        "file": "",
        "rotate": "",
        "show": False,
        "up": "",
    }
    for collection in (out.get("states") or [], (out.get("action") or {}).get("states") or []):
        for state in collection:
            state["image"] = image
            state["show"] = False
            state["text"] = ""
    out["action"]["icon"] = image
    out["action"]["tooltip"] = "Volume up" if up else "Volume down"
    return out


def fix_home_key(key: dict | None) -> dict | None:
    if not key:
        return key
    action = key.get("action") or {}
    if action.get("uuid") != "com.amansprojects.starterpack.switchprofile":
        return key
    out = deepcopy(key)
    out["settings"] = {"device": DEVICE, "profile": "Default"}
    out["action"]["tooltip"] = "Switch to Default"
    return out


def write_profile(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2) + "\n")


def main() -> None:
    profile_dir = Path.home() / "Library/Application Support/opendeck/profiles" / DEVICE
    teams = profile_dir / "Teams.json"
    backup = profile_dir / "Teams.json.bak_callbridge"
    if not backup.exists():
        shutil.copy2(teams, backup)
    data = json.loads(teams.read_text())
    keys = [rewire_key(k) for k in data.get("keys", [])]
    if len(keys) > 4:
        keys[4] = fix_home_key(keys[4])
    if len(keys) > 14:
        keys[13] = fix_volume_key(keys[13], up=False)
        keys[14] = fix_volume_key(keys[14], up=True)
    data["keys"] = keys
    data.setdefault("sliders", [])
    write_profile(teams, data)

    zoom_data = deepcopy(data)
    zoom_data["keys"] = [zoomify_key(k) for k in keys]
    if len(zoom_data["keys"]) > 4:
        zoom_data["keys"][4] = fix_home_key(zoom_data["keys"][4])
    if len(zoom_data["keys"]) > 14:
        zoom_data["keys"][13] = fix_volume_key(zoom_data["keys"][13], up=False)
        zoom_data["keys"][14] = fix_volume_key(zoom_data["keys"][14], up=True)
    write_profile(profile_dir / "Zoom.json", zoom_data)
    print(f"rewired {teams}")
    print(f"wrote {profile_dir / 'Zoom.json'} (no blur; Zoom-blue controls)")

    default = profile_dir / "Default.json"
    data = json.loads(default.read_text())
    keys = data.get("keys", [])
    has_zoom = any(
        (k or {}).get("settings", {}).get("profile") == "Zoom" for k in keys if k
    )
    if not has_zoom and keys and keys[0]:
        slot = 3 if len(keys) > 3 and keys[3] is None else None
        if slot is None:
            for i, k in enumerate(keys):
                if k is None:
                    slot = i
                    break
        if slot is not None:
            src = next(
                (k for k in keys[:3] if k and (k.get("settings") or {}).get("profile") == "Teams"),
                keys[0],
            )
            z = deepcopy(src)
            z["context"] = f"Keypad.{slot}.0"
            z["settings"]["profile"] = "Zoom"
            z["action"]["tooltip"] = "Switch to Zoom"
            for collection in (z.get("states") or [], (z.get("action") or {}).get("states") or []):
                for state in collection:
                    state["image"] = f"{ZOOM_ICON}/logo@2x.png"
            keys[slot] = z
            data["keys"] = keys
            write_profile(default, data)
            print(f"Default.json {z['context']} -> Zoom")
    elif has_zoom:
        for k in keys:
            if k and (k.get("settings") or {}).get("profile") == "Zoom":
                for collection in (k.get("states") or [], (k.get("action") or {}).get("states") or []):
                    for state in collection:
                        state["image"] = f"{ZOOM_ICON}/logo@2x.png"
        write_profile(default, data)
        print("Default.json Zoom key icon updated")


if __name__ == "__main__":
    main()

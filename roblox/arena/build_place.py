#!/usr/bin/env python3
"""Build DragonArena.rbxlx from the .lua files.

    python roblox/arena/build_place.py

The .lua files are the source of truth; the place file is a build artifact. Run this after
changing any module, then close and reopen the place in Studio - Studio will not pick up a file
that changed underneath it, and saving from Studio overwrites whatever this wrote.

(If that cycle gets annoying, that is what `roblox/default.project.json` and Rojo are for: the
files on disk become the tree in Studio and stay live. This script exists for people who just want
a place to open.)

`.rbxlx` is Roblox's XML place format. Studio opens it directly, and File -> Save As gives you a
binary `.rbxl` if you need one.
"""

import io
import os
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROBLOX = os.path.dirname(HERE)          # roblox/
OUT = os.path.join(HERE, "DragonArena.rbxlx")

# Mirrors the Studio tree. Paths are relative to roblox/, so Bridge and Mapping - which the arena
# shares with the obby - come from their own place rather than being copied.
TREE = {
    "ReplicatedStorage": [("Folder", "Arena", [
        ("ModuleScript", "Theme", "arena/ReplicatedStorage/Arena/Theme.lua"),
        ("ModuleScript", "ArenaConfig", "arena/ReplicatedStorage/Arena/ArenaConfig.lua"),
        ("ModuleScript", "Remotes", "arena/ReplicatedStorage/Arena/Remotes.lua"),
        ("ModuleScript", "Icons", "arena/ReplicatedStorage/Arena/Icons.lua"),
    ])],
    "ServerScriptService": [
        ("ModuleScript", "Bridge", "Bridge.lua"),
        ("ModuleScript", "Mapping", "Mapping.lua"),
        ("Script", "ArenaMain", "arena/ServerScriptService/ArenaMain.server.lua"),
        ("Folder", "Arena", [
            ("ModuleScript", "Arena", "arena/ServerScriptService/Arena/Arena.lua"),
            ("ModuleScript", "DragonArm", "arena/ServerScriptService/Arena/DragonArm.lua"),
            ("ModuleScript", "AttackDetect", "arena/ServerScriptService/Arena/AttackDetect.lua"),
            ("ModuleScript", "AttackFx", "arena/ServerScriptService/Arena/AttackFx.lua"),
            ("ModuleScript", "DragonEffects", "arena/ServerScriptService/Arena/DragonEffects.lua"),
            ("ModuleScript", "Pickups", "arena/ServerScriptService/Arena/Pickups.lua"),
            ("ModuleScript", "Rounds", "arena/ServerScriptService/Arena/Rounds.lua"),
            ("ModuleScript", "Sound", "arena/ServerScriptService/Arena/Sound.lua"),
        ]),
    ],
    "StarterPlayer": [("StarterPlayerScripts", "StarterPlayerScripts", [
        ("LocalScript", "ArenaHud", "arena/StarterPlayer/StarterPlayerScripts/ArenaHud.client.lua"),
    ])],
}

_ref = [0]


def _next_ref():
    _ref[0] += 1
    return "RBX%d" % _ref[0]


def _item(cls, name, children_or_path, indent):
    pad = "\t" * indent
    out = ['%s<Item class="%s" referent="%s">' % (pad, cls, _next_ref()),
           "%s\t<Properties>" % pad,
           '%s\t\t<string name="Name">%s</string>' % (pad, name)]
    if isinstance(children_or_path, str):
        path = os.path.join(ROBLOX, children_or_path)
        src = io.open(path, encoding="utf-8").read()
        # CDATA has exactly one way to end. A source containing it would close the block early and
        # produce a place file that opens with half a script in it.
        if "]]>" in src:
            sys.exit("%s contains ']]>', which cannot go in CDATA" % children_or_path)
        out.append('%s\t\t<ProtectedString name="Source"><![CDATA[%s]]></ProtectedString>'
                   % (pad, src))
        out.append("%s\t</Properties>" % pad)
    else:
        out.append("%s\t</Properties>" % pad)
        for c in children_or_path:
            out.append(_item(c[0], c[1], c[2], indent + 1))
    out.append("%s</Item>" % pad)
    return "\n".join(out)


def main():
    body = [_item(service, service, children, 1) for service, children in TREE.items()]
    xml = ('<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
           'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
           'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">\n'
           + "\n".join(body) + "\n</roblox>\n")

    # Parse what was built rather than trusting the string. A malformed place fails in Studio with
    # a dialog that does not say which script broke it.
    ET.fromstring(xml)

    io.open(OUT, "w", encoding="utf-8", newline="\n").write(xml)

    lock = OUT + ".lock"
    if os.path.exists(lock):
        print("  WARNING: %s exists - Studio has the place open." % os.path.basename(lock))
        print("  Close it WITHOUT saving and reopen, or Studio will overwrite this build.")
    print("wrote %s (%d bytes)" % (os.path.relpath(OUT, ROBLOX), len(xml)))


if __name__ == "__main__":
    main()

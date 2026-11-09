# Every clip by name, from the group files beside this one. A group file
# defines CLIPS and imports only motion.py (and body_rig for constants).

import importlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

CLIPS = {}
for name in sorted(os.listdir(HERE)):
    if name.startswith("clips_") and name.endswith(".py"):
        CLIPS.update(importlib.import_module(name[:-3]).CLIPS)

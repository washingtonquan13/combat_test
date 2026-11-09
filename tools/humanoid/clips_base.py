# The neutral stance and Idle.

import math

import motion as m

STANCE = m.STANCE


def idle_at(t):
    """Two breaths and one slow sway of the weight across the loop."""
    tau = 2.0 * math.pi
    breath = math.sin(tau * t * 2.0)
    sway = math.sin(tau * t)
    tired = math.sin(tau * (t * 3.0 + 0.2))
    return m.merge(STANCE, {
        "hip": (0.012 + 0.012 * sway, 0.035 + 0.004 * tired, 0.897 - 0.003 * (0.5 + 0.5 * breath) + 0.0025 * sway * sway),
        "hip_rot": (5.0 + 0.5 * tired, -1.5 - 1.2 * sway, -2.0 + 0.9 * math.sin(tau * (t + 0.1))),
        "chest_rot": (3.0 - 1.1 * breath + 0.4 * tired, 1.0 + 0.7 * sway, 1.5 - 1.2 * math.sin(tau * (t + 0.18))),
        "look": (0.05 * math.sin(tau * (t + 0.3)), -1.0, -0.03 + 0.012 * tired),
    })


CLIPS = {
    "stance": {"length": 1.0, "at": lambda t: STANCE},
    "Idle": {"length": 8.0, "loop": True, "at": idle_at},
}

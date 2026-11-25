"""Stylised stepping diagonal cut, right-high to left-low. Pose sheet for tools/anim/make.py.

Same action as slash_step.py pushed for drama rather than realism: a deep
held coil, a long low lunge, a follow-through that wraps past the body and a
long held finish. Character faces -Y, its left is +X. 24 fps. Starts and ends
in the same guard, in place (no root motion).
"""

L_HOME = (0.16, -0.32)
R_HOME = (-0.18, 0.28)
L_LUNGE = (0.42, -0.92)

GUARD = dict(
    hips=(0.0, -0.02, 0.90), hips_rot=(-30, 5, 0),
    chest=(10, 5, 0), head=(20, 0, 0),
    foot_l=dict(ball=L_HOME, yaw=0),
    foot_r=dict(ball=R_HOME, yaw=-55),
    grip=(-0.35, -0.26, 0.98), blade=(0.15, -0.6, 0.75), edge=(0.1, -0.8, -0.6),
    elbow_r=(-0.5, 0.5, -0.7),
    hand_l=(0.27, -0.33, 1.06), elbow_l=(0.5, 0.6, -0.6),
)

POSES = [
    dict(frame=0, **GUARD),
    # breakdown: sinking back, sword rising
    dict(frame=5,
         hips=(-0.06, 0.10, 0.84), hips_rot=(-45, 4, -3),
         chest=(-20, 4, -3), head=(55, 0, 0),
         foot_l=dict(ball=L_HOME, yaw=0, heel=10),
         grip=(-0.48, 0.20, 1.30), blade=(-0.3, 0.4, 0.85), edge=(0, -0.9, 0.45),
         elbow_r=(-0.8, 0.4, -0.2),
         hand_l=(0.14, -0.42, 1.20), elbow_l=(0.6, 0.1, -0.7)),
    # anticipation: sat very deep on the rear leg, back turned to the target,
    # hand high above the head with the blade up and back over the right
    # shoulder, eyes and off arm on the target
    dict(frame=10,
         hips=(-0.14, 0.26, 0.68), hips_rot=(-70, 4, -8),
         chest=(-50, -8, -12), head=(80, 6, 8),
         foot_l=dict(ball=L_HOME, yaw=0, heel=35),
         foot_r=dict(ball=R_HOME, yaw=-65),
         grip=(-0.20, 0.74, 1.56), blade=(-0.15, 0.7, 0.7), edge=(0.0, -0.7, 0.7),
         elbow_r=(-0.8, 0.5, 0.3),
         hand_l=(-0.02, -0.24, 1.27), elbow_l=(0.3, -0.3, -0.8)),
    # held, still sinking
    dict(frame=14,
         hips=(-0.15, 0.30, 0.63), hips_rot=(-74, 4, -10),
         chest=(-54, -10, -14), head=(82, 6, 8),
         grip=(-0.18, 0.80, 1.48), blade=(-0.1, 0.75, 0.65),
         hand_l=(-0.01, -0.19, 1.21)),
    # drive: hips shoot forward and open, lead knee driven high; the elbow
    # leads, the hand is still behind the head and the tip drops down the back
    dict(frame=17,
         hips=(-0.02, -0.16, 0.75), hips_rot=(20, 10, 0),
         chest=(-65, 2, -4), head=(42, 4, 0),
         foot_l=dict(ball=(0.32, -0.66), yaw=8, heel=-15, lift=0.22),
         foot_r=dict(ball=R_HOME, yaw=-40, heel=35),
         grip=(-0.30, 0.04, 1.56), blade=(0.2, 0.6, -0.75), edge=(-0.3, -0.7, -0.6),
         elbow_r=(-0.6, -0.6, 0.5),
         hand_l=(0.30, -0.44, 1.05), elbow_l=(0.6, 0.2, -0.6)),
    # contact: long low lunge; the hand is outside the right shoulder and the
    # blade crosses the centre line high-right to low-left; off hand snaps back
    # past the hip
    dict(frame=19,
         hips=(0.08, -0.44, 0.62), hips_rot=(30, 18, 0),
         chest=(15, 18, 0), head=(-38, -4, 0),
         foot_l=dict(ball=L_LUNGE, yaw=10, heel=-18, lift=0.04),
         foot_r=dict(ball=R_HOME, yaw=-20, heel=55),
         grip=(-0.15, -1.05, 1.18), blade=(0.6, -0.5, -0.55), edge=(0.5, 0.2, -0.85),
         elbow_r=(-0.7, 0.0, -0.7),
         hand_l=(0.44, -0.24, 0.78), elbow_l=(0.3, 0.9, 0.1)),
    # overshoot: deepest point; hand carried past the lead knee, tip near the
    # ground behind it, chest dragged right round and down, off arm one long
    # line thrown back and up
    dict(frame=21,
         hips=(0.09, -0.45, 0.50), hips_rot=(60, 24, 0),
         chest=(60, 32, 14), head=(-70, -24, 0),
         foot_l=dict(ball=L_LUNGE, yaw=10),
         foot_r=dict(ball=R_HOME, yaw=-10, heel=65),
         grip=(0.72, -0.64, 0.42), blade=(0.6, 0.65, -0.42), edge=(0.5, -0.5, -0.5),
         elbow_r=(-0.4, 0.2, -0.6),
         hand_l=(0.18, 0.26, 1.16), elbow_l=(0.3, 0.5, 0.5)),
    # rebound: hips and chest come back up, the blade drags late
    dict(frame=27,
         hips=(0.08, -0.43, 0.60), hips_rot=(54, 20, 0),
         chest=(46, 16, 8), head=(-60, -10, 0),
         foot_r=dict(ball=R_HOME, yaw=-12, heel=58),
         grip=(0.70, -0.66, 0.54), blade=(0.7, 0.5, -0.5),
         hand_l=(0.19, 0.22, 1.20)),
    # settled finish, head up on the target
    dict(frame=35,
         hips=(0.07, -0.41, 0.62), hips_rot=(48, 19, 0),
         chest=(40, 14, 6), head=(-50, -4, 0),
         grip=(0.66, -0.68, 0.60), blade=(0.8, 0.25, -0.4),
         hand_l=(0.22, 0.16, 1.10)),
    # push back off the lead leg: hips travel back, chest still forward
    dict(frame=39,
         hips=(0.02, -0.24, 0.68), hips_rot=(20, 18, -1),
         chest=(24, 14, 0), head=(-34, -8, 0),
         foot_r=dict(ball=R_HOME, yaw=-35, heel=25),
         grip=(0.36, -0.58, 0.80), blade=(0.65, -0.3, -0.2),
         hand_l=(0.40, -0.04, 0.92), elbow_l=(0.5, 0.6, -0.6)),
    # weight over the rear foot, then the lead foot comes back
    dict(frame=43,
         hips=(-0.10, 0.06, 0.78), hips_rot=(-12, 9, -3),
         chest=(12, 8, 0), head=(4, 0, 0),
         foot_l=dict(ball=(0.30, -0.60), yaw=8, heel=10, lift=0.07),
         foot_r=dict(ball=R_HOME, yaw=-50, heel=6),
         grip=(0.02, -0.40, 0.98), blade=(0.55, -0.7, 0.1), edge=(0.3, -0.2, -0.9),
         elbow_r=(-0.5, 0.3, -0.7),
         hand_l=(0.30, -0.22, 1.00)),
    # sword carries a little past guard as the foot lands
    dict(frame=48,
         hips=(-0.07, 0.07, 0.85), hips_rot=(-36, 4, -3),
         chest=(8, 6, 0), head=(24, 0, 0),
         foot_l=dict(ball=L_HOME, yaw=0),
         foot_r=dict(ball=R_HOME, yaw=-55),
         grip=(-0.38, -0.18, 1.08), blade=(0.05, -0.5, 0.85), edge=(0.1, -0.8, -0.6),
         hand_l=(0.22, -0.28, 1.08)),
    dict(frame=54, **GUARD),
]

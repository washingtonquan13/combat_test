"""Stepping diagonal cut, right-high to left-low. Pose sheet for tools/anim/make.py.

Character faces -Y, its left is +X. 24 fps. Starts and ends in the same guard,
in place (no root motion).

Idea: the weight goes back onto the rear leg while the sword winds over the
right shoulder; the hips drive forward and turn first, the lead foot reaches,
the chest and then the blade follow; the blade arrives as the lead heel lands;
the blade carries on low to the left and pulls the chest round; settle; push
back off the lead leg to guard.
"""

L_HOME = (0.16, -0.32)
R_HOME = (-0.18, 0.28)
L_LUNGE = (0.25, -0.66)

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
    # breakdown: starting back, sword rising
    dict(frame=4,
         hips=(-0.06, 0.08, 0.86), hips_rot=(-40, 3, -2),
         chest=(-15, 2, 0), head=(50, 0, 0),
         foot_l=dict(ball=L_HOME, yaw=0, heel=8),
         grip=(-0.40, 0.12, 1.25), blade=(-0.25, 0.45, 0.85), edge=(0, -0.9, 0.45),
         elbow_r=(-0.7, 0.4, -0.4),
         hand_l=(0.16, -0.34, 1.22), elbow_l=(0.6, 0.2, -0.7)),
    # anticipation: sat deep on the rear leg, chest coiled, hand behind the
    # right shoulder with the tip trailing, off hand reaching forward
    dict(frame=8,
         hips=(-0.12, 0.20, 0.76), hips_rot=(-50, 2, -6),
         chest=(-34, -6, -8), head=(60, 8, 6),
         foot_l=dict(ball=L_HOME, yaw=0, heel=25),
         foot_r=dict(ball=R_HOME, yaw=-55),
         grip=(-0.38, 0.50, 1.46), blade=(-0.6, 0.6, 0.5), edge=(0.3, -0.5, 0.8),
         elbow_r=(-0.8, 0.5, 0.0),
         hand_l=(0.08, -0.30, 1.30), elbow_l=(0.5, 0.1, -0.8)),
    # drive: hips forward and turning, lead foot in the air, chest and sword still back
    dict(frame=11,
         hips=(-0.02, -0.10, 0.80), hips_rot=(-15, 8, 0),
         chest=(-50, 0, 0), head=(62, 5, 0),
         foot_l=dict(ball=(0.22, -0.50), yaw=8, heel=-12, lift=0.09),
         foot_r=dict(ball=R_HOME, yaw=-40, heel=22),
         grip=(-0.44, 0.26, 1.48), blade=(-0.65, 0.5, 0.5), edge=(0.3, -0.5, 0.8),
         elbow_r=(-0.8, 0.3, 0.1),
         hand_l=(0.24, -0.36, 1.20)),
    # contact: blade on the diagonal mid-cut, tip still above and right of the
    # hand, chest half unwound, lead heel just touching
    dict(frame=14,
         hips=(0.05, -0.27, 0.73), hips_rot=(25, 12, 0),
         chest=(-33, 8, 0), head=(14, -6, 0),
         foot_l=dict(ball=L_LUNGE, yaw=10, heel=-15, lift=0.05),
         foot_r=dict(ball=R_HOME, yaw=-22, heel=45),
         grip=(-0.18, -0.84, 1.12), blade=(-0.35, -0.8, 0.35), edge=(0.6, -0.1, -0.75),
         elbow_r=(-0.5, 0.0, -0.9),
         hand_l=(0.38, -0.10, 1.00), elbow_l=(0.2, 0.6, -0.8)),
    # overshoot: arm stays long, the blade carries low past the lead knee and
    # pulls the chest round after it; deepest point of the lunge
    dict(frame=16,
         hips=(0.07, -0.31, 0.70), hips_rot=(40, 13, 0),
         chest=(30, 9, 4), head=(-58, -10, 0),
         foot_l=dict(ball=L_LUNGE, yaw=10),
         foot_r=dict(ball=R_HOME, yaw=-15, heel=55),
         grip=(0.41, -0.79, 0.74), blade=(0.55, -0.6, -0.4), edge=(0.5, 0.5, -0.5),
         elbow_r=(-0.4, 0.2, -0.6),
         hand_l=(0.47, 0.08, 0.86)),
    # settle, then a moving hold
    dict(frame=21,
         hips=(0.06, -0.29, 0.74), hips_rot=(34, 13, 0),
         chest=(26, 9, 2), head=(-50, -8, 0),
         foot_r=dict(ball=R_HOME, yaw=-18, heel=48),
         grip=(0.42, -0.71, 0.80), blade=(0.6, -0.5, -0.35),
         hand_l=(0.45, 0.05, 0.89)),
    dict(frame=27,
         hips=(0.055, -0.28, 0.76), hips_rot=(31, 12, 0),
         chest=(24, 8, 2), head=(-46, -6, 0),
         grip=(0.39, -0.68, 0.85), blade=(0.6, -0.5, -0.3),
         hand_l=(0.43, 0.03, 0.92)),
    # push back off the lead leg; the sword drags behind
    dict(frame=30,
         hips=(0.0, -0.14, 0.80), hips_rot=(12, 9, -1),
         chest=(18, 7, 0), head=(-26, -3, 0),
         foot_r=dict(ball=R_HOME, yaw=-35, heel=25),
         grip=(0.23, -0.49, 0.93), blade=(0.6, -0.5, -0.2),
         hand_l=(0.42, 0.02, 0.90)),
    # weight back onto the rear leg, both feet down, tip leading up the diagonal
    dict(frame=33,
         hips=(-0.05, 0.0, 0.84), hips_rot=(-12, 6, -2),
         chest=(10, 6, 0), head=(4, 0, 0),
         foot_l=dict(ball=L_LUNGE, yaw=10, heel=-10, lift=0.035),
         foot_r=dict(ball=R_HOME, yaw=-50, heel=4),
         grip=(0.01, -0.37, 1.04), blade=(0.55, -0.7, 0.1), edge=(0.3, -0.2, -0.9),
         elbow_r=(-0.5, 0.3, -0.7),
         hand_l=(0.32, -0.20, 1.02), elbow_l=(0.5, 0.6, -0.6)),
    # hips over the rear foot, lead foot drawn back in the air
    dict(frame=39,
         hips=(-0.14, 0.24, 0.85), hips_rot=(-36, 2, -5),
         chest=(10, 5, 0), head=(22, 0, 0),
         foot_l=dict(ball=(0.18, -0.45), yaw=4, heel=12, lift=0.05),
         foot_r=dict(ball=R_HOME, yaw=-55),
         grip=(-0.27, -0.10, 1.09), blade=(0.35, -0.7, 0.4), edge=(0.2, -0.5, -0.85),
         hand_l=(0.16, -0.14, 1.08)),
    dict(frame=44, **GUARD),
]

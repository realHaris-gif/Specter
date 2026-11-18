import numpy as np
from hypothesis import given, settings, strategies as st
from specter_ref import simulate, analyze

@settings(max_examples=12, deadline=None)
@given(bpm=st.floats(8, 30), g=st.floats(0.05, 5.0))
def test_gain_invariance(bpm, g):
    a = analyze(simulate(bpm=bpm, gain=1.0))
    b = analyze(simulate(bpm=bpm, gain=g))
    assert abs(a["bpm"] - b["bpm"]) < 0.3
    assert a["target_bin"] == b["target_bin"]

@settings(max_examples=12, deadline=None)
@given(bpm=st.floats(8, 30), r=st.floats(0.3, 1.2))
def test_recovers_bpm_and_range(bpm, r):
    out = analyze(simulate(bpm=bpm, range_m=r))
    assert abs(out["bpm"] - bpm) < 1.0
    assert abs(out["range_m"] - r) < 0.06

@settings(max_examples=8, deadline=None)
@given(shift=st.integers(1, 200))
def test_delay_equivariance(shift):
    rx = simulate(bpm=15, seconds=25)
    a = analyze(rx)
    b = analyze(np.roll(rx, shift))
    assert abs(a["bpm"] - b["bpm"]) < 0.3
    assert abs(a["range_m"] - b["range_m"]) < 0.06

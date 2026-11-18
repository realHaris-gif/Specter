"""Simulator for synthetic scenes."""
import numpy as np
from .dsp import FS, N, C, SLOW_FS, make_chirp

def simulate(seconds=30, bpm=15.0, amp_mm=5.0, range_m=0.6, f0=18000.0, f1=21000.0, snr_db=20.0, static=((0.0003, 1.0), (0.0062, 0.15)), seed=0, gain=1.0):
    rng = np.random.default_rng(seed)
    chirp = make_chirp(f0, f1)
    S = np.fft.rfft(chirp)
    f = np.fft.rfftfreq(N, 1 / FS)
    K = int(seconds * SLOW_FS)
    t = np.arange(K) / SLOW_FS
    d_m = (amp_mm / 1000.0) * np.sin(2 * np.pi * (bpm / 60.0) * t)
    tau_direct = 0.00030
    rx = np.empty((K, N))
    for k in range(K):
        H = np.zeros(len(f), dtype=complex)
        for tau, a in static:
            H += a * np.exp(-2j * np.pi * f * tau)
        tau_t = tau_direct + 2 * (range_m + d_m[k]) / C
        H += 0.05 * np.exp(-2j * np.pi * f * tau_t)
        rx[k] = np.fft.irfft(S * H, n=N)
    rx = rx.reshape(-1)
    sig_p = np.mean(rx**2)
    noise = rng.normal(0, np.sqrt(sig_p / 10**(snr_db / 10)), rx.shape)
    return gain * (rx + noise)

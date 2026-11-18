"""Specter reference DSP (numpy). Golden source of truth for the Swift port."""
import numpy as np

FS = 48000
N = 512
C = 343.0
SLOW_FS = FS / N

def make_chirp(f0=18000.0, f1=21000.0, n=N, fs=FS, taper=0.1):
    t = np.arange(n) / fs
    T = n / fs
    k = (f1 - f0) / T
    x = np.sin(2 * np.pi * (f0 * t + 0.5 * k * t**2))
    L = int(taper * n / 2)
    w = np.ones(n)
    ramp = 0.5 * (1 - np.cos(np.pi * np.arange(L) / L))
    w[:L] = ramp
    w[n-L:] = ramp[::-1]
    return x * w

def band_bins(f0, f1, n=N, fs=FS):
    return int(np.ceil(f0 * n / fs)), int(np.floor(f1 * n / fs))

def channel_estimate(frames, chirp, f0, f1):
    """frames: (K, N) real. Returns complex analytic channel response (K, N)."""
    S = np.fft.fft(chirp)
    R = np.fft.fft(frames, axis=1)
    m0, m1 = band_bins(f0, f1)
    H = np.zeros_like(R, dtype=complex)
    H[:, m0:m1 + 1] = R[:, m0:m1 + 1] * np.conj(S[m0:m1 + 1])
    h = np.fft.ifft(H, axis=1)
    return h / (np.sqrt(np.sum(np.abs(S[m0:m1 + 1])**2)) + 1e-12)

def remove_static(h, alpha=0.98):
    mu = np.zeros(h.shape[1], dtype=complex)
    out = np.empty_like(h)
    for k in range(h.shape[0]):
        mu = alpha * mu + (1 - alpha) * h[k]
        out[k] = h[k] - mu
    return out

def direct_path_index(h):
    return int(np.argmax(np.mean(np.abs(h), axis=0)))

def pick_target(dyn, n_direct, min_off=42, max_off=420, win=281):
    seg = dyn[-win:, :]
    energy = np.mean(np.abs(seg)**2, axis=0)
    idx = (n_direct + np.arange(min_off, max_off)) % dyn.shape[1]
    return int(idx[np.argmax(energy[idx])])

def circle_center(z):
    x, y = z.real, z.imag
    A = np.c_[x, y, np.ones_like(x)]
    b = -(x**2 + y**2)          # Kasa fit: x^2+y^2 + D x + E y + F = 0
    D, E, _ = np.linalg.lstsq(A, b, rcond=None)[0]
    return complex(-D / 2, -E / 2)

def displacement_mm(z, f_c):
    lam = C / f_c
    zc = z - circle_center(z)
    ph = np.unwrap(np.angle(zc))
    return -ph * lam / (4 * np.pi) * 1000.0

def estimate_bpm(d, fs=SLOW_FS, lo=0.1, hi=0.7):
    d = d - np.polyval(np.polyfit(np.arange(len(d)), d, 1), np.arange(len(d)))
    d = d * np.hanning(len(d))
    nfft = len(d) * 8
    P = np.abs(np.fft.rfft(d, nfft))**2
    ff = np.fft.rfftfreq(nfft, 1 / fs)
    band = (ff >= lo) & (ff <= hi)
    wide = (ff >= 0.05) & (ff <= 1.5)
    k = np.argmax(np.where(band, P, 0))
    near = (ff >= ff[k] - 0.04) & (ff <= ff[k] + 0.04)
    conf = np.sum(P[near]) / (np.sum(P[wide]) + 1e-18)
    return 60.0 * ff[k], float(conf)

def analyze(rx, f0=18000.0, f1=21000.0):
    chirp = make_chirp(f0, f1)
    K = len(rx) // N
    frames = rx[:K * N].reshape(K, N)
    h = channel_estimate(frames, chirp, f0, f1)
    dyn = remove_static(h)
    nd = direct_path_index(h)
    tgt = pick_target(dyn, nd)
    z = h[-1875:, tgt]
    d = displacement_mm(z, 0.5 * (f0 + f1))
    bpm, conf = estimate_bpm(d)
    rng_m = (((tgt - nd) % N) / FS) * C / 2
    return dict(bpm=bpm, conf=conf, range_m=rng_m, target_bin=tgt, direct_bin=nd, disp_mm=d)

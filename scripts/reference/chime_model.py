#!/usr/bin/env python3
"""Reference physical model of a struck wind-chime tube.

Offline, no real-time constraints. It exists so the phone's modal synth has a
measured target to be fitted against, in place of a recording we don't have.

The tube is a free-free Timoshenko beam (finite elements, so the mode shapes are
real and the higher modes drift below the simple 1 : 2.76 : 5.40 series as a real
tube's do), with the ovalling modes of its wall from thin-shell theory. The strike
is a wooden clapper of real mass, or a neighbouring tube with all its own modes and
its swing, meeting the tube through a Hertzian contact spring with Hunt–Crossley
hysteresis, integrated at 5 MHz for the fraction of a millisecond the contact lasts;
after that each mode rings down analytically. Damping per mode is
material plus radiation (rising with frequency) plus the cord at the mode-1 node.
Sound is the modal acceleration, weighted by a radiation efficiency, as a compact
source's far-field pressure is.

    python3 chime_model.py --out renders/ --velocities 0.1 0.35 1.2
    python3 chime_model.py --out renders/ --striker tube:523

Writes one WAV per velocity (a common gain, so their relative loudness is kept),
a JSON mode table for fitting, and a spectrogram PNG per render.
"""
import argparse
import json
import math
import os
import wave

import numpy as np
from scipy.linalg import eigh


# ── Tube ──────────────────────────────────────────────────────────────────────

class Tube:
    """A 6061 aluminium tube: 1 inch outside diameter, 1.5 mm wall."""

    def __init__(self, f1, outer_d=0.0254, wall=0.0015, E=69e9, rho=2700.0, nu=0.33):
        self.E, self.rho, self.nu = E, rho, nu
        self.G = E / (2 * (1 + nu))
        self.Ro = outer_d / 2
        self.Ri = self.Ro - wall
        self.h = wall
        self.R = (self.Ro + self.Ri) / 2            # mid-surface radius
        self.A = math.pi * (self.Ro ** 2 - self.Ri ** 2)
        self.I = math.pi / 4 * (self.Ro ** 4 - self.Ri ** 4)
        self.kappa = 2 * (1 + nu) / (4 + 3 * nu)     # Timoshenko shear coefficient, thin tube
        # Length for the wanted first bending mode (Euler–Bernoulli estimate, then
        # corrected by the FE solution)
        gyr = math.sqrt(self.I / self.A)
        c = math.sqrt(E / rho)
        self.L = math.sqrt(4.7300 ** 2 / (2 * math.pi) * c * gyr / f1)
        self._solve_bending()
        scale = self.bend_f[0] / f1
        self.L *= math.sqrt(scale)                   # f ∝ 1/L², one correction is enough
        self._solve_bending()
        self.mass = rho * self.A * self.L

    def _solve_bending(self, n_el=240, n_modes=12):
        """Free-free Timoshenko beam by finite elements. Returns frequencies and
        mode shapes (transverse displacement at the nodes, mass-normalised)."""
        E, G, I, A, rho, kappa = self.E, self.G, self.I, self.A, self.rho, self.kappa
        le = self.L / n_el
        phi = 12 * E * I / (kappa * G * A * le ** 2)
        # Stiffness (Timoshenko, Przemieniecki) and consistent mass with rotary inertia
        k = E * I / ((1 + phi) * le ** 3) * np.array([
            [12, 6 * le, -12, 6 * le],
            [6 * le, (4 + phi) * le ** 2, -6 * le, (2 - phi) * le ** 2],
            [-12, -6 * le, 12, -6 * le],
            [6 * le, (2 - phi) * le ** 2, -6 * le, (4 + phi) * le ** 2]])
        mt = rho * A * le / 420 * np.array([
            [156, 22 * le, 54, -13 * le],
            [22 * le, 4 * le ** 2, 13 * le, -3 * le ** 2],
            [54, 13 * le, 156, -22 * le],
            [-13 * le, -3 * le ** 2, -22 * le, 4 * le ** 2]])
        mr = rho * I / (30 * le) * np.array([
            [36, 3 * le, -36, 3 * le],
            [3 * le, 4 * le ** 2, -3 * le, -le ** 2],
            [-36, -3 * le, 36, -3 * le],
            [3 * le, -le ** 2, -3 * le, 4 * le ** 2]])
        m = mt + mr
        n_dof = 2 * (n_el + 1)
        K = np.zeros((n_dof, n_dof))
        M = np.zeros((n_dof, n_dof))
        for e in range(n_el):
            idx = [2 * e, 2 * e + 1, 2 * e + 2, 2 * e + 3]
            K[np.ix_(idx, idx)] += k
            M[np.ix_(idx, idx)] += m
        w2, vec = eigh(K, M)
        # Drop the two rigid-body modes
        order = np.argsort(w2)
        w2 = w2[order][2:2 + n_modes]
        vec = vec[:, order][:, 2:2 + n_modes]
        self.bend_f = np.sqrt(np.maximum(w2, 0)) / (2 * math.pi)
        self.bend_shape = vec[0::2, :]            # transverse displacement rows, mass-normalised
        self.x = np.linspace(0, self.L, n_el + 1)

    def bend_at(self, x):
        """Mass-normalised bending mode shapes at position x (metres from one end)."""
        return np.array([np.interp(x, self.x, self.bend_shape[:, j]) for j in range(self.bend_shape.shape[1])])

    def shell_modes(self, f_max=20000.0, n_max=4, m_max=6):
        """Ovalling modes of the wall (Donnell–Mushtari), lowest branch, as a list of
        (frequency, circumferential n, axial m). Axial wavenumber m π / L."""
        E, rho, nu, R, h, L = self.E, self.rho, self.nu, self.R, self.h, self.L
        beta2 = h ** 2 / (12 * R ** 2)
        c = math.sqrt(E / (rho * (1 - nu ** 2)))
        out = []
        # Donnell's theory overestimates the low-n frequencies (by a third at n = 2), so
        # each family is anchored on Love's inextensional ring frequency and Donnell only
        # supplies how the axial orders climb from it
        for n in range(2, n_max + 1):
            f_love = n * (n ** 2 - 1) / math.sqrt(n ** 2 + 1) * h / (R ** 2 * math.sqrt(12)) * c / (2 * math.pi)
            f_dm0 = None
            for m in range(0, m_max + 1):
                lam = m * math.pi * R / L
                Lm = np.array([
                    [lam ** 2 + (1 - nu) / 2 * n ** 2, (1 + nu) / 2 * lam * n, nu * lam],
                    [(1 + nu) / 2 * lam * n, (1 - nu) / 2 * lam ** 2 + n ** 2, n],
                    [nu * lam, n, 1 + beta2 * (lam ** 2 + n ** 2) ** 2]])
                om2 = np.linalg.eigvalsh(Lm)
                f_dm = math.sqrt(max(om2[0], 0)) * c / R / (2 * math.pi)
                if f_dm0 is None:
                    f_dm0 = f_dm
                f = f_love * f_dm / f_dm0
                if f < f_max:
                    out.append((f, n, m))
        return sorted(out)


# ── Modes ─────────────────────────────────────────────────────────────────────

class Mode:
    def __init__(self, f, zeta, shape_at_strike, kind, label, radiation=1.0):
        self.f = f
        self.w = 2 * math.pi * f
        self.zeta = zeta
        self.phi = shape_at_strike       # mass-normalised shape at the strike point
        self.kind = kind
        self.label = label
        self.radiation = radiation
        self.q = 0.0
        self.v = 0.0

    @property
    def t60(self):
        return 6.908 / (self.zeta * self.w)


def tube_modes(tube, strike_frac, cord_frac, args, prefix=''):
    """Every mode of a hung tube that matters at its contact point: rigid translation
    and rotation (it swings on its cord, so a hit moves it bodily), bending, and the
    wall's ovalling. All mass-normalised, so modal mass is 1."""
    modes = []
    x0 = strike_frac * tube.L
    xs = cord_frac * tube.L
    # Rigid body: translation and rotation about the centre, ω = 0, no sound
    modes.append(Mode(0.0, 0.0, 1 / math.sqrt(tube.mass), 'rigid', prefix + 'translate', 0.0))
    J = tube.mass * tube.L ** 2 / 12
    modes.append(Mode(0.0, 0.0, (x0 - tube.L / 2) / math.sqrt(J), 'rigid', prefix + 'rotate', 0.0))
    phi0 = tube.bend_at(x0)
    phis = tube.bend_at(xs)
    phimax = np.abs(tube.bend_shape).max(axis=0)
    f_c = args.coincidence
    for j, f in enumerate(tube.bend_f):
        if f > args.f_max:
            break
        # Material + radiation, anchored on measured ring times of aluminium chimes
        # (about 8 s for the fundamental of an A4 tube, 0.4 s near 4 kHz), plus the cord
        # at the mode-1 node, which barely touches mode 1 and damps the others
        zeta = args.zeta_440 * (f / 440.0) ** args.zeta_slope
        zeta += args.zeta_cord * (phis[j] / phimax[j]) ** 2
        rad = min(1.0, (f / f_c) ** 2)
        modes.append(Mode(f, zeta, phi0[j], 'bend', f'{prefix}bend {j + 1}', rad))
    for f, n, m in tube.shell_modes(args.f_max):
        # Shape at the strike point: cos(nθ) = 1 under the striker, cos(mπx/L) along;
        # modal mass is the tube's × ½ (circumferential) × ½ (axial, m ≥ 1)
        axial = math.cos(m * math.pi * strike_frac)
        mm = tube.mass * 0.5 * (1.0 if m == 0 else 0.5)
        modes.append(Mode(f, args.zeta_shell, axial / math.sqrt(mm), 'shell', f'{prefix}shell n{n} m{m}', 1.0))
    return modes


def clapper_modes(mass):
    """A wooden clapper: a point mass. (Its own body resonances are far quieter than
    the tube and are left out.)"""
    return [Mode(0.0, 0.0, 1 / math.sqrt(mass), 'rigid', 'clapper', 0.0)]


# ── Strike ────────────────────────────────────────────────────────────────────

def collide(striker, target, v0, k, e):
    """Integrate the contact between two modal bodies: the striker's surface meets the
    target's through a Hertz spring F = k δ^1.5 with Hunt–Crossley hysteresis. The
    striker arrives at v0 (its rigid translation), the target is at rest. Returns the
    contact duration and peak force; leaves every mode with its state at separation."""
    dt = 2e-7
    modes = striker + target
    ns = len(striker)
    n = len(modes)
    w = np.array([m.w for m in modes])
    z = np.array([m.zeta for m in modes])
    phi = np.array([m.phi for m in modes])
    sign = np.array([-1.0] * ns + [1.0] * (n - ns))   # force pushes the target +, the striker −
    q = np.zeros(n)
    qv = np.zeros(n)
    # The striker's translation carries its approach speed: surface velocity φ q̇ = v0
    qv[0] = v0 / striker[0].phi
    hc = 1.5 * (1 - e) / max(v0, 1e-3)
    ks = w ** 2
    cs = 2 * z * w

    def accel(q, qv):
        # Gap closes as the striker's surface moves + and the target's moves +
        us = float(phi[:ns] @ q[:ns])
        ut = float(phi[ns:] @ q[ns:])
        dus = float(phi[:ns] @ qv[:ns])
        dut = float(phi[ns:] @ qv[ns:])
        delta = us - ut
        if delta > 0:
            F = k * delta ** 1.5 * max(0.0, 1 + hc * (dus - dut))
        else:
            F = 0.0
        return sign * phi * F - cs * qv - ks * q, F

    t = 0.0
    F_peak = 0.0
    t_contact = 0.0
    in_contact = False
    while True:
        a1, F = accel(q, qv)
        k1 = (qv, a1)
        a2, _ = accel(q + dt / 2 * k1[0], qv + dt / 2 * k1[1])
        k2 = (qv + dt / 2 * k1[1], a2)
        a3, _ = accel(q + dt / 2 * k2[0], qv + dt / 2 * k2[1])
        k3 = (qv + dt / 2 * k2[1], a3)
        a4, _ = accel(q + dt * k3[0], qv + dt * k3[1])
        k4 = (qv + dt * k3[1], a4)
        q = q + dt / 6 * (k1[0] + 2 * k2[0] + 2 * k3[0] + k4[0])
        qv = qv + dt / 6 * (k1[1] + 2 * k2[1] + 2 * k3[1] + k4[1])
        t += dt
        if F > 0:
            in_contact = True
            F_peak = max(F_peak, F)
            t_contact = t
        elif in_contact:
            break
        if t > 0.02:
            break
    for m, qi, vi in zip(modes, q, qv):
        m.q, m.v = qi, vi
    return t_contact, F_peak


# ── Render ────────────────────────────────────────────────────────────────────

def render(modes, sr, seconds, tilt_db_oct=0.0, radius=0.0127):
    w_ka1 = 343.0 / radius     # ω at which ka = 1 for the tube's outer radius
    t = np.arange(int(sr * seconds)) / sr
    out = np.zeros_like(t)
    table = []
    for m in modes:
        if m.w <= 0:
            continue
        wd = m.w * math.sqrt(max(1 - m.zeta ** 2, 0))
        a = m.zeta * m.w
        # Damped free response from (q, v) at separation
        A = m.q
        B = (m.v + a * m.q) / wd
        env = np.exp(-a * t)
        disp = env * (A * np.cos(wd * t) + B * np.sin(wd * t))
        # Far-field pressure follows the surface acceleration while the tube is small
        # against the wavelength (ka < 1), and the surface velocity once it isn't: the
        # weight grows as ω² up to ka = 1 and as ω beyond
        wa = min(m.w, w_ka1)
        weight = m.radiation * m.w * wa * 2 ** (tilt_db_oct / 6.02 * math.log2(m.f / 440.0))
        out += -weight * disp      # the damping terms are negligible for ζ ≪ 1
        amp = weight * math.hypot(A, B)
        table.append({'label': m.label, 'kind': m.kind, 'f': m.f, 'zeta': m.zeta, 't60': m.t60,
                      'amp': amp, 'phi': m.phi})
    return out, table


def write_wav(path, x, sr):
    y = np.clip(x, -1, 1)
    pcm = (y * 32767).astype('<i2')
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def spectrogram_png(path, x, sr, title):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(10, 5))
    ax.specgram(x, NFFT=4096, Fs=sr, noverlap=3584, cmap='magma', vmin=-120, vmax=-20)
    ax.set_ylim(0, 12000)
    ax.set_xlim(0, min(2.0, len(x) / sr))
    ax.set_title(title)
    ax.set_xlabel('s')
    ax.set_ylabel('Hz')
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default='renders')
    ap.add_argument('--pitch', type=float, default=440.0, help='first bending mode, Hz')
    ap.add_argument('--velocities', type=float, nargs='+', default=[0.1, 0.35, 1.2], help='clapper speed, m/s')
    ap.add_argument('--strike', type=float, default=0.62, help='strike point as a fraction of the length')
    ap.add_argument('--cord', type=float, default=0.224, help='suspension point (mode-1 node)')
    ap.add_argument('--hear', default='struck', choices=['struck', 'both'], help='with a tube striker: render only the struck tube (its voice alone) or both')
    ap.add_argument('--striker', default='wood', help="'wood' (a clapper disc) or 'tube:<Hz>' (a neighbouring chime, its first mode at that pitch)")
    ap.add_argument('--clapper-mass', type=float, default=0.04, help='kg')
    ap.add_argument('--clapper-E', type=float, default=2e9, help='clapper material modulus, Pa (wood ~2e9, hard plastic 3e9, aluminium 69e9)')
    ap.add_argument('--clapper-radius', type=float, default=0.035, help='clapper disc radius, m')
    ap.add_argument('--restitution', type=float, default=0.7)
    ap.add_argument('--zeta-440', type=float, default=3.1e-4, help='bending-mode damping ratio at 440 Hz')
    ap.add_argument('--zeta-slope', type=float, default=0.37, help='damping ∝ f^slope')
    ap.add_argument('--zeta-cord', type=float, default=2e-4)
    ap.add_argument('--zeta-shell', type=float, default=2e-3)
    ap.add_argument('--coincidence', type=float, default=440.0, help='below this, radiation falls as f²')
    ap.add_argument('--f-max', type=float, default=20000.0)
    ap.add_argument('--tilt', type=float, default=0.0, help='spectral tilt of the output, dB/octave about 440')
    ap.add_argument('--seconds', type=float, default=5.0)
    ap.add_argument('--sr', type=int, default=48000)
    ap.add_argument('--gain', type=float, default=0.0, help='fixed output gain (0 = normalise the loudest render to -1 dBFS)')
    ap.add_argument('--tag', default='')
    ap.add_argument('--no-png', action='store_true')
    args = ap.parse_args()

    tube = Tube(args.pitch)
    nu_c = 0.3
    striker_tube = None
    if args.striker.startswith('tube:'):
        # Two hung tubes meet at the same depth below the ring. Each hangs from its
        # mode-1 node, so a contact at fraction `strike` of this tube's length lands on
        # the other at the fraction that puts it at the same depth.
        striker_tube = Tube(float(args.striker[5:]))
        depth = (args.strike - args.cord) * tube.L
        args.striker_frac = args.cord + depth / striker_tube.L
        E_star = tube.E / (2 * (1 - tube.nu ** 2))
        R_eff = math.sqrt(tube.Ro * striker_tube.Ro)       # crossed cylinders, as swinging tubes meet
        args.hertz_k = 4 / 3 * E_star * math.sqrt(R_eff)
        tag = f'_by{striker_tube.bend_f[0]:.0f}Hz'
    else:
        # Hertz contact: clapper edge (curved one way) on the tube (curved the other)
        E_star = 1 / ((1 - nu_c ** 2) / args.clapper_E + (1 - tube.nu ** 2) / tube.E)
        R_eff = math.sqrt(args.clapper_radius * tube.Ro)
        args.hertz_k = 4 / 3 * E_star * math.sqrt(R_eff)
        tag = ''
    args.tag = tag + args.tag

    os.makedirs(args.out, exist_ok=True)
    print(f'tube: L = {tube.L * 100:.1f} cm, mass {tube.mass * 1000:.0f} g, bending modes (Hz):',
          ' '.join(f'{f:.0f}' for f in tube.bend_f if f < args.f_max))
    print('      ratios:', ' '.join(f'{f / tube.bend_f[0]:.3f}' for f in tube.bend_f if f < args.f_max))
    print('      shell modes (Hz):', ' '.join(f'{f:.0f}(n{n}m{m})' for f, n, m in tube.shell_modes(args.f_max)))
    if striker_tube is not None:
        print(f'struck by a tube: L = {striker_tube.L * 100:.1f} cm, modes (Hz):',
              ' '.join(f'{f:.0f}' for f in striker_tube.bend_f if f < args.f_max),
              f'| meeting at {args.striker_frac:.2f} of its length')
    print(f'contact stiffness k = {args.hertz_k:.3g} N/m^1.5')

    renders = []
    for v0 in args.velocities:
        target = tube_modes(tube, args.strike, args.cord, args, 'A ' if striker_tube else '')
        if striker_tube is not None:
            striker = tube_modes(striker_tube, args.striker_frac, args.cord, args, 'B ')
        else:
            striker = clapper_modes(args.clapper_mass)
        tc, Fp = collide(striker, target, v0, args.hertz_k, args.restitution)
        modes = (striker + target) if args.hear == 'both' else target
        x, table = render(modes, args.sr, args.seconds, args.tilt, tube.Ro)
        renders.append((v0, x, table, tc, Fp))
        print(f'v = {v0:.2f} m/s: contact {tc * 1000:.3f} ms, peak force {Fp:.0f} N')

    peak = max(np.abs(r[1]).max() for r in renders)
    gain = args.gain if args.gain > 0 else (10 ** (-1 / 20)) / peak
    report = {'tube': {'L': tube.L, 'mass': tube.mass, 'pitch': args.pitch, 'bend_f': [float(f) for f in tube.bend_f]},
              'args': {k: v for k, v in vars(args).items() if isinstance(v, (int, float, str, list))},
              'gain': gain, 'renders': []}
    for v0, x, table, tc, Fp in renders:
        name = f'chime_{args.pitch:.0f}Hz{args.tag}_v{v0:.2f}'
        write_wav(os.path.join(args.out, name + '.wav'), x * gain, args.sr)
        if not args.no_png:
            spectrogram_png(os.path.join(args.out, name + '.png'), x * gain, args.sr, f'{name}: contact {tc * 1000:.2f} ms')
        for row in table:
            row['amp'] *= gain
        report['renders'].append({'v0': v0, 'contact_ms': tc * 1000, 'peak_force': Fp, 'file': name + '.wav',
                                  'modes': table})
        loud = sorted(table, key=lambda r: -r['amp'])[:8]
        print(f'  {name}: loudest modes ' + ', '.join(f"{r['label']} {r['f']:.0f} Hz {20 * math.log10(max(r['amp'], 1e-9)):.0f} dB T60 {r['t60']:.2f}s" for r in loud))
    with open(os.path.join(args.out, f'chime_{args.pitch:.0f}Hz{args.tag}.json'), 'w') as fh:
        json.dump(report, fh, indent=1)


if __name__ == '__main__':
    main()

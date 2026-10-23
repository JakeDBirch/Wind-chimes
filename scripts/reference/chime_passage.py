#!/usr/bin/env python3
"""A short passage of wind on a chime set, rendered through the reference model.

A single strike is the thing a synth has to get right, but nobody's ear has a
reference for one in isolation, so this plays a set the way chimes are heard: five
tubes of a pentatonic, a few gusts over twenty seconds, the clapper striking at
speeds that follow the wind and tubes clashing with each other in the stronger
gusts. The event list is seeded, so every build gets the same passage.

    python3 chime_passage.py --out renders/ --build tube     # 1-inch aluminium tubes
    python3 chime_passage.py --out renders/ --build rod      # 10 mm aluminium rods
    python3 chime_passage.py --out renders/ --build bamboo   # 25 cm bamboo culms
"""
import argparse
import math
import os
import random
import sys
from types import SimpleNamespace

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chime_model import Tube, clapper_modes, collide, render, tube_modes, write_wav  # noqa: E402

PENTATONIC = [440.0, 523.25, 587.33, 659.26, 783.99]   # A4 C5 D5 E5 G5
BAMBOO_CM = [25.0, 23.0, 21.5, 20.0, 18.5]


def model_args(build):
    a = SimpleNamespace(strike=0.62, cord=0.224, clapper_mass=0.04, clapper_E=2e9, clapper_radius=0.035,
                        restitution=0.7, zeta_440=3.1e-4, zeta_slope=0.37, zeta_cord=2e-4, zeta_shell=2e-3,
                        f_max=20000.0, tilt=0.0, air=0.0, zeta_air=0.012)
    if build == 'bamboo':
        a.air = 1.0
    return a


def make_set(build):
    if build == 'tube':
        return [Tube(f) for f in PENTATONIC]
    if build == 'rod':
        return [Tube(f, outer_d=0.010, wall=None) for f in PENTATONIC]
    if build == 'bamboo':
        m = dict(E=12e9, rho=750.0, nu=0.3, outer_d=0.040, wall=0.005, loss=0.02)
        return [Tube(440.0, length=cm / 100, **m) for cm in BAMBOO_CM]
    raise ValueError(build)


def hertz_k(E_star, R_eff):
    return 4 / 3 * E_star * math.sqrt(R_eff)


def wind(t):
    """Mean wind over the passage: a breath, a strong gust, a trailing one."""
    w = 0.08
    for t0, amp, width in ((3.0, 0.45, 1.6), (9.5, 1.0, 2.2), (15.5, 0.6, 1.8)):
        w += amp * math.exp(-((t - t0) / width) ** 2)
    return w


def events(seconds, seed):
    """(time, kind, tube index, other index, speed m/s). kind is 'clapper' or 'clash'."""
    rng = random.Random(seed)
    out = []
    t = 0.0
    last = rng.randrange(5)
    while t < seconds:
        w = wind(t)
        rate = 0.25 + 7.0 * w
        t += rng.expovariate(rate)
        if t >= seconds:
            break
        w = wind(t)
        v = max(0.04, 1.25 * w * (0.35 + 0.9 * rng.random()))
        if rng.random() < 0.4 * w:
            i = rng.randrange(4)
            out.append((t, 'clash', i, i + 1, v * 0.8))
        else:
            i = last if rng.random() < 0.5 else rng.randrange(5)
            out.append((t, 'clapper', i, -1, v))
            last = i
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default='renders')
    ap.add_argument('--build', default='tube', choices=['tube', 'rod', 'bamboo'])
    ap.add_argument('--seconds', type=float, default=20.0)
    ap.add_argument('--seed', type=int, default=7)
    ap.add_argument('--sr', type=int, default=48000)
    args = ap.parse_args()

    a = model_args(args.build)
    tubes = make_set(args.build)
    tail = 6.0 if args.build == 'tube' else 4.0 if args.build == 'rod' else 0.8
    sr = args.sr
    mix = np.zeros(int(sr * (args.seconds + tail)))
    nu_c = 0.3
    ev = events(args.seconds, args.seed)
    print(f'{args.build}: {len(ev)} strikes, {sum(1 for e in ev if e[1] == "clash")} of them clashes')

    def add(x, t0):
        i0 = int(t0 * sr)
        n = min(len(x), len(mix) - i0)
        mix[i0:i0 + n] += x[:n]

    def strike_tube(target, striker_tube, v):
        """Render `target` struck by a wooden clapper (striker_tube None) or by another
        tube, at relative speed v. Returns the sound of the target alone."""
        tgt = tube_modes(target, a.strike, a.cord, a)
        if striker_tube is None:
            E_star = 1 / ((1 - nu_c ** 2) / a.clapper_E + (1 - target.nu ** 2) / target.E)
            k = hertz_k(E_star, math.sqrt(a.clapper_radius * target.Ro))
            stk = clapper_modes(a.clapper_mass)
        else:
            depth = (a.strike - a.cord) * target.L
            frac = min(0.95, max(0.05, a.cord + depth / striker_tube.L))
            E_star = target.E / (2 * (1 - target.nu ** 2))
            k = hertz_k(E_star, math.sqrt(target.Ro * striker_tube.Ro))
            stk = tube_modes(striker_tube, frac, a.cord, a)
        collide(stk, tgt, v, k, a.restitution)
        x, _ = render(tgt, sr, tail, a.tilt, target.Ro)
        return x

    for t, kind, i, j, v in ev:
        if kind == 'clapper':
            add(strike_tube(tubes[i], None, v), t)
        else:
            add(strike_tube(tubes[i], tubes[j], v), t)
            add(strike_tube(tubes[j], tubes[i], v), t + 0.0005)

    peak = np.abs(mix).max()
    gain = 10 ** (-1 / 20) / peak
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, f'passage_{args.build}.wav')
    write_wav(path, mix * gain, sr)
    print('wrote', path)


if __name__ == '__main__':
    main()

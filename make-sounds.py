#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""TurnOver's own sound set (17 Oct 2026: "a more interesting sound set for TurnOver, something fresher").

Synthesised here, no samples: soft plucked and glassy notes (FM synthesis with a decaying modulation index), little
wooden clicks, glides, and a short room around the longer sounds. Writes Resources/Sounds/<name>.wav (44.1 kHz, mono,
16-bit). Pure Python, so it runs anywhere: python3 make-sounds.py [out-folder]

Heard with speech, so: short, soft attacks, nothing harsh above 4 kHz, every sound under half a second, and each kind
of thing its own family (marimba for structure, kalimba for links and comments, glass for modes, wood for the
cursor, glides for in and out).
"""
import math, os, random, struct, sys, wave

SR = 44100
random.seed(17102026)   # the same files every run


def silence(seconds):
    return [0.0] * int(SR * seconds)


def mix(dst, src, at=0.0, gain=1.0):
    start = int(SR * at)
    need = start + len(src)
    if len(dst) < need:
        dst.extend([0.0] * (need - len(dst)))
    for i, v in enumerate(src):
        dst[start + i] += v * gain
    return dst


def fm(freq, dur, ratio=1.0, index=2.0, index_decay=0.05, decay=0.12, attack=0.003, bend=0.0, partial=0.0):
    """A plucked or struck note: carrier at freq, modulator at freq*ratio whose depth dies away (the "strike")."""
    n = int(SR * dur)
    out = []
    phase = mphase = 0.0
    for i in range(n):
        t = i / SR
        f = freq * (1.0 + bend * (1.0 - math.exp(-t / 0.03)))   # a slight bend at the start, then steady
        idx = index * math.exp(-t / index_decay)
        mphase += 2 * math.pi * f * ratio / SR
        phase += 2 * math.pi * f / SR
        v = math.sin(phase + idx * math.sin(mphase))
        if partial:
            v += partial * math.sin(2.76 * phase) * math.exp(-t / (decay / 3))   # a bar's inharmonic overtone
        env = math.exp(-t / decay)
        if t < attack:
            env *= t / attack
        out.append(v * env)
    return out


def glide(f0, f1, dur, decay=None, shape=2.0, harmonics=(1.0, 0.25)):
    """A pitch sweep from f0 to f1, eased, with a soft tail."""
    n = int(SR * dur)
    out = []
    phase = 0.0
    for i in range(n):
        x = i / max(1, n - 1)
        e = 1 - (1 - x) ** shape
        f = f0 * (f1 / f0) ** e
        phase += 2 * math.pi * f / SR
        v = sum(a * math.sin((k + 1) * phase) for k, a in enumerate(harmonics))
        env = math.sin(math.pi * min(1.0, x * 1.15)) if decay is None else math.exp(-i / SR / decay)
        if i < SR * 0.003:
            env *= i / (SR * 0.003)
        out.append(v * env)
    return out


def noise(dur, lowpass=0.3, highpass=0.0, decay=0.01, sweep=None):
    """A filtered noise burst: a click, a breath, a whoosh (sweep: the low-pass opening from a to b)."""
    n = int(SR * dur)
    out = []
    lp = hp_prev_in = hp_prev_out = 0.0
    for i in range(n):
        x = random.uniform(-1, 1)
        a = lowpass if sweep is None else sweep[0] + (sweep[1] - sweep[0]) * (i / n)
        lp += a * (x - lp)
        y = lp
        if highpass:
            hp = highpass * (hp_prev_out + y - hp_prev_in)
            hp_prev_in, hp_prev_out = y, hp
            y = hp
        env = math.exp(-i / SR / decay) if sweep is None else math.sin(math.pi * i / n) ** 2
        out.append(y * env)
    return out


def thud(f0, f1, dur, decay):
    """A soft knock: a low sine falling in pitch, with a breath of noise on the attack."""
    out = glide(f0, f1, dur, decay=decay, shape=1.0, harmonics=(1.0, 0.15))
    return mix(out, noise(0.012, lowpass=0.25, decay=0.004), 0, 0.35)


def room(sig, wet=0.18, tail=0.25):
    """A small, warm room: four damped combs and an all-pass (Schroeder), kept quiet so it never smears speech."""
    sig = sig + silence(tail)
    n = len(sig)
    combs = [(1116, 0.72), (1188, 0.70), (1277, 0.68), (1356, 0.66)]
    wet_sig = [0.0] * n
    for d, fb in combs:
        d = int(d * 0.6)   # a smaller room than Freeverb's
        buf = [0.0] * d
        idx = 0
        store = 0.0
        for i in range(n):
            y = buf[idx]
            store = y * 0.6 + store * 0.4   # damping
            buf[idx] = sig[i] + store * fb
            idx = (idx + 1) % d
            wet_sig[i] += y / len(combs)
    d = 225
    buf = [0.0] * d
    idx = 0
    for i in range(n):
        b = buf[idx]
        y = -wet_sig[i] + b
        buf[idx] = wet_sig[i] + b * 0.5
        idx = (idx + 1) % d
        wet_sig[i] = y
    return [s + w * wet for s, w in zip(sig, wet_sig)]


def finish(sig, peak):
    """Trim the silent tail, fade the last 5 ms, and scale to a set peak (each sound's loudness is chosen by ear)."""
    end = len(sig)
    while end > 0 and abs(sig[end - 1]) < 1e-4:
        end -= 1
    sig = sig[:end]
    fade = int(SR * 0.005)
    for i in range(min(fade, len(sig))):
        sig[len(sig) - 1 - i] *= i / fade
    m = max((abs(v) for v in sig), default=0) or 1.0
    return [v / m * peak for v in sig]


def write(folder, name, sig):
    path = os.path.join(folder, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in sig))


def notes(seq, spacing, **kw):
    out = []
    for k, f in enumerate(seq):
        mix(out, fm(f, kw.get("dur", 0.25), **{a: b for a, b in kw.items() if a != "dur"}), k * spacing)
    return out


# Instruments
def marimba(f, dur=0.22):  return fm(f, dur, ratio=4.0, index=1.6, index_decay=0.012, decay=0.07, partial=0.18)
def kalimba(f, dur=0.2):   return fm(f, dur, ratio=1.0, index=2.2, index_decay=0.02, decay=0.08, bend=0.006)
def glass(f, dur=0.4):     return fm(f, dur, ratio=3.5, index=1.2, index_decay=0.06, decay=0.16, attack=0.004)
def wood(f, dur=0.04):     return fm(f, dur, ratio=1.48, index=3.0, index_decay=0.004, decay=0.010, attack=0.0008)


SOUNDS = {}

def sound(name, peak):
    def deco(fn):
        SOUNDS[name] = (fn, peak)
        return fn
    return deco


# The cursor: wood
@sound("tick", 0.22)
def _(): return mix(wood(2200, 0.03), noise(0.006, lowpass=0.5, highpass=0.9, decay=0.0015), 0, 0.3)

@sound("press", 0.42)
def _(): return mix(thud(900, 520, 0.06, 0.018), wood(1600, 0.03), 0, 0.5)

@sound("edge", 0.5)
def _(): return thud(190, 120, 0.11, 0.035)

@sound("empty", 0.25)
def _(): return wood(330, 0.05)

@sound("secure", 0.18)
def _(): return wood(2800, 0.02)


# Structure: marimba, lower for deeper levels (a pentatonic run down from C6)
for lvl, f in enumerate([1046.5, 880.0, 784.0, 659.3, 587.3, 523.3], start=1):
    SOUNDS[f"heading{lvl}"] = ((lambda f=f: room(marimba(f), wet=0.12, tail=0.12)), 0.5)

@sound("list", 0.42)
def _(): return mix(marimba(1318.5, 0.08), marimba(1318.5, 0.1), 0.055)

@sound("table", 0.45)
def _(): return mix(marimba(392.0), marimba(587.3), 0.0, 0.6)

@sound("landmark", 0.45)
def _(): return room(mix(glass(1568.0, 0.3), glass(2349.3, 0.3), 0.04, 0.5), wet=0.2)

@sound("graphic", 0.3)
def _(): return room(notes([2093.0, 2637.0, 3136.0], 0.028, dur=0.08, ratio=3.5, index=0.8, index_decay=0.02, decay=0.03), wet=0.15, tail=0.1)

@sound("blockquote", 0.38)
def _(): return mix(marimba(523.3, 0.18), noise(0.12, lowpass=0.05, decay=0.05), 0, 0.15)


# Words: kalimba
@sound("link", 0.2)
def _(): return fm(1174.7, 0.06, ratio=1.0, index=0.9, index_decay=0.008, decay=0.022, attack=0.005, bend=0.006)   # shorter, then softer: quieter, lower, rounder (17 Oct)

@sound("spelling", 0.4)
def _():
    a = fm(311.1, 0.18, ratio=1.0, index=0.6, index_decay=0.05, decay=0.07)
    b = fm(323.0, 0.18, ratio=1.0, index=0.6, index_decay=0.05, decay=0.07)
    return mix(a, b)   # two notes a little apart: a soft wobble

@sound("comment", 0.4)
def _(): return mix(kalimba(987.8, 0.12), kalimba(1318.5, 0.16), 0.06)


# Modes: glass
@sound("focus_mode", 0.42)
def _(): return room(mix(glass(659.3, 0.18), glass(987.8, 0.25), 0.05), wet=0.15, tail=0.12)

@sound("browse_mode", 0.42)
def _(): return room(mix(glass(987.8, 0.18), glass(659.3, 0.25), 0.05), wet=0.15, tail=0.12)

@sound("quicknav_on", 0.4)
def _(): return mix(wood(1800, 0.03), glass(1318.5, 0.16), 0.02, 0.8)

@sound("quicknav_off", 0.4)
def _(): return mix(wood(1800, 0.03), glass(880.0, 0.16), 0.02, 0.8)

@sound("tracking_on", 0.4)
def _(): return room(mix(glide(600, 1200, 0.12), glass(1568.0, 0.18), 0.1, 0.6), wet=0.15, tail=0.12)

@sound("tracking_off", 0.4)
def _(): return room(mix(glide(1200, 600, 0.12), glass(784.0, 0.18), 0.1, 0.6), wet=0.15, tail=0.12)


# In and out: glides
@sound("drill_in", 0.38)
def _(): return glide(520, 880, 0.07)

@sound("drill_out", 0.38)
def _(): return glide(880, 520, 0.07)

@sound("popup", 0.4)
def _(): return mix(glide(330, 660, 0.06), kalimba(880.0, 0.1), 0.045, 0.5)

@sound("page_loaded", 0.38)
def _(): return room(mix(noise(0.22, sweep=(0.02, 0.35)), glass(1318.5, 0.3), 0.16, 1.4), wet=0.2)


# TurnOver itself: arpeggios with a room
@sound("startup", 0.45)
def _(): return room(notes([523.3, 659.3, 784.0, 1046.5], 0.075, dur=0.35, ratio=1.0, index=2.0, index_decay=0.02, decay=0.12), wet=0.22, tail=0.3)

@sound("take_over", 0.4)
def _(): return room(mix(kalimba(784.0, 0.15), kalimba(1174.7, 0.2), 0.065), wet=0.15, tail=0.15)

@sound("hand_back", 0.4)
def _(): return room(mix(kalimba(1174.7, 0.15), kalimba(784.0, 0.2), 0.065), wet=0.15, tail=0.15)

@sound("braille_on", 0.4)
def _(): return room(notes([523.3, 784.0, 1046.5], 0.07, dur=0.25, ratio=3.5, index=1.2, index_decay=0.05, decay=0.12), wet=0.2)

@sound("braille_off", 0.4)
def _(): return room(notes([1046.5, 784.0, 523.3], 0.07, dur=0.25, ratio=3.5, index=1.2, index_decay=0.05, decay=0.12), wet=0.2)

@sound("announcement", 0.42)
def _(): return room(mix(glass(1760.0, 0.35), glass(2637.0, 0.3), 0.0, 0.35), wet=0.25, tail=0.3)

@sound("done", 0.4)
def _(): return room(mix(marimba(880.0), marimba(1318.5), 0.07), wet=0.15, tail=0.15)

@sound("marked", 0.4)
def _(): return mix(wood(1200, 0.04), kalimba(1046.5, 0.12), 0.03, 0.8)


# Places (Waypoint, 25 Nov 2026): one cue for the kind of place the focus has entered, so the kind of interaction is
# known before the words. Edit fields use focus_mode and pages with Quick Nav use browse_mode, above. Each is short.
@sound("place_reading", 0.34)
def _(): return glass(523.3, 0.16)

@sound("place_list", 0.34)
def _(): return mix(mix(wood(1500, 0.03), wood(1200, 0.03), 0.04), wood(950, 0.03), 0.08)

@sound("place_menu", 0.4)
def _(): return mix(marimba(880.0, 0.1), marimba(587.3, 0.14), 0.055)

@sound("place_terminal", 0.4)
def _(): return mix(thud(160, 100, 0.1, 0.04), wood(820, 0.03), 0.03, 0.6)

@sound("place_secure", 0.3)
def _(): return mix(wood(430, 0.05), noise(0.05, lowpass=0.08, decay=0.02), 0, 0.4)

@sound("place_dialog", 0.4)
def _(): return mix(thud(280, 210, 0.06, 0.022), thud(280, 210, 0.06, 0.022), 0.085)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "Resources", "Sounds")
    os.makedirs(out, exist_ok=True)
    for name, (fn, peak) in SOUNDS.items():
        write(out, name, finish(fn(), peak))
    print(f"{len(SOUNDS)} sounds in {out}")

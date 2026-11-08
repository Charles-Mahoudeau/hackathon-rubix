#!/usr/bin/env python3
"""Synthesises every sound of the game into assets/audio/*.ogg (GR5-23). Standard library + ffmpeg (built-in Vorbis encoder: stereo only, so mono effects are written on both channels).

Deterministic: one seeded Random per sound, so a rebuild gives the same files. Run from anywhere:
    python3 tools/build_audio.py
The output is committed; run this only to change a sound. The result is original work (CC0), no third-party pack.
"""
import math
import os
import random
import struct
import subprocess
import tempfile
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "audio")
SR = 44100
MUSIC_SR = 32000
TARGET_RMS = 0.126  # about -18 dBFS: every effect has the same loudness, config/audio.luau sets the mix
PEAK_CAP = 0.95
TAU = 2 * math.pi


def tone(freq, dur, shape="sine", sr=SR):
    out = []
    for i in range(int(dur * sr)):
        p = (freq * i / sr) % 1.0
        if shape == "sine":
            v = math.sin(TAU * p)
        elif shape == "soft":  # sine + a little 3rd and 5th: a clean synth blip
            v = math.sin(TAU * p) + 0.25 * math.sin(3 * TAU * p) + 0.08 * math.sin(5 * TAU * p)
        elif shape == "square":
            v = 1.0 if p < 0.5 else -1.0
        elif shape == "tri":
            v = 4 * abs(p - 0.5) - 1
        else:
            v = 2 * p - 1
        out.append(v)
    return out


def env(n, attack, decay_rate, sr=SR):
    a = max(1, int(attack * sr))
    return [min(1.0, i / a) * math.exp(-decay_rate * i / sr) for i in range(n)]


def mul(a, b):
    return [x * y for x, y in zip(a, b)]


def mix(*tracks):
    n = max(len(t) for t in tracks)
    out = [0.0] * n
    for t in tracks:
        for i, v in enumerate(t):
            out[i] += v
    return out


def place(dst, src, at, sr=SR):
    start = int(at * sr)
    if start + len(src) > len(dst):
        dst.extend([0.0] * (start + len(src) - len(dst)))
    for i, v in enumerate(src):
        dst[start + i] += v


def fade_out(x, dur, sr=SR):
    n = min(len(x), int(dur * sr))
    for i in range(n):
        x[len(x) - n + i] *= i and (1 - i / n) or 1.0
    if n:
        x[-1] = 0.0
    return x


def note(freq, dur, shape="soft", attack=0.004, decay=18.0, sr=SR):
    t = tone(freq, dur, shape, sr)
    return fade_out(mul(t, env(len(t), attack, decay, sr)), 0.01, sr)


def normalise(x):
    rms = math.sqrt(sum(v * v for v in x) / len(x)) or 1.0
    peak = max(abs(v) for v in x) or 1.0
    k = min(TARGET_RMS / rms, PEAK_CAP / peak)
    return [v * k for v in x]


# ---- effects ---------------------------------------------------------------------------------------------------

def sfx_mine():
    rng = random.Random(1)
    n = int(0.14 * SR)
    noise = [rng.uniform(-1, 1) for _ in range(n)]
    lp, prev = [], 0.0
    for v in noise:  # one-pole low-pass: a dull rock tick, not a hiss
        prev += 0.35 * (v - prev)
        lp.append(prev)
    return mix(mul(lp, env(n, 0.001, 38)), [0.8 * v for v in note(170, 0.14, "sine", 0.002, 30)])


def sfx_sell():
    out = []
    place(out, note(880, 0.09, "soft", decay=22), 0.0)
    place(out, note(1318.5, 0.16, "soft", decay=14), 0.07)
    return out


def sfx_scan():
    n = int(0.42 * SR)
    out, phase = [], 0.0
    for i in range(n):
        t = i / n
        phase += (420 + 1500 * t * t) / SR
        out.append(math.sin(TAU * phase) * math.sin(math.pi * t) ** 0.7)
    ping = note(1760, 0.3, "sine", 0.002, 12)
    place(out, [0.5 * v for v in ping], 0.34)
    return out


def sfx_confirm():
    return note(660, 0.07, "soft", decay=30)


def sfx_click():
    # A UI button press (GR5-53): a very short, high tick, quieter and shorter than confirm so it never masks a tool cue.
    return mix(note(1250, 0.04, "soft", 0.001, 60), [0.5 * v for v in note(620, 0.05, "soft", 0.001, 50)])


def sfx_error():
    # 0.35 s, the length of the glitch flicker (config/vfx.luau glitch.duration): detuned buzz, bit-crushed, gated.
    rng = random.Random(7)
    dur = 0.35
    n = int(dur * SR)
    a, b = tone(110, dur, "square"), tone(117.5, dur, "square")
    out, held = [], 0.0
    for i in range(n):
        if i % 6 == 0:  # sample-rate reduction
            held = round((a[i] + b[i] + rng.uniform(-0.6, 0.6)) * 3) / 3
        out.append(held)
    gate = [1.0 if (int(i / (0.035 * SR)) % 3) != 2 else 0.15 for i in range(n)]  # stutter, like the frame-hold
    e = [(1 - i / n) ** 1.3 for i in range(n)]
    return fade_out(mul(mul(out, gate), e), 0.01)


def sfx_purchase():
    out = []
    for k, f in enumerate((523.25, 659.25, 783.99, 1046.5)):
        place(out, note(f, 0.18, "soft", decay=11), 0.055 * k)
    return out


def sfx_mission():
    out = []
    for k, f in enumerate((523.25, 659.25, 783.99)):
        place(out, note(f, 0.9, "soft", attack=0.01, decay=3.2), 0.09 * k)
    place(out, note(1046.5, 0.8, "tri", attack=0.01, decay=3.5), 0.3)
    return out


def sfx_tier_up():
    n = int(0.7 * SR)
    sweep, phase = [], 0.0
    for i in range(n):
        t = i / n
        phase += (180 + 700 * t) / SR
        sweep.append(math.sin(TAU * phase) * min(1.0, t * 6) * (1 - t * 0.3))
    out = list(sweep)
    for f in (392.0, 523.25, 783.99):
        place(out, note(f, 1.1, "soft", attack=0.01, decay=2.6), 0.62)
    return fade_out(out, 0.05)


def sfx_alert():
    out = []
    for k in range(2):
        place(out, note(880, 0.13, "square", attack=0.003, decay=9), 0.22 * k)
        place(out, note(622.25, 0.13, "square", attack=0.003, decay=9), 0.22 * k + 0.11)
    return [0.6 * v for v in out]


def sfx_raid():
    rng = random.Random(3)
    n = int(0.32 * SR)
    noise, prev = [], 0.0
    for _ in range(n):
        prev += 0.18 * (rng.uniform(-1, 1) - prev)
        noise.append(prev)
    thump = note(70, 0.32, "sine", 0.002, 9)
    return mix(mul(noise, env(n, 0.001, 14)), [1.6 * v for v in thump])


EFFECTS = {
    "mine": sfx_mine, "sell": sfx_sell, "scan": sfx_scan, "confirm": sfx_confirm, "click": sfx_click, "error": sfx_error,
    "purchase": sfx_purchase, "mission": sfx_mission, "tier_up": sfx_tier_up, "alert": sfx_alert, "raid": sfx_raid,
}


# ---- music -----------------------------------------------------------------------------------------------------

def hz(semitones_from_a4):
    return 440.0 * 2 ** (semitones_from_a4 / 12)


def music():
    """A 40 s loop in A minor: slow pads, a sine bass, a sparse pentatonic pluck, a soft echo. Everything lives on a
    circular buffer (a note running past the end wraps to the start), so the loop point has no seam."""
    rng = random.Random(2024)
    loop = 40.0
    n = int(loop * MUSIC_SR)
    left, right = [0.0] * n, [0.0] * n

    # Am9 / Fmaj7 / Cadd9 / Gsus2, ten seconds each. Semitones from A4.
    chords = [
        {"root": -36, "tones": [-24, -21, -17, -13]},
        {"root": -40, "tones": [-28, -24, -21, -17]},
        {"root": -33, "tones": [-21, -17, -14, -9]},
        {"root": -38, "tones": [-26, -19, -17, -14]},
    ]

    def add(buf, freq, start, length, shape_fn, gain):
        s0 = int(start * MUSIC_SR)
        for i in range(int(length * MUSIC_SR)):
            buf[(s0 + i) % n] += gain * shape_fn(i / MUSIC_SR)

    for c, chord in enumerate(chords):
        start = c * 10.0 - 2.0
        for k, semi in enumerate(chord["tones"]):
            f = hz(semi)
            pan = (k / (len(chord["tones"]) - 1)) if len(chord["tones"]) > 1 else 0.5
            for detune, ch_gain in ((-0.0015, 1 - pan), (0.0015, pan)):
                ff = f * (1 + detune)
                buf = left if detune < 0 else right

                def pad(t, ff=ff):
                    e = math.sin(math.pi * min(1.0, t / 14.0)) ** 2  # swells over 14 s, so chords overlap
                    return e * (math.sin(TAU * ff * t) + 0.3 * math.sin(TAU * 2 * ff * t) + 0.1 * math.sin(TAU * 3 * ff * t))

                add(buf, ff, start, 14.0, pad, 0.045 * (0.4 + ch_gain))
        fb = hz(chord["root"] - 12)

        def bass(t, fb=fb):
            e = math.sin(math.pi * min(1.0, t / 13.0)) ** 1.5
            return e * math.sin(TAU * fb * t)

        add(left, fb, start, 13.0, bass, 0.10)
        add(right, fb, start, 13.0, bass, 0.10)

    pent = [0, 3, 5, 7, 10]  # A minor pentatonic
    step = 0.625
    for s in range(int(loop / step)):
        if rng.random() > 0.42:
            continue
        semi = rng.choice(pent) + 12 * rng.choice((0, 0, 1))
        f = hz(semi)
        pan = rng.uniform(0.2, 0.8)
        gain = 0.07 * rng.uniform(0.6, 1.0)

        def pluck(t, f=f):
            return math.exp(-2.2 * t) * (math.sin(TAU * f * t) + 0.18 * math.sin(TAU * 2 * f * t))

        add(left, f, s * step, 2.4, pluck, gain * (1 - pan))
        add(right, f, s * step, 2.4, pluck, gain * pan)

    # circular echo, a dotted-eighth feel: the taps wrap around the loop
    d = int(0.46875 * MUSIC_SR)
    for buf in (left, right):
        src = list(buf)
        for tap, g in ((1, 0.32), (2, 0.18), (3, 0.09)):
            shift = (d * tap) % n
            for i in range(n):
                buf[i] += g * src[i - shift]
    # swap the echo's sides for width
    left2 = [left[i] + 0.15 * right[i - d % n] for i in range(n)]
    right2 = [right[i] + 0.15 * left[i - d % n] for i in range(n)]
    peak = max(max(abs(v) for v in left2), max(abs(v) for v in right2))
    k = 0.7 / peak
    return [v * k for v in left2], [v * k for v in right2]


# ---- output ----------------------------------------------------------------------------------------------------

def write_ogg(path, channels, sr, kbps):
    n = len(channels[0])
    with tempfile.TemporaryDirectory() as tmp:
        wav_path = os.path.join(tmp, "x.wav")
        with wave.open(wav_path, "wb") as w:
            w.setnchannels(len(channels))
            w.setsampwidth(2)
            w.setframerate(sr)
            frames = bytearray()
            for i in range(n):
                for ch in channels:
                    frames += struct.pack("<h", max(-32767, min(32767, int(ch[i] * 32767))))
            w.writeframes(bytes(frames))
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path, "-c:a", "vorbis", "-strict", "-2", "-b:a", "%dk" % kbps,
                        "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", path], check=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, fn in EFFECTS.items():
        x = normalise(fn())
        write_ogg(os.path.join(OUT, "sfx_%s.ogg" % name), [x, x], SR, 64)
        print("sfx_%s.ogg  %.2f s" % (name, len(x) / SR))
    left, right = music()
    write_ogg(os.path.join(OUT, "music_ambient.ogg"), [left, right], MUSIC_SR, 112)
    print("music_ambient.ogg  %.1f s" % (len(left) / MUSIC_SR))


if __name__ == "__main__":
    main()

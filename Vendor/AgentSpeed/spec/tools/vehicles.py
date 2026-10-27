#!/usr/bin/env python3
"""Validate and render the hero-orb vehicle art (spec/assets/vehicles.json, DESIGN section 4c).

  python3 spec/tools/vehicles.py                  # validate only
  python3 spec/tools/vehicles.py --export         # validate, then write spec/assets/vehicles/*.svg (generated)
  python3 spec/tools/vehicles.py --preview DIR    # validate, then render PNG previews into DIR (needs rsvg-convert)

The JSON is the source of truth; every SVG under spec/assets/vehicles/ is generated from it. Only the Python
standard library is used. PNG previews show each vehicle at its title threshold inside a 112 pt orb mock (@2x) in
both appearances, plus contact sheets.
"""
import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "assets", "vehicles.json")
EXPORT_DIR = os.path.join(ROOT, "assets", "vehicles")

LADDER = ["walk", "bicycle", "ebike", "motorcycle", "car", "sportsCar", "bulletTrain", "raceCar", "maglev",
          "jetliner", "fighterJet", "hypersonic", "rocket"]
# Title thresholds as a fraction of the redline (DESIGN section 1); walk is 0.5 tok/s, i.e. 0.00125 R at R = 400.
THRESHOLDS = [0.00125, 0.02, 0.03, 0.04, 0.06, 0.08, 0.12, 0.17, 0.24, 0.34, 0.5, 0.7, 1.0]
NAMES = ["步行", "自行車", "電動自行車", "摩托車", "汽車", "跑車", "高鐵", "賽車", "磁浮列車", "噴射客機", "戰鬥機",
         "極音速飛機", "火箭"]
ROLES = {"body", "detail", "window", "wheel", "rim", "spoke", "crank", "rider", "light", "glow", "shock", "flame",
         "flameCore"}
FILL_ROLES = {"flame", "flameCore"}
EMITTERS = {"dust", "arc", "exhaust", "trail", "sparks", "contrail", "afterburner", "plume"}
SCENERY = {"road", "rail", "guideway", "sky", "stratosphere", "space"}
PART_KEYS = {"id", "role", "d", "circle", "spin", "sprung", "bleed", "nozzle"}
VEHICLE_KEYS = {"key", "scenery", "groundY", "heading", "motion", "rig", "parts", "emitters"}
MOTION_KEYS = {"speed", "rest", "bob", "float", "hover"}
GROUNDED = {"road", "rail", "guideway"}
COMMAND_ARITY = {"M": 2, "L": 2, "C": 6, "Q": 4, "Z": 0}
NUMBER = re.compile(r"^-?\d+(\.\d{1,2})?$")
CANVAS = 100.0

HEAT_STOPS = [(0.00, 0x7C8798), (0.10, 0x2DD4BF), (0.30, 0x38BDF8), (0.48, 0x818CF8), (0.64, 0xE879F9),
              (0.78, 0xFB7185), (0.90, 0xFB923C), (1.00, 0xFACC15)]
WHITE_HOT = 0xFFF7D6
AMBER_HOT = 0xFFB020
SOURCE_DOTS = [0x34D399, 0xFF8A65, 0xB39DFF]


class SpecError(Exception):
    pass


# ---------------------------------------------------------------- paths


def parse_path(d, where):
    """Strict grammar: absolute M/L/C/Q/Z, single spaces, numbers with at most two decimals."""
    if not isinstance(d, str) or not d or d != d.strip() or "  " in d:
        raise SpecError("%s: path must be a trimmed, single-space separated string" % where)
    toks = d.split(" ")
    segs = []
    i = 0
    started = False
    while i < len(toks):
        cmd = toks[i]
        if cmd not in COMMAND_ARITY:
            raise SpecError("%s: unsupported token %r (only M L C Q Z)" % (where, cmd))
        arity = COMMAND_ARITY[cmd]
        args = toks[i + 1:i + 1 + arity]
        if len(args) != arity or any(not NUMBER.match(a) for a in args):
            raise SpecError("%s: bad arguments for %s near token %d" % (where, cmd, i))
        if not started and cmd != "M":
            raise SpecError("%s: path must start with M" % where)
        started = True
        segs.append((cmd, [float(a) for a in args]))
        i += 1 + arity
    return segs


def sample_path(segs, steps=12):
    pts = []
    cur = start = (0.0, 0.0)
    for cmd, a in segs:
        if cmd == "M":
            cur = start = (a[0], a[1])
            pts.append(cur)
        elif cmd == "L":
            cur = (a[0], a[1])
            pts.append(cur)
        elif cmd == "Q":
            p0, p1, p2 = cur, (a[0], a[1]), (a[2], a[3])
            for k in range(1, steps + 1):
                t = k / float(steps)
                u = 1 - t
                pts.append((u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
                            u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]))
            cur = p2
        elif cmd == "C":
            p0, p1, p2, p3 = cur, (a[0], a[1]), (a[2], a[3]), (a[4], a[5])
            for k in range(1, steps + 1):
                t = k / float(steps)
                u = 1 - t
                pts.append((u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                            u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]))
            cur = p3
        elif cmd == "Z":
            cur = start
            pts.append(cur)
    return pts


def circle_points(c):
    cx, cy, r = c
    return [(cx + r * math.cos(a * math.pi / 18), cy + r * math.sin(a * math.pi / 18)) for a in range(36)]


def fmt(v):
    v = round(v, 2)
    if v == int(v):
        return str(int(v))
    return ("%.2f" % v).rstrip("0").rstrip(".")


def polyline_d(points):
    return "M " + " L ".join("%s %s" % (fmt(x), fmt(y)) for x, y in points)


# ---------------------------------------------------------------- color


def _lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _gam(c):
    c = min(1.0, max(0.0, c))
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def hex_rgb(h):
    return ((h >> 16) & 255) / 255.0, ((h >> 8) & 255) / 255.0, (h & 255) / 255.0


def to_oklab(rgb):
    r, g, b = (_lin(c) for c in rgb)
    l_ = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3.0)
    m_ = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3.0)
    s_ = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3.0)
    return (0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)


def from_oklab(lab):
    L, a, b = lab
    l_ = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m_ = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s_ = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    return (_gam(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_),
            _gam(-1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_),
            _gam(-0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_))


def mix(c0, c1, t):
    a, b = to_oklab(c0), to_oklab(c1)
    return from_oklab(tuple(a[i] + (b[i] - a[i]) * t for i in range(3)))


def heat_color(h):
    h = min(1.0, max(0.0, h))
    for i in range(1, len(HEAT_STOPS)):
        h1, c1 = HEAT_STOPS[i]
        if h <= h1:
            h0, c0 = HEAT_STOPS[i - 1]
            return mix(hex_rgb(c0), hex_rgb(c1), (h - h0) / (h1 - h0))
    return hex_rgb(HEAT_STOPS[-1][1])


def darkened(rgb, amount):
    L, a, b = to_oklab(rgb)
    return from_oklab((L * (1 - amount), a, b))


def luminance(rgb):
    r, g, b = (_lin(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(c0, c1):
    l0, l1 = luminance(c0), luminance(c1)
    return (max(l0, l1) + 0.05) / (min(l0, l1) + 0.05)


def legible(rgb, dark, minimum):
    """DashboardPalette.legible: step OKLab L until the color reaches the contrast target on the popover."""
    surface = hex_rgb(0x3A3A3A if dark else 0xE6E6E6)
    L, a, b = to_oklab(rgb)
    cand = rgb
    for _ in range(40):
        if contrast(cand, surface) >= minimum:
            return cand
        L = min(1.0, max(0.0, L + (0.015 if dark else -0.015)))
        cand = from_oklab((L, a, b))
    return cand


def stroke_color(h, dark):
    """DESIGN 4c: dark = heat color; light = the title label color (darkened 18 %, then ≥ 4.5:1)."""
    if dark:
        return heat_color(h)
    return legible(darkened(heat_color(h), 0.18), False, 4.5)


def hot_color(h, dark, amount=0.65):
    if dark:
        return mix(heat_color(h), hex_rgb(WHITE_HOT), amount)
    return mix(stroke_color(h, False), hex_rgb(AMBER_HOT), 0.45)


def css(rgb):
    return "#%02X%02X%02X" % tuple(int(round(min(1, max(0, c)) * 255)) for c in rgb)


def heat_for(fraction):
    return min(1.0, fraction ** 0.6)


# ---------------------------------------------------------------- rigs


def solve_knee(hip, foot, l1, l2):
    """Two-bone IK; the knee/elbow lies on the +x side (cross(foot - hip, knee - hip) < 0 in y-down space)."""
    dx, dy = foot[0] - hip[0], foot[1] - hip[1]
    d = math.hypot(dx, dy)
    reach = l1 + l2 - 1e-3
    stretched = d > reach
    d = min(max(d, abs(l1 - l2) + 1e-3, 1e-3), reach)
    base = math.atan2(dy, dx)
    cos_a = (l1 * l1 + d * d - l2 * l2) / (2 * l1 * d)
    alpha = math.acos(max(-1.0, min(1.0, cos_a)))
    best = None
    for sign in (1, -1):
        ang = base + sign * alpha
        knee = (hip[0] + l1 * math.cos(ang), hip[1] + l1 * math.sin(ang))
        cross = dx * (knee[1] - hip[1]) - dy * (knee[0] - hip[0])
        if cross < 0:
            best = knee
    return best, stretched


def smoothstep(t):
    t = min(1.0, max(0.0, t))
    return t * t * (3 - 2 * t)


def walk_rig(rig, distance, ground, stand=False):
    """Returns (far strokes, near strokes, circles) for the walker at a ground distance."""
    p = (distance / rig["cycle"]) % 1.0
    stance = rig["stance"]
    a = rig["cycle"] * stance / 2.0
    bob = 0.0 if stand else -rig["bob"] * math.cos(4 * math.pi * (p - stance / 2.0))
    stand_hip = ground - 0.6 - (rig["thigh"] + rig["shin"]) * 0.97
    hip = (rig["hip"][0], stand_hip if stand else rig["hip"][1] + bob)
    shoulder = (hip[0] + rig["torso"][0], hip[1] + rig["torso"][1])
    head = (shoulder[0] + rig["head"][0], shoulder[1] + rig["head"][1], rig["head"][2])
    issues = []

    def leg(phase, spread):
        if stand:
            fx, fy = hip[0] + spread, ground - 0.6
        elif phase < stance:
            fx, fy = hip[0] + a - 2 * a * (phase / stance), ground - 0.6
        else:
            s = (phase - stance) / (1 - stance)
            fx = hip[0] - a + 2 * a * smoothstep(s)
            fy = ground - 0.6 - rig["lift"] * math.sin(math.pi * s)
        knee, stretched = solve_knee(hip, (fx, fy), rig["thigh"], rig["shin"])
        if stretched:
            issues.append("leg overextended at phase %.2f" % phase)
        toe = (fx + rig["foot"], fy)
        return [hip, knee, (fx, fy), toe]

    def arm(phase, rest):
        theta = math.radians(rest if stand else -rig["armSwing"] * math.cos(2 * math.pi * phase))
        elbow = (shoulder[0] + rig["upperArm"] * math.sin(theta), shoulder[1] + rig["upperArm"] * math.cos(theta))
        t2 = theta + math.radians(rig["elbow"] * (0.5 if stand else 1.0))
        hand = (elbow[0] + rig["forearm"] * math.sin(t2), elbow[1] + rig["forearm"] * math.cos(t2))
        return [shoulder, elbow, hand]

    far = [("riderFar", leg((p + 0.5) % 1.0, -1.6)), ("riderFar", arm((p + 0.5) % 1.0, -4))]
    near = [("rider", [hip, shoulder]), ("rider", leg(p, 1.6)), ("rider", arm(p, 4))]
    return far, near, [("rider", head)], issues


def pedal_rig(rig, distance):
    crank = rig["crank"]
    phi = distance / crank["radius"]
    px, py = crank["pivot"]
    L = crank["length"]
    near_pedal = (px - L * math.sin(phi), py + L * math.cos(phi))
    far_pedal = (px + L * math.sin(phi), py - L * math.cos(phi))
    bob = rig["bob"] * math.cos(2 * phi)
    hip = (rig["hip"][0], rig["hip"][1] + bob)
    issues = []

    def leg(pedal):
        knee, stretched = solve_knee(hip, pedal, rig["thigh"], rig["shin"])
        if stretched:
            issues.append("leg overextended at crank %.0f°" % (math.degrees(phi) % 360))
        half = rig["pedal"] / 2.0
        return [hip, knee, pedal], [(pedal[0] - half, pedal[1]), (pedal[0] + half, pedal[1])]

    near_leg, near_pd = leg(near_pedal)
    far_leg, far_pd = leg(far_pedal)
    far = [("riderFar", far_leg), ("riderFar", far_pd)]
    near = [("rider", near_leg), ("crank", near_pd)]
    return far, near, bob, issues


# ---------------------------------------------------------------- validation


def require(cond, msg):
    if not cond:
        raise SpecError(msg)


def point_ok(pt):
    return isinstance(pt, list) and len(pt) == 2 and all(isinstance(v, (int, float)) for v in pt)


def validate(data):
    """Raises SpecError listing every problem; returns warnings."""
    warnings = []
    errors = []

    def check(cond, msg):
        if not cond:
            errors.append(msg)

    require(data.get("version") == 1, "version must be 1")
    canvas = data.get("canvas", {})
    require(canvas.get("width") == 100 and canvas.get("height") == 100, "canvas must be 100 × 100")
    require(0 < canvas.get("orbFraction", 0) < 0.775, "canvas.orbFraction must keep the canvas inside the gauge")
    safe = data["safeCircle"]
    mask = data["mask"]
    require(mask["solid"] < mask["clear"] <= 50, "mask radii must satisfy solid < clear ≤ 50")
    require(safe["r"] <= mask["solid"], "the safe circle must sit inside the mask's opaque zone")
    # Fully transparent before the agent dots (0.3785 S) and the gauge segments (0.3875 S), with a 0.02 S margin.
    reach = mask["clear"] / 100.0 * canvas["orbFraction"]
    require(reach <= 0.3585, "mask clear radius reaches %.4f S, into the agent dots / gauge" % reach)
    base = data["stroke"]["width"]
    require(data["stroke"].get("cap") == "round" and data["stroke"].get("join") == "round", "round caps and joins")
    roles = data["roles"]
    require(set(roles) == ROLES, "roles must be exactly %s" % sorted(ROLES))
    for name, role in roles.items():
        require("fill" not in role or name in FILL_ROLES, "role %s may not fill" % name)
    scen = data["scenery"]
    require(set(scen) == SCENERY, "scenery must be exactly %s" % sorted(SCENERY))
    for cloud in scen["sky"]["clouds"]:
        parse_path(cloud, "scenery.sky.cloud")
    keys = [v.get("key") for v in data["vehicles"]]
    require(keys == LADDER, "vehicles must follow the title ladder: %s" % LADDER)
    cx, cy, r = safe["cx"], safe["cy"], safe["r"]
    previous_hi = 0
    for v in data["vehicles"]:
        key = v["key"]
        require(v.get("scenery") in SCENERY, "%s: unknown scenery" % key)
        require(set(v) <= VEHICLE_KEYS, "%s: unknown keys %s" % (key, sorted(set(v) - VEHICLE_KEYS)))
        ground = v.get("groundY")
        require((ground is not None) == (v["scenery"] in GROUNDED), "%s: groundY is required exactly for road, rail and "
                "guideway scenery" % key)
        require(ground is None or 50 < ground < 88, "%s: groundY out of range" % key)
        motion = v["motion"]
        require(set(motion) <= MOTION_KEYS, "%s: unknown motion keys %s" % (key, sorted(set(motion) - MOTION_KEYS)))
        require("heading" not in v or isinstance(v["heading"], (int, float)), "%s: heading is degrees" % key)
        lo, hi = motion["speed"]
        require(0 < lo < hi, "%s: motion.speed must be an increasing pair" % key)
        require(lo >= previous_hi, "%s: speed range must start at or above the previous title's top" % key)
        previous_hi = hi
        ids = set()
        for p in v["parts"]:
            where = "%s.%s" % (key, p.get("id"))
            require(set(p) <= PART_KEYS, "%s: unknown keys %s" % (where, sorted(set(p) - PART_KEYS)))
            require(p.get("id") and p["id"] not in ids, "%s: missing or duplicate id" % where)
            ids.add(p["id"])
            require(p.get("role") in ROLES, "%s: unknown role" % where)
            require(("d" in p) != ("circle" in p), "%s: exactly one of d / circle" % where)
            if "d" in p:
                pts = sample_path(parse_path(p["d"], where))
            else:
                c = p["circle"]
                require(len(c) == 3 and c[2] > 0, "%s: circle is [cx, cy, r]" % where)
                pts = circle_points(c)
            if p["role"] in FILL_ROLES:
                require("d" in p and p["d"].endswith("Z"), "%s: filled flame shapes must be closed paths" % where)
                require("nozzle" in p, "%s: flames need a nozzle (at, dir)" % where)
            if "nozzle" in p:
                nz = p["nozzle"]
                require(point_ok(nz.get("at")) and point_ok(nz.get("dir")), "%s: nozzle needs at and dir" % where)
                require(abs(math.hypot(*nz["dir"]) - 1) < 0.02, "%s: nozzle.dir must be a unit vector" % where)
            half = base * roles[p["role"]]["weight"] / 2.0
            if "spin" in p:
                s = p["spin"]
                require(point_ok(s.get("pivot")) and s.get("radius", 0) > 0, "%s: spin needs pivot and radius" % where)
                reach = max(math.hypot(x - s["pivot"][0], y - s["pivot"][1]) for x, y in pts)
                far = math.hypot(s["pivot"][0] - cx, s["pivot"][1] - cy) + reach + half
                check(far <= r + 1e-6, "%s: spinning part leaves the safe circle (%.2f > %s)" % (where, far, r))
            if p.get("bleed"):
                check(all(-0.01 <= x <= CANVAS + 0.01 and -0.01 <= y <= CANVAS + 0.01 for x, y in pts),
                      "%s: bleed part leaves the canvas" % where)
                if p["role"] == "body":
                    front = [math.hypot(x - cx, y - cy) for x, y in pts if x > 45]
                    worst = max(front) + half if front else 0
                    check(worst <= r + 1e-6, "%s: the leading half of a bleeding body leaves the safe circle (%.2f)"
                          % (where, worst))
            else:
                worst = max(math.hypot(x - cx, y - cy) for x, y in pts) + half
                check(worst <= r + 1e-6, "%s: outside the safe circle (%.2f > %s)" % (where, worst, r))
        rig = v.get("rig")
        if rig:
            samples = 48
            if rig["type"] == "walk":
                far, near, circles, _ = walk_rig(rig, 0, ground, stand=True)
                for _, pts in far + near:
                    worst = max(math.hypot(x - cx, y - cy) for x, y in pts) + base / 2.0
                    check(worst <= r + 1e-6, "%s: standing pose leaves the safe circle (%.2f)" % (key, worst))
                for _, c in circles:
                    worst = math.hypot(c[0] - cx, c[1] - cy) + c[2] + base / 2.0
                    check(worst <= r + 1e-6, "%s: standing head leaves the safe circle (%.2f)" % (key, worst))
            for k in range(samples):
                if rig["type"] == "walk":
                    dist = rig["cycle"] * k / float(samples)
                    far, near, circles, issues = walk_rig(rig, dist, ground)
                    strokes = far + near
                    circs = [c for _, c in circles]
                elif rig["type"] == "pedal":
                    dist = 2 * math.pi * rig["crank"]["radius"] * k / float(samples)
                    far, near, _, issues = pedal_rig(rig, dist)
                    strokes = far + near
                    circs = []
                else:
                    raise SpecError("%s: unknown rig type" % key)
                if issues:
                    errors.append("%s: %s" % (key, issues[0]))
                for _, pts in strokes:
                    worst = max(math.hypot(x - cx, y - cy) for x, y in pts) + base / 2.0
                    check(worst <= r + 1e-6, "%s: rig pose leaves the safe circle (%.2f)" % (key, worst))
                for c in circs:
                    worst = math.hypot(c[0] - cx, c[1] - cy) + c[2] + base / 2.0
                    check(worst <= r + 1e-6, "%s: rig head leaves the safe circle (%.2f)" % (key, worst))
        for e in v.get("emitters", []):
            where = "%s.emitter.%s" % (key, e.get("id"))
            require(e.get("type") in EMITTERS, "%s: unknown emitter type" % where)
            require(point_ok(e.get("at")) and point_ok(e.get("dir")), "%s: emitter needs at and dir" % where)
            require(0 <= e["at"][0] <= CANVAS and 0 <= e["at"][1] <= CANVAS, "%s: emitter outside canvas" % where)
            length = math.hypot(*e["dir"])
            require(length == 0 or abs(length - 1) < 0.02, "%s: dir must be a unit vector (or 0 for radial)" % where)
        if v["scenery"] == "road" and key != "walk":
            wheels = [p for p in v["parts"] if p["role"] == "wheel"]
            for w in wheels:
                bottom = w["circle"][1] + w["circle"][2]
                check(abs(bottom - ground) < 0.05, "%s.%s: tire must touch the road (%.2f)" % (key, w["id"], bottom))
    idle = data["idle"]
    require(idle.get("vehicle") == "last" and idle.get("fallback") in LADDER, "idle must name last + a fallback")
    seen = []
    for e in errors:
        if e not in seen:
            seen.append(e)
    if seen:
        raise SpecError("%d problem(s):\n  " % len(seen) + "\n  ".join(seen))
    return warnings


# ---------------------------------------------------------------- rendering


def role_style(data, role, color, hot, opacity_scale=1.0, glow=False):
    spec = data["roles"].get(role) or data["roles"]["rider"]
    if role == "riderFar":
        spec = dict(data["roles"]["rider"], opacity=0.42, glow=0.3)
    width = data["stroke"]["width"] * spec["weight"]
    alpha = spec["opacity"] * opacity_scale
    if glow:
        alpha = min(1.0, spec["glow"] * opacity_scale)
    paint = hot if spec.get("color") == "hot" else color
    if "fill" in spec:
        fill_paint = hot if spec["fill"] == "hot" else color
        stroke = 'stroke="%s" stroke-width="%s"' % (css(paint), fmt(width)) if width > 0 else 'stroke="none"'
        return '%s fill="%s" fill-opacity="%s" opacity="%s"' % (stroke, css(fill_paint), fmt(spec["fillOpacity"]),
                                                               fmt(alpha))
    return 'fill="none" stroke="%s" stroke-width="%s" opacity="%s"' % (css(paint), fmt(width), fmt(alpha))


def vehicle_elements(data, v, color, hot, distance=None, glow=False, flames=True, opacity=1.0, stand=False):
    out = []
    if distance is None:
        distance = v["motion"].get("rest", 0)
    rig = v.get("rig")
    far, near, circles, bob = [], [], [], 0.0
    ground = v.get("groundY")
    if rig and rig["type"] == "walk":
        far, near, circles, _ = walk_rig(rig, distance, ground, stand=stand)
    elif rig and rig["type"] == "pedal":
        far, near, bob, _ = pedal_rig(rig, distance)

    def stroke(role, d):
        out.append('<path d="%s" %s/>' % (d, role_style(data, role, color, hot, opacity, glow)))

    for role, pts in far:
        stroke(role, polyline_d(pts))
    for p in v["parts"]:
        if p["role"] in ("flame", "flameCore") and not flames:
            continue
        style = role_style(data, p["role"], color, hot, opacity, glow)
        transform = ""
        if "spin" in p and distance:
            ang = math.degrees(distance / p["spin"]["radius"])
            px, py = p["spin"]["pivot"]
            transform = ' transform="rotate(%s %s %s)"' % (fmt(ang), fmt(px), fmt(py))
        elif p["role"] == "rider" and bob:
            transform = ' transform="translate(0 %s)"' % fmt(bob)
        if "d" in p:
            out.append('<path d="%s" %s%s/>' % (p["d"], style, transform))
        else:
            c = p["circle"]
            out.append('<circle cx="%s" cy="%s" r="%s" %s%s/>' % (fmt(c[0]), fmt(c[1]), fmt(c[2]), style, transform))
    for role, pts in near:
        stroke(role, polyline_d(pts))
    for role, c in circles:
        out.append('<circle cx="%s" cy="%s" r="%s" %s/>' % (fmt(c[0]), fmt(c[1]), fmt(c[2]),
                                                          role_style(data, role, color, hot, opacity, glow)))
    return out


def scenery_elements(data, v, color, heat, dark):
    sc = data["scenery"]
    kind = v["scenery"]
    out = []
    a = 0.30 if dark else 0.34
    w = data["stroke"]["width"]
    c = css(color)
    if kind == "road":
        y = v["groundY"]
        dash, gap = sc["road"]["dash"]
        out.append('<path d="M 0 %s L 100 %s" stroke="%s" stroke-width="%s" stroke-dasharray="%s %s" opacity="%s" '
                   'fill="none"/>' % (fmt(y), fmt(y), c, fmt(w * 0.55), fmt(dash), fmt(gap), fmt(a)))
    elif kind == "rail":
        y = v["groundY"]
        sp, depth = sc["rail"]["sleeperSpacing"], sc["rail"]["sleeperDepth"]
        out.append('<path d="M 0 %s L 100 %s" stroke="%s" stroke-width="%s" opacity="%s" fill="none"/>'
                   % (fmt(y), fmt(y), c, fmt(w * 0.55), fmt(a * 1.3)))
        ticks = " ".join("M %s %s L %s %s" % (fmt(x), fmt(y + 1.4), fmt(x - 1.2), fmt(y + 1.4 + depth))
                         for x in [i * sp + 4 for i in range(12)])
        out.append('<path d="%s" stroke="%s" stroke-width="%s" opacity="%s" fill="none"/>'
                   % (ticks, c, fmt(w * 0.5), fmt(a)))
    elif kind == "guideway":
        g = sc["guideway"]
        y = v["groundY"]
        out.append('<path d="M 0 %s L 100 %s M 0 %s L 100 %s" stroke="%s" stroke-width="%s" opacity="%s" fill="none"/>'
                   % (fmt(y), fmt(y), fmt(y + g["depth"]), fmt(y + g["depth"]), c, fmt(w * 0.55), fmt(a * 1.2)))
        top, bottom = y + g["depth"], y + g["depth"] + g["pylonDepth"]
        pylons = " ".join("M %s %s L %s %s" % (fmt(x), fmt(top), fmt(x), fmt(bottom))
                          for x in [i * g["pylonSpacing"] + 22 for i in range(3)])
        out.append('<path d="%s" stroke="%s" stroke-width="%s" opacity="%s" fill="none"/>'
                   % (pylons, c, fmt(w * 0.55), fmt(a)))
    elif kind == "sky":
        clouds = sc["sky"]["clouds"]
        for i, layer in enumerate(sc["sky"]["layers"]):
            x = [16, 62][i]
            s = layer["scale"]
            out.append('<path d="%s" transform="translate(%s %s) scale(%s)" stroke="%s" stroke-width="%s" '
                       'opacity="%s" fill="none"/>' % (clouds[i % len(clouds)], fmt(x), fmt(layer["y"]), fmt(s), c,
                                                       fmt(w * 0.5 / s), fmt(layer["opacity"] * (1 if dark else 1.2))))
    elif kind == "stratosphere":
        hz = sc["stratosphere"]["horizon"]
        out.append('<circle cx="50" cy="%s" r="%s" stroke="%s" stroke-width="%s" opacity="%s" fill="none"/>'
                   % (fmt(hz["cy"]), fmt(hz["r"]), c, fmt(w * 0.55), fmt(a)))
    elif kind == "space":
        import random
        rnd = random.Random(7)
        for _ in range(sc["space"]["stars"]):
            x, y = rnd.uniform(6, 94), rnd.uniform(6, 94)
            out.append('<path d="M %s %s L %s %s" stroke="%s" stroke-width="%s" opacity="%s" fill="none"/>'
                       % (fmt(x), fmt(y), fmt(x - 2.4), fmt(y + 2.2), c, fmt(w * 0.4), fmt(a * rnd.uniform(0.6, 1.2))))
    return out


def trail_elements(data, v, color, heat):
    out = []
    w = data["stroke"]["width"] * 0.5
    for e in v.get("emitters", []):
        if e["type"] != "trail" or e.get("kind") == "bow":
            continue
        for i, lane in enumerate(e.get("lanes", [])):
            x, y = e["at"][0] - 1.5 - (i % 2) * 2.5, e["at"][1] + lane
            length = e.get("length", 10) * (0.55 + 0.45 * heat)
            out.append('<path d="M %s %s L %s %s" stroke="%s" stroke-width="%s" opacity="0.55" fill="none"/>'
                       % (fmt(x), fmt(y), fmt(x - length), fmt(y), css(color), fmt(w)))
    return out


def vehicle_svg_group(data, v, heat, dark, idle=False, uid="v"):
    """Vehicle layer in canvas units (0–100): scenery, trail marks, glow and crisp strokes, circular soft mask."""
    color = stroke_color(0 if idle else heat, dark)
    hot = hot_color(heat, dark) if not idle else color
    m = data["mask"]
    glow_sigma = 1.0 + 1.4 * heat
    glow_alpha = (0.30 + 0.45 * heat) if dark else (0.14 + 0.18 * heat)
    opacity = (0.55 if dark else 0.5) if idle else 1.0
    parts = []
    parts.append('<defs><radialGradient id="%s-m" cx="50" cy="50" r="%s" gradientUnits="userSpaceOnUse">'
                 '<stop offset="%s" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>'
                 '</radialGradient><mask id="%s-mask" maskUnits="userSpaceOnUse" x="0" y="0" width="100" height="100">'
                 '<rect width="100" height="100" fill="url(#%s-m)"/></mask>'
                 '<filter id="%s-glow" x="-20%%" y="-20%%" width="140%%" height="140%%">'
                 '<feGaussianBlur stdDeviation="%s"/></filter></defs>'
                 % (uid, fmt(m["clear"]), fmt(m["solid"] / float(m["clear"])), uid, uid, uid, fmt(glow_sigma)))
    parts.append('<g mask="url(#%s-mask)">' % uid)
    if not idle:
        parts += scenery_elements(data, v, color, heat, dark)
        parts += trail_elements(data, v, color, heat)
        parts.append('<g filter="url(#%s-glow)" opacity="%s">' % (uid, fmt(glow_alpha)))
        parts += vehicle_elements(data, v, color, hot, glow=True)
        parts.append('</g>')
    parts += vehicle_elements(data, v, color, hot, flames=not idle, opacity=opacity,
                              stand=idle and v.get("rig", {}).get("type") == "walk")
    parts.append('</g>')
    return "".join(parts)


def orb_svg(data, v, heat, dark, idle=False, uid="o", size=112.0, background=True):
    """A 112 pt dashboard hero orb mock (DESIGN sections 2 and 4) with the vehicle layer."""
    S = size
    c = S / 2.0
    pad = 8.0
    W = S + 2 * pad
    o = []
    bg = "#232327" if dark else "#ECECEF"
    if background:
        o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>' % (fmt(-pad), fmt(-pad), fmt(W), fmt(W), bg))
    h = 0 if idle else heat
    aura = heat_color(max(h, 0.12)) if dark else stroke_color(max(h, 0.12), False)
    aura_a = (0.55 if dark else 0.32) * h
    o.append('<defs>'
             '<radialGradient id="%s-aura" cx="%s" cy="%s" r="%s" gradientUnits="userSpaceOnUse">'
             '<stop offset="%s" stop-color="%s" stop-opacity="%s"/><stop offset="1" stop-color="%s" stop-opacity="0"/>'
             '</radialGradient>'
             '<linearGradient id="%s-body" x1="0" y1="0" x2="0" y2="1">'
             '<stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient>'
             '<linearGradient id="%s-rim" x1="0" y1="0" x2="0" y2="1">'
             '<stop offset="0" stop-color="#fff" stop-opacity="%s"/>'
             '<stop offset="0.6" stop-color="#fff" stop-opacity="0"/>'
             '</linearGradient>'
             '<radialGradient id="%s-lens" cx="0.3" cy="0.22" r="0.55">'
             '<stop offset="0" stop-color="#fff" stop-opacity="%s"/>'
             '<stop offset="1" stop-color="#fff" stop-opacity="0"/>'
             '</radialGradient>'
             '<filter id="%s-seg" x="-50%%" y="-50%%" width="200%%" height="200%%">'
             '<feGaussianBlur stdDeviation="%s"/></filter>'
             '</defs>'
             % (uid, fmt(c), fmt(c), fmt(0.66 * S), fmt(0.5 / 0.66), css(aura), fmt(aura_a), css(aura),
                uid, "#1B2030" if dark else "#FFFFFF", "#090B10" if dark else "#E7EBF3",
                uid, "0.14" if dark else "0.95", uid, "0.06" if dark else "0.7", uid, fmt(0.02 * S)))
    if aura_a > 0.001:
        o.append('<circle cx="%s" cy="%s" r="%s" fill="url(#%s-aura)"/>' % (fmt(c), fmt(c), fmt(0.66 * S), uid))
    o.append('<circle cx="%s" cy="%s" r="%s" fill="url(#%s-body)" opacity="%s"/>'
             % (fmt(c), fmt(c), fmt(S / 2), uid, "0.92" if dark else "0.96"))
    o.append('<circle cx="%s" cy="%s" r="%s" fill="url(#%s-lens)"/>' % (fmt(c), fmt(c), fmt(S / 2), uid))
    o.append('<circle cx="%s" cy="%s" r="%s" fill="none" stroke="url(#%s-rim)" stroke-width="1"/>'
             % (fmt(c), fmt(c), fmt(S / 2 - 0.5), uid))
    if not dark:
        o.append('<circle cx="%s" cy="%s" r="%s" fill="none" stroke="#000" stroke-opacity="0.08" stroke-width="1"/>'
                 % (fmt(c), fmt(c), fmt(S / 2 + 0.5)))
    # gauge
    seg_len = 0.045 * S
    gr = 0.41 * S
    slot = 270.0 / 36
    seg_w = gr * (slot - 2.2) * math.pi / 180
    corner = min(seg_w, seg_len) * 0.24
    lit = h * 36
    unlit = ('fill="#fff" fill-opacity="0.07"' if dark else 'fill="#000" fill-opacity="0.08"')
    blooms, segs = [], []
    for i in range(36):
        ang = 135 + slot * (i + 0.5)
        x = c + gr * math.cos(math.radians(ang))
        y = c + gr * math.sin(math.radians(ang))
        rect = '<rect x="%s" y="%s" width="%s" height="%s" rx="%s" transform="translate(%s %s) rotate(%s)" %%s/>' % (
            fmt(-seg_len / 2), fmt(-seg_w / 2), fmt(seg_len), fmt(seg_w), fmt(corner), fmt(x), fmt(y), fmt(ang))
        b = min(1.0, max(0.0, lit - i))
        if b < 1:
            segs.append(rect % unlit)
        if b > 0:
            col = heat_color(i / 35.0) if dark else darkened(heat_color(i / 35.0), 0.18)
            lead = b > 0 and lit - i < 1.0 + 1e-9 and i == int(math.ceil(lit)) - 1
            if lead:
                col = mix(col, hex_rgb(WHITE_HOT), 0.8) if dark else mix(col, hex_rgb(AMBER_HOT), 0.2)
            segs.append(rect % ('fill="%s" fill-opacity="%s"' % (css(col), fmt(b))))
            blooms.append(rect % ('fill="%s" fill-opacity="%s"' % (css(col), fmt(b * (0.3 if dark else 0.2)))))
    o.append('<g filter="url(#%s-seg)">%s</g>' % (uid, "".join(blooms)))
    o.extend(segs)
    # agent dots
    if not idle:
        unit = S / 148.0
        dd, spc = 4 * unit, 3.2 * unit
        total = 3 * dd + 2 * spc
        for i, col in enumerate(SOURCE_DOTS):
            rgb = hex_rgb(col) if dark else darkened(hex_rgb(col), 0.12)
            o.append('<circle cx="%s" cy="%s" r="%s" fill="%s"/>' % (fmt(c - total / 2 + i * (dd + spc) + dd / 2),
                                                                     fmt(c + 0.392 * S), fmt(dd / 2), css(rgb)))
    side = data["canvas"]["orbFraction"] * S
    k = side / 100.0
    o.append('<g transform="translate(%s %s) scale(%s)">' % (fmt(c - side / 2), fmt(c - side / 2), fmt(k)))
    o.append(vehicle_svg_group(data, v, heat, dark, idle=idle, uid=uid + "v"))
    o.append('</g>')
    return "".join(o), W, pad


def wrap_svg(body, width, height, scale=1.0, view=None):
    vb = view or (0, 0, width, height)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%s" height="%s" viewBox="%s %s %s %s" '
            'stroke-linecap="round" stroke-linejoin="round">%s</svg>\n'
            % (fmt(width * scale), fmt(height * scale), fmt(vb[0]), fmt(vb[1]), fmt(vb[2]), fmt(vb[3]), body))


def contact_sheet(data, dark, columns=7, size=112.0, label=True):
    cells = []
    entries = [(v, THRESHOLDS[i], NAMES[i], False) for i, v in enumerate(data["vehicles"])]
    fallback = next(v for v in data["vehicles"] if v["key"] == data["idle"]["fallback"])
    entries.append((fallback, 0.0, "待機", True))
    cell = size + 16
    label_h = 22 if label else 0
    rows = int(math.ceil(len(entries) / float(columns)))
    W, H = columns * cell, rows * (cell + label_h)
    bg = "#232327" if dark else "#ECECEF"
    cells.append('<rect width="%s" height="%s" fill="%s"/>' % (fmt(W), fmt(H), bg))
    for i, (v, t, name, idle) in enumerate(entries):
        heat = heat_for(t) if not idle else 0
        body, _, pad = orb_svg(data, v, heat, dark, idle=idle, uid="c%d" % i, size=size, background=False)
        x = (i % columns) * cell + 8
        y = (i // columns) * (cell + label_h) + 8
        cells.append('<g transform="translate(%s %s)">%s</g>' % (fmt(x), fmt(y), body))
        if label:
            tc = css(stroke_color(heat, dark)) if not idle else ("#9AA3B2" if dark else "#5B6472")
            sub = "%s tok/s" % fmt(t * 400) if not idle else "idle"
            cells.append('<text x="%s" y="%s" text-anchor="middle" '
                         'font-family="PingFang TC, Helvetica Neue, sans-serif" '
                         'font-size="11" font-weight="600" fill="%s">%s '
                         '<tspan font-weight="400" fill-opacity="0.6">%s</tspan></text>'
                         % (fmt(x + size / 2), fmt(y + size + 13), tc, name, sub))
    return cells, W, H


# ---------------------------------------------------------------- commands


def export(data):
    if os.path.isdir(EXPORT_DIR):
        for name in os.listdir(EXPORT_DIR):
            if name.endswith(".svg"):
                os.remove(os.path.join(EXPORT_DIR, name))
    else:
        os.makedirs(EXPORT_DIR)
    for i, v in enumerate(data["vehicles"]):
        heat = heat_for(THRESHOLDS[i])
        color = stroke_color(heat, True)
        body = "".join(vehicle_elements(data, v, color, hot_color(heat, True)))
        with open(os.path.join(EXPORT_DIR, v["key"] + ".svg"), "w") as f:
            f.write("<!-- Generated by spec/tools/vehicles.py from spec/assets/vehicles.json; do not edit. -->\n")
            f.write(wrap_svg(body, 100, 100))
    fallback = next(v for v in data["vehicles"] if v["key"] == data["idle"]["fallback"])
    idle = "".join(vehicle_elements(data, fallback, stroke_color(0, True), stroke_color(0, True), flames=False,
                                    opacity=0.6, stand=True))
    with open(os.path.join(EXPORT_DIR, "idle.svg"), "w") as f:
        f.write("<!-- Generated by spec/tools/vehicles.py from spec/assets/vehicles.json; do not edit. -->\n")
        f.write(wrap_svg(idle, 100, 100))
    cells, W, H = contact_sheet(data, True)
    with open(os.path.join(EXPORT_DIR, "contact-sheet.svg"), "w") as f:
        f.write("<!-- Generated by spec/tools/vehicles.py from spec/assets/vehicles.json; do not edit. -->\n")
        f.write(wrap_svg("".join(cells), W, H))
    print("exported %d SVGs to %s" % (len(data["vehicles"]) + 2, os.path.relpath(EXPORT_DIR, os.getcwd())))


def rasterize(svg_text, png_path, tool):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg_text)
        tmp = f.name
    try:
        subprocess.check_call([tool, "-o", png_path, tmp])
    finally:
        os.remove(tmp)


def preview(data, out_dir):
    tool = shutil.which("rsvg-convert")
    if not tool:
        raise SpecError("--preview needs rsvg-convert (brew install librsvg)")
    os.makedirs(out_dir, exist_ok=True)
    for dark in (False, True):
        mode = "dark" if dark else "light"
        cells, W, H = contact_sheet(data, dark)
        rasterize(wrap_svg("".join(cells), W, H, scale=2), os.path.join(out_dir, "contact-%s.png" % mode), tool)
        for i, v in enumerate(data["vehicles"]):
            body, W1, pad = orb_svg(data, v, heat_for(THRESHOLDS[i]), dark, uid="p")
            rasterize(wrap_svg(body, W1, W1, scale=2, view=(-pad, -pad, W1, W1)),
                      os.path.join(out_dir, "%02d-%s-%s.png" % (i + 1, v["key"], mode)), tool)
        fallback = next(v for v in data["vehicles"] if v["key"] == data["idle"]["fallback"])
        body, W1, pad = orb_svg(data, fallback, 0, dark, idle=True, uid="p")
        rasterize(wrap_svg(body, W1, W1, scale=2, view=(-pad, -pad, W1, W1)),
                  os.path.join(out_dir, "14-idle-%s.png" % mode), tool)
    print("rendered previews into %s" % out_dir)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", default=SOURCE)
    parser.add_argument("--export", action="store_true", help="write spec/assets/vehicles/*.svg")
    parser.add_argument("--preview", metavar="DIR", help="render PNG previews (rsvg-convert)")
    args = parser.parse_args()
    with open(args.source) as f:
        data = json.load(f)
    try:
        for w in validate(data):
            print("warning: " + w)
        print("ok: %s (%d vehicles)" % (os.path.basename(args.source), len(data["vehicles"])))
        if args.export:
            export(data)
        if args.preview:
            preview(data, args.preview)
    except SpecError as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

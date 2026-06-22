#!/usr/bin/env python3
"""Compare PaceRunner distance calculators against Apple Workout's GPS trace.

Inputs:
  --log         PaceRunner verbose debug-log export (the .txt with `[gps] sample` lines).
  --gpx         GPX file from HealthFit (or any HKWorkoutRoute exporter).
  --health-zip  Apple Health export zip; the matching workout-route GPX
                is selected automatically by aligning to the PaceRunner
                workout's start time (parsed from the export header).
  --csv         Optional CSV output path (per-sample method totals).

Both inputs are processed independently with the same set of distance methods,
then a comparison table is printed. The PaceRunner log carries CLLocation
`speed` (Kalman-filtered chip output) in each sample; Apple's GPX carries
speed (and course / hAcc / vAcc) as `<extensions>` children, which we read
when present and fall back to chord/dt otherwise.

Methods (matching what the watch ships today):
  chord        — 2D haversine between consecutive fixes
  chord3D      — chord plus altitude delta via Pythagoras
  speedFloor   — max(chord, speed × dt)
  speedFloor3D — max(chord3D, speed × dt)

Min-step threshold: 0.5 m (matches DistanceCalculator.swift).

Usage:
    # File mode (existing behavior)
    python distance_compare.py --log run.txt --gpx run.gpx
    python distance_compare.py --log run.txt --health-zip export.zip
    python distance_compare.py --log run.txt --health-zip export.zip --csv out.csv

    # MCP mode — pull both the log and the GPX straight from the iPhone
    python distance_compare.py --mcp http://chrisb16.local:8765/mcp --token 123456
    python distance_compare.py --mcp ... --token ... --list
    python distance_compare.py --mcp ... --token ... --workout-id <UUID>
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone, timedelta
from pathlib import Path

EARTH_RADIUS_M = 6_371_000.0
MILES_PER_METER = 1.0 / 1609.344
MIN_STEP_M = 0.5  # mirror DistanceCalculator.swift


# ---------------------------------------------------------------------------
# Sample type
# ---------------------------------------------------------------------------

@dataclass
class Sample:
    t: float          # elapsed seconds from workout start
    lat: float
    lon: float
    alt: float | None = None
    speed: float | None = None  # m/s; None means "compute from chord/dt"
    h_acc: float | None = None
    v_acc: float | None = None
    course: float | None = None


# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------

_LOG_SAMPLE_RE = re.compile(r"\[gps\] sample \{([^}]+)\}")
_KV_RE = re.compile(r"([A-Za-z0-9_.]+)=(-?\d+(?:\.\d+)?|nil)")


def parse_pacerunner_log(source) -> list[Sample]:
    """Extract [gps] sample lines from a PaceRunner verbose debug log.

    Accepts either a `Path` (read line-by-line) or a raw string of log text
    (used when the log arrived over MCP rather than via a file export).
    """
    samples: list[Sample] = []
    if isinstance(source, str):
        iterator = source.splitlines()
    else:
        iterator = source.read_text(encoding="utf-8", errors="replace").splitlines()

    for line in iterator:
        m = _LOG_SAMPLE_RE.search(line)
        if not m:
            continue
        kv = dict(_KV_RE.findall(m.group(1)))
        try:
            samples.append(Sample(
                t=float(kv["t"]),
                lat=float(kv["lat"]),
                lon=float(kv["lon"]),
                alt=float(kv["alt"]) if "alt" in kv else None,
                speed=float(kv["speed"]) if "speed" in kv else None,
                h_acc=float(kv["acc"]) if "acc" in kv else None,
                v_acc=float(kv["vAcc"]) if "vAcc" in kv else None,
                course=float(kv["course"]) if "course" in kv else None,
            ))
        except (KeyError, ValueError):
            continue
    return samples


def _strip_ns(tag: str) -> str:
    return tag.split("}", 1)[-1] if "}" in tag else tag


def _parse_iso_z(txt: str) -> datetime | None:
    txt = txt.strip()
    if txt.endswith("Z"):
        txt = txt[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(txt)
    except ValueError:
        return None


def _gpx_root_from(source) -> ET.Element:
    """Accept Path | bytes | str and return the parsed GPX root element."""
    if isinstance(source, (bytes, bytearray)):
        return ET.fromstring(source)
    if isinstance(source, str):
        # Path-as-string OR raw XML text
        if source.lstrip().startswith("<"):
            return ET.fromstring(source)
        return ET.parse(source).getroot()
    return ET.parse(source).getroot()  # Path or file-like


def parse_gpx(source) -> list[Sample]:
    """Parse a GPX into samples. Accepts a `Path`, raw XML bytes, or a
    file-like object. Apple's HKWorkoutRoute export carries speed / course /
    hAcc / vAcc as plain children of `<extensions>` — we pick them up if
    present; speed falls back to chord/dt downstream when absent."""
    root = _gpx_root_from(source)

    # Find every <trkpt> regardless of namespace
    trkpts: list[ET.Element] = [
        elem for elem in root.iter() if _strip_ns(elem.tag) == "trkpt"
    ]
    if not trkpts:
        raise ValueError("No <trkpt> elements found in GPX source")

    samples: list[Sample] = []
    base_time: datetime | None = None
    for pt in trkpts:
        try:
            lat = float(pt.get("lat", "nan"))
            lon = float(pt.get("lon", "nan"))
        except (TypeError, ValueError):
            continue
        if math.isnan(lat) or math.isnan(lon):
            continue

        ele: float | None = None
        when: datetime | None = None
        speed: float | None = None
        course: float | None = None
        h_acc: float | None = None
        v_acc: float | None = None

        for child in pt.iter():
            tag = _strip_ns(child.tag)
            if not child.text:
                continue
            text = child.text.strip()
            if tag == "ele":
                try: ele = float(text)
                except ValueError: pass
            elif tag == "time":
                when = _parse_iso_z(text)
            elif tag == "speed":
                try: speed = float(text)
                except ValueError: pass
            elif tag == "course":
                try: course = float(text)
                except ValueError: pass
            elif tag == "hAcc":
                try: h_acc = float(text)
                except ValueError: pass
            elif tag == "vAcc":
                try: v_acc = float(text)
                except ValueError: pass

        if when is None:
            continue
        if base_time is None:
            base_time = when
        t = (when - base_time).total_seconds()

        samples.append(Sample(
            t=t,
            lat=lat,
            lon=lon,
            alt=ele,
            speed=speed,
            h_acc=h_acc,
            v_acc=v_acc,
            course=course,
        ))

    return samples


# ---------------------------------------------------------------------------
# PaceRunner header + Health-zip matching
# ---------------------------------------------------------------------------

# \s in Python's re matches Unicode whitespace by default — important because
# Apple's DateFormatter inserts U+202F (NARROW NO-BREAK SPACE) before AM/PM
# on iOS 16+. A literal space in the regex would miss this.
_PR_DATE_RE = re.compile(r"^Date:\s+(\w+\s+\d+,\s+\d+\s+\d+:\d+\s*[AP]M)\s*$", re.MULTILINE)
_PR_DUR_RE = re.compile(r"^Duration:\s+(\d+):(\d+)\s*$", re.MULTILINE)
# Precise start: first `[HH:MM:SS.fff] [timing] Workout started` event.
_PR_WORKOUT_STARTED_RE = re.compile(
    r"^\[(\d{2}):(\d{2}):(\d{2})\.(\d{3})\]\s+\[timing\]\s+Workout started",
    re.MULTILINE,
)


def parse_pacerunner_header(text: str) -> tuple[datetime, float]:
    """Return (start_utc_datetime, duration_seconds) from a PaceRunner export.

    The `Date:` line is only minute-precision (e.g. `Jun 5, 2026 7:27 AM`),
    so we prefer the millisecond-precise wall-clock from the first
    `[timing] Workout started` event and combine it with the header's date.
    Fallback to header time only if the timing line is missing.
    """
    dm = _PR_DATE_RE.search(text)
    du = _PR_DUR_RE.search(text)
    if not dm:
        raise ValueError("Could not find a `Date: ...` line in the PaceRunner export header")
    if not du:
        raise ValueError("Could not find a `Duration: M:SS` line in the PaceRunner export header")

    # Header gives us the calendar date (and rough time as a sanity check).
    raw = re.sub(r"\s+", " ", dm.group(1)).strip()
    header_local = datetime.strptime(raw, "%b %d, %Y %I:%M %p")

    # Refine with the precise [HH:MM:SS.fff] from the workout-started event.
    tm = _PR_WORKOUT_STARTED_RE.search(text)
    if tm:
        hh, mm, ss, ms = (int(g) for g in tm.groups())
        local_naive = header_local.replace(
            hour=hh, minute=mm, second=ss, microsecond=ms * 1000
        )
    else:
        local_naive = header_local

    # Naive local → UTC (Python 3.6+: astimezone() treats naive as local).
    start_utc = local_naive.astimezone(timezone.utc)
    duration_s = int(du.group(1)) * 60 + int(du.group(2))
    return start_utc, float(duration_s)


_GPX_TIME_RE = re.compile(rb"<time>([^<]+)</time>")


def _gpx_first_last_time(data: bytes) -> tuple[datetime | None, datetime | None]:
    """Cheap scan of a GPX blob for the first and last <time> elements that
    appear *inside* a <trkpt>. Skipping the leading <metadata><time> (export
    creation, not workout start) — that one would otherwise dominate matching
    since every Apple Health export is timestamped at export time."""
    # Slice to start at the first <trkpt occurrence, ignoring metadata header.
    trk_start = data.find(b"<trkpt")
    if trk_start == -1:
        return None, None
    matches = _GPX_TIME_RE.findall(data, trk_start)
    if not matches:
        return None, None
    first = _parse_iso_z(matches[0].decode("ascii", errors="ignore"))
    last = _parse_iso_z(matches[-1].decode("ascii", errors="ignore"))
    return first, last


@dataclass
class GpxCandidate:
    name: str
    start: datetime
    end: datetime
    data: bytes

    @property
    def duration_s(self) -> float:
        return (self.end - self.start).total_seconds()


def find_matching_gpx(zip_path: Path,
                      pr_start: datetime,
                      pr_duration: float,
                      tolerance_s: float = 30 * 60) -> GpxCandidate:
    """Walk every GPX inside the Apple Health export zip and pick the one
    whose start time best aligns with the PaceRunner workout. Returns the
    full GPX bytes so the caller can parse it via `parse_gpx(data)`.

    A 30-minute tolerance is generous on purpose — the route can be uploaded
    well after the workout starts, but two runs an hour apart on the same
    day shouldn't collide."""
    candidates: list[GpxCandidate] = []
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            name = info.filename
            if "workout-routes/" not in name or not name.endswith(".gpx"):
                continue
            data = zf.read(info)
            start, end = _gpx_first_last_time(data)
            if start is None or end is None:
                continue
            candidates.append(GpxCandidate(name=name, start=start, end=end, data=data))

    if not candidates:
        raise FileNotFoundError(f"No workout-route GPX files found inside {zip_path}")

    # Score by start-time offset; break ties by duration similarity
    def score(c: GpxCandidate) -> tuple[float, float]:
        return (abs((c.start - pr_start).total_seconds()),
                abs(c.duration_s - pr_duration))

    candidates.sort(key=score)
    best = candidates[0]
    offset = (best.start - pr_start).total_seconds()
    if abs(offset) > tolerance_s:
        raise FileNotFoundError(
            f"No GPX within {tolerance_s/60:.0f} min of PaceRunner start "
            f"{pr_start.isoformat()}. Closest: {best.name} "
            f"(starts {best.start.isoformat()}, offset {offset:+.0f}s)"
        )
    return best


# ---------------------------------------------------------------------------
# Distance methods
# ---------------------------------------------------------------------------

def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance between two lat/lon pairs in meters."""
    p1 = math.radians(lat1)
    p2 = math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


def compute_methods(samples: list[Sample]) -> dict[str, list[float]]:
    """Run each method over the sample list, returning cumulative-distance
    series (in meters) keyed by method name. All series include t=0 at index 0
    so they line up 1:1 with `samples`."""
    n = len(samples)
    out = {name: [0.0] * n for name in ("chord", "chord3D", "speedFloor", "speedFloor3D")}

    for i in range(1, n):
        prev = samples[i - 1]
        cur = samples[i]
        dt = max(0.0, cur.t - prev.t)
        chord = haversine_m(prev.lat, prev.lon, cur.lat, cur.lon)

        if cur.alt is not None and prev.alt is not None:
            dh = cur.alt - prev.alt
            chord_3d = math.sqrt(chord * chord + dh * dh)
        else:
            chord_3d = chord

        # If the source didn't carry speed, derive it from chord/dt so the
        # speedFloor variants still have something meaningful to compare.
        if cur.speed is not None:
            speed = cur.speed
        elif dt > 0:
            speed = chord / dt
        else:
            speed = 0.0
        speed_dt = max(0.0, speed) * dt

        # Mirror DistanceCalculator.swift: drop tiny chord steps as noise.
        chord_step = 0.0 if chord < MIN_STEP_M else chord
        chord3d_step = 0.0 if chord_3d < MIN_STEP_M else chord_3d

        sf = max(chord_step, speed_dt)
        sf3d = max(chord3d_step, speed_dt)

        out["chord"][i] = out["chord"][i - 1] + chord_step
        out["chord3D"][i] = out["chord3D"][i - 1] + chord3d_step
        out["speedFloor"][i] = out["speedFloor"][i - 1] + sf
        out["speedFloor3D"][i] = out["speedFloor3D"][i - 1] + sf3d

    return out


# ---------------------------------------------------------------------------
# Mile splits
# ---------------------------------------------------------------------------

def mile_splits(samples: list[Sample], totals: list[float]) -> list[tuple[int, float]]:
    """Return [(mile, t_at_that_mile_seconds), ...] using linear interpolation
    between samples for sub-sample precision."""
    splits: list[tuple[int, float]] = []
    mile_m = 1609.344
    target = mile_m
    mile = 1
    for i in range(1, len(totals)):
        while totals[i] >= target:
            # Interpolate between samples[i-1] and samples[i]
            d0 = totals[i - 1]
            d1 = totals[i]
            t0 = samples[i - 1].t
            t1 = samples[i].t
            if d1 == d0:
                t_mile = t1
            else:
                frac = (target - d0) / (d1 - d0)
                t_mile = t0 + frac * (t1 - t0)
            splits.append((mile, t_mile))
            mile += 1
            target = mile * mile_m
    return splits


def fmt_pace(seconds_per_mile: float) -> str:
    if seconds_per_mile <= 0 or math.isinf(seconds_per_mile):
        return "—"
    m = int(seconds_per_mile // 60)
    s = int(round(seconds_per_mile - m * 60))
    if s == 60:
        m += 1
        s = 0
    return f"{m}:{s:02d}"


def fmt_time(seconds: float) -> str:
    if seconds <= 0:
        return "—"
    m = int(seconds // 60)
    s = seconds - m * 60
    return f"{m}:{s:05.2f}"


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def report_track(label: str, samples: list[Sample], totals_by_method: dict[str, list[float]]) -> None:
    if not samples:
        print(f"\n[{label}] no samples")
        return

    duration = samples[-1].t
    print(f"\n=== {label} ===")
    print(f"Samples: {len(samples)}   Duration: {fmt_time(duration)}")

    header = f"{'Method':<14} {'Total (mi)':>10} {'Total (m)':>10}"
    # Determine the max mile reached across all methods for column count
    max_mile = 0
    splits_by_method: dict[str, list[tuple[int, float]]] = {}
    for name, totals in totals_by_method.items():
        sp = mile_splits(samples, totals)
        splits_by_method[name] = sp
        if sp:
            max_mile = max(max_mile, sp[-1][0])

    for mile in range(1, max_mile + 1):
        header += f"   M{mile:>2} split"
    print(header)
    print("-" * len(header))

    for name, totals in totals_by_method.items():
        total_m = totals[-1]
        total_mi = total_m * MILES_PER_METER
        row = f"{name:<14} {total_mi:>10.4f} {total_m:>10.1f}"
        sp = splits_by_method[name]
        # Compute per-mile split duration (time between consecutive mile crossings)
        prev_t = 0.0
        sp_map = {m: t for m, t in sp}
        for mile in range(1, max_mile + 1):
            if mile in sp_map:
                mile_t = sp_map[mile]
                split = mile_t - prev_t
                row += f"   {fmt_pace(split):>9}"
                prev_t = mile_t
            else:
                row += f"   {'—':>9}"
        print(row)


def report_diff(label_a: str, label_b: str,
                samples_a: list[Sample], totals_a: dict[str, list[float]],
                samples_b: list[Sample], totals_b: dict[str, list[float]]) -> None:
    """Print per-method totals from track A, side-by-side with the corresponding
    totals from track B, and the percentage difference. Useful for spotting
    which of our methods comes closest to the GPX reference."""
    if not samples_a or not samples_b:
        return
    print(f"\n=== {label_a} vs {label_b} ===")
    print(f"{'Method':<14} {label_a + ' (mi)':>18} {label_b + ' (mi)':>18} {'Δ (mi)':>10} {'Δ %':>8}")
    print("-" * 74)
    for name in totals_a:
        ta = totals_a[name][-1] * MILES_PER_METER
        tb = totals_b[name][-1] * MILES_PER_METER
        d = ta - tb
        pct = (d / tb * 100.0) if tb else 0.0
        print(f"{name:<14} {ta:>18.4f} {tb:>18.4f} {d:>+10.4f} {pct:>+7.2f}%")


# ---------------------------------------------------------------------------
# CSV
# ---------------------------------------------------------------------------

def write_csv(path: Path,
              pr_samples: list[Sample], pr_totals: dict[str, list[float]],
              gpx_samples: list[Sample], gpx_totals: dict[str, list[float]]) -> None:
    """Two stacked sections: PaceRunner samples + their per-method totals,
    then GPX samples + their per-method totals. Loading this into a sheet
    and pivoting gives you clean plots."""
    method_names = list(pr_totals.keys())
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["source", "i", "t", "lat", "lon", "alt", "speed", "h_acc", "v_acc", "course",
                    *[f"{m}_m" for m in method_names]])
        for src, samples, totals in (("pacerunner", pr_samples, pr_totals),
                                     ("gpx", gpx_samples, gpx_totals)):
            for i, s in enumerate(samples):
                w.writerow([
                    src, i, f"{s.t:.3f}", s.lat, s.lon,
                    s.alt if s.alt is not None else "",
                    s.speed if s.speed is not None else "",
                    s.h_acc if s.h_acc is not None else "",
                    s.v_acc if s.v_acc is not None else "",
                    s.course if s.course is not None else "",
                    *[f"{totals[m][i]:.3f}" for m in method_names],
                ])
    print(f"\nWrote per-sample CSV to {path}")


# ---------------------------------------------------------------------------
# MCP client (talks to PaceRunner's in-app MCP server)
# ---------------------------------------------------------------------------

class MCPClient:
    """Tiny JSON-RPC-over-HTTP client for the PaceRunner MCP server.

    Single-shot per call; no SSE, no keep-alive. Mirrors the server's
    expectations: POST to `/mcp` with `Authorization: Bearer <token>` and
    a JSON-RPC 2.0 envelope. `tools/call` results wrap a content array
    whose first item is a `text` block holding JSON-stringified output —
    we parse that out here so callers see a clean dict.
    """

    def __init__(self, url: str, token: str, timeout: float = 60.0):
        self.url = url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self._req_id = 0

    def _rpc(self, method: str, params: dict | None = None) -> dict:
        self._req_id += 1
        envelope = {
            "jsonrpc": "2.0",
            "id": self._req_id,
            "method": method,
        }
        if params is not None:
            envelope["params"] = params
        req = urllib.request.Request(
            self.url,
            data=json.dumps(envelope).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                body = resp.read().decode("utf-8")
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"MCP HTTP {e.code}: {e.read().decode('utf-8', 'replace')}") from e
        except urllib.error.URLError as e:
            raise RuntimeError(f"MCP transport error: {e.reason}") from e

        obj = json.loads(body)
        if "error" in obj:
            err = obj["error"]
            raise RuntimeError(f"MCP error {err.get('code')}: {err.get('message')}")
        return obj.get("result", {})

    def initialize(self) -> dict:
        return self._rpc("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "distance_compare.py", "version": "0.1"},
        })

    def list_workouts(self, since: datetime | None = None,
                      until: datetime | None = None,
                      activity_type: str | None = None,
                      limit: int = 50) -> list[dict]:
        args: dict = {"limit": limit}
        if since is not None:
            args["since"] = _to_iso(since)
        if until is not None:
            args["until"] = _to_iso(until)
        if activity_type is not None:
            args["activity_type"] = activity_type
        result = self._rpc("tools/call", {"name": "list_workouts", "arguments": args})
        payload = _unwrap_tool_text(result)
        return payload.get("workouts", [])

    def get_workout(self, workout_id: str, fields: list[str]) -> dict:
        result = self._rpc("tools/call", {
            "name": "get_workout",
            "arguments": {"id": workout_id, "fields": fields},
        })
        return _unwrap_tool_text(result)

    def get_pacerunner_log(self, workout_id: str) -> dict:
        result = self._rpc("tools/call", {
            "name": "get_pacerunner_log",
            "arguments": {"workout_id": workout_id},
        })
        return _unwrap_tool_text(result)


def _to_iso(dt: datetime) -> str:
    """Emit RFC-3339 without fractional seconds — fits the Swift server's
    fast-path parser even before the fractional-seconds fix lands."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _unwrap_tool_text(result: dict) -> dict:
    """MCP tool results wrap a content array whose first item is a `text`
    block holding JSON. Unwrap that into a plain dict."""
    content = result.get("content") or []
    if not content:
        return {}
    first = content[0]
    if first.get("type") != "text":
        return {}
    return json.loads(first.get("text", "{}"))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)

    # Two top-level modes, mutually exclusive:
    #   1. File mode: --log + (--gpx or --health-zip). What we had before.
    #   2. MCP mode:  --mcp + --token (+ optional --workout-id or --latest).
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--gpx", type=Path, help="Workout GPX file (e.g. from HealthFit)")
    src.add_argument("--health-zip", type=Path,
                     help="Apple Health export.zip; the matching route GPX is auto-selected")
    src.add_argument("--mcp", metavar="URL",
                     help="PaceRunner MCP endpoint, e.g. http://chrisb16.local:8765/mcp")

    ap.add_argument("--log", type=Path,
                    help="PaceRunner verbose debug log (required in file mode; "
                         "in MCP mode pulled from the server automatically)")
    ap.add_argument("--token", help="Bearer token shown in PaceRunner's MCP tab (required with --mcp)")
    ap.add_argument("--workout-id", help="HK workout UUID to fetch (MCP mode only). "
                                          "Omit to use the most recent running workout with a PR log.")
    ap.add_argument("--latest", action="store_true",
                    help="MCP mode: pick the most recent running workout that also has a PR log.")
    ap.add_argument("--days", type=int, default=14,
                    help="MCP mode: look-back window when picking the latest workout (default 14)")
    ap.add_argument("--list", action="store_true",
                    help="MCP mode: just list workouts and exit (useful for finding a workout id).")
    ap.add_argument("--csv", type=Path, help="Optional per-sample CSV output")
    args = ap.parse_args()

    # ----- MCP mode --------------------------------------------------------
    if args.mcp:
        if not args.token:
            print("error: --mcp requires --token", file=sys.stderr)
            return 1
        return run_mcp_mode(args)

    # ----- File mode -------------------------------------------------------
    if not args.log:
        print("error: --log is required in file mode", file=sys.stderr)
        return 1
    if not args.log.is_file():
        print(f"error: log file not found: {args.log}", file=sys.stderr)
        return 1

    pr_text = args.log.read_text(encoding="utf-8", errors="replace")
    pr_samples = parse_pacerunner_log(args.log)
    if not pr_samples:
        print(f"error: no [gps] sample lines found in {args.log} — was verbose GPS logging on?",
              file=sys.stderr)
        return 1

    gpx_label = "Workout GPX"
    if args.gpx:
        if not args.gpx.is_file():
            print(f"error: gpx file not found: {args.gpx}", file=sys.stderr)
            return 1
        gpx_samples = parse_gpx(args.gpx)
        gpx_label = f"Workout GPX ({args.gpx.name})"
    else:
        if not args.health_zip.is_file():
            print(f"error: health-zip not found: {args.health_zip}", file=sys.stderr)
            return 1
        try:
            pr_start, pr_dur = parse_pacerunner_header(pr_text)
        except ValueError as e:
            print(f"error parsing PaceRunner header: {e}", file=sys.stderr)
            return 1
        try:
            match = find_matching_gpx(args.health_zip, pr_start, pr_dur)
        except FileNotFoundError as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        offset = (match.start - pr_start).total_seconds()
        print(f"Matched GPX:  {match.name}")
        print(f"  PR start:   {pr_start.isoformat()}  duration {pr_dur:.0f}s")
        print(f"  GPX start:  {match.start.isoformat()}  duration {match.duration_s:.0f}s")
        print(f"  Offset:     {offset:+.1f}s   Δduration {match.duration_s - pr_dur:+.1f}s")
        gpx_samples = parse_gpx(match.data)
        gpx_label = f"Workout GPX ({Path(match.name).name})"

    if not gpx_samples:
        print("error: GPX produced no parseable samples", file=sys.stderr)
        return 1

    pr_totals = compute_methods(pr_samples)
    gpx_totals = compute_methods(gpx_samples)

    report_track("PaceRunner log", pr_samples, pr_totals)
    report_track(gpx_label, gpx_samples, gpx_totals)
    report_diff("PaceRunner log", "Workout GPX",
                pr_samples, pr_totals, gpx_samples, gpx_totals)

    if args.csv:
        write_csv(args.csv, pr_samples, pr_totals, gpx_samples, gpx_totals)

    return 0


def run_mcp_mode(args) -> int:
    """MCP fetch-and-compare flow: pull both the PR debug log and the matching
    HealthKit route GPX directly from the iPhone, then run the same
    comparison the file mode does. No zip wrangling required."""
    client = MCPClient(args.mcp, args.token)

    try:
        client.initialize()
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    since = datetime.now(timezone.utc) - timedelta(days=args.days)
    try:
        workouts = client.list_workouts(since=since, activity_type="running")
    except RuntimeError as e:
        print(f"error listing workouts: {e}", file=sys.stderr)
        return 1

    if not workouts:
        print(f"No running workouts found in the last {args.days} days.", file=sys.stderr)
        return 1

    if args.list:
        print(f"{'Date':<22} {'Distance':>9} {'Duration':>9}  PR log  ID")
        print("-" * 80)
        for w in workouts:
            dist_mi = w.get("distance_miles", 0.0)
            dur_min = w.get("duration_seconds", 0.0) / 60
            print(f"{w.get('start','')[:19]:<22} {dist_mi:>6.2f} mi  "
                  f"{dur_min:>6.1f} min  "
                  f"{'yes ' if w.get('has_pacerunner_log') else 'no  '}  "
                  f"{w.get('id','')}")
        return 0

    # Resolve which workout to use
    target: dict
    if args.workout_id:
        match = next((w for w in workouts if w.get("id") == args.workout_id), None)
        if match is None:
            print(f"error: workout {args.workout_id} not found in last {args.days} days",
                  file=sys.stderr)
            return 1
        target = match
    else:
        # `--latest` is the default behavior when no id given. Prefer one with
        # a PR log so the comparison is meaningful.
        with_log = [w for w in workouts if w.get("has_pacerunner_log")]
        target = (with_log or workouts)[-1]
        print(f"Auto-selected workout: {target.get('start','')[:19]} "
              f"({target.get('distance_miles',0):.2f} mi)")

    workout_id = target["id"]
    print(f"Fetching workout {workout_id}…")
    payload = client.get_workout(workout_id, fields=["metadata", "route_gpx", "pacerunner_log"])

    gpx_text = payload.get("route_gpx")
    pr_log = payload.get("pacerunner_log")
    if not gpx_text:
        print("error: workout has no route_gpx — Apple Workout app may not have recorded GPS",
              file=sys.stderr)
        return 1
    if not pr_log:
        print("error: no pacerunner_log on disk for this workout — verbose GPS logging must "
              "have been on during the run, and the log must still be in DebugLogStore.",
              file=sys.stderr)
        return 1

    print(f"  GPX bytes:        {len(gpx_text):>9,}")
    print(f"  PR log bytes:     {len(pr_log):>9,}")

    pr_samples = parse_pacerunner_log(pr_log)
    gpx_samples = parse_gpx(gpx_text.encode("utf-8"))
    if not pr_samples:
        print("error: PR log has no [gps] sample lines (verbose GPS off?)", file=sys.stderr)
        return 1
    if not gpx_samples:
        print("error: GPX produced no parseable samples", file=sys.stderr)
        return 1

    pr_totals = compute_methods(pr_samples)
    gpx_totals = compute_methods(gpx_samples)

    report_track("PaceRunner log (MCP)", pr_samples, pr_totals)
    report_track(f"Workout GPX (MCP, {workout_id[:8]})", gpx_samples, gpx_totals)
    report_diff("PaceRunner log", "Workout GPX",
                pr_samples, pr_totals, gpx_samples, gpx_totals)

    if args.csv:
        write_csv(args.csv, pr_samples, pr_totals, gpx_samples, gpx_totals)
    return 0


if __name__ == "__main__":
    sys.exit(main())

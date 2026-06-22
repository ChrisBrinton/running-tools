import Foundation

/// Parses a saved verbose-GPS debug log and renders a self-contained Leaflet
/// HTML file that draws the run path colored by pace.
///
/// Input is the same text format produced by `DebugLog.exportAsText()` —
/// looks for `[gps] sample` events with `lat`, `lon`, `speed`, `totalM`, `t`.
/// Each segment between consecutive samples is colored by the GPS-reported
/// instantaneous speed (greener = faster, redder = slower).
public enum GPSMapRenderer {

    public struct Sample {
        public let timeSeconds: Double
        public let lat: Double
        public let lon: Double
        public let speedMps: Double      // -1 if unknown
        public let totalMeters: Double
        public let course: Double        // -1 if unknown
        public let altitude: Double?
        public let baroRelative: Double?
    }

    /// Render an HTML map from a debug log text. Returns the HTML string.
    public static func renderHTML(fromDebugLog logText: String, title: String = "PaceRunner Run") -> String {
        let samples = parseSamples(from: logText)
        return buildHTML(samples: samples, title: title)
    }

    // MARK: - Parsing

    /// Public for testing; matches `[gps] sample {key=value, ...}` lines.
    public static func parseSamples(from logText: String) -> [Sample] {
        var samples: [Sample] = []
        for line in logText.split(separator: "\n", omittingEmptySubsequences: true) {
            // Look for "[gps] sample {...}" — skip [gps-rej], [gps-turn], etc.
            guard line.contains("[gps] sample") else { continue }
            // Extract the {...} payload
            guard let braceStart = line.firstIndex(of: "{"),
                  let braceEnd = line.lastIndex(of: "}") else { continue }
            let payload = line[line.index(after: braceStart)..<braceEnd]
            let fields = parseFields(payload: String(payload))

            guard let lat = fields["lat"].flatMap(Double.init),
                  let lon = fields["lon"].flatMap(Double.init) else { continue }
            let t = fields["t"].flatMap(Double.init) ?? 0
            let speed = fields["speed"].flatMap(Double.init) ?? -1
            let totalM = fields["totalM"].flatMap(Double.init) ?? 0
            let course = fields["course"].flatMap(Double.init) ?? -1
            let alt = fields["alt"].flatMap(Double.init)
            let baro = fields["baroRel"].flatMap(Double.init)

            samples.append(Sample(
                timeSeconds: t,
                lat: lat,
                lon: lon,
                speedMps: speed,
                totalMeters: totalM,
                course: course,
                altitude: alt,
                baroRelative: baro
            ))
        }
        return samples
    }

    private static func parseFields(payload: String) -> [String: String] {
        var dict: [String: String] = [:]
        for piece in payload.split(separator: ",") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if let eq = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eq])
                let value = String(trimmed[trimmed.index(after: eq)...])
                dict[key] = value
            }
        }
        return dict
    }

    // MARK: - HTML Generation

    private static func buildHTML(samples: [Sample], title: String) -> String {
        // Build a JSON array of [lat, lon, speed, t, totalM] for Leaflet to render
        var rows: [String] = []
        for s in samples {
            rows.append("[\(s.lat),\(s.lon),\(s.speedMps),\(s.timeSeconds),\(s.totalMeters),\(s.course)]")
        }
        let dataJSON = "[\(rows.joined(separator: ","))]"

        let minLat = samples.map(\.lat).min() ?? 0
        let maxLat = samples.map(\.lat).max() ?? 0
        let minLon = samples.map(\.lon).min() ?? 0
        let maxLon = samples.map(\.lon).max() ?? 0

        return """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>\(title)</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
<style>
  html, body { margin: 0; padding: 0; height: 100%; font-family: -apple-system, sans-serif; }
  #map { height: 100vh; }
  .legend { background: rgba(255,255,255,0.92); padding: 8px 12px; border-radius: 6px; box-shadow: 0 1px 4px rgba(0,0,0,0.2); font-size: 12px; line-height: 1.5; }
  .legend .swatch { display: inline-block; width: 14px; height: 14px; vertical-align: middle; margin-right: 4px; border-radius: 2px; }
  .stats { background: rgba(255,255,255,0.92); padding: 8px 12px; border-radius: 6px; box-shadow: 0 1px 4px rgba(0,0,0,0.2); font-size: 12px; }
</style>
</head>
<body>
<div id="map"></div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
  const samples = \(dataJSON);
  // Each: [lat, lon, speedMps, t, totalM, course]

  const map = L.map('map');
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '© OpenStreetMap'
  }).addTo(map);

  if (samples.length === 0) {
    map.setView([\((minLat+maxLat)/2),\((minLon+maxLon)/2)], 13);
  } else {
    map.fitBounds([[\(minLat),\(minLon)], [\(maxLat),\(maxLon)]], { padding: [20,20] });
  }

  // Speed → color (green fast, red slow). Target pace 3 m/s ≈ 8:54/mi.
  // Anchor 1.5 m/s = red, 3.5 m/s = green.
  function paceColor(speed) {
    if (speed < 0) return '#888';
    const minSpeed = 1.5;
    const maxSpeed = 3.5;
    const t = Math.max(0, Math.min(1, (speed - minSpeed) / (maxSpeed - minSpeed)));
    // Red → Yellow → Green
    const r = Math.round(255 * (1 - t));
    const g = Math.round(180 * t + 60);
    const b = 60;
    return `rgb(${r},${g},${b})`;
  }

  // Pace in min/mi from m/s
  function paceMinPerMi(speed) {
    if (speed <= 0) return '—';
    const mpm = 26.8224 / speed; // 1609.344m / 60s
    const min = Math.floor(mpm);
    const sec = Math.round((mpm - min) * 60);
    return `${min}:${String(sec).padStart(2, '0')}/mi`;
  }

  // Draw each segment with its color
  for (let i = 1; i < samples.length; i++) {
    const a = samples[i-1];
    const b = samples[i];
    const speed = b[2];
    L.polyline([[a[0], a[1]], [b[0], b[1]]], {
      color: paceColor(speed),
      weight: 5,
      opacity: 0.9
    }).addTo(map).bindTooltip(
      `t=${b[3].toFixed(0)}s<br>` +
      `${paceMinPerMi(speed)}<br>` +
      `speed=${speed.toFixed(2)} m/s<br>` +
      `course=${b[5].toFixed(0)}°<br>` +
      `totalM=${b[4].toFixed(0)}`,
      { sticky: true }
    );
  }

  // Start and end markers
  if (samples.length > 0) {
    L.circleMarker([samples[0][0], samples[0][1]], {
      radius: 7, color: 'white', fillColor: '#22c55e', fillOpacity: 1, weight: 2
    }).addTo(map).bindTooltip('Start', { permanent: false });
    const last = samples[samples.length - 1];
    L.circleMarker([last[0], last[1]], {
      radius: 7, color: 'white', fillColor: '#ef4444', fillOpacity: 1, weight: 2
    }).addTo(map).bindTooltip('End', { permanent: false });
  }

  // Legend
  const legend = L.control({ position: 'bottomright' });
  legend.onAdd = () => {
    const div = L.DomUtil.create('div', 'legend');
    div.innerHTML =
      '<div><b>Pace</b> (GPS speed)</div>' +
      '<div><span class="swatch" style="background:rgb(0,180,60)"></span>Fast (≥3.5 m/s, ~7:40/mi)</div>' +
      '<div><span class="swatch" style="background:rgb(128,120,60)"></span>Medium (~2.5 m/s)</div>' +
      '<div><span class="swatch" style="background:rgb(255,60,60)"></span>Slow (≤1.5 m/s, ~17:53/mi)</div>' +
      '<div><span class="swatch" style="background:#888"></span>Speed unknown</div>';
    return div;
  };
  legend.addTo(map);

  // Stats
  const stats = L.control({ position: 'topright' });
  stats.onAdd = () => {
    const div = L.DomUtil.create('div', 'stats');
    const totalKm = samples.length > 0 ? (samples[samples.length - 1][4] / 1000) : 0;
    const totalMi = totalKm * 0.621371;
    const totalSec = samples.length > 0 ? samples[samples.length - 1][3] : 0;
    const min = Math.floor(totalSec / 60);
    const sec = Math.round(totalSec % 60);
    div.innerHTML =
      `<b>\(title)</b><br>` +
      `${samples.length} samples<br>` +
      `${totalMi.toFixed(2)} mi (${totalKm.toFixed(2)} km)<br>` +
      `${min}m ${sec}s`;
    return div;
  };
  stats.addTo(map);
</script>
</body>
</html>
"""
    }
}

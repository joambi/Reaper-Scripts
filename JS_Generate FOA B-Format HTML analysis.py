# @description Generate FOA B-Format HTML analysis
# @version 1.0
# @author Codex
# @about
#   Analysiert eine FOA/B-Format-Datei (4 Kanaele) aus einem selektierten Media Item
#   oder ueber Dateiauswahl und erzeugt ein HTML-Dashboard mit Plotly:
#   Intensitaetsvektor X/Y/Z, Azimut, Elevation, Fokus, Pegel und Kanal-RMS.
#   Unterstuetzt ambiX (ACN/SN3D: W,Y,Z,X) und FuMa (W,X,Y,Z).

from reaper_python import *
import json
import math
import os


DEFAULT_FRAME_MS = 50.0
EPSILON = 1.0e-12


def show_error(message):
    RPR_ShowMessageBox(str(message), "FOA HTML Analysis", 0)


def show_info(message):
    RPR_ShowMessageBox(str(message), "FOA HTML Analysis", 0)


def sanitize_path(path):
    return path.replace("\\", "/")


def clamp(value, minimum, maximum):
    return max(minimum, min(maximum, value))


def dbfs(value):
    if value <= EPSILON:
        return -120.0
    return 20.0 * math.log10(value)


def get_take_file_path(take):
    source = RPR_GetMediaItemTake_Source(take)
    if not source or source == "(PCM_source*)0x0000000000000000":
        return ""
    _, filename, _ = RPR_GetMediaSourceFileName(source, "", 4096)
    return filename


def get_selected_take_context():
    item = RPR_GetSelectedMediaItem(0, 0)
    if not item or item == "(MediaItem*)0x0000000000000000":
        return None

    take = RPR_GetActiveTake(item)
    if not take or take == "(MediaItem_Take*)0x0000000000000000":
        return None

    source = RPR_GetMediaItemTake_Source(take)
    if not source or source == "(PCM_source*)0x0000000000000000":
        return None

    length, _, _ = RPR_GetMediaSourceLength(source, 0)
    sample_rate = RPR_GetMediaSourceSampleRate(source)
    channels = RPR_GetMediaSourceNumChannels(source)
    source_path = get_take_file_path(take)

    return {
        "mode": "take",
        "item": item,
        "take": take,
        "source": source,
        "source_path": source_path,
        "length": float(length),
        "sample_rate": int(sample_rate),
        "channels": int(channels),
        "accessor": None,
        "temp_track": None,
        "temp_item": None,
    }


def build_temp_take_context(file_path):
    source = RPR_PCM_Source_CreateFromFile(file_path)
    if not source or source == "(PCM_source*)0x0000000000000000":
        return None

    length, _, _ = RPR_GetMediaSourceLength(source, 0)
    sample_rate = RPR_GetMediaSourceSampleRate(source)
    channels = RPR_GetMediaSourceNumChannels(source)

    track_index = int(RPR_CountTracks(0))
    RPR_InsertTrackAtIndex(track_index, False)
    track = RPR_GetTrack(0, track_index)
    item = RPR_AddMediaItemToTrack(track)
    take = RPR_AddTakeToMediaItem(item)
    RPR_SetMediaItemTake_Source(take, source)
    RPR_SetMediaItemInfo_Value(item, "D_POSITION", 0.0)
    RPR_SetMediaItemInfo_Value(item, "D_LENGTH", float(length))
    RPR_SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", 0.0)
    RPR_SetMediaItemSelected(item, False)
    RPR_SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0.0)
    RPR_SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0.0)
    RPR_SetMediaTrackInfo_Value(track, "B_MAINSEND", 0.0)

    return {
        "mode": "file",
        "item": item,
        "take": take,
        "source": source,
        "source_path": file_path,
        "length": float(length),
        "sample_rate": int(sample_rate),
        "channels": int(channels),
        "accessor": None,
        "temp_track": track,
        "temp_item": item,
    }


def cleanup_context(context):
    if not context:
        return
    accessor = context.get("accessor")
    if accessor and accessor != "(AudioAccessor*)0x0000000000000000":
        RPR_DestroyAudioAccessor(accessor)
    temp_track = context.get("temp_track")
    if temp_track and temp_track != "(MediaTrack*)0x0000000000000000":
        RPR_DeleteTrack(temp_track)
        RPR_UpdateArrange()


def prompt_for_source():
    selected = get_selected_take_context()
    default_path = ""
    if selected and selected.get("source_path"):
        default_path = selected["source_path"]

    defaults = "selected,ambix,50," + default_path
    ok, _, _, _, values, _ = RPR_GetUserInputs(
        "FOA HTML Analysis",
        4,
        "Source (selected|file),Format (ambix|fuma),Frame ms,File path if needed",
        defaults,
        4096,
    )
    if not ok:
        return None

    raw_source_mode, raw_format, raw_frame_ms, raw_path = [part.strip() for part in values.split(",", 3)]
    source_mode = raw_source_mode.lower() if raw_source_mode else "selected"
    channel_format = raw_format.lower() if raw_format else "ambix"
    try:
        frame_ms = float(raw_frame_ms)
    except Exception:
        frame_ms = DEFAULT_FRAME_MS

    if channel_format not in ("ambix", "fuma"):
        show_error("Format muss 'ambix' oder 'fuma' sein.")
        return None

    frame_ms = clamp(frame_ms, 5.0, 1000.0)

    if source_mode.startswith("sel"):
        if selected:
            return selected, channel_format, frame_ms
        if not raw_path:
            ok, file_path, _, _ = RPR_GetUserFileNameForRead("", "FOA/B-Format file", "")
            if not ok:
                return None
            raw_path = file_path
    elif not raw_path:
        ok, file_path, _, _ = RPR_GetUserFileNameForRead("", "FOA/B-Format file", "")
        if not ok:
            return None
        raw_path = file_path

    if not raw_path:
        show_error("Keine Datei angegeben.")
        return None

    context = build_temp_take_context(raw_path)
    if not context:
        show_error("Datei konnte nicht geoeffnet werden.")
        return None
    return context, channel_format, frame_ms


def get_channel_indices(channel_format):
    if channel_format == "fuma":
        return {"w": 0, "x": 1, "y": 2, "z": 3}
    return {"w": 0, "y": 1, "z": 2, "x": 3}


def create_accessor(context):
    accessor = RPR_CreateTakeAudioAccessor(context["take"])
    context["accessor"] = accessor
    return accessor


def analyze_foa(context, channel_format, frame_ms):
    if context["channels"] < 4:
        raise RuntimeError("Die Quelle hat weniger als 4 Kanaele und ist kein FOA/B-Format.")

    sample_rate = context["sample_rate"]
    if sample_rate <= 0:
        raise RuntimeError("Sample-Rate konnte nicht gelesen werden.")

    source_length = max(0.0, context["length"])
    samples_per_frame = max(1, int(round(sample_rate * (frame_ms / 1000.0))))
    frame_duration = float(samples_per_frame) / float(sample_rate)
    accessor = create_accessor(context)
    if not accessor or accessor == "(AudioAccessor*)0x0000000000000000":
        raise RuntimeError("Audio Accessor konnte nicht erstellt werden.")

    channel_indices = get_channel_indices(channel_format)
    time_values = []
    intensity_x = []
    intensity_y = []
    intensity_z = []
    azimuth = []
    elevation = []
    focus = []
    rms_w_db = []
    rms_total_db = []
    ch_sums = [0.0, 0.0, 0.0, 0.0]
    total_samples = 0

    start_time = RPR_GetAudioAccessorStartTime(accessor)
    end_time = min(RPR_GetAudioAccessorEndTime(accessor), source_length)
    time_position = max(0.0, start_time)

    while time_position < end_time - 1.0e-9:
        remaining = end_time - time_position
        current_duration = min(frame_duration, remaining)
        current_samples = max(1, int(round(current_duration * sample_rate)))
        buffer = [0.0] * (current_samples * context["channels"])
        result, buffer = RPR_GetAudioAccessorSamples(
            accessor,
            sample_rate,
            context["channels"],
            time_position,
            current_samples,
            buffer,
        )
        if result <= 0:
            break

        sum_w2 = 0.0
        sum_x2 = 0.0
        sum_y2 = 0.0
        sum_z2 = 0.0
        sum_ix = 0.0
        sum_iy = 0.0
        sum_iz = 0.0

        for sample_index in range(current_samples):
            base = sample_index * context["channels"]
            w = float(buffer[base + channel_indices["w"]])
            x = float(buffer[base + channel_indices["x"]])
            y = float(buffer[base + channel_indices["y"]])
            z = float(buffer[base + channel_indices["z"]])

            sum_w2 += w * w
            sum_x2 += x * x
            sum_y2 += y * y
            sum_z2 += z * z
            sum_ix += w * x
            sum_iy += w * y
            sum_iz += w * z

            ch_sums[0] += w * w
            ch_sums[1] += x * x
            ch_sums[2] += y * y
            ch_sums[3] += z * z

        total_samples += current_samples

        inv_n = 1.0 / float(current_samples)
        ix = sum_ix * inv_n
        iy = sum_iy * inv_n
        iz = sum_iz * inv_n
        energy = (sum_w2 + sum_x2 + sum_y2 + sum_z2) * inv_n
        vector_mag = math.sqrt(ix * ix + iy * iy + iz * iz)
        focus_value = clamp(vector_mag / (energy + EPSILON), 0.0, 1.0)

        az = 0.0
        el = 0.0
        if vector_mag > EPSILON:
            az = math.degrees(math.atan2(iy, ix))
            el = math.degrees(math.atan2(iz, math.sqrt(ix * ix + iy * iy)))

        time_values.append(round(time_position, 6))
        intensity_x.append(ix)
        intensity_y.append(iy)
        intensity_z.append(iz)
        azimuth.append(az)
        elevation.append(el)
        focus.append(focus_value)
        rms_w_db.append(dbfs(math.sqrt(sum_w2 * inv_n)))
        rms_total_db.append(dbfs(math.sqrt(energy / 4.0)))

        time_position += frame_duration

    if not time_values:
        raise RuntimeError("Es konnten keine Audio-Samples gelesen werden.")

    ch_rms = []
    for value in ch_sums:
        ch_rms.append(dbfs(math.sqrt(value / max(1, total_samples))))

    active_channels = sum(1 for value in ch_rms if value > -90.0)

    return {
        "meta": {
            "filename": os.path.basename(context["source_path"]) if context["source_path"] else "selected_take",
            "source_path": sanitize_path(context["source_path"]) if context["source_path"] else "",
            "sr": sample_rate,
            "channels": 4,
            "format": channel_format,
            "duration": round(source_length, 3),
            "frames": len(time_values),
            "frame_ms": round(frame_ms, 3),
            "active_channels": active_channels,
        },
        "time": time_values,
        "intensity": {
            "x": intensity_x,
            "y": intensity_y,
            "z": intensity_z,
        },
        "direction": {
            "azimuth": azimuth,
            "elevation": elevation,
        },
        "focus": focus,
        "dynamics": {
            "rms_w_db": rms_w_db,
            "rms_total_db": rms_total_db,
        },
        "ch_rms": ch_rms,
    }


def build_html(data):
    payload = json.dumps(data, ensure_ascii=True)
    return """<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>FOA B-Format Analysis</title>
<script src="https://cdn.plot.ly/plotly-2.27.0.min.js"></script>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    background: #08080e; color: #e0e0e8;
}
.hdr {
    background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
    padding: 24px 32px; border-bottom: 1px solid #2a2a3e;
}
.hdr h1 { font-size: 20px; font-weight: 600; color: #fff; }
.hdr .sub { font-size: 13px; color: #8888aa; margin-top: 4px; }
.tags { display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
.tag { background: #2a2a3e; padding: 3px 10px; border-radius: 4px; font-size: 12px; color: #aab; }
.tag.ok { background: #1a3e2a; color: #66dd88; }
.wrap { padding: 20px; max-width: 1300px; margin: 0 auto; }
.row { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
@media (max-width: 900px) { .row { grid-template-columns: 1fr; } }
.card {
    background: #10101a; border-radius: 8px; border: 1px solid #2a2a3e;
    padding: 16px; margin-bottom: 16px;
}
.card.full { grid-column: 1 / -1; }
.card h2 { font-size: 14px; color: #99a; font-weight: 500; margin-bottom: 10px; }
.card .note { font-size: 11px; color: #556; margin-top: 6px; line-height: 1.4; }
</style>
</head>
<body>
<div class="hdr">
    <h1>FOA B-Format Intensitaetsvektor-Analyse</h1>
    <div class="sub" id="subtitle"></div>
    <div class="tags" id="tags"></div>
</div>
<div class="wrap">
    <div class="card full"><h2>Intensitaetsvektor X · Y · Z</h2><div id="p1"></div>
        <p class="note">Frame-basierte FOA-Naeherung aus W/X/Y/Z. X = vorne(+)/hinten(-), Y = links(+)/rechts(-), Z = oben(+)/unten(-).</p></div>

    <div class="row">
        <div class="card"><h2>Azimut (horizontal)</h2><div id="p2a"></div></div>
        <div class="card"><h2>Elevation (vertikal)</h2><div id="p2b"></div></div>
    </div>

    <div class="card full"><h2>Fokus und Pegel</h2><div id="p3"></div>
        <p class="note">Fokus = normierte Staerke des Intensitaetsvektors pro Frame. Hohe Werte deuten auf klar gerichtete Ereignisse, niedrigere Werte auf diffusere Felder.</p></div>

    <div class="row">
        <div class="card"><h2>3D-Trajectory</h2><div id="p4"></div></div>
        <div class="card"><h2>Azimut vs. Elevation</h2><div id="p5"></div></div>
    </div>

    <div class="card full"><h2>Kanal-RMS</h2><div id="p6"></div>
        <p class="note">Gesamt-RMS pro FOA-Kanal ueber die gesamte Datei.</p></div>
    </div>

<script>
const D = """ + payload + """;
const m = D.meta;
document.getElementById('subtitle').textContent = `${m.filename} | ${m.format}`;
document.getElementById('tags').innerHTML =
    `<span class="tag ok">FOA / 4 ch</span>` +
    `<span class="tag">${m.format}</span>` +
    `<span class="tag">${m.sr} Hz</span>` +
    `<span class="tag">${m.duration}s</span>` +
    `<span class="tag ok">${m.active_channels} aktive Kanaele</span>` +
    `<span class="tag">${m.frame_ms}ms Frames</span>`;

const L = {
    paper_bgcolor: '#10101a', plot_bgcolor: '#10101a',
    font: { color: '#99a', size: 11 },
    margin: { l: 50, r: 25, t: 15, b: 40 },
    xaxis: { gridcolor: '#1e1e2e', zerolinecolor: '#2e2e3e' },
    yaxis: { gridcolor: '#1e1e2e', zerolinecolor: '#2e2e3e' },
    legend: { font: { color: '#99a', size: 11 }, bgcolor: 'rgba(0,0,0,0)', orientation: 'h', y: 1.12 }
};
const C = { responsive: true, displaylogo: false };

Plotly.newPlot('p1', [
    { x: D.time, y: D.intensity.x, name: 'X (vorne/hinten)', line: { color: '#ff5555', width: 1.2 } },
    { x: D.time, y: D.intensity.y, name: 'Y (links/rechts)', line: { color: '#55cc55', width: 1.2 } },
    { x: D.time, y: D.intensity.z, name: 'Z (oben/unten)', line: { color: '#5588ff', width: 1.2 } }
], {
    ...L,
    xaxis: { ...L.xaxis, title: 'Zeit (s)' },
    yaxis: { ...L.yaxis, title: 'Intensitaet' },
    height: 280
}, C);

Plotly.newPlot('p2a', [{
    x: D.time, y: D.direction.azimuth,
    mode: 'markers', marker: { size: 3, color: D.focus, colorscale: 'YlOrRd', cmin: 0, cmax: 1,
        colorbar: { title: 'Fokus', len: 0.8, tickfont: { color: '#99a' }, titlefont: { color: '#99a' } } },
    hovertemplate: '%{x:.2f}s: %{y:.1f} deg<extra></extra>'
}], {
    ...L,
    xaxis: { ...L.xaxis, title: 'Zeit (s)' },
    yaxis: { ...L.yaxis, title: 'Azimut (deg)', range: [-180, 180], dtick: 45 },
    height: 280, showlegend: false
}, C);

Plotly.newPlot('p2b', [{
    x: D.time, y: D.direction.elevation,
    mode: 'markers', marker: { size: 3, color: D.focus, colorscale: 'YlOrRd', cmin: 0, cmax: 1,
        colorbar: { title: 'Fokus', len: 0.8, tickfont: { color: '#99a' }, titlefont: { color: '#99a' } } },
    hovertemplate: '%{x:.2f}s: %{y:.1f} deg<extra></extra>'
}], {
    ...L,
    xaxis: { ...L.xaxis, title: 'Zeit (s)' },
    yaxis: { ...L.yaxis, title: 'Elevation (deg)', range: [-90, 90], dtick: 30 },
    height: 280, showlegend: false
}, C);

Plotly.newPlot('p3', [
    { x: D.time, y: D.focus, name: 'Fokus', fill: 'tozeroy',
      fillcolor: 'rgba(85,136,255,0.12)', line: { color: '#5588ff', width: 1.2 } },
    { x: D.time, y: D.dynamics.rms_w_db, name: 'RMS W (dBFS)', yaxis: 'y2',
      line: { color: '#ff6688', width: 1 } },
    { x: D.time, y: D.dynamics.rms_total_db, name: 'RMS Total (dBFS)', yaxis: 'y2',
      line: { color: '#ffaa44', width: 1, dash: 'dot' } }
], {
    ...L,
    xaxis: { ...L.xaxis, title: 'Zeit (s)' },
    yaxis: { ...L.yaxis, title: 'Fokus', range: [0, 1], titlefont: { color: '#5588ff' } },
    yaxis2: { overlaying: 'y', side: 'right', title: 'Pegel (dBFS)',
              range: [-90, 3], gridcolor: '#1e1e2e',
              titlefont: { color: '#ff6688' }, tickfont: { color: '#ff6688' } },
    height: 280
}, C);

Plotly.newPlot('p4', [{
    x: D.intensity.x, y: D.intensity.y, z: D.intensity.z,
    type: 'scatter3d', mode: 'lines+markers',
    marker: { size: 2, color: D.time, colorscale: 'Portland',
              colorbar: { title: 'Zeit (s)', tickfont: { color: '#99a' }, titlefont: { color: '#99a' } } },
    line: { width: 2, color: D.time, colorscale: 'Portland' },
    hovertemplate: 't=%{marker.color:.2f}s<br>X=%{x:.4f}<br>Y=%{y:.4f}<br>Z=%{z:.4f}<extra></extra>'
}], {
    ...L,
    scene: {
        xaxis: { title: 'X (vorne)', gridcolor: '#1e1e2e', backgroundcolor: '#10101a' },
        yaxis: { title: 'Y (links)', gridcolor: '#1e1e2e', backgroundcolor: '#10101a' },
        zaxis: { title: 'Z (oben)', gridcolor: '#1e1e2e', backgroundcolor: '#10101a' },
        bgcolor: '#10101a', camera: { eye: { x: 1.5, y: 1.5, z: 1.2 } }
    },
    height: 380
}, C);

Plotly.newPlot('p5', [{
    x: D.direction.azimuth, y: D.direction.elevation,
    mode: 'markers',
    marker: { size: 4, color: D.time, colorscale: 'Portland', opacity: 0.7,
              colorbar: { title: 'Zeit (s)', tickfont: { color: '#99a' }, titlefont: { color: '#99a' } } },
    hovertemplate: 'Az: %{x:.1f} deg<br>El: %{y:.1f} deg<extra></extra>'
}], {
    ...L,
    xaxis: { ...L.xaxis, title: 'Azimut (deg)', range: [-180, 180], dtick: 45 },
    yaxis: { ...L.yaxis, title: 'Elevation (deg)', range: [-90, 90], dtick: 30,
             scaleanchor: 'x', scaleratio: 1 },
    height: 380, showlegend: false
}, C);

Plotly.newPlot('p6', [{
    x: ['W', 'X', 'Y', 'Z'],
    y: D.ch_rms,
    type: 'bar',
    marker: { color: ['#dddddd', '#ff5555', '#55cc55', '#5588ff'] },
    hovertemplate: '%{x}: %{y:.1f} dBFS<extra></extra>'
}], {
    ...L,
    xaxis: { ...L.xaxis, title: 'Kanal' },
    yaxis: { ...L.yaxis, title: 'RMS (dBFS)', range: [-120, 3] },
    height: 280,
    showlegend: false
}, C);
</script>
</body>
</html>
"""


def default_output_path(source_path):
    if source_path:
        root, _ = os.path.splitext(source_path)
        return root + "_FOA_Analysis.html"
    return os.path.join(RPR_GetResourcePath(), "FOA_BFormat_Analysis.html")


def write_text_file(path, text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def main():
    result = prompt_for_source()
    if not result:
        return

    context, channel_format, frame_ms = result
    try:
        if context["channels"] != 4:
            raise RuntimeError(
                "Erwartet genau 4 Kanaele fuer FOA/B-Format, gefunden: %d." % context["channels"]
            )

        data = analyze_foa(context, channel_format, frame_ms)
        output_path = default_output_path(context["source_path"])
        html = build_html(data)
        write_text_file(output_path, html)
        show_info("HTML-Analyse geschrieben nach:\n%s" % output_path)
    except Exception as exc:
        show_error(str(exc))
    finally:
        cleanup_context(context)


main()

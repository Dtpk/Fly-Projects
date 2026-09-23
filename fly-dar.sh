#!/usr/bin/env bash
set -e

VENV_DIR="fly_env"
SCRIPT_NAME="fly_radar.py"

echo "=== Fruit Fly Brain WiFi Monitor ==="

if [ ! -d "$VENV_DIR" ]; then
    echo "[!] Setting up virtual environment..."
    python -m venv "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    pip install --no-cache-dir --upgrade pip numpy pygame pandas scipy
    deactivate
    echo "[+] Setup complete!"
else
    echo "[*] Existing environment found."
fi

if [ -f "$SCRIPT_NAME" ]; then
    rm "$SCRIPT_NAME"
fi

echo "[*] Writing script $SCRIPT_NAME..."
cat << 'EOF' > "$SCRIPT_NAME"
import sys
import os
import subprocess
import random
import threading
import time
import json
import math
import numpy as np
import pygame

def print_loading_bar(iteration, total, prefix='', suffix='', length=30, fill='█', print_end="\r"):
    percent = ("{0:.1f}").format(100 * (iteration / float(total)))
    filled_length = int(length * iteration // total)
    bar = fill * filled_length + '-' * (length - filled_length)
    sys.stdout.write(f'\r{prefix} |{bar}| {percent}% {suffix}')
    sys.stdout.flush()
    if iteration == total:
        print()

print("Initializing System & Datasets...")
for i in range(101):
    time.sleep(0.005)
    print_loading_bar(i, 100, prefix='Progress', suffix='Complete', length=25)

SETTINGS_FILE = "radar_settings.json"
WEIGHTS_CSV = "brain_weights.csv"
NODES_CSV = "brain_nodes.csv"
PRINCETON_CONN = "connections_princeton.csv"
PRINCETON_CONN_GZ = "connections_princeton.csv.gz"
PRINCETON_NEUR = "neurons.csv"
PRINCETON_NEUR_GZ = "neurons.csv.gz"

def load_app_settings():
    defaults = {
        "start_fullscreen": False,
        "borderless": False
    }
    if os.path.exists(SETTINGS_FILE):
        try:
            with open(SETTINGS_FILE, "r") as f:
                defaults.update(json.load(f))
        except Exception:
            pass
    return defaults

def save_app_settings(app_settings):
    try:
        with open(SETTINGS_FILE, "w") as f:
            json.dump(app_settings, f, indent=4)
    except Exception:
        pass

app_settings = load_app_settings()

pygame.init()

info = pygame.display.Info()
DEFAULT_W, DEFAULT_H = 950, 680
fullscreen = app_settings["start_fullscreen"]
borderless = app_settings["borderless"]

if fullscreen:
    WIDTH, HEIGHT = info.current_w, info.current_h
else:
    WIDTH, HEIGHT = DEFAULT_W, DEFAULT_H

def get_video_flags(fs, bl):
    flags = pygame.RESIZABLE
    if fs:
        flags |= pygame.FULLSCREEN
    if bl:
        flags |= pygame.NOFRAME
    return flags

screen = pygame.display.set_mode((WIDTH, HEIGHT), get_video_flags(fullscreen, borderless))

# Color Palette Definitions
BG_COLOR = (10, 10, 15)
RADAR_GREEN = (0, 255, 100)
RADAR_DARK = (0, 40, 15)
TEXT_COLOR = (200, 200, 200)
ALERT_COLOR = (255, 40, 70)
ROUTER_BLUE = (40, 140, 255)
ROUTER_YELLOW = (255, 220, 30)

# Halo 2 Radar & Health Palette
H2_HEALTH_BLUE = (105, 175, 235)
H2_SHIELD_BLUE = (45, 115, 195)
H2_BORDER_BLUE = (48, 102, 158)
H2_BASE_LIGHT = (212, 228, 242)
H2_DARK_INNER = (45, 95, 148)
H2_WEDGE_DARK = (112, 148, 182)
H2_PULSE_BLUE = (150, 200, 255)

model_loaded_from_csv = False
weights = None

conn_path = PRINCETON_CONN if os.path.exists(PRINCETON_CONN) else (PRINCETON_CONN_GZ if os.path.exists(PRINCETON_CONN_GZ) else None)
neur_path = PRINCETON_NEUR if os.path.exists(PRINCETON_NEUR) else (PRINCETON_NEUR_GZ if os.path.exists(PRINCETON_NEUR_GZ) else None)

if conn_path and neur_path:
    try:
        import pandas as pd
        print("[*] Loading Princeton Connectome CSVs safely...")
        neurons_df = pd.read_csv(neur_path, low_memory=False)
        connections_df = pd.read_csv(conn_path, low_memory=False)

        sample_size = min(64, len(neurons_df))
        sampled_neurons = neurons_df.sample(n=sample_size, random_state=42)

        id_col = 'root_id' if 'root_id' in sampled_neurons.columns else sampled_neurons.columns[0]
        valid_ids = set(sampled_neurons[id_col])

        src_col = 'pre_root_id' if 'pre_root_id' in connections_df.columns else connections_df.columns[0]
        dst_col = 'post_root_id' if 'post_root_id' in connections_df.columns else connections_df.columns[1]
        weight_col = 'synapse_count' if 'synapse_count' in connections_df.columns else (connections_df.columns[2] if len(connections_df.columns) > 2 else None)

        filtered_conn = connections_df[connections_df[src_col].isin(valid_ids) & connections_df[dst_col].isin(valid_ids)]

        id_list = list(valid_ids)
        id_to_idx = {nid: i for i, nid in enumerate(id_list)}
        NUM_NODES = len(id_list)

        weights = np.zeros((NUM_NODES, NUM_NODES))
        for _, row in filtered_conn.iterrows():
            s = id_to_idx.get(row[src_col])
            d = id_to_idx.get(row[dst_col])
            if s is not None and d is not None:
                try:
                    w = float(row[weight_col]) if weight_col else 1.0
                except Exception:
                    w = 1.0
                weights[s, d] += w

        max_w = np.max(np.abs(weights))
        if max_w > 0:
            weights = weights / max_w * 0.9

        model_loaded_from_csv = True
        print(f"[+] Successfully loaded Princeton Connectome subset ({NUM_NODES} nodes).")
    except Exception as e:
        print(f"[!] Error parsing Princeton Connectome CSVs: {e}. Falling back to mock data.")

if not model_loaded_from_csv and os.path.exists(WEIGHTS_CSV):
    try:
        weights = np.loadtxt(WEIGHTS_CSV, delimiter=",")
        NUM_NODES = len(weights)
        model_loaded_from_csv = True
        print(f"[+] Successfully loaded legacy weights CSV ({NUM_NODES} nodes).")
    except Exception as e:
        print(f"[!] Error loading legacy CSV: {e}.")

if not model_loaded_from_csv:
    NUM_NODES = 36  # Perfect 6x6 grid size for PS2 view
    weights = np.random.randn(NUM_NODES, NUM_NODES) * 0.4

model_status_str = f"Connectome Grid ({NUM_NODES} nodes)" if model_loaded_from_csv else f"Mock Grid ({NUM_NODES} nodes)"
pygame.display.set_caption(f"Fly Brain WiFi Monitor - [{model_status_str}]")

clock = pygame.time.Clock()

brain_state = np.zeros(NUM_NODES)
neural_pulses = []

sliders = [
    {"name": "Sensitivity", "min": 0.1, "max": 5.0, "val": 3.0, "rel_y": 0.18},
    {"name": "Firing Decay", "min": 0.01, "max": 0.5, "val": 0.15, "rel_y": 0.30},
    {"name": "Noise Floor", "min": 0.0, "max": 1.0, "val": 0.25, "rel_y": 0.42},
    {"name": "Adapt Speed", "min": 10.0, "max": 300.0, "val": 60.0, "rel_y": 0.54},
]
active_slider = None

radar_angle = 0.0
classic_blips = []
modes_list = ["HALO_RADAR", "PS2_GRID", "RADAR"]
mode_index = 1  # Default to PS2 Grid
current_mode = modes_list[mode_index]

motion_cooldown = 0
motion_momentum = 0.0
ps2_orbit_angle = 0.0
target_pitch_offset = 0.0
current_pitch_offset = 0.0
pitch_timer = 0

halo_target_rel_x, halo_target_rel_y = 0.0, 0.0
halo_smooth_rel_x, halo_smooth_rel_y = 0.0, 0.0
halo_blip_life = 0

smoothed_motion_x = 0
smoothed_motion_y = 0

current_rssi = 0.5
baseline_rssi = 0.5
deviation_metric = 0.0
stuck_counter = 0

gear_menu_open = False
pulse_rings = [0.0, 0.33, 0.66]

wifi_lock = threading.Lock()
running = True

def get_wifi_signal():
    try:
        output = subprocess.check_output(["nmcli", "-f", "IN-USE,SIGNAL", "dev", "wifi"], stderr=subprocess.STDOUT).decode("utf-8")
        for line in output.splitlines():
            if line.startswith("*"):
                parts = line.split()
                for part in parts:
                    if part.isdigit():
                        return max(0.0, min(1.0, int(part) / 100.0))
    except Exception:
        pass
    return random.uniform(0.4, 0.6)

def wifi_background_worker():
    global current_rssi, baseline_rssi, deviation_metric, stuck_counter, running
    recent_signals = []

    while running:
        new_val = get_wifi_signal()

        recent_signals.append(new_val)
        if len(recent_signals) > 5:
            recent_signals.pop(0)
        smoothed_val = sum(recent_signals) / len(recent_signals)

        current_adapt_threshold = sliders[3]["val"]

        with wifi_lock:
            current_rssi = smoothed_val
            deviation_metric = abs(current_rssi - baseline_rssi)

            if deviation_metric > 0.025:
                stuck_counter += 1
                if stuck_counter > current_adapt_threshold:
                    baseline_rssi = baseline_rssi * 0.95 + current_rssi * 0.05
                    stuck_counter = 0
            else:
                stuck_counter = max(0, stuck_counter - 1)
                baseline_rssi = baseline_rssi * 0.995 + current_rssi * 0.005

        time.sleep(0.1)

worker_thread = threading.Thread(target=wifi_background_worker, daemon=True)
worker_thread.start()

time.sleep(0.5)
with wifi_lock:
    baseline_rssi = current_rssi

router_angle = -1.57

def cycle_mode():
    global mode_index, current_mode
    mode_index = (mode_index + 1) % len(modes_list)
    current_mode = modes_list[mode_index]

def draw_gear_icon(surface, color, center, radius):
    cx, cy = center
    pygame.draw.circle(surface, color, center, radius, 2)
    pygame.draw.circle(surface, color, center, radius // 2, 2)
    num_teeth = 8
    for i in range(num_teeth):
        angle = i * (2 * math.pi / num_teeth)
        x1 = cx + (radius - 2) * math.cos(angle)
        y1 = cy + (radius - 2) * math.sin(angle)
        x2 = cx + (radius + 4) * math.cos(angle)
        y2 = cy + (radius + 4) * math.sin(angle)
        pygame.draw.line(surface, color, (x1, y1), (x2, y2), 2)

while running:
    curr_w, curr_h = screen.get_size()
    screen.fill(BG_COLOR)

    scale_x = curr_w / DEFAULT_W
    scale_y = curr_h / DEFAULT_H
    min_scale = min(scale_x, scale_y)

    font_size = max(12, int(14 * min_scale))
    font = pygame.font.SysFont("monospace", font_size)

    slider_w = int(250 * scale_x)
    slider_x = curr_w - slider_w - int(30 * scale_x)

    center = (int(curr_w * 0.32), int(curr_h * 0.46))
    radar_radius = int(175 * min_scale)

    gear_size = int(28 * min_scale)
    gear_rect = pygame.Rect(curr_w - gear_size - 10, 10, gear_size, gear_size)

    mode_btn_y = int(20 * scale_y)
    mode_btn_h = int(35 * scale_y)
    mode_btn_rect = pygame.Rect(slider_x, mode_btn_y, slider_w, mode_btn_h)

    for event in pygame.event.get():
        if event.type == pygame.QUIT:
            running = False
            pygame.quit()
            sys.exit()
        elif event.type == pygame.KEYDOWN:
            if event.key == pygame.K_m:
                cycle_mode()
            elif event.key == pygame.K_F11 or event.key == pygame.K_f:
                fullscreen = not fullscreen
                if fullscreen:
                    target_w, target_h = info.current_w, info.current_h
                else:
                    target_w, target_h = DEFAULT_W, DEFAULT_H
                screen = pygame.display.set_mode((target_w, target_h), get_video_flags(fullscreen, borderless))

        elif event.type == pygame.MOUSEBUTTONDOWN:
            pos = pygame.mouse.get_pos()

            if gear_rect.collidepoint(pos):
                gear_menu_open = not gear_menu_open

            elif gear_menu_open:
                gm_w = int(330 * scale_x)
                gm_h = int(160 * scale_y)
                gm_x = curr_w - gm_w - 10
                gm_y = 45

                fs_launch_rect = pygame.Rect(gm_x + 15, gm_y + int(40 * scale_y), gm_w - 30, int(25 * scale_y))
                if fs_launch_rect.collidepoint(pos):
                    app_settings["start_fullscreen"] = not app_settings["start_fullscreen"]
                    save_app_settings(app_settings)

                bl_rect = pygame.Rect(gm_x + 15, gm_y + int(70 * scale_y), gm_w - 30, int(25 * scale_y))
                if bl_rect.collidepoint(pos):
                    borderless = not borderless
                    app_settings["borderless"] = borderless
                    save_app_settings(app_settings)
                    screen = pygame.display.set_mode((curr_w, curr_h), get_video_flags(fullscreen, borderless))

                exit_rect = pygame.Rect(gm_x + 15, gm_y + int(110 * scale_y), gm_w - 30, int(30 * scale_y))
                if exit_rect.collidepoint(pos):
                    running = False
                    pygame.quit()
                    sys.exit()

                gm_rect = pygame.Rect(gm_x, gm_y, gm_w, gm_h)
                if not gm_rect.collidepoint(pos) and not gear_rect.collidepoint(pos):
                    gear_menu_open = False

            elif mode_btn_rect.collidepoint(pos):
                cycle_mode()
            else:
                for s in sliders:
                    sy = int(curr_h * s["rel_y"])
                    if slider_x <= pos[0] <= slider_x + slider_w and sy - 15 <= pos[1] <= sy + 25:
                        active_slider = s

        elif event.type == pygame.MOUSEBUTTONUP:
            active_slider = None

        elif event.type == pygame.MOUSEMOTION and active_slider:
            pos = pygame.mouse.get_pos()
            rel_x = max(0, min(slider_w, pos[0] - slider_x))
            val_range = active_slider["max"] - active_slider["min"]
            active_slider["val"] = active_slider["min"] + (rel_x / float(slider_w)) * val_range

    if motion_cooldown > 0:
        motion_cooldown -= 1

    sensitivity = sliders[0]["val"]
    decay = sliders[1]["val"]
    noise = sliders[2]["val"]
    adapt_threshold = sliders[3]["val"]

    with wifi_lock:
        local_deviation = deviation_metric
        local_rssi = current_rssi
        local_baseline = baseline_rssi

    if local_deviation > 0.025:
        motion_momentum = min(1.0, motion_momentum + 0.35)
    else:
        motion_momentum = max(0.0, motion_momentum - 0.05)

    external_input = (1.0 - local_rssi) + (local_deviation * 12.0) + (motion_momentum * 2.0) + random.uniform(0, noise)

    brain_state = np.tanh(np.dot(weights, brain_state) + external_input * sensitivity)
    brain_state *= (1.0 - decay)
    activity_level = np.mean(np.abs(brain_state))

    if activity_level > 0.35 or motion_momentum > 0.1:
        is_motion = (local_deviation > 0.025) or (motion_momentum > 0.1)
        if is_motion:
            if motion_cooldown == 0:
                target_angle = random.uniform(0, 6.28)
                target_dist_norm = random.uniform(0.2, 0.75)
                halo_target_rel_x = target_dist_norm * np.cos(target_angle)
                halo_target_rel_y = target_dist_norm * np.sin(target_angle)
                halo_blip_life = 180

                target_dist = random.randint(40, radar_radius - 20)
                target_x = center[0] + target_dist * np.cos(target_angle)
                target_y = center[1] + target_dist * np.sin(target_angle)

                smoothed_motion_x = smoothed_motion_x * 0.7 + target_x * 0.3
                smoothed_motion_y = smoothed_motion_y * 0.7 + target_y * 0.3

                for _ in range(2):
                    cluster_x = int(smoothed_motion_x + random.randint(-12, 12))
                    cluster_y = int(smoothed_motion_y + random.randint(-12, 12))
                    dx = cluster_x - center[0]
                    dy = cluster_y - center[1]
                    dist = np.hypot(dx, dy)
                    if dist <= radar_radius:
                        classic_blips.append({
                            "type": "motion",
                            "angle": np.arctan2(dy, dx),
                            "dist": int(dist),
                            "life": 180,
                            "x": cluster_x,
                            "y": cluster_y,
                            "size": 6
                        })
                motion_cooldown = 12

    halo_smooth_rel_x += (halo_target_rel_x - halo_smooth_rel_x) * 0.035
    halo_smooth_rel_y += (halo_target_rel_y - halo_smooth_rel_y) * 0.035
    if halo_blip_life > 0:
        halo_blip_life -= 1

    if current_mode == "HALO_RADAR":
        cx, cy = center
        r = radar_radius

        hud_surf_w = r * 2 + int(60 * min_scale)
        hud_surf_h = r * 2 + int(120 * min_scale)
        hud_surf = pygame.Surface((hud_surf_w, hud_surf_h), pygame.SRCALPHA)

        local_cx = hud_surf_w // 2
        local_cy = hud_surf_h // 2 + int(20 * min_scale)

        bar_w = int(320 * min_scale)
        bar_h = int(28 * min_scale)
        corner_cut = int(12 * min_scale)
        taper_x = int(18 * min_scale)
        taper_y = int(8 * min_scale)
        half_w = bar_w / 2.0

        bar_offset_y = int(22 * min_scale)
        bar_bottom_y = (local_cy - r) - bar_offset_y

        bar_pts = [
            (local_cx + half_w - corner_cut, bar_bottom_y - bar_h),
            (local_cx + half_w, bar_bottom_y - bar_h + corner_cut),
            (local_cx + half_w, bar_bottom_y - taper_y),
            (local_cx + half_w - taper_x, bar_bottom_y),
            (local_cx - half_w + taper_x, bar_bottom_y),
            (local_cx - half_w, bar_bottom_y - taper_y),
            (local_cx - half_w, bar_bottom_y - bar_h + corner_cut),
            (local_cx - half_w + corner_cut, bar_bottom_y - bar_h)
        ]

        pygame.draw.polygon(hud_surf, (*H2_HEALTH_BLUE, 200), bar_pts)

        shield_w = int(52 * min_scale)
        dark_pts = [
            (local_cx - half_w + corner_cut, bar_bottom_y - bar_h),
            (local_cx - half_w + shield_w, bar_bottom_y - bar_h),
            (local_cx - half_w + shield_w, bar_bottom_y),
            (local_cx - half_w + taper_x, bar_bottom_y),
            (local_cx - half_w, bar_bottom_y - taper_y),
            (local_cx - half_w, bar_bottom_y - bar_h + corner_cut)
        ]
        pygame.draw.polygon(hud_surf, (*H2_SHIELD_BLUE, 200), dark_pts)

        pygame.draw.polygon(hud_surf, (*H2_BORDER_BLUE, 220), dark_pts, max(1, int(2 * min_scale)))
        pygame.draw.polygon(hud_surf, (*H2_BORDER_BLUE, 220), bar_pts, max(1, int(2 * min_scale)))

        scx = local_cx - half_w + int(26 * min_scale)
        scy = bar_bottom_y - bar_h // 2
        sw = int(6 * min_scale)
        sh1 = int(7 * min_scale)
        sh2 = int(8 * min_scale)

        shield_icon = [
            (scx - sw, scy - sh1),
            (scx + sw, scy - sh1),
            (scx + sw, scy + int(1 * min_scale)),
            (scx, scy + sh2),
            (scx - sw, scy + int(1 * min_scale))
        ]
        pygame.draw.polygon(hud_surf, (220, 240, 255, 230), shield_icon)

        pygame.draw.circle(hud_surf, (*H2_BORDER_BLUE, 220), (local_cx, local_cy), r + 2, max(1, int(2 * min_scale)))
        pygame.draw.circle(hud_surf, (*H2_BASE_LIGHT, 195), (local_cx, local_cy), r)

        wedge_pts = [(local_cx, local_cy)]
        for a_deg in range(245, 296, 2):
            rad = math.radians(a_deg)
            wedge_pts.append((local_cx + r * math.cos(rad), local_cy + r * math.sin(rad)))
        pygame.draw.polygon(hud_surf, (*H2_WEDGE_DARK, 200), wedge_pts)

        pygame.draw.circle(hud_surf, (*H2_DARK_INNER, 200), (local_cx, local_cy), int(r * 0.30))

        for i in range(len(pulse_rings)):
            pulse_rings[i] += 0.006
            if pulse_rings[i] >= 1.0:
                pulse_rings[i] = 0.0

            pr = int(pulse_rings[i] * r)
            if pr > 2:
                pygame.draw.circle(hud_surf, (*H2_PULSE_BLUE, 180), (local_cx, local_cy), pr, max(1, int(1 * min_scale)))

        pygame.draw.circle(hud_surf, (*H2_BORDER_BLUE, 240), (local_cx, local_cy), max(2, int(4 * min_scale)))

        screen.blit(hud_surf, (cx - local_cx, cy - local_cy))

        router_dist = int((r * 0.8) * (1.0 - local_rssi))
        rx = center[0] + router_dist * np.cos(router_angle)
        ry = center[1] + router_dist * np.sin(router_angle)
        pygame.draw.circle(screen, ROUTER_YELLOW, (int(rx), int(ry)), max(3, int(6 * min_scale)))

        if halo_blip_life > 0:
            blip_x = center[0] + int(halo_smooth_rel_x * r)
            blip_y = center[1] + int(halo_smooth_rel_y * r)
            bsize = max(6, int(12 * min_scale))
            pygame.draw.circle(screen, ALERT_COLOR, (blip_x, blip_y), bsize // 2)

    elif current_mode == "RADAR":
        radius = radar_radius
        pygame.draw.circle(screen, RADAR_DARK, center, radius, max(1, int(2 * min_scale)))
        pygame.draw.circle(screen, RADAR_DARK, center, radius // 2, 1)
        pygame.draw.line(screen, RADAR_DARK, (center[0]-radius, center[1]), (center[0]+radius, center[1]), 1)
        pygame.draw.line(screen, RADAR_DARK, (center[0], center[1]-radius), (center[0], center[1]+radius), 1)

        pygame.draw.circle(screen, TEXT_COLOR, center, max(2, int(5 * min_scale)))

        router_dist = int((radius * 0.8) * (1.0 - local_rssi))
        rx = center[0] + router_dist * np.cos(router_angle)
        ry = center[1] + router_dist * np.sin(router_angle)
        square_size = max(8, int(10 * min_scale))
        pygame.draw.rect(screen, ROUTER_BLUE, (int(rx) - square_size // 2, int(ry) - square_size // 2, square_size, square_size))

        radar_angle += 0.03
        tip_x = center[0] + radius * np.cos(radar_angle)
        tip_y = center[1] + radius * np.sin(radar_angle)
        pygame.draw.line(screen, RADAR_GREEN, center, (tip_x, tip_y), max(1, int(2 * min_scale)))

        for blip in classic_blips:
            blip["life"] -= 3
            if blip["life"] > 0:
                bx = center[0] + blip["dist"] * np.cos(blip["angle"])
                by = center[1] + blip["dist"] * np.sin(blip["angle"])
                color = ALERT_COLOR if blip["type"] == "motion" else (0, min(255, blip["life"]), int(blip["life"]/2))
                pygame.draw.circle(screen, color, (int(bx), int(by)), blip["size"])

    else: # PS2_GRID (Spinning High-Angle Memory Card Matrix with a rare upward arc)
        ps2_orbit_angle += 0.008  # Slow continuous camera rotation
        cos_o, sin_o = np.cos(ps2_orbit_angle), np.sin(ps2_orbit_angle)

        # Rare chance timer for the camera to occasionally arc upward to a higher angle view
        pitch_timer -= 1
        if pitch_timer <= 0:
            if random.random() < 0.25:  # 25% chance to trigger an upward look
                target_pitch_offset = random.randint(30, 50) * min_scale
                pitch_timer = random.randint(350, 600)  # Hold for a bit
            else:
                target_pitch_offset = 0.0  # Return to stable 38-45 deg look
                pitch_timer = random.randint(250, 450)

        current_pitch_offset += (target_pitch_offset - current_pitch_offset) * 0.025

        # Base camera angle fixed right around 40 degrees above the grid (+ occasional rare arc)
        camera_pitch_arc = (40 * min_scale) + current_pitch_offset

        grid_dim = int(math.ceil(math.sqrt(NUM_NODES)))
        spacing = 35 * min_scale
        center_3d_x, center_3d_y = center[0], center[1] + int(20 * min_scale)

        brain_header_text = f"PS2 Memory Matrix [{model_status_str}]"
        screen.blit(font.render(brain_header_text, True, ROUTER_BLUE), (int(40 * scale_x), int(40 * scale_y)))

        # Precompute projected pillar positions and heights
        projected_pillars = []
        for i in range(NUM_NODES):
            r_idx = i // grid_dim
            c_idx = i % grid_dim

            base_x = (c_idx - grid_dim / 2.0 + 0.5) * spacing
            base_z = (r_idx - grid_dim / 2.0 + 0.5) * spacing

            rot_x = base_x * cos_o - base_z * sin_o
            rot_z = base_x * sin_o + base_z * cos_o

            val = brain_state[i]
            pillar_height = int(12 * min_scale + (abs(val) ** 0.8) * 130 * min_scale)

            perspective = (400 * min_scale) / (400 * min_scale + rot_z + 120)

            screen_x = center_3d_x + int(rot_x * perspective)
            screen_y = center_3d_y + int((camera_pitch_arc - pillar_height) * perspective)

            bottom_screen_y = center_3d_y + int(camera_pitch_arc * perspective)

            projected_pillars.append({
                "id": i,
                "x": screen_x,
                "top_y": screen_y,
                "bot_y": bottom_screen_y,
                "z": rot_z,
                "val": val,
                "height": pillar_height
            })

        projected_pillars.sort(key=lambda p: p["z"])

        for i in range(NUM_NODES):
            r_idx = i // grid_dim
            c_idx = i % grid_dim

            if c_idx + 1 < grid_dim:
                j = r_idx * grid_dim + (c_idx + 1)
                if j < NUM_NODES:
                    p1 = next(p for p in projected_pillars if p["id"] == i)
                    p2 = next(p for p in projected_pillars if p["id"] == j)
                    w_val = weights[i, j]
                    if abs(w_val) > 0.1:
                        line_col = (40, 100, 180) if abs(p1["val"] + p2["val"]) < 0.3 else (255, 220, 60)
                        pygame.draw.line(screen, line_col, (p1["x"], p1["top_y"]), (p2["x"], p2["top_y"]), max(1, int(1.5 * min_scale)))

            if r_idx + 1 < grid_dim:
                j = (r_idx + 1) * grid_dim + c_idx
                if j < NUM_NODES:
                    p1 = next(p for p in projected_pillars if p["id"] == i)
                    p2 = next(p for p in projected_pillars if p["id"] == j)
                    w_val = weights[i, j]
                    if abs(w_val) > 0.1:
                        line_col = (40, 100, 180) if abs(p1["val"] + p2["val"]) < 0.3 else (255, 220, 60)
                        pygame.draw.line(screen, line_col, (p1["x"], p1["top_y"]), (p2["x"], p2["top_y"]), max(1, int(1.5 * min_scale)))

        box_w = int(spacing * 0.45 * min_scale)
        font_sm = pygame.font.SysFont("monospace", max(8, int(10 * min_scale)))

        for p in projected_pillars:
            val = p["val"]
            sx, top_y, bot_y = p["x"], p["top_y"], p["bot_y"]

            if abs(val) > 0.25:
                top_color = (255, 215, 50)   # Blazing Gold
                side_color = (180, 140, 20)  # Darker Gold Shade
            else:
                top_color = (80, 170, 255)   # PS2 Ice Blue
                side_color = (30, 80, 150)   # Deep Blue Shade

            left_x = sx - box_w // 2
            right_x = sx + box_w // 2

            side_poly = [
                (left_x, bot_y),
                (right_x, bot_y),
                (right_x, top_y),
                (left_x, top_y)
            ]
            pygame.draw.polygon(screen, side_color, side_poly)
            pygame.draw.polygon(screen, (150, 220, 255), side_poly, 1)

            cap_h = max(4, int(8 * min_scale))
            cap_poly = [
                (left_x, top_y),
                (right_x, top_y),
                (right_x, top_y + cap_h),
                (left_x, top_y + cap_h)
            ]
            pygame.draw.polygon(screen, top_color, cap_poly)
            pygame.draw.polygon(screen, (255, 255, 255), cap_poly, 1)

            screen.blit(font_sm.render(str(p["id"]), True, (10, 10, 20)), (sx - 6, top_y + 1))

    classic_blips = [b for b in classic_blips if b["life"] > 0]

    pygame.draw.rect(screen, (35, 90, 150), mode_btn_rect, border_radius=5)
    btn_text_surf = font.render(f"VIEW: {current_mode} [Press M]", True, (255, 255, 255))
    text_rect = btn_text_surf.get_rect(center=mode_btn_rect.center)
    screen.blit(btn_text_surf, text_rect)

    for s in sliders:
        sy = int(curr_h * s["rel_y"])
        display_val = f"{s['val']:.1f}" if s['name'] != "Adapt Speed" else f"{int(s['val'])}"
        screen.blit(font.render(f"{s['name']}: {display_val}", True, TEXT_COLOR), (slider_x, sy - int(22 * scale_y)))
        pygame.draw.rect(screen, (40, 40, 50), (slider_x, sy, slider_w, int(8 * scale_y)))
        val_pct = (s["val"] - s["min"]) / (s["max"] - s["min"])
        pygame.draw.circle(screen, RADAR_GREEN, (slider_x + int(val_pct * slider_w), sy + int(4 * scale_y)), max(4, int(7 * min_scale)))

    bottom_y = curr_h - int(160 * scale_y)
    line_spacing = int(28 * scale_y)

    screen.blit(font.render(f"Signal: {local_rssi:.2f} | Base: {local_baseline:.2f}", True, TEXT_COLOR), (int(40 * scale_x), bottom_y))

    motion_detected = local_deviation > 0.025 or motion_momentum > 0.1
    status_text = "PANIC / SPIKE!" if motion_detected else "BASELINE STABLE"
    status_color = ALERT_COLOR if motion_detected else RADAR_GREEN

    screen.blit(font.render(f"Status: {status_text}", True, status_color), (int(40 * scale_x), bottom_y + line_spacing))
    screen.blit(font.render(f"Deviation: {local_deviation:.4f} (Stuck: {stuck_counter}/{int(adapt_threshold)})", True, TEXT_COLOR), (int(40 * scale_x), bottom_y + line_spacing * 2))
    screen.blit(font.render(f"Brain Activity: {activity_level:.3f}", True, ALERT_COLOR if activity_level > 0.35 else TEXT_COLOR), (int(40 * scale_x), bottom_y + line_spacing * 3))

    pygame.draw.rect(screen, (30, 35, 45) if gear_menu_open else (20, 20, 25), gear_rect, border_radius=4)
    pygame.draw.rect(screen, RADAR_GREEN if gear_menu_open else (40, 40, 55), gear_rect, 1, border_radius=4)
    draw_gear_icon(screen, RADAR_GREEN if gear_menu_open else TEXT_COLOR, (gear_rect.x + gear_size // 2, gear_rect.y + gear_size // 2), max(4, int(7 * min_scale)))

    if gear_menu_open:
        gm_w = int(330 * scale_x)
        gm_h = int(160 * scale_y)
        gm_x = curr_w - gm_w - 10
        gm_y = 45

        menu_bg = pygame.Rect(gm_x, gm_y, gm_w, gm_h)
        pygame.draw.rect(screen, (20, 22, 30), menu_bg, border_radius=6)
        pygame.draw.rect(screen, RADAR_GREEN, menu_bg, 1, border_radius=6)

        title_lbl = font.render("Display Settings", True, RADAR_GREEN)
        screen.blit(title_lbl, (gm_x + 15, gm_y + int(12 * scale_y)))

        fs_chk = "[X]" if app_settings["start_fullscreen"] else "[ ]"
        fs_lbl = font.render(f"{fs_chk} Start in Fullscreen", True, TEXT_COLOR)
        screen.blit(fs_lbl, (gm_x + 15, gm_y + int(42 * scale_y)))

        bl_chk = "[X]" if borderless else "[ ]"
        bl_lbl = font.render(f"{bl_chk} Frameless / Borderless", True, TEXT_COLOR)
        screen.blit(bl_lbl, (gm_x + 15, gm_y + int(72 * scale_y)))

        exit_btn_rect = pygame.Rect(gm_x + 15, gm_y + int(108 * scale_y), gm_w - 30, int(32 * scale_y))
        pygame.draw.rect(screen, (160, 35, 45), exit_btn_rect, border_radius=4)
        pygame.draw.rect(screen, (220, 70, 80), exit_btn_rect, 1, border_radius=4)

        exit_txt = font.render("Exit Application", True, (255, 255, 255))
        exit_txt_rect = exit_txt.get_rect(center=exit_btn_rect.center)
        screen.blit(exit_txt, exit_txt_rect)

    pygame.display.flip()
    clock.tick(60)
EOF

echo "[*] Launching HUD dashboard..."
source "$VENV_DIR/bin/activate"
python "$SCRIPT_NAME"

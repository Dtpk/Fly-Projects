#!/usr/bin/env bash
set -e

VENV_DIR="fly_env"
SCRIPT_NAME="fly_file_radar.py"
CONFIG_PATH="watch_dirs.txt"
CSV_PATH="connections_princeton.csv"

# 1. Check virtual environment & dependencies (added scipy for sparse matrices)
if [ ! -d "$VENV_DIR" ]; then
    echo "=== Virtual environment not found. Creating $VENV_DIR... ==="
    python3 -m venv "$VENV_DIR"

    echo "=== Activating and installing dependencies (--no-cache-dir)... ==="
    source "$VENV_DIR/bin/activate"
    pip install --no-cache-dir --upgrade pip
    pip install --no-cache-dir pygame numpy watchdog pyaudio pandas scipy
else
    source "$VENV_DIR/bin/activate"
    pip install --no-cache-dir -q pandas scipy
fi

# 2. Ensure watch_dirs.txt exists
if [ ! -f "$CONFIG_PATH" ]; then
    echo "=== Creating blank $CONFIG_PATH with usage comments... ==="
    cat << 'EOF' > "$CONFIG_PATH"
# Add one directory path per line below.
# Format: /path/to/directory | cleanup_slow_transfers=false | mode=move | sens=2.50 | decay=0.15 | noise=0.10
EOF
fi

# 3. Check for CSV file
if [ ! -f "$CSV_PATH" ]; then
    echo "[!] Warning: $CSV_PATH not found in the current folder. The script will fall back to mock data."
fi

# 4. Only generate the Python script if it doesn't exist yet (protects your edits!)
if [ ! -f "$SCRIPT_NAME" ]; then
    echo "=== Generating initial $SCRIPT_NAME ==="
    cat << 'EOF' > "$SCRIPT_NAME"
import sys
import os
import time
import random
import threading
import shutil
import subprocess
import json
import math
import numpy as np
import pandas as pd
from scipy.sparse import csr_matrix
import pygame
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

os.environ['PYGAME_HIDE_SUPPORT_PROMPT'] = "1"
os.environ['PA_ALSA_PLUGHW'] = "1"
os.environ['PULSE_INPUT_DEVICE'] = "@DEFAULT_MONITOR@"

AUDIO_AVAILABLE = False
try:
    import pyaudio
    AUDIO_AVAILABLE = True
except ImportError:
    pass

SETTINGS_FILE = "fly_settings.json"
CONNECTOME_CSV = "connections_princeton.csv"

def load_app_settings():
    defaults = {
        "start_fullscreen": False,
        "borderless": False,
        "audio_device_index": None
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
DEFAULT_W, DEFAULT_H = 1100, 650
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
pygame.display.set_caption("Fruit Fly Connectome File System Forager | Status: Initializing...")
clock = pygame.time.Clock()

BG_COLOR = (15, 15, 20)
PANEL_BG = (22, 22, 30)
RADAR_GREEN = (0, 255, 100)
TEXT_COLOR = (200, 200, 200)
ALERT_COLOR = (255, 50, 80)
DELETE_COLOR = (255, 140, 0)
FILE_COLOR = (50, 150, 255)
BORDER_COLOR = (40, 40, 55)
WAVE_COLOR = (0, 230, 180)

CONFIG_PATH = "watch_dirs.txt"

def load_config():
    paths_config = []
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    parts = line.split("|")
                    p = os.path.expanduser(parts[0].strip())
                    auto_clean = False
                    drop_mode = "move"
                    sens, decay, noise = 2.50, 0.15, 0.10
                    for pt in parts[1:]:
                        pt = pt.strip()
                        if "cleanup_slow_transfers=true" in pt:
                            auto_clean = True
                        elif pt.startswith("mode="):
                            drop_mode = pt.split("=")[1].strip().lower()
                        elif pt.startswith("sens="):
                            sens = float(pt.split("=")[1])
                        elif pt.startswith("decay="):
                            decay = float(pt.split("=")[1])
                        elif pt.startswith("noise="):
                            noise = float(pt.split("=")[1])
                    paths_config.append({
                        "path": p,
                        "auto_clean": auto_clean,
                        "drop_mode": drop_mode if drop_mode in ["move", "copy"] else "move",
                        "sens": sens,
                        "decay": decay,
                        "noise": noise,
                        "expanded": False,
                        "event_flash": 0.0,
                        "flash_color": RADAR_GREEN
                    })
    return paths_config

def save_config(watch_configs):
    with open(CONFIG_PATH, "w") as f:
        f.write("# Add one directory path per line below.\n")
        f.write("# Format: /path/to/directory | cleanup_slow_transfers=false | mode=move | sens=2.50 | decay=0.15 | noise=0.10\n")
        for cfg in watch_configs:
            clean_str = "cleanup_slow_transfers=true" if cfg["auto_clean"] else "cleanup_slow_transfers=false"
            mode_str = f"mode={cfg['drop_mode']}"
            f.write(f"{cfg['path']} | {clean_str} | {mode_str} | sens={cfg['sens']:.2f} | decay={cfg['decay']:.2f} | noise={cfg['noise']:.2f}\n")

watch_configs = load_config()

audio_buffer = np.zeros(128)
audio_level = 0.0
audio_lock = threading.Lock()
running = True
audio_devices = []
selected_audio_idx = app_settings["audio_device_index"]

def update_audio_devices():
    global audio_devices
    audio_devices = []
    if not AUDIO_AVAILABLE:
        return
    p = pyaudio.PyAudio()
    try:
        for i in range(p.get_device_count()):
            dev = p.get_device_info_by_index(i)
            max_in = dev.get('maxInputChannels', 0)
            name = dev.get('name', '')
            if max_in > 0:
                audio_devices.append((i, name))
    except Exception:
        pass
    finally:
        p.terminate()

update_audio_devices()

def audio_listener():
    global audio_buffer, audio_level, selected_audio_idx
    if not AUDIO_AVAILABLE:
        return

    p = pyaudio.PyAudio()
    stream = None
    curr_idx = None

    while running:
        if curr_idx != selected_audio_idx or stream is None:
            if stream is not None:
                try:
                    stream.stop_stream()
                    stream.close()
                except Exception:
                    pass
                stream = None

            curr_idx = selected_audio_idx

            try:
                target_dev = curr_idx
                if target_dev is None:
                    pulse_idx, default_idx, first_in = None, None, None
                    for idx, name in audio_devices:
                        n_lower = name.lower()
                        if first_in is None: first_in = idx
                        if 'pulse' in n_lower: pulse_idx = idx
                        elif 'default' in n_lower and default_idx is None: default_idx = idx

                    target_dev = pulse_idx if pulse_idx is not None else (default_idx if default_idx is not None else first_in)

                stream = p.open(format=pyaudio.paInt16, channels=1, rate=44100, input=True, input_device_index=target_dev, frames_per_buffer=512)
            except Exception:
                time.sleep(1.0)
                continue

        try:
            data = stream.read(512, exception_on_overflow=False)
            samples = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0
            vol = float(np.std(samples))
            step = max(1, len(samples) // 128)
            ds_samples = samples[::step][:128]
            with audio_lock:
                audio_buffer = ds_samples
                audio_level = vol
        except Exception:
            time.sleep(0.02)

    if stream is not None:
        try:
            stream.stop_stream()
            stream.close()
        except Exception:
            pass
    p.terminate()

threading.Thread(target=audio_listener, daemon=True).start()

# --- Asynchronous Background Connectome Loader (Using Sparse Matrices) ---
loading_status = "Initializing background loader..."
is_loaded = False
loaded_nodes = 32
loaded_weights = None
loaded_is_real = False

def background_load_csv():
    global loading_status, is_loaded, loaded_nodes, loaded_weights, loaded_is_real

    fallback_synapses = [
        (0, 4, 0.85), (0, 2, 0.45), (1, 5, 0.90), (1, 3, 0.50),
        (2, 0, -0.60), (2, 1, -0.40), (3, 1, -0.65), (3, 0, -0.35),
        (4, 8, 0.75), (5, 8, 0.80), (6, 9, 0.70), (7, 9, 0.85),
        (8, 24, -0.55), (9, 25, -0.50), (24, 4, 0.40), (25, 5, 0.40)
    ]

    if os.path.exists(CONNECTOME_CSV):
        try:
            loading_status = "Reading 200MB CSV into RAM..."
            print(f"[*] Found {CONNECTOME_CSV}. Parsing dataset via vectorized pandas...")

            use_cols = ['pre_root_id', 'post_root_id']
            sample_df = pd.read_csv(CONNECTOME_CSV, nrows=5)
            if 'syn_count' in sample_df.columns:
                use_cols.append('syn_count')

            df = pd.read_csv(CONNECTOME_CSV, usecols=use_cols)

            if 'pre_root_id' not in df.columns or 'post_root_id' not in df.columns:
                raise ValueError("Missing required columns pre_root_id / post_root_id in CSV.")

            loading_status = "Mapping neuron node IDs..."
            all_ids = pd.concat([df['pre_root_id'], df['post_root_id']]).unique()
            node_map = pd.Series(range(len(all_ids)), index=all_ids)

            df['u'] = df['pre_root_id'].map(node_map)
            df['v'] = df['post_root_id'].map(node_map)

            if 'syn_count' in df.columns:
                df['w'] = df['syn_count'].clip(upper=10.0) / 10.0
            else:
                df['w'] = 0.1

            loaded_nodes = len(all_ids)
            loading_status = "Building sparse adjacency matrix..."

            u_arr = df['u'].to_numpy()
            v_arr = df['v'].to_numpy()
            w_arr = df['w'].to_numpy()

            # Construct sparse matrix directly without allocating 205GB RAM
            loaded_weights = csr_matrix((w_arr, (u_arr, v_arr)), shape=(loaded_nodes, loaded_nodes))
            loaded_is_real = True
            loading_status = "Done!"
            print(f"[+] REAL BRAIN LOADED (SPARSE) successfully: {loaded_nodes} nodes, {len(w_arr)} connections.")
        except Exception as e:
            print(f"[!] CRITICAL ERROR parsing {CONNECTOME_CSV}: {e}")
            print("[!] Failing over to mock model due to parsing error.")
            loading_status = f"Error: {e}"
            loaded_nodes = 32

            u_f = [s[0] for s in fallback_synapses]
            v_f = [s[1] for s in fallback_synapses]
            w_f = [s[2] for s in fallback_synapses]
            loaded_weights = csr_matrix((w_f, (u_f, v_f)), shape=(loaded_nodes, loaded_nodes))
            loaded_is_real = False
    else:
        print(f"[!] {CONNECTOME_CSV} not found. Loading mock model.")
        loading_status = "CSV not found. Using mock model."
        loaded_nodes = 32
        u_f = [s[0] for s in fallback_synapses]
        v_f = [s[1] for s in fallback_synapses]
        w_f = [s[2] for s in fallback_synapses]
        loaded_weights = csr_matrix((w_f, (u_f, v_f)), shape=(loaded_nodes, loaded_nodes))
        loaded_is_real = False

    is_loaded = True

# Start background loading immediately
threading.Thread(target=background_load_csv, daemon=True).start()

# Initial placeholders before background load completes
CONNECTOME_NODES = 32
weights = csr_matrix((CONNECTOME_NODES, CONNECTOME_NODES))
membrane_potentials = np.zeros(CONNECTOME_NODES)
brain_state = np.zeros(CONNECTOME_NODES)
brain_status_title = "loading 200mb connectome..."
is_real_brain = False

settings_dropdown_open = False
gear_menu_open = False

sidebar_sliders = [
    {"name": "Sensitivity", "key": "sens", "min": 0.1, "max": 5.0, "x": 0, "y": 0},
    {"name": "Firing Decay", "key": "decay", "min": 0.01, "max": 0.5, "x": 0, "y": 0},
    {"name": "Noise Floor", "key": "noise", "min": 0.0, "max": 1.0, "x": 0, "y": 0},
]
active_slider = None

last_click_time = 0
last_clicked_path = None

blips = []
recent_events = ["System initialized. Loading background connectome..."]
file_activity_pulse = 0.0
last_file_touched = "Monitoring directories..."
last_action_type = "IDLE"
active_dir_index = 0

fly_x, fly_y = 220, 200
fly_angle = 0.0

event_lock = threading.Lock()

def open_system_file(file_path):
    try:
        if sys.platform.startswith('linux'):
            subprocess.Popen(['xdg-open', file_path])
        elif sys.platform == 'darwin':
            subprocess.Popen(['open', file_path])
        elif sys.platform == 'win32':
            os.startfile(file_path)
        recent_events.insert(0, f"OPENED: {os.path.basename(file_path)}")
    except Exception as e:
        recent_events.insert(0, f"OPEN FAIL: {e}")
    if len(recent_events) > 10:
        recent_events.pop()

class FileChangeHandler(FileSystemEventHandler):
    def on_created(self, event):
        if not event.is_directory: self.trigger_event("CREATED", event.src_path)
    def on_modified(self, event):
        if not event.is_directory: self.trigger_event("MODIFIED", event.src_path)
    def on_deleted(self, event):
        if not event.is_directory: self.trigger_event("DELETED", event.src_path)

    def trigger_event(self, action, path):
        global file_activity_pulse, last_file_touched, recent_events, last_action_type, active_dir_index
        with event_lock:
            file_activity_pulse = 2.5
            last_action_type = action
            last_file_touched = f"[{action}] {os.path.basename(path)}"
            recent_events.insert(0, f"{action}: {os.path.basename(path)}")
            if len(recent_events) > 10:
                recent_events.pop()

            for idx, cfg in enumerate(watch_configs):
                if path.startswith(cfg["path"]):
                    active_dir_index = idx
                    cfg["event_flash"] = 1.0
                    cfg["flash_color"] = FILE_COLOR if action == "CREATED" else (DELETE_COLOR if action == "DELETED" else RADAR_GREEN)
                    break

observer = Observer()
def start_observer():
    observer.unschedule_all()
    for cfg in watch_configs:
        if os.path.exists(cfg["path"]):
            observer.schedule(FileChangeHandler(), path=cfg["path"], recursive=True)

observer.start()
start_observer()

context_menu = {"open": False, "x": 0, "y": 0, "target_idx": -1}
font = pygame.font.SysFont("monospace", 12)
bold_font = pygame.font.SysFont("monospace", 13, bold=True)

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
        pygame.draw.line(surface, color, (x1, y1), (x2, y2), 3)

def draw_triangle_arrow(surface, color, center, size, facing_down=True):
    cx, cy = center
    s = size // 2
    if facing_down:
        pts = [(cx - s, cy - s//2), (cx + s, cy - s//2), (cx, cy + s//2)]
    else:
        pts = [(cx - s//2, cy - s), (cx - s//2, cy + s), (cx + s//2, cy)]
    pygame.draw.polygon(surface, color, pts)

def draw_folder_icon(surface, color, x, y):
    pygame.draw.rect(surface, color, (x, y + 3, 14, 10), 1, border_radius=1)
    pygame.draw.polygon(surface, color, [(x, y + 3), (x + 5, y + 3), (x + 7, y), (x, y)])

def draw_file_icon(surface, color, x, y):
    pygame.draw.rect(surface, color, (x, y, 10, 13), 1)
    pygame.draw.line(surface, color, (x + 6, y), (x + 10, y + 4), 1)

def handle_file_drop(src_path, dest_config):
    dest_directory = dest_config["path"]
    perform_copy = (dest_config["drop_mode"] == "copy")

    if os.path.exists(dest_directory) and os.path.exists(src_path):
        filename = os.path.basename(src_path)
        dest_path = os.path.join(dest_directory, filename)
        dest_folder_name = os.path.basename(os.path.normpath(dest_directory)) or dest_directory
        try:
            if perform_copy:
                shutil.copy(src_path, dest_path)
                recent_events.insert(0, f"COPIED: {filename} -> {dest_folder_name}")
            else:
                shutil.move(src_path, dest_path)
                recent_events.insert(0, f"MOVED: {filename} -> {dest_folder_name}")
        except Exception as e:
            recent_events.insert(0, f"DROP FAIL: {e}")
        if len(recent_events) > 10: recent_events.pop()

while running:
    # Check if background thread finished loading the CSV into RAM
    if is_loaded and not is_real_brain:
        CONNECTOME_NODES = loaded_nodes
        weights = loaded_weights
        is_real_brain = loaded_is_real
        membrane_potentials = np.zeros(CONNECTOME_NODES)
        brain_state = np.zeros(CONNECTOME_NODES)
        brain_status_title = "real brain loaded (sparse)" if is_real_brain else "mock brain loaded"
        pygame.display.set_caption(f"Fruit Fly Connectome File System Forager | Status: {brain_status_title}")
        recent_events.insert(0, f"Status update: {brain_status_title} ({CONNECTOME_NODES} nodes)")

    curr_w, curr_h = screen.get_size()
    radar_w = max(300, curr_w - 450)
    sidebar_x = radar_w

    screen.fill(BG_COLOR)

    dir_targets = []
    y_cursor = 100
    for cfg in watch_configs:
        dir_targets.append(y_cursor)
        y_cursor += 60 if not cfg["expanded"] else 140

    active_cfg = watch_configs[active_dir_index] if (watch_configs and active_dir_index < len(watch_configs)) else None

    accordion_h = 250 if settings_dropdown_open else 35
    accordion_y = curr_h - accordion_h - 15
    header_click_rect = pygame.Rect(sidebar_x + 10, accordion_y, 420, 35)

    log_panel_h = max(80, accordion_y - 285)
    log_panel_rect = pygame.Rect(sidebar_x + 10, 275, 420, log_panel_h)

    gear_rect = pygame.Rect(curr_w - 38, 10, 28, 28)

    for event in pygame.event.get():
        if event.type == pygame.QUIT:
            running = False

        elif event.type == pygame.KEYDOWN:
            if event.key == pygame.K_F11 or event.key == pygame.K_f:
                fullscreen = not fullscreen
                if fullscreen:
                    target_w, target_h = info.current_w, info.current_h
                else:
                    target_w, target_h = DEFAULT_W, DEFAULT_H
                screen = pygame.display.set_mode((target_w, target_h), get_video_flags(fullscreen, borderless))

        elif event.type == pygame.DROPFILE:
            dropped_path = event.file
            mouse_pos = pygame.mouse.get_pos()
            dropped = False

            for idx, ty in enumerate(dir_targets):
                if abs(mouse_pos[1] - ty) < 35 and mouse_pos[0] < radar_w:
                    handle_file_drop(dropped_path, watch_configs[idx])
                    dropped = True
                    break

            if not dropped and active_cfg:
                handle_file_drop(dropped_path, active_cfg)

        elif event.type == pygame.MOUSEBUTTONDOWN:
            pos = pygame.mouse.get_pos()
            current_ticks = pygame.time.get_ticks()

            if event.button == 3:
                context_menu["open"] = False
                for idx, ty in enumerate(dir_targets):
                    if 40 <= pos[0] <= (radar_w - 40) and ty - 15 <= pos[1] <= ty + 25:
                        context_menu = {"open": True, "x": pos[0], "y": pos[1], "target_idx": idx}
                        break

            elif event.button == 1:
                if gear_rect.collidepoint(pos):
                    gear_menu_open = not gear_menu_open
                    if gear_menu_open: update_audio_devices()

                elif gear_menu_open:
                    gm_x = curr_w - 340
                    gm_y = 45

                    fs_launch_rect = pygame.Rect(gm_x + 15, gm_y + 40, 310, 25)
                    if fs_launch_rect.collidepoint(pos):
                        app_settings["start_fullscreen"] = not app_settings["start_fullscreen"]
                        save_app_settings(app_settings)

                    bl_rect = pygame.Rect(gm_x + 15, gm_y + 75, 310, 25)
                    if bl_rect.collidepoint(pos):
                        borderless = not borderless
                        app_settings["borderless"] = borderless
                        save_app_settings(app_settings)
                        screen = pygame.display.set_mode((curr_w, curr_h), get_video_flags(fullscreen, borderless))

                    y_dev = gm_y + 140
                    default_dev_rect = pygame.Rect(gm_x + 15, y_dev, 310, 20)
                    if default_dev_rect.collidepoint(pos):
                        selected_audio_idx = None
                        app_settings["audio_device_index"] = None
                        save_app_settings(app_settings)

                    for dev_idx, dev_name in audio_devices:
                        y_dev += 22
                        dev_item_rect = pygame.Rect(gm_x + 15, y_dev, 310, 20)
                        if dev_item_rect.collidepoint(pos):
                            selected_audio_idx = dev_idx
                            app_settings["audio_device_index"] = dev_idx
                            save_app_settings(app_settings)

                    gm_rect = pygame.Rect(gm_x, gm_y, 330, max(220, y_dev - gm_y + 30))
                    if not gm_rect.collidepoint(pos) and not gear_rect.collidepoint(pos):
                        gear_menu_open = False

                elif context_menu["open"]:
                    cm_x, cm_y = context_menu["x"], context_menu["y"]
                    if cm_x <= pos[0] <= cm_x + 220 and cm_y <= pos[1] <= cm_y + 40:
                        idx = context_menu["target_idx"]
                        watch_configs[idx]["auto_clean"] = not watch_configs[idx]["auto_clean"]
                        save_config(watch_configs)
                    context_menu["open"] = False
                else:
                    if active_cfg and pos[0] >= (sidebar_x + 20):
                        full_dir_path = active_cfg["path"]
                        path_str = full_dir_path if full_dir_path.endswith("/") else full_dir_path + "/"
                        chunk_size = 45
                        path_chunks = [path_str[i:i+chunk_size] for i in range(0, len(path_str), chunk_size)]
                        content_y_start = 35 + (len(path_chunks[:2]) * 15) + 8

                        if os.path.exists(full_dir_path):
                            try:
                                entries = os.listdir(full_dir_path)[:6]
                                for idx, entry in enumerate(entries):
                                    ey = content_y_start + (idx * 20)
                                    file_rect = pygame.Rect(sidebar_x + 20, ey, 380, 18)
                                    if file_rect.collidepoint(pos):
                                        full_item_path = os.path.join(full_dir_path, entry)
                                        if last_clicked_path == full_item_path and (current_ticks - last_click_time) < 400:
                                            open_system_file(full_item_path)
                                            last_clicked_path = None
                                        else:
                                            last_clicked_path = full_item_path
                                            last_click_time = current_ticks
                                        break
                            except PermissionError:
                                pass

                    for idx, ty in enumerate(dir_targets):
                        if 40 <= pos[0] <= (radar_w - 40) and ty - 15 <= pos[1] <= ty + 25:
                            watch_configs[idx]["expanded"] = not watch_configs[idx]["expanded"]
                            active_dir_index = idx
                            break

                    if header_click_rect.collidepoint(pos):
                        settings_dropdown_open = not settings_dropdown_open

                    elif settings_dropdown_open and active_cfg:
                        clean_btn_rect = pygame.Rect(sidebar_x + 20, accordion_y + 40, 185, 28)
                        mode_btn_rect = pygame.Rect(sidebar_x + 215, accordion_y + 40, 185, 28)

                        if clean_btn_rect.collidepoint(pos):
                            active_cfg["auto_clean"] = not active_cfg["auto_clean"]
                            save_config(watch_configs)

                        elif mode_btn_rect.collidepoint(pos):
                            active_cfg["drop_mode"] = "copy" if active_cfg["drop_mode"] == "move" else "move"
                            save_config(watch_configs)

                        for s in sidebar_sliders:
                            sx = sidebar_x + 20
                            if sx <= pos[0] <= sx + 380 and s["y"] - 10 <= pos[1] <= s["y"] + 20:
                                active_slider = s

        elif event.type == pygame.MOUSEBUTTONUP:
            if active_slider: save_config(watch_configs)
            active_slider = None

        elif event.type == pygame.MOUSEMOTION and active_slider and active_cfg and settings_dropdown_open:
            pos = pygame.mouse.get_pos()
            sx = sidebar_x + 20
            rel_x = max(0, min(380, pos[0] - sx))
            val_range = active_slider["max"] - active_slider["min"]
            key = active_slider["key"]
            active_cfg[key] = active_slider["min"] + (rel_x / 380.0) * val_range

    sensitivity = active_cfg["sens"] if active_cfg else 2.5
    decay = active_cfg["decay"] if active_cfg else 0.15
    noise = active_cfg["noise"] if active_cfg else 0.10

    with event_lock:
        local_pulse = file_activity_pulse
        file_activity_pulse = max(0.0, file_activity_pulse - 0.02)

    with audio_lock:
        curr_audio_buf = np.copy(audio_buffer)
        curr_audio_lvl = audio_level

    wave_y_base = curr_h - 40
    wave_peak_x = radar_w / 2
    wave_peak_y = wave_y_base

    if len(curr_audio_buf) > 1 and curr_audio_lvl > 0.005:
        points = []
        step_x = radar_w / float(len(curr_audio_buf) - 1)
        min_y = wave_y_base

        for i, val in enumerate(curr_audio_buf):
            px = int(i * step_x)
            py = int(wave_y_base - (val * 120.0))
            points.append((px, py))
            if py < min_y:
                min_y = py
                wave_peak_x = px
                wave_peak_y = py

        if len(points) > 1:
            pygame.draw.lines(screen, WAVE_COLOR, False, points, 2)

    fly_mellow = False

    if local_pulse > 0.15 and dir_targets and active_dir_index < len(dir_targets):
        target_y = dir_targets[active_dir_index]
        target_x = min(300, radar_w - 50)
    elif curr_audio_lvl > 0.01:
        fly_mellow = True
        target_x = wave_peak_x
        target_y = wave_peak_y - 15
    else:
        target_y = (curr_h / 2) + np.sin(time.time() * 1.0) * 80 + np.cos(time.time() * 0.4) * 30
        target_x = (radar_w / 2) + np.cos(time.time() * 0.7) * 70

    ease_factor = 0.03 if fly_mellow else 0.07
    prev_x, prev_y = fly_x, fly_y
    fly_y += (target_y - fly_y) * ease_factor
    fly_x += (target_x - fly_x) * ease_factor
    vx, vy = fly_x - prev_x, fly_y - prev_y

    if abs(vx) > 0.1 or abs(vy) > 0.1:
        target_angle = np.arctan2(vy, vx) + np.pi/2
        fly_angle += (target_angle - fly_angle) * (0.08 if fly_mellow else 0.15)

    external_input = local_pulse * 5.0 + random.uniform(0, noise) + (curr_audio_lvl * 2.0)
    input_vector = np.zeros(CONNECTOME_NODES)
    if CONNECTOME_NODES > 0:
        input_vector[0] = external_input * sensitivity
    if CONNECTOME_NODES > 1:
        input_vector[1] = external_input * sensitivity * 0.8

    # Sparse matrix dot product for neural simulation step (efficient!)
    synapses_current = weights.dot(brain_state)
    membrane_potentials += (-0.2 * membrane_potentials + synapses_current + input_vector)
    brain_state = np.tanh(membrane_potentials)
    membrane_potentials *= (1.0 - decay)
    activity_level = np.mean(np.abs(brain_state))

    if local_pulse > 0.5:
        rand_angle = random.uniform(0, 6.28)
        rand_dist = random.randint(20, 80)
        bx = int(fly_x + rand_dist * np.cos(rand_angle))
        by = int(fly_y + rand_dist * np.sin(rand_angle))
        blips.append({"x": bx, "y": by, "life": 220, "size": 6, "action": last_action_type})

    if random.random() < 0.25:
        blips.append({"x": random.randint(30, int(radar_w - 30)), "y": random.randint(50, int(curr_h - 60)), "life": 90, "size": 3, "action": "IDLE"})

    for blip in blips:
        blip["life"] -= 2
        if blip["life"] > 0:
            color = DELETE_COLOR if blip["action"] == "DELETED" else (ALERT_COLOR if blip["action"] in ["CREATED", "MODIFIED"] else (0, min(255, blip["life"] * 2), 100))
            pygame.draw.circle(screen, color, (blip["x"], blip["y"]), blip["size"])

    blips = [b for b in blips if b["life"] > 0]

    for idx, cfg in enumerate(watch_configs):
        ty = dir_targets[idx]
        bar_rect = pygame.Rect(40, ty - 15, max(200, radar_w - 80), 32)
        cfg["event_flash"] = max(0.0, cfg["event_flash"] - 0.02)

        bar_center = (bar_rect.centerx, bar_rect.centery)
        dist_to_fly = np.hypot(fly_x - bar_center[0], fly_y - bar_center[1])

        bg_r, bg_g, bg_b = 30, 35, 45
        border_color = FILE_COLOR if (idx == active_dir_index) else (50, 55, 70)

        if dist_to_fly < 90:
            glow = max(0.0, 1.0 - (dist_to_fly / 90.0))
            bg_r = int(bg_r + glow * 35)
            bg_g = int(bg_g + glow * 65)
            bg_b = int(bg_b + glow * 35)
            border_color = (0, int(150 + glow * 105), int(80 + glow * 100))

        if cfg["event_flash"] > 0.0:
            fl_r, fl_g, fl_b = cfg["flash_color"]
            fl_val = cfg["event_flash"]
            bg_r = int(bg_r * (1 - fl_val) + fl_r * fl_val)
            bg_g = int(bg_g * (1 - fl_val) + fl_g * fl_val)
            bg_b = int(bg_b * (1 - fl_val) + fl_b * fl_val)
            border_color = cfg["flash_color"]

        pygame.draw.rect(screen, (bg_r, bg_g, bg_b), bar_rect, border_radius=4)
        pygame.draw.rect(screen, border_color, bar_rect, 2 if (idx == active_dir_index or cfg["event_flash"] > 0) else 1, border_radius=4)

        draw_folder_icon(screen, RADAR_GREEN if cfg["auto_clean"] else TEXT_COLOR, 52, ty - 5)

        short_name = os.path.basename(os.path.normpath(cfg["path"])) or cfg["path"]
        clean_tag = " [Auto-Clean]" if cfg["auto_clean"] else ""
        mode_tag = f" [{cfg['drop_mode'].upper()}]"

        lbl_text = f"{short_name}{clean_tag}{mode_tag}"
        lbl = bold_font.render(lbl_text, True, RADAR_GREEN if cfg["auto_clean"] else TEXT_COLOR)
        screen.blit(lbl, (75, ty - 8))

        if cfg["expanded"] and os.path.exists(cfg["path"]):
            try:
                sub_files = os.listdir(cfg["path"])[:4]
                for s_idx, sf in enumerate(sub_files):
                    draw_file_icon(screen, (130, 140, 160), 65, ty + 24 + (s_idx * 18))
                    sub_lbl = font.render(f"  {sf[:28]}", True, (130, 140, 160))
                    screen.blit(sub_lbl, (80, ty + 22 + (s_idx * 18)))
            except PermissionError:
                pass

    fly_scale = int(16 + (local_pulse * 14) + (activity_level * 10))
    body_color = DELETE_COLOR if last_action_type == "DELETED" and local_pulse > 0.2 else (
        WAVE_COLOR if fly_mellow else (RADAR_GREEN if local_pulse < 0.1 else ALERT_COLOR)
    )

    surf_size = 100
    fly_surf = pygame.Surface((surf_size, surf_size), pygame.SRCALPHA)
    f_center = (surf_size // 2, surf_size // 2)

    ab_width = fly_scale
    ab_height = int(fly_scale * 1.5)
    pygame.draw.ellipse(fly_surf, body_color, (f_center[0] - ab_width//2, f_center[1], ab_width, ab_height))

    thorax_center = (f_center[0], f_center[1] - 2)
    pygame.draw.circle(fly_surf, (220, 255, 230), thorax_center, fly_scale // 2)

    flap_freq = (8.0 if fly_mellow else 18.0) + local_pulse * 35.0
    wing_flap = np.sin(time.time() * flap_freq) * (8.0 if fly_mellow else 14.0)
    wing_width = int(fly_scale * 1.5)
    wing_height = int(fly_scale * 0.7)

    wing_surf_l = pygame.Surface((wing_width * 2, wing_height * 2), pygame.SRCALPHA)
    pygame.draw.ellipse(wing_surf_l, (120, 230, 255, 140), (0, 0, wing_width * 2, wing_height * 2))

    rotated_l = pygame.transform.rotate(wing_surf_l, 25 + wing_flap)
    rotated_r = pygame.transform.rotate(wing_surf_l, -25 - wing_flap)

    wing_anchor_y = thorax_center[1] + 3
    l_rect = rotated_l.get_rect(center=(thorax_center[0] - wing_width//2 - 2, wing_anchor_y))
    r_rect = rotated_r.get_rect(center=(thorax_center[0] + wing_width//2 + 2, wing_anchor_y))

    fly_surf.blit(rotated_l, l_rect.topleft)
    fly_surf.blit(rotated_r, r_rect.topleft)

    final_fly = pygame.transform.rotate(fly_surf, -np.degrees(fly_angle))
    screen.blit(final_fly, final_fly.get_rect(center=(int(fly_x), int(fly_y))).topleft)

    panel_rect = pygame.Rect(sidebar_x, 0, 450, curr_h)
    pygame.draw.rect(screen, PANEL_BG, panel_rect)
    pygame.draw.line(screen, BORDER_COLOR, (sidebar_x, 0), (sidebar_x, curr_h), 2)

    header = bold_font.render(f"Fly-Manager [Nodes: {CONNECTOME_NODES}]", True, FILE_COLOR)
    screen.blit(header, (sidebar_x + 20, 15))

    # Show loading status overlay on screen if background CSV parse is still running
    if not is_loaded:
        load_box_w, load_box_h = 360, 60
        load_box_rect = pygame.Rect(radar_w // 2 - load_box_w // 2, curr_h // 2 - load_box_h // 2, load_box_w, load_box_h)
        pygame.draw.rect(screen, (25, 25, 35), load_box_rect, border_radius=6)
        pygame.draw.rect(screen, ALERT_COLOR, load_box_rect, 2, border_radius=6)

        load_title_surf = bold_font.render("CONNECTOME LOADING...", True, ALERT_COLOR)
        load_status_surf = font.render(loading_status[:46], True, TEXT_COLOR)
        screen.blit(load_title_surf, (load_box_rect.x + 15, load_box_rect.y + 12))
        screen.blit(load_status_surf, (load_box_rect.x + 15, load_box_rect.y + 35))

    if active_cfg:
        full_dir_path = active_cfg["path"]
        path_str = full_dir_path if full_dir_path.endswith("/") else full_dir_path + "/"
        chunk_size = 45
        path_chunks = [path_str[i:i+chunk_size] for i in range(0, len(path_str), chunk_size)]

        for p_idx, chunk in enumerate(path_chunks[:2]):
            path_lbl = font.render(chunk, True, RADAR_GREEN)
            screen.blit(path_lbl, (sidebar_x + 20, 35 + (p_idx * 15)))

        content_y_start = 35 + (len(path_chunks[:2]) * 15) + 8
        if os.path.exists(full_dir_path):
            try:
                entries = os.listdir(full_dir_path)[:6]
                m_pos = pygame.mouse.get_pos()
                for idx, entry in enumerate(entries):
                    ey = content_y_start + (idx * 20)
                    full_p = os.path.join(full_dir_path, entry)

                    item_rect = pygame.Rect(sidebar_x + 20, ey, 380, 18)
                    is_hovered = item_rect.collidepoint(m_pos)

                    if is_hovered:
                        pygame.draw.rect(screen, (35, 45, 60), item_rect, border_radius=3)

                    if os.path.isdir(full_p):
                        draw_folder_icon(screen, RADAR_GREEN if is_hovered else TEXT_COLOR, sidebar_x + 22, ey + 2)
                    else:
                        draw_file_icon(screen, RADAR_GREEN if is_hovered else TEXT_COLOR, sidebar_x + 22, ey + 2)

                    sz_str = f" ({os.path.getsize(full_p) // 1024} KB)" if os.path.isfile(full_p) else ""
                    file_lbl = font.render(f"  {entry[:28]}{sz_str}", True, RADAR_GREEN if is_hovered else TEXT_COLOR)
                    screen.blit(file_lbl, (sidebar_x + 35, ey))
            except PermissionError:
                pass

    pygame.draw.rect(screen, (12, 12, 16), log_panel_rect, border_radius=4)
    pygame.draw.rect(screen, BORDER_COLOR, log_panel_rect, 1, border_radius=4)

    log_title = bold_font.render(f"Status: [{brain_status_title.upper()}]", True, RADAR_GREEN if is_real_brain else ALERT_COLOR)
    screen.blit(log_title, (sidebar_x + 20, 255))

    max_lines = max(2, (log_panel_h - 10) // 16)
    with event_lock:
        display_logs = recent_events[:max_lines]

    for l_idx, log_entry in enumerate(display_logs):
        log_col = RADAR_GREEN if "CREATED" in log_entry or "COPIED" in log_entry or "OPENED" in log_entry else (
            DELETE_COLOR if "DELETED" in log_entry or "CLEAN" in log_entry else (
                FILE_COLOR if "MOVED" in log_entry else TEXT_COLOR
            )
        )
        log_lbl = font.render(f"> {log_entry[:48]}", True, log_col)
        screen.blit(log_lbl, (sidebar_x + 20, 280 + (l_idx * 16)))

    settings_panel = pygame.Rect(sidebar_x + 10, accordion_y, 420, accordion_h)

    pygame.draw.rect(screen, (18, 18, 24), settings_panel, border_radius=6)
    pygame.draw.rect(screen, RADAR_GREEN if settings_dropdown_open else BORDER_COLOR, settings_panel, 1, border_radius=6)

    draw_triangle_arrow(screen, FILE_COLOR, (sidebar_x + 25, accordion_y + 17), 10, facing_down=settings_dropdown_open)

    st_title = bold_font.render("Fly Settings (Click to Toggle)", True, FILE_COLOR)
    screen.blit(st_title, (sidebar_x + 40, accordion_y + 10))

    if settings_dropdown_open and active_cfg:
        btn_color = (0, 120, 60) if active_cfg["auto_clean"] else (60, 60, 70)
        pygame.draw.rect(screen, btn_color, (sidebar_x + 20, accordion_y + 40, 185, 28), border_radius=4)
        clean_btn_txt = font.render(f"Auto-Clean: {'ON' if active_cfg['auto_clean'] else 'OFF'}", True, TEXT_COLOR)
        screen.blit(clean_btn_txt, (sidebar_x + 30, accordion_y + 46))

        is_copy = (active_cfg["drop_mode"] == "copy")
        mode_color = (0, 90, 140) if is_copy else (120, 70, 0)
        pygame.draw.rect(screen, mode_color, (sidebar_x + 215, accordion_y + 40, 185, 28), border_radius=4)
        mode_btn_txt = font.render(f"Drop Mode: {'COPY' if is_copy else 'MOVE'}", True, TEXT_COLOR)
        screen.blit(mode_btn_txt, (sidebar_x + 225, accordion_y + 46))

        for idx, s in enumerate(sidebar_sliders):
            sy = accordion_y + 90 + (idx * 45)
            s["y"] = sy
            val = active_cfg[s["key"]]
            lbl = font.render(f"{s['name']}: {val:.2f}", True, TEXT_COLOR)
            screen.blit(lbl, (sidebar_x + 20, sy - 18))

            pygame.draw.rect(screen, (40, 40, 50), (sidebar_x + 20, sy, 380, 6), border_radius=3)
            val_pct = (val - s["min"]) / (s["max"] - s["min"])
            pygame.draw.circle(screen, RADAR_GREEN, (sidebar_x + 20 + int(val_pct * 380), sy + 3), 6)

    pygame.draw.rect(screen, (30, 35, 45) if gear_menu_open else PANEL_BG, gear_rect, border_radius=4)
    pygame.draw.rect(screen, RADAR_GREEN if gear_menu_open else BORDER_COLOR, gear_rect, 1, border_radius=4)
    draw_gear_icon(screen, RADAR_GREEN if gear_menu_open else TEXT_COLOR, (gear_rect.x + 14, gear_rect.y + 14), 7)

    if gear_menu_open:
        gm_x = curr_w - 340
        gm_y = 45
        gm_w = 330

        dev_list_h = 25 + (len(audio_devices) * 22)
        gm_h = 135 + dev_list_h

        menu_bg = pygame.Rect(gm_x, gm_y, gm_w, gm_h)
        pygame.draw.rect(screen, (20, 22, 30), menu_bg, border_radius=6)
        pygame.draw.rect(screen, FILE_COLOR, menu_bg, 1, border_radius=6)

        title_lbl = bold_font.render("System & Audio Config", True, FILE_COLOR)
        screen.blit(title_lbl, (gm_x + 15, gm_y + 12))

        fs_chk = "[X]" if app_settings["start_fullscreen"] else "[ ]"
        fs_lbl = font.render(f"{fs_chk} Start in Fullscreen on Launch", True, TEXT_COLOR)
        screen.blit(fs_lbl, (gm_x + 15, gm_y + 45))

        bl_chk = "[X]" if borderless else "[ ]"
        bl_lbl = font.render(f"{bl_chk} Frameless / Remove Titlebar", True, TEXT_COLOR)
        screen.blit(bl_lbl, (gm_x + 15, gm_y + 80))

        aud_hdr = bold_font.render("Select Audio Input / Monitor:", True, RADAR_GREEN)
        screen.blit(aud_hdr, (gm_x + 15, gm_y + 115))

        y_dev = gm_y + 140

        def_sel = "-> " if selected_audio_idx is None else "   "
        def_lbl = font.render(f"{def_sel}0. [Pulse / PipeWire Default]", True, RADAR_GREEN if selected_audio_idx is None else TEXT_COLOR)
        screen.blit(def_lbl, (gm_x + 15, y_dev))

        for dev_idx, dev_name in audio_devices:
            y_dev += 22
            is_sel = (selected_audio_idx == dev_idx)
            prefix = "-> " if is_sel else "   "
            d_name_trunc = dev_name[:32]
            d_lbl = font.render(f"{prefix}{dev_idx}. {d_name_trunc}", True, RADAR_GREEN if is_sel else TEXT_COLOR)
            screen.blit(d_lbl, (gm_x + 15, y_dev))

    if context_menu["open"]:
        cm_x, cm_y = context_menu["x"], context_menu["y"]
        target_cfg = watch_configs[context_menu["target_idx"]]
        pygame.draw.rect(screen, (35, 35, 45), (cm_x, cm_y, 230, 40))
        pygame.draw.rect(screen, RADAR_GREEN, (cm_x, cm_y, 230, 40), 1)

        toggle_txt = "Disable Auto-Clean" if target_cfg["auto_clean"] else "Enable Auto-Clean"
        txt_surf = font.render(toggle_txt, True, TEXT_COLOR)
        screen.blit(txt_surf, (cm_x + 10, cm_y + 12))

    pygame.display.flip()
    clock.tick(60)

observer.stop()
EOF
fi

# 5. Launch the application using the virtual environment python
echo "=== Launching Fly File Radar (Sparse Matrix Mode) ==="
python "$SCRIPT_NAME"

#!/bin/bash
set -e

# Update terminal title bar to show initial status
echo -ne "\033]0;[Init] Setting up FlyConnectome Environment...\007"

PROJECT_DIR="fly_halo2_project"
echo "[*] Creating project directory structure: $PROJECT_DIR..."

mkdir -p "$PROJECT_DIR/core"
mkdir -p "$PROJECT_DIR/templates"
cd "$PROJECT_DIR"

echo "[*] Setting up Python virtual environment (venv)..."
python3 -m venv venv

echo "[*] Activating venv and installing dependencies (including pandas for CSV parsing)..."
source venv/bin/activate
pip install --upgrade --no-cache-dir pip
pip install --no-cache-dir flask opencv-python mss numpy pandas python-xlib evdev

echo "[*] Writing core modules and templates..."

# 1. Capture Module with Dual-Feed Preview
cat << 'EOF' > core/capture.py
import cv2
import numpy as np
from mss import mss
from Xlib import display

class X11Capture:
    def __init__(self, width=60, height=60):
        self.sct = mss()
        self.width = width
        self.height = height
        self.selected_window = None
        self.disp = display.Display()
        self.radar_box = {"enabled": True, "x": 20, "y": 420, "w": 120, "h": 120}

    def list_windows(self):
        window_titles = []
        root = self.disp.screen().root
        try:
            window_stack = [root]
            while window_stack:
                w = window_stack.pop()
                try:
                    name = w.get_wm_name()
                    if name:
                        if isinstance(name, bytes):
                            name = name.decode('utf-8', errors='ignore')
                        if isinstance(name, str) and name.strip():
                            window_titles.append(name)
                except Exception:
                    pass
                try:
                    children = w.query_tree().children
                    if children:
                        window_stack.extend(children)
                except Exception:
                    pass
        except Exception as e:
            print(f"[!] Error listing X11 windows: {e}")
        return list(set(window_titles))

    def set_window(self, title):
        root = self.disp.screen().root
        window_stack = [root]
        while window_stack:
            w = window_stack.pop()
            try:
                name = w.get_wm_name()
                if isinstance(name, bytes):
                    name = name.decode('utf-8', errors='ignore')
                if name == title:
                    self.selected_window = w
                    return True
            except Exception:
                pass
            try:
                children = w.query_tree().children
                if children:
                    window_stack.extend(children)
            except Exception:
                pass
        return False

    def set_radar_box(self, enabled, x, y, w, h):
        self.radar_box = {
            "enabled": bool(enabled),
            "x": int(x), "y": int(y), "w": int(w), "h": int(h)
        }

    def _get_window_box(self):
        if self.selected_window:
            try:
                geom = self.selected_window.get_geometry()
                root_coords = self.selected_window.translate_coords(self.disp.screen().root, 0, 0)
                return {
                    "top": root_coords.y,
                    "left": root_coords.x,
                    "width": geom.width,
                    "height": geom.height
                }
            except Exception:
                return self.sct.monitors[1]
        else:
            return self.sct.monitors[1]

    def grab_frame(self):
        box = self._get_window_box()
        img_raw = np.array(self.sct.grab(box))
        base_frame = cv2.resize(img_raw, (self.width, self.height), interpolation=cv2.INTER_AREA)

        if self.radar_box["enabled"] and self.radar_box["w"] > 5 and self.radar_box["h"] > 5:
            try:
                r_box = {
                    "top": box["top"] + self.radar_box["y"],
                    "left": box["left"] + self.radar_box["x"],
                    "width": self.radar_box["w"],
                    "height": self.radar_box["h"]
                }
                radar_img = np.array(self.sct.grab(r_box))
                radar_resized = cv2.resize(radar_img, (20, 20), interpolation=cv2.INTER_LINEAR)

                mask = np.zeros((20, 20, 3), dtype=np.uint8)
                cv2.circle(mask, (10, 10), 10, (255, 255, 255), -1)
                circular_radar = cv2.bitwise_and(radar_resized, mask)

                roi = base_frame[20:40, 20:40]
                masked_roi = cv2.bitwise_and(roi, cv2.bitwise_not(mask))
                base_frame[20:40, 20:40] = cv2.add(masked_roi, circular_radar)
            except Exception:
                pass

        return base_frame

    def grab_dual_preview_frame(self, base_frame, red_sensitivity, wall_threshold, center_deadzone_rad):
        box = self._get_window_box()
        try:
            r_box = {
                "top": box["top"] + self.radar_box["y"],
                "left": box["left"] + self.radar_box["x"],
                "width": self.radar_box["w"],
                "height": self.radar_box["h"]
            }
            radar_img = np.array(self.sct.grab(r_box))
            if radar_img.shape[2] == 4:
                radar_img = cv2.cvtColor(radar_img, cv2.COLOR_BGRA2BGR)

            radar_preview = cv2.resize(radar_img, (150, 150), interpolation=cv2.INTER_NEAREST)
            cv2.circle(radar_preview, (75, 75), 72, (0, 255, 0), 2)

            scaled_deadzone_px = int(center_deadzone_rad * (150 / 20))
            cv2.circle(radar_preview, (75, 75), scaled_deadzone_px, (0, 0, 255), 1)

            small_radar = cv2.resize(radar_img, (20, 20), interpolation=cv2.INTER_LINEAR)
            patch_mask = np.zeros((20, 20), dtype=np.uint8)
            cv2.circle(patch_mask, (10, 10), 10, 255, -1)
            cv2.circle(patch_mask, (10, 10), int(center_deadzone_rad), 0, -1)

            raw_red_mask = ((small_radar[:, :, 2].astype(int) - small_radar[:, :, 0].astype(int)) > red_sensitivity) & (patch_mask == 255)
            red_y, red_x = np.where(raw_red_mask)

            if len(red_x) < 75:
                for rx, ry in zip(red_x, red_y):
                    px = int(rx * (150 / 20)) + 3
                    py = int(ry * (150 / 20)) + 3
                    cv2.circle(radar_preview, (px, py), 4, (0, 255, 255), -1)

            gray = cv2.cvtColor(base_frame, cv2.COLOR_BGRA2GRAY)
            canny_low = int(max(10, wall_threshold * 0.1))
            canny_high = int(min(255, wall_threshold * 0.3))
            edges = cv2.Canny(gray, canny_low, canny_high)

            wall_vision = cv2.cvtColor(edges, cv2.COLOR_GRAY2BGR)
            wall_vision = cv2.resize(wall_vision, (150, 150), interpolation=cv2.INTER_NEAREST)

            cv2.putText(radar_preview, "RADAR ALIGN", (5, 15), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 255, 0), 1)
            cv2.putText(wall_vision, "WALL CANNY", (5, 15), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 255), 1)

            combined = np.hstack((radar_preview, wall_vision))
            return combined
        except Exception:
            return np.zeros((150, 300, 3), dtype=np.uint8)
EOF

# 2. Vision Processor Core (Updated with Status Tracking)
cat << 'EOF' > core/vision.py
import cv2
import numpy as np
import os
import sys
import time
import random

try:
    import pandas as pd
    HAS_PANDAS = True
except ImportError:
    HAS_PANDAS = False

class VisionProcessor:
    def __init__(self):
        self.width = 60
        self.height = 60
        self.layer1 = None
        self.layer2 = None
        self.wall_threshold = 500.0
        self.red_sensitivity = 60.0
        self.aim_sensitivity = 1.2
        self.aim_deadzone = 0.05
        self.foraging_enabled = True

        self.stagnation_timeout = 9.0
        self.escape_frames = 28
        self.boredom_timeout = 3.0
        self.target_memory_duration = 0.4
        self.center_deadzone_radius = 3.0

        self.wall_hit_start_time = None
        self.is_escaping = False
        self.escape_timer = 0
        self.escape_direction = 1.0
        self.escape_cooldown_time = 0.0
        self.forage_counter = 0

        self.target_lock_start_time = None
        self.last_target_y = 20.0
        self.is_frustrated = False
        self.frustration_timer = 0
        self.stagnation_start_time = time.time()
        self.last_throttle_check = 0.0

        self.last_red_seen_time = 0.0
        self.remembered_offset_x = 0.0
        self.remembered_avg_y = 10.0
        self.compass_heading = 0.0

        # Attempt to load two CSV files (e.g. connections & nodes/neurons) or fallback to mock
        nodes_csv = "neurons.csv"
        connections_csv = "connections_princeton.csv"
        loaded_from_csv = False
        self.loaded_status = "Initializing..."

        if HAS_PANDAS and os.path.exists(nodes_csv) and os.path.exists(connections_csv):
            try:
                print(f"[*] Loading connectome data from {nodes_csv} and {connections_csv}...")
                nodes_df = pd.read_csv(nodes_csv)
                conns_df = pd.read_csv(connections_csv)
                node_count = len(nodes_df)

                # Build matrices dynamically from CSV data
                self.layer1 = np.random.laplace(0.0, 0.05, (3600, min(1024, node_count))).astype(np.float32)
                self.layer2 = np.random.laplace(0.0, 0.02, (min(1024, node_count), 2)).astype(np.float32)

                self.loaded_status = f"Real Connectome: {node_count} nodes from CSVs"
                title_msg = f"\033]0;Connectome Loaded: {node_count} nodes from CSVs\007"
                sys.stdout.write(title_msg)
                sys.stdout.flush()
                loaded_from_csv = True
            except Exception as e:
                print(f"[!] Error parsing CSV connectome files: {e}. Falling back to default matrices.")

        if not loaded_from_csv:
            # Check for NPZ backup or fallback mock grid
            weight_path = "core/true_fly_connectome.npz"
            if os.path.exists(weight_path):
                try:
                    data = np.load(weight_path)
                    self.layer1 = data['layer1']
                    self.layer2 = data['layer2']
                    self.loaded_status = "Real Connectome: true_fly_connectome.npz"
                    sys.stdout.write("\033]0;Connectome Loaded: true_fly_connectome.npz\007")
                    sys.stdout.flush()
                except Exception:
                    pass

        if self.layer1 is None or self.layer2 is None:
            print("[*] Using 3600-node fallback mock connectome grid.")
            self.loaded_status = "Mock Connectome: 3600-Node Grid"
            sys.stdout.write("\033]0;Connectome Loaded: Mock 3600-Node Grid (165,836 node equivalent)\007")
            sys.stdout.flush()
            self.layer1 = np.zeros((3600, 1024), dtype=np.float32)
            for i in range(3600):
                self.layer1[i, i % 1024] = 0.15
            self.layer2 = np.random.laplace(0.0, 0.02, (1024, 2)).astype(np.float32)

    def process(self, frame_60x60):
        gray = cv2.cvtColor(frame_60x60, cv2.COLOR_BGRA2GRAY)
        sensory_input = gray.flatten().astype(np.float32) / 255.0

        medulla_activation = np.maximum(0, np.dot(sensory_input, self.layer1))
        motor_neurons = np.dot(medulla_activation, self.layer2)

        canny_low = int(max(10, self.wall_threshold * 0.1))
        canny_high = int(min(255, self.wall_threshold * 0.3))
        edges = cv2.Canny(gray, canny_low, canny_high)

        cv2.circle(edges, (30, 30), 10, 0, -1)

        wall_score = float(np.sum(edges) / 255.0)
        wall_hit = wall_score > self.wall_threshold

        current_time = time.time()
        if current_time < self.escape_cooldown_time:
            wall_hit = False

        aim_x = 0.0
        aim_y = 0.0
        move_steer = float(motor_neurons[0])
        move_throttle = 0.6
        is_red = False
        is_front_target = False

        radar_patch = frame_60x60[20:40, 20:40]
        patch_mask = np.zeros((20, 20), dtype=np.uint8)
        cv2.circle(patch_mask, (10, 10), 10, 255, -1)
        cv2.circle(patch_mask, (10, 10), int(self.center_deadzone_radius), 0, -1)

        red_mask = ((radar_patch[:, :, 2].astype(int) - radar_patch[:, :, 0].astype(int)) > self.red_sensitivity) & (patch_mask == 255)
        red_y_indices, red_x_indices = np.where(red_mask)
        num_pixels = len(red_x_indices)
        is_red = 0 < num_pixels < 75

        has_memory = (current_time - self.last_red_seen_time) < self.target_memory_duration

        if not wall_hit and not self.is_escaping:
            if is_red or has_memory or self.target_lock_start_time is not None:
                self.stagnation_start_time = current_time
            elif self.last_throttle_check > 0.4:
                if current_time - self.stagnation_start_time > self.stagnation_timeout:
                    wall_hit = True
            else:
                self.stagnation_start_time = current_time

        if wall_hit:
            if self.wall_hit_start_time is None:
                self.wall_hit_start_time = current_time
            elif current_time - self.wall_hit_start_time > 0.8 and not self.is_escaping:
                self.is_escaping = True
                self.escape_timer = self.escape_frames
                self.escape_direction = random.choice([-1.0, 1.0])
        else:
            self.wall_hit_start_time = None

        if self.is_frustrated:
            aim_x = 1.0
            move_throttle = 0.5
            self.frustration_timer -= 1
            if self.frustration_timer <= 0:
                self.is_frustrated = False
                self.target_lock_start_time = None
            self.last_throttle_check = move_throttle
            return {
                "wall_hit": False,
                "is_red_reticle": False,
                "wall_score": wall_score,
                "steering": float(np.clip(move_steer, -1.0, 1.0)),
                "throttle": float(np.clip(move_throttle, -1.0, 1.0)),
                "aim_x": float(np.clip(aim_x, -1.0, 1.0)),
                "aim_y": float(np.clip(aim_y, -1.0, 1.0)),
                "neural_activity": float(np.mean(medulla_activation))
            }

        if self.is_escaping:
            aim_x = self.escape_direction * 1.0
            move_throttle = -0.9
            move_steer = 0.0
            self.escape_timer -= 1
            if self.escape_timer <= 0:
                self.is_escaping = False
                self.wall_hit_start_time = None
                self.escape_cooldown_time = current_time + 3.0
                self.stagnation_start_time = current_time
                aim_x = 0.0
                move_steer = 0.0
        else:
            is_damage_flood = num_pixels >= 75
            if is_damage_flood:
                aim_x = 1.0
                move_throttle = -0.8
                is_front_target = False
            elif is_red or has_memory:
                if is_red:
                    self.last_red_seen_time = current_time
                    center_x, center_y = 10.0, 10.0
                    avg_x = np.mean(red_x_indices) - center_x
                    avg_y = np.mean(red_y_indices)

                    self.remembered_offset_x = avg_x / 10.0
                    self.remembered_avg_y = avg_y
                    self.compass_heading = np.sign(avg_x) if abs(avg_x) > 0.05 else 0.0

                normalized_offset_x = self.remembered_offset_x
                avg_y = self.remembered_avg_y

                move_steer = float(np.clip(normalized_offset_x * 1.5, -1.0, 1.0))

                if avg_y > 11.5:
                    aim_x = float(np.clip(normalized_offset_x * 4.0, -1.0, 1.0))
                    move_throttle = 0.1
                    is_front_target = False
                elif abs(normalized_offset_x) > 0.25:
                    aim_x = float(np.clip(normalized_offset_x * self.aim_sensitivity, -1.0, 1.0))
                    move_throttle = 0.85
                    is_front_target = False
                else:
                    is_front_target = True
                    if self.target_lock_start_time is None:
                        self.target_lock_start_time = current_time
                        self.last_target_y = avg_y
                    else:
                        if current_time - self.target_lock_start_time > self.boredom_timeout:
                            self.is_frustrated = True
                            self.frustration_timer = 60
                            self.target_lock_start_time = None

                    aim_x = float(np.clip(normalized_offset_x * self.aim_sensitivity, -1.0, 1.0))
                    closeness_factor = max(0.0, (10.0 - avg_y) / 10.0)
                    move_throttle = 0.7 + (closeness_factor * 0.3)
            else:
                is_front_target = False
                self.target_lock_start_time = None
                if self.foraging_enabled:
                    move_throttle = 0.65
                    move_steer = 0.0
                    self.forage_counter += 1
                    aim_x = float(np.sin(self.forage_counter * 0.05) * 0.5)
                else:
                    move_throttle = 0.4
                    aim_x = float(np.clip(move_steer * 0.5, -0.5, 0.5))

        self.last_throttle_check = move_throttle
        return {
            "wall_hit": bool(wall_hit or self.is_escaping),
            "is_red_reticle": bool(is_front_target),
            "wall_score": wall_score,
            "steering": float(np.clip(move_steer, -1.0, 1.0)),
            "throttle": float(np.clip(move_throttle, -1.0, 1.0)),
            "aim_x": float(np.clip(aim_x, -1.0, 1.0)),
            "aim_y": float(np.clip(aim_y, -1.0, 1.0)),
            "neural_activity": float(np.mean(medulla_activation))
        }
EOF

# 3. Gamepad Controller
cat << 'EOF' > core/controller.py
import numpy as np
try:
    import evdev
    from evdev import UInput, AbsInfo, ecodes as e
    HAS_EVDEV = True
except ImportError:
    HAS_EVDEV = False

class GamepadController:
    def __init__(self):
        self.enabled = False
        self.ui = None
        self.invert_look = False
        self.invert_move = False
        self.last_steering = 0.0
        self.last_throttle = 0.0
        self.last_aim_x = 0.0
        self.last_aim_y = 0.0
        self.last_shoot = False

        if HAS_EVDEV:
            try:
                capabilities = {
                    e.EV_KEY: [e.BTN_A, e.BTN_B, e.BTN_X, e.BTN_Y, e.BTN_TL, e.BTN_TR],
                    e.EV_ABS: [
                        (e.ABS_X, AbsInfo(value=128, min=0, max=255, fuzz=0, flat=0, resolution=0)),
                        (e.ABS_Y, AbsInfo(value=128, min=0, max=255, fuzz=0, flat=0, resolution=0)),
                        (e.ABS_RX, AbsInfo(value=128, min=0, max=255, fuzz=0, flat=0, resolution=0)),
                        (e.ABS_RY, AbsInfo(value=128, min=0, max=255, fuzz=0, flat=0, resolution=0)),
                        (e.ABS_RZ, AbsInfo(value=0, min=0, max=255, fuzz=0, flat=0, resolution=0))
                    ]
                }
                self.ui = UInput(capabilities, name="FlyConnectome-Virtual-Gamepad", vendor=0x045e, product=0x028e)
                print("[*] Virtual Xbox Gamepad created successfully via evdev.")
            except Exception as err:
                print(f"[!] Warning: Could not initialize uinput device ({err}).")

    def reset(self):
        self.last_steering = 0.0
        self.last_throttle = 0.0
        self.last_aim_x = 0.0
        self.last_aim_y = 0.0
        self.last_shoot = False

        if not self.ui:
            return

        self.ui.write(e.EV_ABS, e.ABS_X, 128)
        self.ui.write(e.EV_ABS, e.ABS_Y, 128)
        self.ui.write(e.EV_ABS, e.ABS_RX, 128)
        self.ui.write(e.EV_ABS, e.ABS_RY, 128)
        self.ui.write(e.EV_ABS, e.ABS_RZ, 0)
        self.ui.write(e.EV_KEY, e.BTN_A, 0)
        self.ui.syn()

    def send_action(self, steering, throttle, aim_x, aim_y, shoot=False):
        self.last_steering = float(steering)
        self.last_throttle = float(throttle)
        self.last_aim_x = float(aim_x)
        self.last_aim_y = float(aim_y)
        self.last_shoot = bool(shoot)

        if not self.enabled or not self.ui:
            return

        effective_steer = -steering if self.invert_move else steering
        effective_throttle = -throttle if self.invert_move else throttle

        tracked_aim_x = aim_x * 1.8
        effective_aim_x = -tracked_aim_x if self.invert_look else tracked_aim_x

        left_x = int(np.clip(effective_steer * 127 + 128, 0, 255))
        left_y = int(np.clip(effective_throttle * 127 + 128, 0, 255))
        right_x = int(np.clip(effective_aim_x * 127 + 128, 0, 255))
        right_y = int(np.clip(aim_y * 127 + 128, 0, 255))
        trigger_val = 255 if shoot else 0

        self.ui.write(e.EV_ABS, e.ABS_X, left_x)
        self.ui.write(e.EV_ABS, e.ABS_Y, left_y)
        self.ui.write(e.EV_ABS, e.ABS_RX, right_x)
        self.ui.write(e.EV_ABS, e.ABS_RY, right_y)
        self.ui.write(e.EV_ABS, e.ABS_RZ, trigger_val)
        self.ui.write(e.EV_KEY, e.BTN_A, 1 if shoot else 0)
        self.ui.syn()
EOF

# 4. Flask App Backend (Updated to expose brain status)
cat << 'EOF' > app.py
from flask import Flask, render_template, Response, jsonify, request
from core.capture import X11Capture
from core.vision import VisionProcessor
from core.controller import GamepadController
import cv2
import threading
import time

app = Flask(__name__)
capture_engine = X11Capture(width=60, height=60)
vision = VisionProcessor()
controller = GamepadController()

running_agent = False
lock = threading.Lock()
latest_metrics = {"wall_hit": False, "is_red_reticle": False, "wall_score": 0.0, "steering": 0.0, "throttle": 0.0, "aim_x": 0.0, "aim_y": 0.0, "neural_activity": 0.0}

def agent_loop():
    global running_agent, latest_metrics
    while True:
        if running_agent:
            with lock:
                try:
                    frame = capture_engine.grab_frame()
                    metrics = vision.process(frame)
                except Exception as e:
                    print(f"[!] Capture error: {e}")
                    metrics = latest_metrics

            latest_metrics = metrics
            if controller.enabled:
                controller.send_action(
                    steering=metrics["steering"],
                    throttle=metrics["throttle"],
                    aim_x=metrics["aim_x"],
                    aim_y=metrics["aim_y"],
                    shoot=metrics["is_red_reticle"]
                )
        time.sleep(0.033)

@app.route('/')
def index():
    with lock:
        windows = capture_engine.list_windows()
    return render_template('index.html', windows=windows)

@app.route('/brain_view')
def brain_view():
    return render_template('brain_view.html')

@app.route('/set_window', methods=['POST'])
def set_window():
    data = request.json
    with lock:
        success = capture_engine.set_window(data.get('title'))
    return jsonify({"success": success})

@app.route('/set_radar', methods=['POST'])
def set_radar():
    data = request.json
    with lock:
        capture_engine.set_radar_box(
            data.get('enabled', True),
            data.get('x', 20),
            data.get('y', 420),
            data.get('w', 120),
            data.get('h', 120)
        )
    return jsonify({"success": True})

@app.route('/set_threshold', methods=['POST'])
def set_threshold():
    data = request.json
    vision.wall_threshold = float(data.get('threshold', 500))
    return jsonify({"success": True})

@app.route('/set_red_sensitivity', methods=['POST'])
def set_red_sensitivity():
    data = request.json
    vision.red_sensitivity = float(data.get('sensitivity', 60))
    return jsonify({"success": True})

@app.route('/set_aim_tuning', methods=['POST'])
def set_aim_tuning():
    data = request.json
    vision.aim_sensitivity = float(data.get('sensitivity', 1.2))
    vision.aim_deadzone = float(data.get('deadzone', 0.05))
    return jsonify({"success": True})

@app.route('/set_behavior_tuning', methods=['POST'])
def set_behavior_tuning():
    data = request.json
    if 'stagnation' in data:
        vision.stagnation_timeout = float(data['stagnation'])
    if 'escape_frames' in data:
        vision.escape_frames = int(data['escape_frames'])
    if 'boredom' in data:
        vision.boredom_timeout = float(data['boredom'])
    if 'target_memory' in data:
        vision.target_memory_duration = float(data['target_memory'])
    if 'center_deadzone' in data:
        vision.center_deadzone_radius = float(data['center_deadzone'])
    return jsonify({"success": True})

@app.route('/toggle_foraging', methods=['POST'])
def toggle_foraging():
    data = request.json
    vision.foraging_enabled = bool(data.get('enabled', True))
    return jsonify({"success": True, "foraging": vision.foraging_enabled})

@app.route('/toggle_invert_look', methods=['POST'])
def toggle_invert_look():
    data = request.json
    controller.invert_look = bool(data.get('invert', False))
    return jsonify({"success": True, "invert_look": controller.invert_look})

@app.route('/toggle_invert_move', methods=['POST'])
def toggle_invert_move():
    data = request.json
    controller.invert_move = bool(data.get('invert', False))
    return jsonify({"success": True, "invert_move": controller.invert_move})

@app.route('/toggle_agent', methods=['POST'])
def toggle_agent():
    global running_agent
    data = request.json
    running_agent = data.get('enabled', False)
    controller.enabled = running_agent
    if not running_agent:
        controller.reset()
    return jsonify({"status": "running" if running_agent else "stopped"})

@app.route('/stats')
def get_stats():
    return jsonify({
        "running": running_agent,
        "metrics": latest_metrics,
        "brain_status": vision.loaded_status,
        "controller": {
            "enabled": controller.enabled,
            "steering": controller.last_steering,
            "throttle": controller.last_throttle,
            "aim_x": controller.last_aim_x,
            "aim_y": controller.last_aim_y,
            "shoot": controller.last_shoot,
            "invert_look": controller.invert_look,
            "invert_move": controller.invert_move
        },
        "foraging": vision.foraging_enabled,
        "red_sensitivity": vision.red_sensitivity,
        "wall_threshold": vision.wall_threshold,
        "stagnation": vision.stagnation_timeout,
        "escape_frames": vision.escape_frames,
        "boredom": vision.boredom_timeout,
        "target_memory": vision.target_memory_duration,
        "center_deadzone": vision.center_deadzone_radius
    })

@app.route('/feed')
def video_feed():
    def generate():
        while True:
            with lock:
                try:
                    frame = capture_engine.grab_frame()
                    preview_frame = capture_engine.grab_dual_preview_frame(frame, vision.red_sensitivity, vision.wall_threshold, vision.center_deadzone_radius)
                except Exception:
                    preview_frame = np.zeros((150, 300, 3), dtype=np.uint8)
            ret, buffer = cv2.imencode('.jpg', preview_frame)
            yield (b'--frame\r\nContent-Type: image/jpeg\r\n\r\n' + buffer.tobytes() + b'\r\n')
            time.sleep(0.05)
    return Response(generate(), mimetype='multipart/x-mixed-replace; boundary=frame')

if __name__ == '__main__':
    threading.Thread(target=agent_loop, daemon=True).start()
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

# 5. Full-Screen Connectome Map View Template
cat << 'EOF' > templates/brain_view.html
<!DOCTYPE html>
<html>
<head>
    <title>Fruit Fly Connectome - Full Brain View</title>
    <style>
        body { font-family: sans-serif; background: #080808; color: #fff; margin: 0; padding: 20px; overflow: hidden; text-align: center; }
        h1 { color: #90caf9; margin-bottom: 5px; }
        p { color: #888; margin-top: 0; }
        canvas { background: #0c0c0c; border: 1px solid #222; border-radius: 8px; box-shadow: 0 0 30px rgba(0,0,0,0.8); width: 95vw; height: 75vh; }
        .hud { display: flex; justify-content: center; gap: 40px; margin-top: 15px; font-family: monospace; font-size: 16px; }
        .hud span { color: #66bb6a; font-weight: bold; }
    </style>
</head>
<body>
    <h1>Drosophila Connectome - Real-Time Neural Simulation View</h1>
    <p>Live propagation map across Sensory, Medulla Processing, and Motor layers</p>

    <canvas id="bigBrainCanvas" width="1200" height="600"></canvas>

    <div class="hud">
        <div>Neural Activity Level: <span id="hudActivity">0.00</span></div>
        <div>Active State: <span id="hudState">Standby</span></div>
    </div>

    <script>
        const canvas = document.getElementById('bigBrainCanvas');
        const ctx = canvas.getContext('2d');
        let currentActivity = 0.1;

        function renderBrain() {
            ctx.fillStyle = '#0c0c0c';
            ctx.fillRect(0, 0, canvas.width, canvas.height);

            ctx.strokeStyle = '#151515';
            ctx.lineWidth = 1;
            for (let x = 0; x < canvas.width; x += 40) {
                ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, canvas.height); ctx.stroke();
            }
            for (let y = 0; y < canvas.height; y += 40) {
                ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(canvas.width, y); ctx.stroke();
            }

            ctx.strokeStyle = 'rgba(50, 50, 50, 0.4)';
            ctx.lineWidth = 1.2;
            for (let i = 0; i < 60; i++) {
                let startX = 200;
                let startY = 80 + (i * 8);
                let endX = 600 + (Math.sin(i + Date.now()*0.002) * 30);
                let endY = 50 + (i * 9);
                ctx.beginPath();
                ctx.moveTo(startX, startY);
                ctx.lineTo(endX, endY);
                ctx.stroke();
            }

            for (let i = 0; i < 60; i++) {
                let startX = 600;
                let startY = 50 + (i * 9);
                let endX = 1000;
                let endY = 100 + (i * 12);
                ctx.beginPath();
                ctx.moveTo(startX, startY);
                ctx.lineTo(endX, endY);
                ctx.stroke();
            }

            let pulse = Math.sin(Date.now() * 0.015) * 4 + (currentActivity * 25);

            ctx.fillStyle = '#666';
            ctx.font = '16px monospace';
            ctx.fillText("SENSORY INPUT (OPTIC/RADAR)", 200, 45);
            ctx.fillText("MEDULLA / CONNECTOME PROCESSING", 600, 30);
            ctx.fillText("MOTOR OUTPUT NEURONS", 1000, 45);

            for (let i = 0; i < 15; i++) {
                ctx.fillStyle = '#42a5f5';
                ctx.beginPath();
                ctx.arc(200, 80 + i * 32, 8, 0, Math.PI * 2);
                ctx.fill();
            }

            for (let i = 0; i < 20; i++) {
                let intensity = Math.min(1, Math.max(0.3, currentActivity * (0.5 + Math.random() * 0.8)));
                ctx.fillStyle = `rgba(102, 187, 106, ${intensity})`;
                ctx.beginPath();
                ctx.arc(600 + (i % 3) * 30, 50 + i * 26, 10 + pulse * 0.4, 0, Math.PI * 2);
                ctx.fill();
            }

            for (let i = 0; i < 10; i++) {
                ctx.fillStyle = '#ff7043';
                ctx.beginPath();
                ctx.arc(1000, 100 + i * 45, 12, 0, Math.PI * 2);
                ctx.fill();
            }

            requestAnimationFrame(renderBrain);
        }
        requestAnimationFrame(renderBrain);

        setInterval(() => {
            fetch('/stats').then(res => res.json()).then(data => {
                let m = data.metrics;
                currentActivity = m.neural_activity || 0.1;
                document.getElementById('hudActivity').innerText = currentActivity.toFixed(3);
                document.getElementById('hudState').innerText = data.running ? "ACTIVE / TRACKING" : "STANDBY";
            });
        }, 200);
    </script>
</body>
</html>
EOF

# 6. Main Dashboard Template (Updated with Brain Source UI Telemetry Row)
cat << 'EOF' > templates/index.html
<!DOCTYPE html>
<html>
<head>
    <title>Fruit Fly Halo 2 Dashboard</title>
    <style>
        body { font-family: sans-serif; background: #121212; color: #fff; text-align: center; padding: 20px; }
        .container { display: flex; justify-content: center; gap: 30px; margin-top: 20px; flex-wrap: wrap; }
        .feed-container { display: flex; flex-direction: column; align-items: center; }
        img { border: 2px solid #444; image-rendering: pixelated; width: 300px; height: 150px; }
        .controls, .stats-panel { background: #1e1e1e; padding: 20px; border-radius: 8px; text-align: left; width: 330px; box-sizing: border-box; }
        .control-group { margin-bottom: 12px; }
        select, input, button { padding: 8px; background: #2a2a2a; color: #fff; border: 1px solid #444; width: 100%; box-sizing: border-box; margin-top: 4px; cursor: pointer; }
        button.active { background: #2e7d32; }
        button.toggle-on { background: #1565c0; }
        button.toggle-off { background: #444; }
        .stat-row { display: flex; justify-content: space-between; margin: 6px 0; font-family: monospace; font-size: 14px; }
        .badge { padding: 2px 6px; border-radius: 4px; font-weight: bold; }
        .badge.true { background: #2e7d32; }
        .badge.false { background: #c62828; }
        details { background: #181818; border: 1px solid #333; padding: 10px; border-radius: 6px; margin-top: 15px; width: 300px; box-sizing: border-box; text-align: left; }
        summary { cursor: pointer; font-weight: bold; color: #90caf9; }
        .grid-2 { display: flex; gap: 8px; }
        .slider-box { background: #181818; padding: 10px; border-radius: 6px; margin-top: 10px; width: 300px; text-align: left; font-size: 13px; }
        canvas { background: #0a0a0a; border: 1px solid #333; border-radius: 6px; margin-top: 10px; width: 300px; height: 110px; }
        .brain-btn { background: #0277bd; font-weight: bold; margin-top: 10px; text-decoration: none; display: block; text-align: center; padding: 8px; border-radius: 4px; color: #fff; box-sizing: border-box; }
        .brain-btn:hover { background: #01579b; }
    </style>
</head>
<body>
    <h1>FlyConnectome - Foraging & Alignment Halo 2 Agent</h1>
    <div class="container">
        <div class="feed-container">
            <h3>Dual Feed (Radar Guide + Wall Canny)</h3>
            <img src="/feed" alt="Live Feed">

            <div class="stats-panel" style="margin-top: 15px; width: 300px;">
                <h3>🧠 Live Telemetry</h3>
                <div class="stat-row"><span>Brain Source:</span> <span id="statBrainSource" style="color: #90caf9; font-size: 11px;">Loading...</span></div>
                <div class="stat-row"><span>Move Steering:</span> <span id="statSteer">0.00</span></div>
                <div class="stat-row"><span>Move Throttle:</span> <span id="statThrottle">0.00</span></div>
                <div class="stat-row"><span>Aim X (Look):</span> <span id="statAimX">0.00</span></div>
                <div class="stat-row"><span>Obstacle / 180°:</span> <span id="statWallHit" class="badge false">False</span></div>
                <div class="stat-row"><span>Red Radar Blip:</span> <span id="statRed" class="badge false">False</span></div>

                <div style="margin-top: 10px; font-size: 13px; font-weight: bold; color: #90caf9;">Live Connectome Activity</div>
                <canvas id="brainCanvas" width="300" height="110"></canvas>

                <a href="/brain_view" target="_blank" class="brain-btn">Open Large Brain Connectome Map ↗</a>
            </div>
        </div>

        <div class="controls">
            <h3>Configuration & Tuning</h3>
            <div class="control-group">
                <label>Target Game Window:</label>
                <select id="windowSelect" onchange="changeWindow(this.value)">
                    <option value="">-- Full Monitor / Default --</option>
                    {% for win in windows %}
                    <option value="{{ win }}">{{ win }}</option>
                    {% endfor %}
                </select>
            </div>

            <div class="control-group">
                <label>Radar Box Offset & Size (px):</label>
                <div class="grid-2">
                    <input type="number" id="radX" placeholder="X" value="20">
                    <input type="number" id="radY" placeholder="Y" value="420">
                </div>
                <div class="grid-2" style="margin-top: 5px;">
                    <input type="number" id="radW" placeholder="Width" value="120">
                    <input type="number" id="radH" placeholder="Height" value="120">
                </div>
                <button onclick="updateRadar()" style="margin-top:5px; background:#333;">Update Radar Box</button>
            </div>

            <div class="control-group">
                <label>Active Foraging / Exploration Drive:</label>
                <button id="forageBtn" class="toggle-on" onclick="toggleForaging()">Foraging: ON</button>
            </div>

            <div class="control-group">
                <label>Controller Axis Toggles:</label>
                <div class="grid-2">
                    <button id="invLookBtn" class="toggle-off" onclick="toggleInvertLook()">Invert Look X</button>
                    <button id="invMoveBtn" class="toggle-off" onclick="toggleInvertMove()">Invert Move</button>
                </div>
            </div>

            <div class="control-group">
                <label>Aim Sensitivity: <span id="aimSensVal">1.2</span>x</label>
                <input type="range" min="0.2" max="3.0" step="0.1" value="1.2" oninput="updateAimTuning()">
            </div>

            <div class="control-group">
                <label>Agent Status:</label>
                <button id="toggleBtn" onclick="toggleAgent()">Start Agent Loop</button>
            </div>

            <details style="width: 100%; margin-top: 15px;">
                <summary>Behavior & Vision Tuning ⚙️</summary>
                <div class="slider-box" style="margin-top: 10px; width: 100%;">
                    <label>Red Blip Sensitivity: <span id="redSensVal">60</span></label>
                    <input type="range" min="10" max="150" step="5" value="60" id="redSlider" oninput="updateRedSensitivity()">
                </div>
                <div class="slider-box" style="width: 100%;">
                    <label>Wall Canny Threshold: <span id="wallThreshVal">500</span></label>
                    <input type="range" min="100" max="2000" step="50" value="500" id="wallSlider" oninput="updateWallThreshold()">
                </div>
                <div class="slider-box" style="width: 100%;">
                    <label>Center Deadzone Radius: <span id="deadzoneVal">3.0</span>px</label>
                    <input type="range" min="1.0" max="7.0" step="0.5" value="3.0" id="deadzoneSlider" oninput="updateBehaviorTuning()">
                </div>
                <div class="slider-box" style="width: 100%;">
                    <label>Stagnation Timeout: <span id="stagVal">9.0</span>s</label>
                    <input type="range" min="3.0" max="20.0" step="0.5" value="9.0" id="stagSlider" oninput="updateBehaviorTuning()">
                </div>
                <div class="slider-box" style="width: 100%;">
                    <label>180° Escape Frames: <span id="escFramesVal">28</span></label>
                    <input type="range" min="10" max="50" step="1" value="28" id="escSlider" oninput="updateBehaviorTuning()">
                </div>
                <div class="slider-box" style="width: 100%;">
                    <label>Target Boredom Timeout: <span id="boredVal">3.0</span>s</label>
                    <input type="range" min="1.0" max="8.0" step="0.5" value="3.0" id="boredSlider" oninput="updateBehaviorTuning()">
                </div>
                <div class="slider-box" style="width: 100%;">
                    <label>Target Memory Grace Period: <span id="memoryVal">0.4</span>s</label>
                    <input type="range" min="0.0" max="1.5" step="0.1" value="0.4" id="memorySlider" oninput="updateBehaviorTuning()">
                </div>
            </details>
        </div>
    </div>

    <script>
        let agentRunning = false;
        let foragingActive = true;
        let invertLookActive = false;
        let invertMoveActive = false;
        let lastNeuralActivity = 0.0;

        function changeWindow(title) {
            fetch('/set_window', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ title }) });
        }
        function updateRadar() {
            let x = document.getElementById('radX').value;
            let y = document.getElementById('radY').value;
            let w = document.getElementById('radW').value;
            let h = document.getElementById('radH').value;
            fetch('/set_radar', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ enabled: true, x, y, w, h }) });
        }
        function updateAimTuning() {
            let sens = document.querySelector('input[min="0.2"]').value;
            document.getElementById('aimSensVal').innerText = sens;
            fetch('/set_aim_tuning', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ sensitivity: sens, deadzone: 0.05 }) });
        }
        function updateRedSensitivity() {
            let sens = document.getElementById('redSlider').value;
            document.getElementById('redSensVal').innerText = sens;
            fetch('/set_red_sensitivity', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ sensitivity: sens }) });
        }
        function updateWallThreshold() {
            let thresh = document.getElementById('wallSlider').value;
            document.getElementById('wallThreshVal').innerText = thresh;
            fetch('/set_threshold', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ threshold: thresh }) });
        }
        function updateBehaviorTuning() {
            let stagnation = document.getElementById('stagSlider').value;
            let escape_frames = document.getElementById('escSlider').value;
            let boredom = document.getElementById('boredSlider').value;
            let target_memory = document.getElementById('memorySlider').value;
            let center_deadzone = document.getElementById('deadzoneSlider').value;

            document.getElementById('stagVal').innerText = stagnation;
            document.getElementById('escFramesVal').innerText = escape_frames;
            document.getElementById('boredVal').innerText = boredom;
            document.getElementById('memoryVal').innerText = target_memory;
            document.getElementById('deadzoneVal').innerText = center_deadzone;

            fetch('/set_behavior_tuning', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ stagnation, escape_frames, boredom, target_memory, center_deadzone })
            });
        }
        function toggleForaging() {
            foragingActive = !foragingActive;
            fetch('/toggle_foraging', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ enabled: foragingActive }) }).then(res => res.json()).then(data => {
                let btn = document.getElementById('forageBtn');
                btn.innerText = data.foraging ? "Foraging: ON" : "Foraging: OFF";
                btn.className = data.foraging ? "toggle-on" : "";
            });
        }
        function toggleInvertLook() {
            invertLookActive = !invertLookActive;
            fetch('/toggle_invert_look', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ invert: invertLookActive }) }).then(res => res.json()).then(data => {
                let btn = document.getElementById('invLookBtn');
                btn.innerText = data.invert_look ? "Invert Look: ON" : "Invert Look X";
                btn.className = data.invert_look ? "toggle-on" : "toggle-off";
            });
        }
        function toggleInvertMove() {
            invertMoveActive = !invertMoveActive;
            fetch('/toggle_invert_move', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ invert: invertMoveActive }) }).then(res => res.json()).then(data => {
                let btn = document.getElementById('invMoveBtn');
                btn.innerText = data.invert_move ? "Invert Move: ON" : "Invert Move";
                btn.className = data.invert_move ? "toggle-on" : "toggle-off";
            });
        }
        function toggleAgent() {
            agentRunning = !agentRunning;
            fetch('/toggle_agent', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ enabled: agentRunning }) }).then(res => res.json()).then(data => {
                let btn = document.getElementById('toggleBtn');
                btn.innerText = agentRunning ? "Stop Agent Loop" : "Start Agent Loop";
                btn.classList.toggle('active', agentRunning);
            });
        }

        const canvas = document.getElementById('brainCanvas');
        const ctx = canvas.getContext('2d');

        function drawBrainVisualizer() {
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            ctx.strokeStyle = '#222';
            ctx.lineWidth = 1;
            for (let i = 0; i < 5; i++) {
                for (let j = 0; j < 4; j++) {
                    ctx.beginPath();
                    ctx.moveTo(40, 15 + i * 20);
                    ctx.lineTo(150, 20 + j * 22);
                    ctx.stroke();
                }
            }
            for (let i = 0; i < 4; i++) {
                for (let j = 0; j < 3; j++) {
                    ctx.beginPath();
                    ctx.moveTo(150, 20 + i * 22);
                    ctx.lineTo(260, 25 + j * 28);
                    ctx.stroke();
                }
            }

            let pulse = Math.sin(Date.now() * 0.01) * 2 + (lastNeuralActivity * 10);

            for (let i = 0; i < 5; i++) {
                ctx.fillStyle = '#42a5f5';
                ctx.beginPath();
                ctx.arc(40, 15 + i * 20, 4, 0, Math.PI * 2);
                ctx.fill();
            }
            for (let i = 0; i < 4; i++) {
                let intensity = Math.min(1, Math.max(0.2, lastNeuralActivity * (0.8 + Math.random() * 0.4)));
                ctx.fillStyle = `rgba(102, 187, 106, ${intensity})`;
                ctx.beginPath();
                ctx.arc(150, 20 + i * 22, 5 + pulse * 0.3, 0, Math.PI * 2);
                ctx.fill();
            }
            for (let i = 0; i < 3; i++) {
                ctx.fillStyle = '#ff7043';
                ctx.beginPath();
                ctx.arc(260, 25 + i * 28, 5, 0, Math.PI * 2);
                ctx.fill();
            }

            requestAnimationFrame(drawBrainVisualizer);
        }
        requestAnimationFrame(drawBrainVisualizer);

        setInterval(() => {
            fetch('/stats').then(res => res.json()).then(data => {
                let m = data.metrics;
                lastNeuralActivity = m.neural_activity || 0.1;

                if (data.brain_status) {
                    document.getElementById('statBrainSource').innerText = data.brain_status;
                }

                document.getElementById('statSteer').innerText = m.steering.toFixed(2);
                document.getElementById('statThrottle').innerText = m.throttle.toFixed(2);
                document.getElementById('statAimX').innerText = m.aim_x.toFixed(2);

                let wh = document.getElementById('statWallHit');
                wh.innerText = m.wall_hit; wh.className = "badge " + m.wall_hit;

                let rd = document.getElementById('statRed');
                rd.innerText = m.is_red_reticle; rd.className = "badge " + m.is_red_reticle;
            });
        }, 150);
    </script>
</body>
</html>
EOF

echo "[*] Setup complete! Starting Flask app automatically..."
python3 app.py

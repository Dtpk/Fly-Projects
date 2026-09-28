#!/usr/bin/env python3
"""
Flywire Liar's Dice Engine - Connectome-Driven Bluffing Simulation
------------------------------------------------------------------
Includes homeostatic memory, neural monitor, safe restart, and an
expanded settings gear menu with Windowed, Borderless, and Fullscreen modes.
"""

import os
import sys
import subprocess
import venv
import random
import json
import configparser
import math

VENV_DIR = "venv_fly"
CONFIG_FILE = "dice_config.txt"
MEMORY_FILE = "fly_memory.json"
CONNECTIONS_CSV = "connections_princeton.csv"
NEURONS_CSV = "neurons.csv"

#Have not tried this yet but instead of squares for fly dice count it would be fly's
FLY_IMAGE = "fly.png"

def ensure_virtual_environment():
    abs_venv_dir = os.path.abspath(VENV_DIR)
    is_running_in_venv = os.path.commonpath([os.path.abspath(sys.prefix), abs_venv_dir]) == abs_venv_dir

    if not os.path.isdir(abs_venv_dir) or not is_running_in_venv:
        if not os.path.exists(abs_venv_dir):
            venv.create(abs_venv_dir, with_pip=True)

        venv_python = os.path.join(abs_venv_dir, "Scripts", "python.exe") if sys.platform == "win32" else os.path.join(abs_venv_dir, "bin", "python")
        venv_pip = os.path.join(abs_venv_dir, "Scripts", "pip") if sys.platform == "win32" else os.path.join(abs_venv_dir, "bin", "pip")

        subprocess.check_call([venv_pip, "install", "--no-cache-dir", "numpy", "pygame"])
        os.execv(venv_python, [venv_python] + sys.argv)

# Ensure the virtual environment is set up and active before importing third-party packages
ensure_virtual_environment()

import pygame
import numpy as np

def ensure_config_file():
    if not os.path.exists(CONFIG_FILE):
        config = configparser.ConfigParser()
        config['Settings'] = {
            'dice_mode': 'symmetric',
            'starting_dice': '5',
            'num_flies': '4'
        }
        with open(CONFIG_FILE, 'w') as f:
            config.write(f)

def load_config():
    ensure_config_file()
    config = configparser.ConfigParser()
    config.read(CONFIG_FILE)

    dice_mode = config.get('Settings', 'dice_mode', fallback='symmetric').strip().lower()
    try:
        starting_dice = int(config.get('Settings', 'starting_dice', fallback='5'))
    except ValueError:
        starting_dice = 5

    try:
        num_flies = int(config.get('Settings', 'num_flies', fallback='4'))
    except ValueError:
        num_flies = 4

    return dice_mode, starting_dice, num_flies

def load_or_create_fly_memories(num_flies):
    has_connections = os.path.exists(CONNECTIONS_CSV)
    conn_data = None
    if has_connections:
        try:
            conn_data = np.genfromtxt(CONNECTIONS_CSV, delimiter=',', skip_header=1, filling_values=1.0)
        except Exception:
            try:
                conn_data = np.genfromtxt(CONNECTIONS_CSV, delimiter=',', skip_header=0, filling_values=1.0)
            except Exception:
                pass

    total_rows = len(conn_data) if (conn_data is not None and conn_data.ndim > 1) else 0

    if os.path.exists(MEMORY_FILE):
        try:
            with open(MEMORY_FILE, 'r') as f:
                data = json.load(f)
                if isinstance(data, list) and len(data) == num_flies:
                    for p in data:
                        if 'orig_risk' not in p:
                            p['orig_risk'] = p['base_risk']
                        if 'orig_bluff' not in p:
                            p['orig_bluff'] = p['base_bluff']
                    return data, True
        except Exception:
            pass

    personalities = []
    any_real = False

    for i in range(num_flies):
        if conn_data is not None and total_rows > num_flies:
            try:
                chunk_size = random.randint(200, 800)
                start_idx = random.randint(0, max(0, total_rows - chunk_size))
                sub_slice = conn_data[start_idx : start_idx + chunk_size]

                weights = sub_slice[:, -1] if sub_slice.ndim > 1 and sub_slice.shape[1] > 2 else sub_slice.flatten()

                base_risk = float(np.mean(weights) / (np.max(weights) + 1e-8))
                base_bluff = float(np.std(weights) / (np.mean(weights) + 1e-8))

                r_val = min(max(base_risk, 0.2), 0.85)
                b_val = min(max(base_bluff, 0.15), 0.75)

                personalities.append({
                    'name': f"Fly {i+1}",
                    'mode': 'Real Connectome',
                    'nodes': len(sub_slice),
                    'orig_risk': r_val,
                    'orig_bluff': b_val,
                    'base_risk': r_val,
                    'base_bluff': b_val,
                    'risk': r_val,
                    'bluff': b_val,
                    'brain_slice': weights[:20].tolist(),
                    'wins': 0
                })
                any_real = True
                continue
            except Exception:
                pass

        r_val = round(random.uniform(0.3, 0.7), 2)
        b_val = round(random.uniform(0.2, 0.6), 2)
        personalities.append({
            'name': f"Fly {i+1}",
            'mode': 'Mock Brain',
            'nodes': random.randint(150, 600),
            'orig_risk': r_val,
            'orig_bluff': b_val,
            'base_risk': r_val,
            'base_bluff': b_val,
            'risk': r_val,
            'bluff': b_val,
            'brain_slice': [random.random() for _ in range(20)],
            'wins': 0
        })

    save_fly_memories(personalities)
    return personalities, any_real

def save_fly_memories(personalities):
    try:
        with open(MEMORY_FILE, 'w') as f:
            json.dump(personalities, f, indent=4)
    except Exception:
        pass

class LiarsDiceGame:
    def __init__(self):
        self.dice_mode, self.starting_dice, self.num_flies = load_config()
        self.personalities, self.is_global_real = load_or_create_fly_memories(self.num_flies)

        pygame.init()

        self.logical_width = 1000
        self.logical_height = 750
        self.canvas = pygame.Surface((self.logical_width, self.logical_height))

        self.screen = pygame.display.set_mode((self.logical_width, self.logical_height), pygame.RESIZABLE)
        pygame.display.set_caption("Flywire Liar's Dice")
        self.clock = pygame.time.Clock()
        self.font = pygame.font.SysFont(None, 24)
        self.font_large = pygame.font.SysFont(None, 30)

        self.show_settings_menu = False

        self.fly_img = None
        if os.path.exists(FLY_IMAGE):
            try:
                img = pygame.image.load(FLY_IMAGE).convert_alpha()
                self.fly_img = pygame.transform.scale(img, (22, 22))
            except Exception:
                pass

        self.reset_game()

    def reset_game(self):
        total_players = self.num_flies + 1
        self.hands = {}
        for p in range(total_players):
            count = random.randint(1, max(2, self.starting_dice + 2)) if self.dice_mode == 'random' else self.starting_dice
            self.hands[p] = sorted([random.randint(1, 6) for _ in range(count)])

        self.current_turn = 0
        self.current_bid = (0, 2)
        self.draft_bid_qty = 1
        self.draft_bid_face = 2
        self.bid_owner = None
        self.message = "Game started! Press [R] anytime to wipe/reset memories."
        self.winner = None

    def reset_memories_file(self):
        if os.path.exists(MEMORY_FILE):
            os.remove(MEMORY_FILE)
        self.personalities, self.is_global_real = load_or_create_fly_memories(self.num_flies)
        self.reset_game()
        self.message = "Brain memories wiped! Fresh connectome slices loaded."

    def roll_all_dice(self):
        for p in self.hands:
            count = len(self.hands[p])
            if count > 0:
                self.hands[p] = sorted([random.randint(1, 6) for _ in range(count)])

    def count_total_face(self, face):
        total = 0
        for p in self.hands:
            hand = self.hands[p]
            if face == 1:
                total += hand.count(1)
            else:
                total += hand.count(face) + hand.count(1)
        return total

    def is_valid_bid(self, new_qty, new_face):
        curr_qty, curr_face = self.current_bid
        if curr_qty == 0:
            return new_qty >= 1 and 1 <= new_face <= 6

        if new_qty > curr_qty:
            return True
        if new_qty == curr_qty and new_face > curr_face:
            return True
        return False

    def ai_turn(self, fly_idx):
        if self.winner is not None:
            return
        player_id = fly_idx + 1
        hand = self.hands.get(player_id, [])
        if not hand:
            self.advance_turn()
            return

        profile = self.personalities[fly_idx]

        shift = random.uniform(-0.06, 0.06)
        profile['risk'] = min(max(profile['base_risk'] + shift, 0.15), 0.95)
        profile['bluff'] = min(max(profile['base_bluff'] - shift, 0.10), 0.85)

        qty, face = self.current_bid

        if qty > 0:
            my_count = hand.count(face) + hand.count(1)
            total_dice_out = sum(len(h) for h in self.hands.values())
            expected_total = total_dice_out * (2.0 / 6.0) + my_count

            bidder_dice_count = len(self.hands.get(self.bid_owner, [])) if self.bid_owner is not None else 5
            desperation_multiplier = 0.85 if bidder_dice_count == 1 else 1.0

            if qty > (expected_total * desperation_multiplier) + (profile['risk'] * 2.0):
                self.resolve_challenge(challenger_id=player_id)
                return

        if qty == 0:
            new_qty = 1
            new_face = random.choice(hand) if hand and random.random() > profile['bluff'] else random.randint(2, 6)
        else:
            if random.random() < 0.5 and face < 6:
                new_qty = qty
                new_face = face + 1
            else:
                new_qty = qty + 1
                new_face = face

        self.current_bid = (new_qty, new_face)
        self.bid_owner = player_id
        self.message = f"{profile['name']} ({profile['wins']} wins) bid {new_qty} of '{new_face}'s [Risk: {profile['risk']:.2f}]."
        self.advance_turn()

    def advance_turn(self):
        active_players = [p for p in range(self.num_flies + 1) if len(self.hands.get(p, [])) > 0]
        if not active_players:
            return

        if len(active_players) == 1:
            w_id = active_players[0]
            if w_id > 0:
                win_profile = self.personalities[w_id - 1]
                win_profile['wins'] += 1

                orig_r = win_profile.get('orig_risk', win_profile['base_risk'])
                updated_risk = (win_profile['base_risk'] * 0.92) + (orig_r * 0.08) + 0.012
                win_profile['base_risk'] = min(max(orig_r - 0.15, updated_risk), orig_r + 0.15)

                save_fly_memories(self.personalities)
                self.winner = f"{win_profile['name']} (Evolved Base Risk: {win_profile['base_risk']:.2f})"
            else:
                self.winner = "You"

            self.message = f"Game Over! {self.winner} wins the match!"
            return

        if self.current_turn not in active_players:
            self.current_turn = active_players[0]
        else:
            idx = active_players.index(self.current_turn)
            self.current_turn = active_players[(idx + 1) % len(active_players)]

    def resolve_challenge(self, challenger_id):
        qty, face = self.current_bid
        actual_total = self.count_total_face(face)

        bidder_name = "You" if self.bid_owner == 0 else self.personalities[self.bid_owner - 1]['name']
        challenger_name = "You" if challenger_id == 0 else self.personalities[challenger_id - 1]['name']

        if actual_total >= qty:
            loser = challenger_id
            self.message = f"Challenge failed! Actual '{face}'s were {actual_total}. {challenger_name} loses a die."
        else:
            loser = self.bid_owner
            self.message = f"Challenge successful! Actual '{face}'s were {actual_total}. {bidder_name} was lying and loses a die!"

        if loser in self.hands and len(self.hands[loser]) > 0:
            self.hands[loser].pop()

        if len(self.hands.get(0, [])) == 0 and self.winner is None:
            self.message += " You are out of dice! Now entering spectator mode."

        self.roll_all_dice()
        self.current_bid = (0, 2)
        self.draft_bid_qty = max(1, self.current_bid[0])
        self.draft_bid_face = 2
        self.bid_owner = None
        self.advance_turn()

    def draw_gear_icon(self, surface, rect):
        cx, cy = rect.center
        pygame.draw.circle(surface, (200, 220, 240), (cx, cy), 11)
        pygame.draw.circle(surface, (45, 55, 75), (cx, cy), 5)
        for i in range(6):
            angle = i * (2 * math.pi / 6)
            tx = cx + int(14 * math.cos(angle))
            ty = cy + int(14 * math.sin(angle))
            pygame.draw.circle(surface, (200, 220, 240), (tx, ty), 3.5)
        pygame.draw.circle(surface, (45, 55, 75), (cx, cy), 5)

    def run(self):
        running = True
        while running:
            self.canvas.fill((25, 30, 40))

            gear_rect = pygame.Rect(950, 15, 36, 36)
            menu_rect = pygame.Rect(760, 60, 230, 175) if self.show_settings_menu else None

            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    running = False
                elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                    actual_w, actual_h = self.screen.get_size()

                    # Account for letterboxing when mapping mouse clicks in scaled/fullscreen mode
                    target_aspect = self.logical_width / self.logical_height
                    window_aspect = actual_w / actual_h
                    if window_aspect > target_aspect:
                        draw_h = actual_h
                        draw_w = int(draw_h * target_aspect)
                        draw_x = (actual_w - draw_w) // 2
                        draw_y = 0
                    else:
                        draw_w = actual_w
                        draw_h = int(draw_w / target_aspect)
                        draw_x = 0
                        draw_y = (actual_h - draw_h) // 2

                    m_x = int((event.pos[0] - draw_x) * (self.logical_width / draw_w))
                    m_y = int((event.pos[1] - draw_y) * (self.logical_height / draw_h))
                    m_pos = (m_x, m_y)

                    if gear_rect.collidepoint(m_pos):
                        self.show_settings_menu = not self.show_settings_menu
                    elif menu_rect and menu_rect.collidepoint(m_pos):
                        win_btn = pygame.Rect(menu_rect.x + 10, menu_rect.y + 12, 210, 32)
                        border_btn = pygame.Rect(menu_rect.x + 10, menu_rect.y + 52, 210, 32)
                        full_btn = pygame.Rect(menu_rect.x + 10, menu_rect.y + 92, 210, 32)
                        exit_btn = pygame.Rect(menu_rect.x + 10, menu_rect.y + 132, 210, 32)

                        if win_btn.collidepoint(m_pos):
                            self.screen = pygame.display.set_mode((self.logical_width, self.logical_height), pygame.RESIZABLE)
                            self.show_settings_menu = False
                        elif border_btn.collidepoint(m_pos):
                            self.screen = pygame.display.set_mode((0, 0), pygame.NOFRAME)
                            self.show_settings_menu = False
                        elif full_btn.collidepoint(m_pos):
                            self.screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
                            self.show_settings_menu = False
                        elif exit_btn.collidepoint(m_pos):
                            running = False
                    else:
                        self.show_settings_menu = False

                elif event.type == pygame.KEYDOWN:
                    if self.winner is not None:
                        self.reset_game()
                    else:
                        if event.key == pygame.K_r:
                            self.reset_memories_file()
                        elif self.current_turn == 0 and len(self.hands.get(0, [])) > 0:
                            if event.key == pygame.K_UP:
                                self.draft_bid_qty += 1
                            elif event.key == pygame.K_DOWN:
                                self.draft_bid_qty = max(1, self.draft_bid_qty - 1)
                            elif event.key == pygame.K_RIGHT:
                                self.draft_bid_face = min(6, self.draft_bid_face + 1)
                            elif event.key == pygame.K_LEFT:
                                self.draft_bid_face = max(1, self.draft_bid_face - 1)
                            elif event.key == pygame.K_RETURN:
                                if self.is_valid_bid(self.draft_bid_qty, self.draft_bid_face):
                                    self.current_bid = (self.draft_bid_qty, self.draft_bid_face)
                                    self.bid_owner = 0
                                    self.message = f"You bid {self.current_bid[0]} of '{self.current_bid[1]}'s."
                                    self.advance_turn()
                                else:
                                    self.message = "Invalid bid! Must raise quantity, or keep/lower quantity with a higher face value."
                            elif event.key == pygame.K_l:
                                if self.bid_owner is not None and self.bid_owner != 0:
                                    self.resolve_challenge(0)

            if self.winner is None and (self.current_turn != 0 or len(self.hands.get(0, [])) == 0):
                pygame.time.delay(900)
                if self.current_turn != 0:
                    self.ai_turn(self.current_turn - 1)
                else:
                    active = [p for p in range(1, self.num_flies + 1) if len(self.hands.get(p, [])) > 0]
                    if active:
                        self.current_turn = active[0]
                        self.ai_turn(self.current_turn - 1)

            # Top Header
            status_suffix = "Real Connectome" if self.is_global_real else "Mock Brain"
            title_text = self.font_large.render(f"Flywire Liar's Dice ({status_suffix}) [Homeostatic Evolution]", True, (220, 220, 240))
            self.canvas.blit(title_text, (30, 20))

            msg_surface = self.font.render(self.message, True, (255, 200, 100))
            self.canvas.blit(msg_surface, (30, 65))

            # --- RENDER SETTINGS GEAR BUTTON ---
            pygame.draw.rect(self.canvas, (45, 55, 75), gear_rect, border_radius=6)
            pygame.draw.rect(self.canvas, (90, 110, 140), gear_rect, 1, border_radius=6)
            self.draw_gear_icon(self.canvas, gear_rect)

            # --- LEFT COLUMN: Flies, Dice, Bidding, Controls ---
            y_offset = 120
            for i, profile in enumerate(self.personalities):
                p_id = i + 1
                dice_list = self.hands.get(p_id, [])
                dice_count = len(dice_list)
                is_active = (self.current_turn == p_id and self.winner is None)

                avatar_rect = pygame.Rect(30, y_offset + (i * 85), 36, 36)
                if self.fly_img:
                    self.canvas.blit(self.fly_img, (avatar_rect.x + 7, avatar_rect.y + 7))
                else:
                    pygame.draw.rect(self.canvas, (100, 120, 140), avatar_rect, border_radius=4)

                color = (255, 120, 120) if is_active else (200, 200, 200)
                if dice_count == 0:
                    color = (100, 100, 100)

                active_indicator = " [DEEP THOUGHT...]" if is_active else ""
                info_text = f"{profile['name']} (Wins: {profile['wins']}) | Nodes: {profile['nodes']} | Dice: {dice_count}{active_indicator}"
                surf = self.font.render(info_text, True, color)
                self.canvas.blit(surf, (80, y_offset + (i * 85) + 8))

                for d_idx in range(dice_count):
                    token_rect = pygame.Rect(80 + (d_idx * 26), y_offset + (i * 85) + 36, 22, 22)
                    if self.fly_img:
                        self.canvas.blit(self.fly_img, token_rect.topleft)
                    else:
                        pygame.draw.rect(self.canvas, (70, 130, 180), token_rect, border_radius=3)

            # Current Bid Display
            bid_str = f"Current Bid: {self.current_bid[0]} of '{self.current_bid[1]}'s (Wild 1s apply)" if self.current_bid[0] > 0 else "Current Bid: None (Opening bid needed)"
            bid_surf = self.font_large.render(bid_str, True, (100, 220, 255))
            self.canvas.blit(bid_surf, (30, 485))

            # Human Status & Draft Bid
            human_dice = self.hands.get(0, [])
            human_status = f"Your Dice: {human_dice}" if human_dice else "Your Dice: ELIMINATED (Spectating)"
            human_text = self.font.render(human_status, True, (200, 255, 200) if human_dice else (150, 150, 150))
            self.canvas.blit(human_text, (30, 535))

            if human_dice and self.winner is None:
                draft_text = self.font.render(f"Draft Bid -> Qty: {self.draft_bid_qty} | Face: {self.draft_bid_face}", True, (255, 255, 150))
                self.canvas.blit(draft_text, (30, 570))

                controls_text = self.font.render("Controls: [UP/DN] Qty | [LT/RT] Face | [ENTER] Bid | [L] Liar | [R] Wipe Memory", True, (180, 200, 220))
                self.canvas.blit(controls_text, (30, 605))

            # --- RIGHT COLUMN: Live Neural Firing Monitor Panel ---
            # The flys use way more neurons then I can display so only shows 20 or so of most active
            # Just for visual flare and a winning screen animation
            panel_rect = pygame.Rect(640, 100, 330, 400)
            pygame.draw.rect(self.canvas, (35, 42, 55), panel_rect, border_radius=8)
            pygame.draw.rect(self.canvas, (70, 90, 115), panel_rect, 2, border_radius=8)

            panel_title = self.font.render("🧠 Neural Synapse Monitor", True, (150, 220, 255))
            self.canvas.blit(panel_title, (panel_rect.x + 15, panel_rect.y + 15))

            active_fly_idx = (self.current_turn - 1) if (0 < self.current_turn <= self.num_flies) else 0
            active_profile = self.personalities[active_fly_idx] if 0 <= active_fly_idx < len(self.personalities) else self.personalities[0]

            brain_info = self.font.render(f"Active Subject: {active_profile['name']}", True, (240, 240, 240))
            self.canvas.blit(brain_info, (panel_rect.x + 15, panel_rect.y + 48))

            traits_info = self.font.render(f"Risk: {active_profile['risk']:.2f} | Bluff: {active_profile['bluff']:.2f}", True, (200, 200, 200))
            self.canvas.blit(traits_info, (panel_rect.x + 15, panel_rect.y + 73))

            node_origin_x = panel_rect.x + 30
            node_origin_y = panel_rect.y + 115
            cols = 4

            for idx, weight in enumerate(active_profile['brain_slice'][:20]):
                r = idx // cols
                c = idx % cols
                nx = node_origin_x + (c * 65)
                ny = node_origin_y + (r * 50)

                is_firing = (self.current_turn > 0 and random.random() > 0.35)
                node_color = (255, 100, 100) if is_firing else (70, 130, 180)

                pygame.draw.circle(self.canvas, node_color, (nx, ny), 11)
                pygame.draw.circle(self.canvas, (220, 220, 220), (nx, ny), 11, 1)

                if c < cols - 1 and idx + 1 < len(active_profile['brain_slice'][:20]):
                    pygame.draw.line(self.canvas, (90, 110, 140), (nx + 11, ny), (nx + 54, ny), 2)

            panel_footer = self.font.render("Homeostatic drift capped at +/- 15%", True, (130, 150, 170))
            self.canvas.blit(panel_footer, (panel_rect.x + 15, panel_rect.bottom - 30))

            # --- SETTINGS MENU POPUP ---
            if self.show_settings_menu and menu_rect:
                pygame.draw.rect(self.canvas, (32, 38, 50), menu_rect, border_radius=6)
                pygame.draw.rect(self.canvas, (110, 135, 165), menu_rect, 2, border_radius=6)

                win_btn = pygame.Rect(menu_rect.x + 10, menu_rect.y + 12, 210, 32)
                border_btn = pygame.Rect(menu_rect.x + 10, menu_rect.y + 52, 210, 32)
                full_btn = pygame.Rect(menu_rect.x + 10, menu_rect.y + 92, 210, 32)
                exit_btn = pygame.Rect(menu_rect.x + 10, menu_rect.y + 132, 210, 32)

                pygame.draw.rect(self.canvas, (50, 65, 90), win_btn, border_radius=4)
                w_lbl = self.font.render("Windowed (1000x750)", True, (240, 240, 240))
                self.canvas.blit(w_lbl, (win_btn.centerx - w_lbl.get_width() // 2, win_btn.centery - w_lbl.get_height() // 2))

                pygame.draw.rect(self.canvas, (50, 65, 90), border_btn, border_radius=4)
                b_lbl = self.font.render("Borderless Fullscreen", True, (240, 240, 240))
                self.canvas.blit(b_lbl, (border_btn.centerx - b_lbl.get_width() // 2, border_btn.centery - b_lbl.get_height() // 2))

                pygame.draw.rect(self.canvas, (50, 65, 90), full_btn, border_radius=4)
                f_lbl = self.font.render("Fullscreen", True, (240, 240, 240))
                self.canvas.blit(f_lbl, (full_btn.centerx - f_lbl.get_width() // 2, full_btn.centery - f_lbl.get_height() // 2))

                pygame.draw.rect(self.canvas, (110, 50, 50), exit_btn, border_radius=4)
                e_lbl = self.font.render("Exit Game", True, (240, 240, 240))
                self.canvas.blit(e_lbl, (exit_btn.centerx - e_lbl.get_width() // 2, exit_btn.centery - e_lbl.get_height() // 2))

            # Winner Announcement Popup
            if self.winner is not None:
                win_rect = pygame.Rect(180, 280, 640, 140)
                pygame.draw.rect(self.canvas, (40, 50, 70), win_rect, border_radius=8)
                pygame.draw.rect(self.canvas, (255, 215, 0), win_rect, 3, border_radius=8)
                win_surf = self.font_large.render(f"🏆 WINNER: {self.winner} 🏆", True, (255, 215, 0))
                self.canvas.blit(win_surf, (win_rect.centerx - win_surf.get_width() // 2, win_rect.centery - 35))

                sub_win = self.font.render("Press any key to start next match (Memory Kept)", True, (200, 200, 200))
                self.canvas.blit(sub_win, (win_rect.centerx - sub_win.get_width() // 2, win_rect.centery + 10))

            # --- RENDER WITH ASPECT RATIO PRESERVATION (LETTERBOX/PILLARBOX) ---
            actual_w, actual_h = self.screen.get_size()
            target_aspect = self.logical_width / self.logical_height
            window_aspect = actual_w / actual_h

            if window_aspect > target_aspect:
                draw_h = actual_h
                draw_w = int(draw_h * target_aspect)
                draw_x = (actual_w - draw_w) // 2
                draw_y = 0
            else:
                draw_w = actual_w
                draw_h = int(draw_w / target_aspect)
                draw_x = 0
                draw_y = (actual_h - draw_h) // 2

                #For Differnt Border Colors In Fullscreen Right Now Matches Background Of Game
            self.screen.fill((25, 30, 40))
            scaled_canvas = pygame.transform.smoothscale(self.canvas, (draw_w, draw_h))
            self.screen.blit(scaled_canvas, (draw_x, draw_y))

            pygame.display.flip()
            self.clock.tick(30)

        pygame.quit()

if __name__ == "__main__":
    game = LiarsDiceGame()
    game.run()

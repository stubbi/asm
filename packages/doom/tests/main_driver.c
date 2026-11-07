// SPDX-License-Identifier: GPL-2.0-or-later
// Native integration fixture for the real assembly main loop and clock.
// Device input, elapsed time, rendering and simulation are observable stubs.
// This fixture is never linked into the game or used as a game backend.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

uint8_t doom_player[128];
uint32_t doom_actor_count, doom_paused, doom_level_complete;

enum Scenario { CLOCK, MENU, FOCUS, OVERLOAD };
static enum Scenario scenario;
static char current_map[8] = "E1M1";
static uint64_t elapsed_ms, tick_times[64];
static unsigned polls, ticks, frames, presents, menu_frames;
static unsigned capture, capture_changes, captured_ticks, paused_ticks, captured_menu_frames;
static unsigned ticks_since_frame, max_ticks_between_frames, sleep_calls;
static unsigned menu_selections[16], capture_history[32];

int doom_world_init(const char *name) {
    memcpy(current_map, name, 4);
    memset(doom_player, 0, sizeof doom_player);
    doom_paused = doom_level_complete = 0;
    return 0;
}

const char *doom_world_map(void) { return current_map; }
int doom_world_transition(const char *name) { return doom_world_init(name); }

void doom_world_tick(const void *input) {
    (void)input;
    if (ticks < 64) tick_times[ticks] = elapsed_ms;
    ++ticks;
    ++ticks_since_frame;
    if (ticks_since_frame > max_ticks_between_frames)
        max_ticks_between_frames = ticks_since_frame;
    captured_ticks += capture != 0;
    paused_ticks += doom_paused != 0;
    if (scenario == OVERLOAD) elapsed_ms += 40;
}

int doom_world_save(const char *path) { (void)path; return -1; }
int doom_world_restore(const char *path) { (void)path; return -1; }

int doom_platform_init(void) {
    const char *name = getenv("ASM_DOOM_MAIN_SCENARIO");
    if (!name) return -1;
    if (!strcmp(name, "clock")) scenario = CLOCK;
    else if (!strcmp(name, "menu")) scenario = MENU;
    else if (!strcmp(name, "focus")) scenario = FOCUS;
    else if (!strcmp(name, "overload")) scenario = OVERLOAD;
    else return -1;
    return 0;
}

int doom_platform_audio_available(void) { return 1; }
const char *doom_platform_error(void) { return "Unknown main-loop test scenario"; }

void doom_platform_capture(unsigned enabled) {
    capture = enabled != 0;
    if (!capture_changes || capture_history[capture_changes - 1] != capture) {
        if (capture_changes < 32) capture_history[capture_changes++] = capture;
    }
}

uint64_t doom_platform_ticks(void) { return elapsed_ms; }
void doom_platform_sleep(unsigned milliseconds) {
    elapsed_ms += milliseconds;
    ++sleep_calls;
}

int doom_platform_poll(uint32_t *input) {
    memset(input, 0, 32);
    unsigned poll = polls++;
    if (scenario == CLOCK || scenario == OVERLOAD) {
        if (ticks >= (scenario == CLOCK ? 35u : 20u)) return 1;
        if (!poll) input[5] = 2; // Enter resumes the initial menu.
        return 0;
    }
    if (scenario == MENU) {
        // Initial menu, Up wraps to Quit, Down wraps to Resume, Enter starts.
        // Escape then opens and closes the menu between simulation ticks.
        static const unsigned menu[] = {0, 3, 4, 2, 0, 1, 1, 0};
        if (poll >= sizeof menu / sizeof *menu) return 1;
        input[5] = menu[poll];
        return 0;
    }
    // Focus loss is the platform contract: set paused, then release capture.
    // The main loop must show its menu until Enter explicitly resumes play.
    if (poll == 0 || poll == 4) input[5] = 2;
    if (poll == 2) {
        doom_paused = 1;
        doom_platform_capture(0);
    }
    return poll >= 6;
}

void doom_render(void *framebuffer) {
    (void)framebuffer;
    ++frames;
    ticks_since_frame = 0;
}

void doom_render_menu(void *framebuffer, unsigned selection) {
    (void)framebuffer;
    if (menu_frames < 16) menu_selections[menu_frames] = selection;
    ++menu_frames;
    captured_menu_frames += capture != 0;
}

void doom_render_free(void) {}
void doom_platform_present(void *framebuffer) { (void)framebuffer; ++presents; }
void doom_music(const char *name) { (void)name; }
void doom_sound(int id, const char *name) { (void)id; (void)name; }

void doom_platform_shutdown(void) {
    printf("{\"ticks\":%u,\"frames\":%u,\"presents\":%u,\"menu_frames\":%u,"
           "\"captured_ticks\":%u,\"paused_ticks\":%u,\"paused\":%u,\"captured_menu_frames\":%u,"
           "\"capture\":%u,\"max_ticks_between_frames\":%u,\"sleep_calls\":%u,"
           "\"tick_times_ms\":[", ticks, frames, presents, menu_frames,
           captured_ticks, paused_ticks, doom_paused, captured_menu_frames, capture,
           max_ticks_between_frames, sleep_calls);
    for (unsigned i = 0; i < ticks && i < 64; ++i)
        printf("%s%llu", i ? "," : "", (unsigned long long)tick_times[i]);
    printf("],\"menu_selections\":[");
    for (unsigned i = 0; i < menu_frames && i < 16; ++i)
        printf("%s%u", i ? "," : "", menu_selections[i]);
    printf("],\"capture_history\":[");
    for (unsigned i = 0; i < capture_changes && i < 32; ++i)
        printf("%s%u", i ? "," : "", capture_history[i]);
    printf("]}\n");
}

/* SPDX-License-Identifier: GPL-2.0-or-later
 * Save boundary regression fixture. All game behavior remains in world.s. */
#define main existing_world_fixture_main
#include "world_driver.c"
#undef main
#include <sys/stat.h>

static uint32_t read32(const unsigned char *p, size_t off) {
    uint32_t value;
    memcpy(&value, p + off, sizeof value);
    return value;
}
static void write32(unsigned char *p, size_t off, uint32_t value) {
    memcpy(p + off, &value, sizeof value);
}
static void write_float(unsigned char *p, size_t off, float value) {
    memcpy(p + off, &value, sizeof value);
}
static unsigned char *read_file(const char *path, size_t *size) {
    FILE *file = fopen(path, "rb");
    assert(file && fseek(file, 0, SEEK_END) == 0);
    long length = ftell(file);
    assert(length >= 0 && length <= 4 * 1024 * 1024);
    rewind(file);
    unsigned char *bytes = malloc((size_t)length + 1);
    assert(bytes && fread(bytes, 1, (size_t)length, file) == (size_t)length);
    assert(fclose(file) == 0);
    *size = (size_t)length;
    return bytes;
}
static void write_file(const char *path, const unsigned char *bytes, size_t size) {
    FILE *file = fopen(path, "wb");
    assert(file && fwrite(bytes, 1, size, file) == size);
    assert(fclose(file) == 0);
}
static void rehash(unsigned char *bytes, size_t size) {
    write32(bytes, 40, 0);
    uint32_t hash = 0x811c9dc5;
    for (size_t i = 0; i < size; ++i) hash = (hash ^ bytes[i]) * 0x1000193;
    write32(bytes, 40, hash);
}
static void assert_unchanged(const char *path, const unsigned char *before, size_t size) {
    assert(doom_world_save(path) == 0);
    size_t actual_size;
    unsigned char *actual = read_file(path, &actual_size);
    assert(actual_size == size && memcmp(actual, before, size) == 0);
    free(actual);
    assert(unlink(path) == 0);
}

int main(int argc, char **argv) {
    assert(argc == 3);
    const char *which = argv[1];
    assert(doom_world_init("E1M1") == 0);
    doom_actor_count = 0;
    doom_player.health = 73;
    tick(3, (Input){0});
    const char *directory = argv[2];
    char baseline[1024], path[1024], after[1024];
    assert(snprintf(baseline, sizeof baseline, "%s/baseline", directory) > 0);
    assert(snprintf(path, sizeof path, "%s/hostile", directory) > 0);
    assert(snprintf(after, sizeof after, "%s/after", directory) > 0);
    assert(doom_world_save(baseline) == 0);
    size_t size;
    unsigned char *bytes = read_file(baseline, &size);
    unsigned char *before = malloc(size);
    assert(before);
    memcpy(before, bytes, size);
    if (!strcmp(which, "fifo")) {
        assert(mkfifo(path, 0600) == 0);
        assert(doom_world_restore(path) == -1);
        assert(doom_world_save(path) == -1);
    } else if (!strcmp(which, "symlink")) {
        assert(symlink(baseline, path) == 0);
        assert(doom_world_restore(path) == -1);
        assert(doom_world_save(path) == -1);
        size_t target_size;
        unsigned char *target = read_file(baseline, &target_size);
        assert(target_size == size && !memcmp(target, before, size));
        free(target);
    } else if (!strcmp(which, "hardlink")) {
        assert(link(baseline, path) == 0);
        assert(doom_world_save(path) == -1);
        size_t target_size;
        unsigned char *target = read_file(baseline, &target_size);
        assert(target_size == size && !memcmp(target, before, size));
        free(target);
    } else if (!strcmp(which, "unrelated")) {
        const unsigned char unrelated[] = "Keep this existing file.\n";
        write_file(path, unrelated, sizeof unrelated);
        assert(doom_world_restore(path) == -1);
        assert(doom_world_save(path) == -1);
        size_t actual_size;
        unsigned char *actual = read_file(path, &actual_size);
        assert(actual_size == sizeof unrelated && !memcmp(actual, unrelated, sizeof unrelated));
        free(actual);
    } else {
        /* The fixture has no actors and one sector. Derive the mover offset. */
        size_t mover = 256 + 80 * read32(bytes, 16) + 12 * read32(bytes, 20);
        assert(mover + 24 <= size);
        write32(bytes, mover, 9);
        write_float(bytes, mover + 4, 0);
        write_float(bytes, mover + 8, 1);
        write_float(bytes, mover + 16, 128);
        if (!strcmp(which, "negative-speed")) write_float(bytes, mover + 8, -1);
        else if (!strcmp(which, "zero-speed")) write_float(bytes, mover + 8, 0);
        else if (!strcmp(which, "large-speed")) write_float(bytes, mover + 8, 129);
        else if (!strcmp(which, "large-target")) write_float(bytes, mover + 4, -40000);
        else if (!strcmp(which, "large-top")) write_float(bytes, mover + 16, 40000);
        else if (!strncmp(which, "crusher-", 8)) {
            write32(bytes, mover, 7);
            write_float(bytes, mover + 4, 8);
            if (!strcmp(which, "crusher-nan")) write32(bytes, mover + 20, 0x7fc00000);
            else if (!strcmp(which, "crusher-inf")) write32(bytes, mover + 20, 0x7f800000);
            else if (!strcmp(which, "crusher-negative")) write_float(bytes, mover + 20, -1);
            else if (!strcmp(which, "crusher-large")) write_float(bytes, mover + 20, 3);
            else return 2;
        } else if (!strcmp(which, "door-wait")) {
            write32(bytes, mover, 1);
            write32(bytes, mover + 20, 1051);
        } else if (!strcmp(which, "floor-crush")) {
            write32(bytes, mover, 2);
            write32(bytes, mover + 20, 2);
        } else return 2;
        rehash(bytes, size);
        write_file(path, bytes, size);
        assert(doom_world_restore(path) == -1);
    }
    assert_unchanged(after, before, size);
    assert(unlink(path) == 0);
    assert(unlink(baseline) == 0);
    free(before);
    free(bytes);
    puts("Hostile save rejected; state and existing files preserved.");
    return 0;
}

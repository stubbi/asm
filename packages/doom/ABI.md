# Engine module contract

All game code is handwritten Apple AArch64 assembly. All exported symbols below have a leading underscore in assembly.
Use the Apple arm64 C ABI: preserve x19–x28, x29, SP and the lower 64 bits of v8–v15. Keep SP 16-byte aligned.
No function can retain caller-saved registers across a call. Document routine contracts and stack use.
Integer/pointer arguments use x0–x7; floating arguments use s0–s7. Variadic C arguments belong on the stack.

## Ownership

- Root: `wad.s`, `textures.s`, `main.s`, resource globals, build/integration/tests/package evidence.
- World agent: `world.s`, world and actor globals, collision, gameplay, dynamic sectors, saves.
- Render agent: `render.s`, rendering buffers and caches.
- Platform agent: `platform.s`, SDL/input/audio state, pinned SDL build helper.
- Only root changes this ABI. Send interface requests before changing shared state.

## Resources (root exports)

`doom_wad_init(x0=data,x1=bytes) -> w0=0/-1`. Validates IWAD/PWAD and every directory range. Does not own the input.
`doom_lump(x0=NUL name up to 8 bytes) -> x0=data or 0,x1=bytes` (private two-register return).
`doom_lump_index(w0=index) -> x0=data or 0,x1=bytes`.
`doom_lump_number(x0=name) -> w0=index or -1`.
`doom_map_load(x0=NUL E1M1 name) -> w0=0/-1`. Validate all map records and indices before replacing globals.
Map globals are 64-bit pointers and 32-bit counts: `doom_vertices/doom_vertex_count` (4-byte records), `doom_lines/doom_line_count` (14), `doom_sides/doom_side_count` (30), `doom_sectors/doom_sector_count` (26), `doom_segs/doom_seg_count` (12), `doom_subsectors/doom_subsector_count` (4), `doom_nodes/doom_node_count` (28), `doom_things/doom_thing_count` (10), `doom_reject/doom_reject_bytes`, `doom_blockmap/doom_blockmap_bytes`.
Raw records are standard little-endian Doom layout. Coordinates and heights are signed 16-bit. Maximum 32768 records per lump; actors maximum 4096.
Global `doom_palette` points at 768-byte PLAYPAL. `doom_colormap` points at the COLORMAP lump.
`doom_texture(x0=name) -> x0=descriptor or 0`. Composite wall texture; name is 8 bytes or NUL terminated.
`doom_patch(x0=name) -> x0=descriptor or 0`. Decode transparent posts without reserving a palette color.
Descriptor layout: u32 width at0, u32 height at4, pointer to row-major palette bytes at8, i32 leftoffset at16, i32 topoffset at20, pointer to row-major alpha bytes at24. Alpha is0 fortransparent or1 foropaque. A NULLalpha pointer permits legacyfixtures where palette255 denotes transparency. Realresources always supply alpha and retain all256 palette colors. Owned by resource module; valid until shutdown.
`doom_flat(x0=name) -> x0=4096 palette bytes or 0`.
`doom_resources_free()`. Called only after consumers stop.

## World (world agent exports)

`doom_world_init(x0=map name) -> w0=0/-1`. Loads map, starts player, copies dynamic sector state and spawns actors.
`doom_world_transition(x0=map name) -> w0=0/-1`. Starts another map while retaining public inventory and private backpack/armor type. Resets map keys, counters and temporary powers.
`doom_world_map() -> x0=borrowed NUL-terminated current map name`. Changes only after successful initialization or restore.
`doom_world_side_texture(w0=side index,w1=slot 0 upper/1 lower/2 middle) -> x0=borrowed 8-byte name orNULL`. Includes switch changes.
`doom_world_floor_flat(w0=sector) -> x0=borrowed 8-byte name orNULL`. Includes floor material changes.
`doom_world_side_offset(w0=side) -> s0=dynamic horizontal offset`. Includes scrolling walls.
`doom_world_tick(x0=input)` runs exactly one 1/35-second game tick.
`doom_point_sector(s0=x,s1=y) -> w0=sector or -1`.
`doom_world_save(x0=path) -> w0=0/-1`; `doom_world_restore(x0=path) -> w0=0/-1`. Reject symlinks, corrupt files, wrong versions, and existing unrelated destinations. Preserve state on failure.
Global `doom_player` is 128 bytes:
offsets 0 x:f32; 4 y:f32; 8 feet_z:f32; 12 angle:f32 radians (east=0, north=pi/2); 16 health:i32; 20 armor:i32; 24 bullets:i32; 28 shells:i32; 32 rockets:i32; 36 cells:i32; 40 weapon:i32 (1 fist,2 pistol,3 shotgun,4 chaingun,5 rocket,6 plasma,7 BFG); 44 keys:u32 (blue1,yellow2,red4); 48 sector:i32; 52 eye_height:f32; 56 kills:i32; 60 items:i32; 64 secrets:i32; 68 weapon_tics:i32; 72 owned_weapons:u32 (bit=weapon); 76 damage_flash:i32; 80 onward reserved zero.
Global `doom_actors` contains up to 4096 fixed 80-byte records. `doom_actor_count` is u32.
Actor offsets: 0 x:f32;4 y:f32;8 z:f32;12 angle:f32;16 radius:f32;20 height:f32;24 Doom thing type:i32;28 health:i32;32 flags:u32;36 state:i32;40 state_tics:i32;44 target:i32;48 sprite:8 ASCII bytes (full lump name, e.g. TROOA1);56 frame:i32;60 pain:i32;64 cooldown:i32;68 spawn_x:f32;72 spawn_y:f32;76 misc:i32.
Actor flags: solid=1, shootable=2, pickup=4, corpse=8, missile=16, monster=32, hidden=64.
Global `doom_sector_floors` and `doom_sector_ceilings` point to sector_count f32 values; `doom_sector_lights` points to sector_count i32 values. Raw map records remain immutable.
Global `doom_tic` u32, `doom_level_complete` u32 (0 none,1 normal,2 secret), `doom_skill` u32 (1..5;default3), `doom_paused` u32.
`doom_sound(w0=sound id,x1=8-byte name)` is imported from platform. sound id is advisory; name selects DS lump. Null/missing audio must be harmless.

## Input and platform (platform agent exports)

Input is 32 bytes: f32 forward at0 (world units/tic, nominal4), f32 strafe at4 (positive moves right), f32 turn at8 (positive turns left, radians/tic), u32 buttons at12 (use1,fire2,run4,pause8), i32 weapon at16 (0 no change), i32 menu at20 (0 none,1 escape,2 enter,3 up,4 down), i32 save at24 (1 save,2 restore), u32 reserved at28.
`doom_platform_init() -> w0=0/-1`. Uses SDL3, 960x600 resizable window, correct 4:3 gameplay aspect.
`doom_platform_poll(x0=input) -> w0=1 quit or 0`. Clears then fills input; release capture on escape; pause on focus loss.
`doom_platform_present(x0=RGBA framebuffer)` presents 320x200 pixels. Host little-endian u32 pixel is 0xffRRGGBB.
`doom_platform_ticks() -> x0=monotonic milliseconds`.
`doom_platform_sleep(w0=milliseconds)`.
`doom_platform_shutdown()`.
`doom_platform_error() -> x0=borrowed SDL error string`.
`doom_platform_audio_available() -> w0=1 or0`.
`doom_platform_capture(w0=0 release/1 capture)`. Safe before initialization; main controls capture while menus are open.
`doom_sound(w0=id,x1=lump name)` queues decoded DS sound. Uses bounded assembly mixer and SDL for device output.
`doom_music(x0=MUS lump name)` starts music; null stops. Decode and synthesize in assembly; document timbre limitations.
Headless main never calls platform init, poll, present, or music; world sound calls must safely do nothing without init.

## Renderer (render agent exports)

`doom_render(x0=framebuffer)` fills exactly 320*200 u32 pixels. Render scene in first168 rows and HUD in last32.
`doom_render_menu(x0=framebuffer,w1=selection)` draws menu over the existing frame. Selection 0 resume,1 new game,2 save,3 load,4 quit.
`doom_render_free()` releases renderer-owned buffers.
Calls world/resource exports and primitive system math functions; never SDL. Use real map geometry and textures. Use transparent sprites, visibility, correct walls and planes; keep all accesses bounded.

## Main (root)

Owns app lifecycle, argument parsing, fixed35Hz scheduling, map progression, menus, screenshot/JSON headless output, and embedded data expansion.
Commands: `--help`, `--version`, `--headless --ticks N [--map E1M1] [--screenshot PATH] [--iwad PATH]`. Additional test scripts may be added with a documented bounded format.
Default launch starts a playable bundled game and shows controls. Does not execute on install. No external commands or network are used at runtime.

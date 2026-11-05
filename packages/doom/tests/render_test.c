/* SPDX-License-Identifier: GPL-2.0-or-later
 * Native framebuffer contract tests. Resource doubles supply bounded, immutable
 * Doom records; all rendering and projection run in handwritten assembly. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void *doom_vertices, *doom_lines, *doom_sides, *doom_sectors;
void *doom_segs, *doom_subsectors, *doom_nodes, *doom_things;
uint32_t doom_vertex_count, doom_line_count, doom_side_count, doom_sector_count;
uint32_t doom_seg_count, doom_subsector_count, doom_node_count, doom_thing_count;
uint8_t *doom_palette, *doom_colormap;
float *doom_sector_floors, *doom_sector_ceilings;
int32_t *doom_sector_lights;
_Alignas(16) uint8_t doom_player[128], doom_actors[4096*80];
uint32_t doom_actor_count, doom_tic, doom_paused;

struct texture { uint32_t width,height; uint8_t *pixels; int32_t left,top; uint8_t *mask; };
static uint8_t wall_pixels[64*64], far_pixels[64*64], floor_pixels[4096], ceil_pixels[4096];
static uint8_t sprite_pixels[32*32], palette[768];
static uint8_t sprite_back_pixels[32*32],sprite_pair_pixels[32*32];
static struct texture wall={64,64,wall_pixels,0,64};
static struct texture farwall={64,64,far_pixels,0,64};
static struct texture sprite={32,32,sprite_pixels,16,32};
static struct texture sprite_back={32,32,sprite_back_pixels,16,32};
static struct texture sprite_pair={32,32,sprite_pair_pixels,16,32};
static uint8_t weapon_idle_pixels[64],weapon_fire_pixels[64];
static uint8_t wall_mask[4096],sprite_mask[1024],weapon_mask[64];
static struct texture weapon_idle={8,8,weapon_idle_pixels,0,0};
static struct texture weapon_fire={8,8,weapon_fire_pixels,0,0};
void *doom_texture(const char *name) {
    if(!memcmp(name,"WALL",4))return &wall;
    return !memcmp(name,"FARWALL",7) ? &farwall : NULL;
}
void *doom_flat(const char *name) {
    return !memcmp(name,"FLOOR",5) ? floor_pixels : ceil_pixels;
}
void *doom_patch(const char *name) {
    if(!memcmp(name,"TESTA0",6))return &sprite;
    if(!memcmp(name,"TESTA5",6))return &sprite_back;
    if(!memcmp(name,"TESTA2A8",8))return &sprite_pair;
    if(!memcmp(name,"PISGA0",6))return &weapon_idle;
    if(!memcmp(name,"PISGB0",6))return &weapon_fire;
    return NULL;
}
int doom_point_sector(float x,float y) {
    (void)y;if(!doom_sector_count)return -1;
    return doom_sector_count==2&&x>64?1:0;
}
const char *doom_world_map(void) { return "E1M1"; }
/* An absent renderer must fail an observable assertion before implementation. */
__attribute__((weak)) void doom_render(uint32_t *fb) { (void)fb; }
__attribute__((weak)) void doom_render_menu(uint32_t *fb,int selection) { (void)fb; (void)selection; }
void doom_render_free(void);
int doom_render_abi(uint32_t *);

static uint8_t vertices[8*4], lines[8*14], sides[16*30], sectors[2*26];
static float floors[2], ceilings[2];
static int32_t lights[2];
static float scroll_offset;
const char *doom_world_side_texture(unsigned side,unsigned slot) {
    return side<doom_side_count&&slot<3?(char *)sides+side*30+4+8*slot:NULL;
}
const char *doom_world_floor_flat(unsigned sector) {
    return sector<doom_sector_count?(char *)sectors+sector*26+4:NULL;
}
float doom_world_side_offset(unsigned side) {
    int16_t offset;memcpy(&offset,sides+side*30,2);return offset+scroll_offset;
}
static void u16(uint8_t *p,int n) { p[0]=n; p[1]=n>>8; }
static void vertex(int n,int x,int y) { u16(vertices+n*4,x);u16(vertices+n*4+2,y); }
static void side(int n,int sector) {
    uint8_t *p=sides+n*30;
    memcpy(p+4,"WALL",4);memcpy(p+12,"WALL",4);memcpy(p+20,"WALL",4);
    u16(p+28,sector);
}
static void line(int n,int a,int b,int front,int back) {
    uint8_t *p=lines+n*14;
    u16(p,a);u16(p+2,b);u16(p+10,front);u16(p+12,back);
}
static void setup(void) {
    memset(vertices,0,sizeof vertices);memset(lines,0,sizeof lines);
    memset(sides,0,sizeof sides);memset(sectors,0,sizeof sectors);
    memset(doom_player,0,sizeof doom_player);memset(doom_actors,0,sizeof doom_actors);
    vertex(0,-64,-64);vertex(1,-64,64);vertex(2,64,64);vertex(3,64,-64);
    for(int i=0;i<4;i++){side(i,0);line(i,i,(i+1)%4,i,65535);}
    for(int i=0;i<2;i++) {
        memcpy(sectors+i*26+4,"FLOOR",5);memcpy(sectors+i*26+12,"CEIL",4);
        floors[i]=0;ceilings[i]=64;lights[i]=255;
    }
    for(int i=0;i<256;i++) { palette[i*3]=i;palette[i*3+1]=0;palette[i*3+2]=0; }
    memset(wall_pixels,120,sizeof wall_pixels);memset(floor_pixels,40,sizeof floor_pixels);
    memset(far_pixels,160,sizeof far_pixels);
    memset(ceil_pixels,80,sizeof ceil_pixels);memset(sprite_pixels,200,sizeof sprite_pixels);
    memset(sprite_back_pixels,230,sizeof sprite_back_pixels);
    for(int i=0;i<1024;i++)sprite_pair_pixels[i]=i%32<16?210:230;
    memset(weapon_idle_pixels,180,sizeof weapon_idle_pixels);
    memset(weapon_fire_pixels,220,sizeof weapon_fire_pixels);
    wall.mask=sprite.mask=weapon_idle.mask=NULL;
    doom_vertices=vertices;doom_vertex_count=4;doom_lines=lines;doom_line_count=4;
    doom_sides=sides;doom_side_count=4;doom_sectors=sectors;doom_sector_count=1;
    doom_sector_floors=floors;doom_sector_ceilings=ceilings;doom_sector_lights=lights;
    doom_palette=palette;doom_colormap=NULL;doom_actor_count=0;
    scroll_offset=0;
    *(float *)(doom_player+52)=32;*(int32_t *)(doom_player+16)=100;
}
static void check(int yes,const char *message) { if(!yes){fprintf(stderr,"FAIL: %s\n",message);exit(1);} }
static int red(uint32_t p) { return (p>>16)&255; }
int main(void) {
    uint32_t *guarded=malloc((64000+2)*4),*fb=guarded+1;
    check(guarded!=NULL,"allocate framebuffer");setup();
    for(int i=0;i<64002;i++)guarded[i]=0x12345678;
    doom_render(fb);
    check(guarded[0]==0x12345678&&guarded[64001]==0x12345678,"framebuffer guards remain intact");
    check(fb[84*320+160]!=0x12345678,"renderer fills the center wall");
    check(red(fb[84*320+160])>red(fb[166*320+160]),"actual wall differs from floor texture");
    check(red(fb[1*320+160])!=red(fb[84*320+160]),"ceiling uses its own flat");
    for(int i=0;i<64000;i++)check((fb[i]>>24)==255,"renderer fills every RGBA pixel");
    memcpy(sides+2*30+20,"FARWALL",7);doom_render(fb);
    check(red(fb[84*320+160])==160,"switch texture changes appear without rebuilding geometry");
    memset(sides+2*30+20,0,8);memcpy(sides+2*30+20,"WALL",4);
    memcpy(sectors+4,"CEIL\0\0\0\0",8);doom_render(fb);
    check(red(fb[167*320+160])==80,"floor material changes appear without rebuilding geometry");
    memcpy(sectors+4,"FLOOR\0\0\0",8);
    for(int i=0;i<4096;i++)wall_pixels[i]=100+i%64;
    scroll_offset=16;doom_render(fb);
    check(red(fb[84*320+160])==116,"scrolling sidedef offsets update the next frame");
    scroll_offset=0;memset(wall_pixels,120,sizeof wall_pixels);
    for(int i=0;i<4096;i++)floor_pixels[i]=20+i/64;
    *(float *)(doom_player+4)=16;doom_render(fb);
    check(red(fb[167*320+160])==68,"Doom flat rows use negative world Y coordinates");
    *(float *)(doom_player+4)=0;memset(floor_pixels,40,sizeof floor_pixels);
    *(int32_t *)(doom_player+76)=4;doom_render(fb);
    check(red(fb[84*320+160])>120,"damage flash gives visible scene feedback");
    *(int32_t *)(doom_player+76)=0;
    memcpy(sides+1*30+20,"FARWALL",7);*(float *)(doom_player+4)=32;doom_render(fb);
    check(red(fb[84*320])==160&&red(fb[84*320+319])==120,
          "camera rays put the north wall on the left of an eastward view");
    memset(sides+1*30+20,0,8);memcpy(sides+1*30+20,"WALL",4);
    *(float *)(doom_player+4)=0;
    /* A world sprite must appear in front of the wall, and masked texels expose it. */
    *(float *)(doom_actors+0)=40;*(float *)(doom_actors+8)=0;
    memcpy(doom_actors+48,"TESTA0",6);doom_actor_count=1;
    doom_render(fb);check(red(fb[100*320+160])>140,"world sprite projects above the floor");
    *(float *)(doom_actors+4)=16;doom_render(fb);
    check(red(fb[100*320+96])==200,"north is left when the player looks east");
    *(float *)(doom_actors+4)=0;
    memcpy(doom_actors+48,"TESTA1",6);doom_render(fb);
    check(red(fb[100*320+160])==230,"world sprite rotation shows the actor's back");
    *(float *)(doom_actors+12)=2.35619449f;doom_render(fb);
    check(red(fb[100*320+150])==210,"paired Doom rotation patch is visible");
    *(float *)(doom_actors+12)=3.92699082f;doom_render(fb);
    check(red(fb[100*320+150])==230,"paired Doom rotation patch mirrors its second rotation");
    memcpy(doom_actors+48,"TESTA0",6);
    memset(sprite_pixels,255,sizeof sprite_pixels);
    doom_render(fb);check(red(fb[100*320+160])<140,"transparent sprite texels expose the world");
    *(float *)(doom_actors+0)=100;memset(sprite_pixels,200,sizeof sprite_pixels);
    doom_render(fb);check(red(fb[100*320+160])<140,"solid walls occlude world sprites");
    /* The real linedef geometry controls projection. Move east near the wall. */
    doom_actor_count=0;*(float *)doom_player=48;
    doom_render(fb);check(red(fb[1*320+160])==red(fb[84*320+160]),"near wall occupies the upper view");
    uint64_t before=0,after=0;for(int i=0;i<64000;i++)before+=fb[i];
    doom_render_menu(fb,2);for(int i=0;i<64000;i++)after+=fb[i];
    check(before!=after,"menu draws a visible selection over the frame");
    check(fb[140*320+80]==0xffd0d0d0,"menu displays the keyboard and mouse controls");
    /* Two actual sectors share a portal with a 24-unit floor step. */
    setup();vertex(4,192,64);vertex(5,192,-64);
    side(4,1);side(5,1);side(6,1);side(7,1);
    line(2,2,3,2,4);line(4,2,4,5,65535);line(5,4,5,6,65535);line(6,5,3,7,65535);
    memset(sides+2*30+20,0,8);memset(sides+4*30+20,0,8);
    memcpy(sides+6*30+20,"FARWALL",7);
    doom_vertex_count=6;doom_line_count=7;doom_side_count=8;doom_sector_count=2;
    floors[1]=24;ceilings[1]=96;doom_render_free();doom_render(fb);
    check(red(fb[84*320+160])==160,"open portal exposes the second sector's wall");
    check(red(fb[130*320+160])==120,"higher next-sector floor renders its lower wall");
    floors[1]=60;doom_render(fb);
    check(red(fb[84*320+160])==120,"dynamic sector heights change the portal aperture");
    check(doom_render_abi(fb)==0,"render and menu preserve Apple arm64 callee-saved registers");
    *(int32_t *)(doom_player+40)=2;doom_render(fb);
    check(red(fb[166*320+160])==180,"equipped weapon is visible in the overlay");
    *(int32_t *)(doom_player+68)=4;doom_render(fb);
    check(red(fb[166*320+160])==220,"firing changes the weapon overlay frame");
    *(int32_t *)(doom_player+40)=0;floors[1]=24;ceilings[1]=32;
    memcpy(sectors+12,"F_SKY1",6);memcpy(sectors+26+12,"F_SKY1",6);
    doom_render_free();doom_render(fb);
    check(red(fb[40*320+160])==112,"adjacent sky ceilings merge without a false upper wall");
    memcpy(sectors+12,"CEIL\0\0\0\0",8);memcpy(sectors+26+12,"CEIL\0\0\0\0",8);
    floors[1]=0;ceilings[0]=ceilings[1]=128;u16(lines+2*14+4,16);
    memcpy(sides+2*30+20,"WALL\0\0\0\0",8);doom_render_free();doom_render(fb);
    check(red(fb[84*320+160])==120,"lower-unpegged masked wall anchors to the floor");
    memset(wall_pixels,255,sizeof wall_pixels);doom_render(fb);
    check(red(fb[84*320+160])==160,"masked wall holes expose the next sector");
    memset(wall_pixels,120,sizeof wall_pixels);
    setup();wall.width=0;doom_render_free();doom_render(fb);wall.width=64;
    check((fb[84*320+160]>>24)==255,"invalid texture dimensions use the bounded fallback");
    doom_line_count=doom_sector_count=0;
    doom_sector_floors=doom_sector_ceilings=NULL;doom_sector_lights=NULL;
    doom_render_free();doom_render(fb);
    check(guarded[0]==0x12345678&&guarded[64001]==0x12345678,"empty world keeps framebuffer guards intact");
    for(int i=0;i<64000;i++)check((fb[i]>>24)==255,"empty world still fills an opaque frame");
    setup();memset(wall_pixels,255,sizeof wall_pixels);memset(wall_mask,1,sizeof wall_mask);
    wall.mask=wall_mask;doom_render_free();doom_render(fb);
    check(red(fb[84*320+160])==255,"explicit wall alpha preserves opaque palette index255");
    memset(wall_pixels,120,sizeof wall_pixels);
    *(float *)doom_actors=40;memcpy(doom_actors+48,"TESTA0",6);doom_actor_count=1;
    memset(sprite_pixels,255,sizeof sprite_pixels);memset(sprite_mask,1,sizeof sprite_mask);sprite.mask=sprite_mask;
    doom_render(fb);
    check(red(fb[100*320+160])==255,"explicit sprite alpha preserves opaque palette index255");
    memset(sprite_mask,0,sizeof sprite_mask);doom_render(fb);
    check(red(fb[100*320+160])==120,"explicit zero alpha exposes the world");
    doom_actor_count=0;*(int32_t *)(doom_player+40)=2;
    memset(weapon_idle_pixels,255,sizeof weapon_idle_pixels);memset(weapon_mask,1,sizeof weapon_mask);
    weapon_idle.mask=weapon_mask;doom_render(fb);
    check(red(fb[166*320+160])==255,"explicit UI alpha preserves opaque palette index255");
    check(doom_render_abi(fb)==0,"explicit-alpha paths preserve the Apple arm64 ABI");
    check(guarded[0]==0x12345678&&guarded[64001]==0x12345678,"explicit-alpha rendering keeps framebuffer guards intact");
    free(guarded);puts("native render tests passed");return 0;
}

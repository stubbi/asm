/* SPDX-License-Identifier: GPL-2.0-or-later
 * Native behavioral driver. This file contains test fixtures, not game rules. */
#include <assert.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct { float x,y,z,angle; int health,armor,bullets,shells,rockets,cells,weapon; unsigned keys; int sector; float eye; int kills,items,secrets,weapon_tics; unsigned owned; int flash; char reserved[48]; } Player;
typedef struct { float x,y,z,angle,radius,height; int type,health; unsigned flags; int state,tics,target; char sprite[8]; int frame,pain,cooldown; float spawnx,spawny; int misc; } Actor;
typedef struct { float forward,strafe,turn; unsigned buttons; int weapon,menu,save,reserved; } Input;
extern Player doom_player;
extern Actor doom_actors[4096];
extern unsigned doom_actor_count,doom_tic,doom_level_complete,doom_skill,doom_paused;
extern float *doom_sector_floors,*doom_sector_ceilings;
extern int *doom_sector_lights;
extern const char *doom_world_side_texture(unsigned,unsigned);
extern int doom_world_transition(const char *);
extern int doom_world_init(const char *),doom_world_save(const char *),doom_world_restore(const char *);
extern void doom_world_tick(Input *);
extern int doom_point_sector(float,float);
void *doom_vertices,*doom_lines,*doom_sides,*doom_sectors,*doom_segs,*doom_subsectors,*doom_nodes,*doom_things,*doom_reject,*doom_blockmap;
unsigned doom_vertex_count,doom_line_count,doom_side_count,doom_sector_count,doom_seg_count,doom_subsector_count,doom_node_count,doom_thing_count,doom_reject_bytes,doom_blockmap_bytes;
static int extra_start,fixture_special,fixture_hazard,fixture_gap;
static void gap_room(int);
static uint8_t vertices[64],lines[224],sides[480],sectors[104],segs[192],subs[12],nodes[56],things[80];
static void put16(void *v,unsigned offset,int n){uint16_t t=(uint16_t)n;memcpy((char *)v+offset,&t,2);}
static void thing(unsigned i,int x,int y,int angle,int type){put16(things,i*10,x);put16(things,i*10+2,y);put16(things,i*10+4,angle);put16(things,i*10+6,type);put16(things,i*10+8,7);}
static void line(unsigned i,unsigned a,unsigned b,unsigned right,unsigned left,int special,int tag){put16(lines,i*14,a);put16(lines,i*14+2,b);put16(lines,i*14+4,left==65535?1:4);put16(lines,i*14+6,special);put16(lines,i*14+8,tag);put16(lines,i*14+10,right);put16(lines,i*14+12,left);}
int doom_map_load(const char *name){
 if(strcmp(name,"E1M1")&&strcmp(name,"E1M2")&&strcmp(name,"E2M8"))return -1;
 memset(vertices,0,sizeof(vertices));memset(lines,0,sizeof(lines));memset(sides,0,sizeof(sides));memset(sectors,0,sizeof(sectors));memset(segs,0,sizeof(segs));memset(subs,0,sizeof(subs));memset(nodes,0,sizeof(nodes));memset(things,0,sizeof(things));
 const int xy[4][2]={{-128,-128},{128,-128},{128,128},{-128,128}};
 for(unsigned i=0;i<4;i++){put16(vertices,4*i,xy[i][0]);put16(vertices,4*i+2,xy[i][1]);line(i,i,(i+1)%4,i,65535,0,0);put16(sides,i*30+28,0);put16(segs,i*12+6,i);}
 line(1,2,1,1,65535,0,0);put16(sectors,0,0);put16(sectors,2,128);put16(sectors,20,160);put16(subs,0,4);put16(subs,2,0);
 thing(0,!strcmp(name,"E1M2")?-64:0,!strcmp(name,"E1M2")?32:0,0,1);thing(1,0,0,0,2011);thing(2,80,0,180,3004);
 doom_vertices=vertices;doom_vertex_count=4;doom_lines=lines;doom_line_count=4;doom_sides=sides;doom_side_count=4;doom_sectors=sectors;doom_sector_count=1;doom_segs=segs;doom_seg_count=4;doom_subsectors=subs;doom_subsector_count=1;doom_nodes=nodes;doom_node_count=0;doom_things=things;doom_thing_count=3;if(extra_start){thing(3,0,0,0,11);doom_thing_count=4;}
 if(fixture_gap)gap_room(fixture_gap==1);
 if(fixture_hazard)put16(sectors,22,5);
 if(fixture_special){put16(lines,14+6,fixture_special);put16(lines,14+8,1);put16(sectors,24,1);memcpy(sides+30+20,"SW1BRCOM",8);}
 return 0;
}
int doom_lump_number(const char *name){return (!strcmp(name,"E1M1")||!strcmp(name,"E1M2")||!strcmp(name,"E2M8"))?0:-1;}
typedef struct {void *data; size_t bytes;} Lump;
Lump doom_lump_index(unsigned index){switch(index){case 1:return (Lump){things,doom_thing_count*10};case 2:return (Lump){lines,doom_line_count*14};case 3:return (Lump){sides,doom_side_count*30};case 4:return (Lump){vertices,doom_vertex_count*4};case 5:return (Lump){segs,doom_seg_count*12};case 6:return (Lump){subs,doom_subsector_count*4};case 7:return (Lump){nodes,doom_node_count*28};case 8:return (Lump){sectors,doom_sector_count*26};case 9:case 10:return (Lump){things,0};default:return (Lump){0,0};}}
void *doom_texture(const char *name){(void)name;return NULL;}
void doom_sound(unsigned id,const char *name){(void)id;(void)name;}
static void portal(int floor,int ceiling,int special){
 memset(vertices,0,sizeof(vertices));memset(lines,0,sizeof(lines));memset(sides,0,sizeof(sides));memset(sectors,0,sizeof(sectors));memset(nodes,0,sizeof(nodes));memset(segs,0,sizeof(segs));memset(subs,0,sizeof(subs));
 const int xy[6][2]={{-128,-128},{0,-128},{128,-128},{128,128},{0,128},{-128,128}};
 for(unsigned i=0;i<6;i++){put16(vertices,4*i,xy[i][0]);put16(vertices,4*i+2,xy[i][1]);line(i,i,(i+1)%6,i,65535,0,0);put16(sides,i*30+28,(i>=1&&i<=3)?1:0);}
 line(6,4,1,6,7,special,0);put16(sides,6*30+28,0);put16(sides,7*30+28,1);
 put16(sectors,0,0);put16(sectors,2,128);put16(sectors,20,160);put16(sectors,26,floor);put16(sectors,28,ceiling);put16(sectors,46,160);
 put16(subs,0,1);put16(subs,2,0);put16(subs,4,1);put16(subs,6,1);put16(segs,6,0);put16(segs,18,2);
 put16(nodes,4,0);put16(nodes,6,1);put16(nodes,24,0x8001);put16(nodes,26,0x8000);
 doom_vertex_count=6;doom_line_count=7;doom_side_count=8;doom_sector_count=2;doom_seg_count=2;doom_subsector_count=2;doom_node_count=1;doom_thing_count=1;thing(0,-64,0,0,1);
}
static void chain(int special,int f0,int f1,int f2){
 portal(0,128,0);memset(lines,0,sizeof(lines));memset(sides,0,sizeof(sides));memset(sectors,0,sizeof(sectors));
 for(unsigned i=0;i<3;i++){put16(sectors,i*26,i==0?f0:i==1?f1:f2);put16(sectors,i*26+2,192);put16(sectors,i*26+20,160);memcpy(sectors+i*26+4,"FLOOR0_1",8);}
 put16(sectors,24,1);line(0,4,1,0,65535,special,1);put16(sides,28,2);line(1,4,1,1,2,0,0);put16(sides,30+28,0);put16(sides,60+28,1);line(2,4,1,3,4,0,0);put16(sides,90+28,1);put16(sides,120+28,2);
 doom_line_count=3;doom_side_count=5;doom_sector_count=3;doom_actor_count=0;doom_player.x=-32;doom_player.y=0;doom_player.sector=0;doom_player.z=f0;for(unsigned i=0;i<3;i++){doom_sector_floors[i]=(float)(i==0?f0:i==1?f1:f2);doom_sector_ceilings[i]=192;}
}
static void gap_room(int gap){
 memset(vertices,0,sizeof(vertices));memset(lines,0,sizeof(lines));memset(sides,0,sizeof(sides));memset(sectors,0,sizeof(sectors));memset(nodes,0,sizeof(nodes));memset(segs,0,sizeof(segs));memset(subs,0,sizeof(subs));memset(things,0,sizeof(things));
 const int xy[8][2]={{-2048,-128},{0,-128},{128,-128},{2048,-128},{2048,128},{128,128},{0,128},{-2048,128}};
 for(unsigned i=0;i<8;i++){put16(vertices,4*i,xy[i][0]);put16(vertices,4*i+2,xy[i][1]);line(i,i,(i+1)%8,i,65535,0,0);int sec=(i==0||i==6||i==7)?0:(i==1||i==5)?1:2;put16(sides,i*30+28,sec);}
 line(8,6,1,8,9,0,0);put16(sides,8*30+28,0);put16(sides,9*30+28,1);line(9,5,2,10,11,0,0);put16(sides,10*30+28,1);put16(sides,11*30+28,2);
 for(unsigned i=0;i<3;i++){put16(sectors,i*26,gap&&i==1?-128:0);put16(sectors,i*26+2,128);put16(sectors,i*26+20,160);put16(subs,i*4,1);put16(subs,i*4+2,i);put16(segs,i*12+6,i);}
 put16(nodes,0,128);put16(nodes,6,1);put16(nodes,24,0x8002);put16(nodes,26,0x8001);put16(nodes,28+6,1);put16(nodes,28+24,0);put16(nodes,28+26,0x8000);
 thing(0,-768,0,0,1);doom_vertex_count=8;doom_line_count=10;doom_side_count=12;doom_sector_count=3;doom_seg_count=3;doom_subsector_count=3;doom_node_count=2;doom_thing_count=1;
}
static const char *wide_side(unsigned side,unsigned slot){
 register uintptr_t arg0 __asm__("x0")=((uintptr_t)1<<32)|side;
 register uintptr_t arg1 __asm__("x1")=slot;
 __asm__ volatile("bl _doom_world_side_texture" : "+r"(arg0) : "r"(arg1) : "x8","x17","x30","cc","memory");
 return (const char *)arg0;
}
static void tick(unsigned n,Input input){for(unsigned i=0;i<n;i++)doom_world_tick(&input);}
int main(int argc,char **argv){
 assert(argc==2);const char *which=argv[1];
 assert(sizeof(Player)==128&&sizeof(Actor)==80&&sizeof(Input)==32);
 extra_start=!strcmp(which,"start-markers");
 fixture_special=!strcmp(which,"switch-texture")?62:0;fixture_hazard=!strcmp(which,"transition");fixture_gap=!strcmp(which,"run-gap")?1:(!strcmp(which,"momentum")||!strcmp(which,"momentum-save"))?2:0;
 assert(doom_world_init("E1M1")==0);
 assert(doom_player.health==100&&doom_player.bullets==50&&doom_player.weapon==2);
 assert(doom_point_sector(doom_player.x,doom_player.y)==doom_player.sector);
 if(!strcmp(which,"spawn")){assert(doom_actor_count==2);assert(doom_actors[1].type==3004);assert(doom_player.eye==41);puts("spawn passed");return 0;}
 if(!strcmp(which,"movement")){doom_actor_count=0;tick(100,(Input){.forward=4});assert(doom_player.x>100&&doom_player.x<=112.01f);assert(fabsf(doom_player.y)<.01);assert(doom_player.z==0);puts("movement passed");return 0;}
 if(!strcmp(which,"combat")){doom_actors[1].x=80;doom_actors[1].cooldown=1000;tick(80,(Input){.buttons=2});assert(doom_actors[1].health<=0);assert(doom_actors[1].flags&8);assert(doom_player.kills==1);assert(doom_player.bullets<50);puts("combat passed");return 0;}
 if(!strcmp(which,"pickup")){doom_actor_count=1;doom_player.health=50;tick(1,(Input){0});assert(doom_player.health==60);assert(doom_actors[0].flags&64);assert(doom_player.items==1);puts("pickup passed");return 0;}
 if(!strcmp(which,"exit")){doom_actor_count=0;put16(lines,14+6,11);doom_player.x=80;tick(1,(Input){.buttons=1});assert(doom_level_complete==1);puts("exit passed");return 0;}
 if(!strcmp(which,"step")){portal(24,128,0);/* initialize copies from modified fixture via direct globals */doom_sector_floors[1]=24;doom_sector_ceilings[1]=128;doom_player.x=-64;doom_player.y=0;doom_player.sector=0;doom_actor_count=0;assert(doom_point_sector(-64,0)==0);assert(doom_point_sector(64,0)==1);tick(28,(Input){.forward=4});assert(doom_player.x>16&&doom_player.z==24&&doom_player.sector==1);puts("step passed");return 0;}
 if(!strcmp(which,"high-step")){portal(32,128,0);doom_sector_floors[1]=32;doom_sector_ceilings[1]=128;doom_player.x=-64;doom_player.sector=0;doom_actor_count=0;tick(40,(Input){.forward=4});assert(doom_player.x<=-16&&doom_player.z==0);puts("high-step passed");return 0;}
 if(!strcmp(which,"door")){portal(0,0,26);doom_sector_floors[1]=0;doom_sector_ceilings[1]=0;doom_player.x=-32;doom_player.sector=0;doom_actor_count=0;tick(1,(Input){.buttons=1});tick(10,(Input){0});assert(doom_sector_ceilings[1]==0);doom_player.keys=1;tick(1,(Input){.buttons=1});tick(50,(Input){0});assert(doom_sector_ceilings[1]>=100);tick(24,(Input){.forward=4});assert(doom_player.x>16&&doom_player.sector==1);puts("door passed");return 0;}
 if(!strcmp(which,"pickup-z-high")||!strcmp(which,"pickup-z-low")||!strcmp(which,"pickup-z-upper-touch")||!strcmp(which,"pickup-z-lower-touch")){int height=!strcmp(which,"pickup-z-high")?128:!strcmp(which,"pickup-z-low")?-9:!strcmp(which,"pickup-z-upper-touch")?56:-8;int accepted=height>=-8&&height<=56;doom_actor_count=1;doom_player.health=50;doom_sector_ceilings[0]=512;doom_actors[0].x=20;doom_actors[0].y=0;doom_actors[0].z=height;tick(1,(Input){0});assert(doom_player.health==(accepted?60:50));assert(!!(doom_actors[0].flags&64)==accepted);puts("pickup vertical reach passed");return 0;}
 if(!strcmp(which,"door-reversal")){portal(0,0,1);doom_sector_floors[1]=0;doom_sector_ceilings[1]=0;doom_player.x=-32;doom_player.sector=0;doom_actor_count=0;tick(1,(Input){.buttons=1});tick(10,(Input){0});float open=doom_sector_ceilings[1];assert(open>0);tick(1,(Input){.buttons=1});tick(5,(Input){0});assert(doom_sector_ceilings[1]<open);tick(1,(Input){.buttons=1});tick(70,(Input){0});assert(doom_sector_ceilings[1]==124);tick(150,(Input){0});assert(doom_sector_ceilings[1]<124);puts("manual door reversal preserves wait passed");return 0;}
 if(!strcmp(which,"lift-retrigger-bottom")||!strcmp(which,"lift-retrigger-lowering")){int top=!strcmp(which,"lift-retrigger-lowering")?256:64;portal(top,top+128,62);doom_sector_floors[1]=top;doom_sector_ceilings[1]=top+128;doom_player.x=-32;doom_player.sector=0;doom_actor_count=0;tick(1,(Input){.buttons=1});tick(35,(Input){0});if(top==64)assert(doom_sector_floors[1]==0);else assert(doom_sector_floors[1]>0&&doom_sector_floors[1]<top);tick(1,(Input){.buttons=1});tick(300,(Input){0});assert(doom_sector_floors[1]==top);puts("active lift retrigger preserved top passed");return 0;}
 if(!strcmp(which,"run-gap")){tick(180,(Input){.forward=8,.buttons=4});assert(doom_player.x>128&&doom_player.z==0&&doom_player.sector==2);puts("run gap passed");return 0;}
 if(!strcmp(which,"momentum")){float start=doom_player.x;tick(1,(Input){.forward=4});assert(fabsf(doom_player.x-start-.78125f)<.0001);float x=doom_player.x;tick(1,(Input){0});assert(fabsf(doom_player.x-x-.7080078125f)<.0001);tick(38,(Input){.forward=8,.buttons=4});x=doom_player.x;tick(1,(Input){0});assert(doom_player.x-x>12&&doom_player.x-x<17);tick(90,(Input){0});x=doom_player.x;tick(1,(Input){0});assert(doom_player.x==x);puts("momentum passed");return 0;}
 if(!strcmp(which,"air-momentum")){doom_actor_count=0;tick(1,(Input){.forward=4});doom_player.z=64;float x=doom_player.x;tick(1,(Input){.forward=8});assert(fabsf(doom_player.x-x-.7080078125f)<.0001);x=doom_player.x;tick(1,(Input){0});assert(fabsf(doom_player.x-x-.7080078125f)<.0001);puts("air momentum passed");return 0;}
 if(!strcmp(which,"momentum-save")){tick(40,(Input){.forward=8,.buttons=4});char path[]="/tmp/asm-doom-momentum-XXXXXX";int fd=mkstemp(path);assert(fd>=0);close(fd);unlink(path);float saved_x=doom_player.x;assert(doom_world_save(path)==0);tick(30,(Input){0});assert(doom_player.x>saved_x+100);Player expected=doom_player;unsigned tic=doom_tic;assert(doom_world_restore(path)==0);tick(30,(Input){0});assert(!memcmp(&expected,&doom_player,128)&&doom_tic==tic);unlink(path);puts("momentum save passed");return 0;}
 if(!strcmp(which,"accessor-abi")){assert(wide_side(1,2)==doom_world_side_texture(1,2));puts("accessor ABI passed");return 0;}
 if(!strcmp(which,"projectile-reuse")){doom_actor_count=0;doom_player.weapon=6;doom_player.owned|=64;for(int i=0;i<5000;i++){doom_player.cells=600;tick(3,(Input){.buttons=2});for(unsigned j=0;j<doom_actor_count;j++)if(doom_actors[j].type<0&&(doom_actors[j].flags&16))doom_actors[j].cooldown=1;}assert(doom_actor_count<=2);puts("projectile reuse passed");return 0;}
 if(!strcmp(which,"boss-exit")){assert(doom_world_init("E2M8")==0);doom_actors[0].flags=64;doom_actors[1].type=16;doom_actors[1].health=1;doom_actors[1].flags=3;tick(80,(Input){.buttons=2});assert(doom_actors[1].health<=0&&doom_level_complete==0);tick(50,(Input){0});assert(doom_level_complete==1);puts("boss exit passed");return 0;}
 if(!strcmp(which,"state-save-bounds")){doom_actors[1].state=2;doom_actors[1].tics=10;doom_actors[1].misc=0;char path[]="/tmp/asm-doom-state-XXXXXX";int fd=mkstemp(path);assert(fd>=0);close(fd);unlink(path);assert(doom_world_save(path)==0);FILE *f=fopen(path,"r+b");assert(f);assert(!fseek(f,0,SEEK_END));long size=ftell(f);rewind(f);uint8_t *bytes=malloc(size);assert(bytes&&fread(bytes,1,size,f)==(size_t)size);uint32_t index=3;memcpy(bytes+128+128+80+76,&index,4);memset(bytes+40,0,4);uint32_t hash=2166136261u;for(long i=0;i<size;i++)hash=(hash^bytes[i])*16777619u;memcpy(bytes+40,&hash,4);rewind(f);assert(fwrite(bytes,1,size,f)==(size_t)size);fclose(f);free(bytes);doom_player.health=73;assert(doom_world_restore(path)==-1&&doom_player.health==73);unlink(path);puts("state save bounds passed");return 0;}
 if(!strcmp(which,"transition")){doom_actor_count=1;doom_actors[0].type=8;doom_actors[0].flags=4;tick(1,(Input){0});doom_actors[0].type=2019;doom_actors[0].flags=4;tick(1,(Input){0});doom_player.bullets=333;doom_player.keys=7;assert(doom_world_transition("E1M2")==0);assert(doom_player.x==-64&&doom_player.y==32);assert(doom_player.bullets==333&&doom_player.armor==200&&doom_player.keys==0&&doom_player.kills==0);doom_actor_count=0;tick(32,(Input){0});assert(doom_player.health==95&&doom_player.armor==195);doom_actor_count=1;doom_actors[0].x=-64;doom_actors[0].y=32;doom_actors[0].type=2048;doom_actors[0].flags=4;tick(1,(Input){0});assert(doom_player.bullets==383);puts("transition passed");return 0;}
 if(!strcmp(which,"backpack")){doom_actor_count=1;doom_actors[0].type=8;doom_actors[0].flags=4;doom_player.bullets=200;tick(1,(Input){0});assert(doom_player.bullets==210);for(int i=0;i<5;i++){doom_actors[0].type=2048;doom_actors[0].flags=4;tick(1,(Input){0});}assert(doom_player.bullets==400);puts("backpack passed");return 0;}
 if(!strcmp(which,"berserk")){doom_actor_count=1;doom_actors[0].type=2023;doom_actors[0].flags=4;doom_player.health=100;tick(1,(Input){0});assert((doom_actors[0].flags&64)&&doom_player.weapon==1);puts("berserk passed");return 0;}
 if(!strcmp(which,"float")){doom_player.z=64;doom_player.x=64;doom_actor_count=2;doom_actors[0].flags=64;doom_actors[1].type=3005;doom_actors[1].x=-64;doom_actors[1].z=0;doom_actors[1].flags=35;doom_actors[1].cooldown=1000;tick(1,(Input){0});assert(doom_actors[1].z==3);puts("float passed");return 0;}
 if(!strcmp(which,"strafe-cardinal")){doom_actor_count=0;tick(1,(Input){.strafe=4});assert(fabsf(doom_player.x)<.001&&doom_player.y==-.78125f);assert(doom_world_init("E1M1")==0);doom_actor_count=0;doom_player.angle=1.57079632679f;tick(1,(Input){.strafe=4});assert(fabsf(doom_player.x-.78125f)<.001&&fabsf(doom_player.y)<.001);puts("strafe cardinal passed");return 0;}
 if(!strcmp(which,"bfg")){doom_actor_count=2;doom_actors[0].flags=64;doom_actors[1].x=80;doom_actors[1].y=0;doom_actors[1].health=4000;doom_actors[1].radius=40;doom_actors[1].flags=3;doom_player.weapon=7;doom_player.cells=40;doom_player.owned|=128;tick(1,(Input){.buttons=2});tick(40,(Input){0});assert(doom_player.cells==0);assert(doom_actors[1].health<3200);puts("BFG spray passed");return 0;}
 if(!strcmp(which,"cyber-rockets")||!strcmp(which,"caco-fireball")||!strcmp(which,"baron-fireball")){int type=!strcmp(which,"cyber-rockets")?16:!strcmp(which,"caco-fireball")?3005:3003;int missile=type==16?-5:type==3005?-2:-3;int base=type==16?20:type==3005?5:8;doom_actor_count=2;doom_actors[0].flags=64;doom_actors[1].x=96;doom_actors[1].y=0;doom_actors[1].type=type;doom_actors[1].flags=35;doom_actors[1].health=4000;doom_actors[1].target=0;doom_actors[1].cooldown=0;tick(type==16?8:type==3005?11:17,(Input){0});int found=0;for(unsigned i=0;i<doom_actor_count;i++)found|=doom_actors[i].type==missile&&doom_actors[i].health==base;assert(found);puts("monster projectile family passed");return 0;}
 if(!strcmp(which,"skull-charge")){doom_actor_count=2;doom_actors[0].flags=64;doom_actors[1].x=100;doom_actors[1].y=0;doom_actors[1].type=3006;doom_actors[1].flags=35;doom_actors[1].health=100;doom_actors[1].target=0;doom_actors[1].cooldown=0;tick(12,(Input){0});assert(doom_actors[1].state==4);tick(10,(Input){0});assert(doom_player.health<100);puts("skull charge passed");return 0;}
 if(!strcmp(which,"shotgunner-windup")){doom_actor_count=2;doom_actors[0].flags=64;doom_actors[1].type=9;doom_actors[1].flags=35;doom_actors[1].health=30;doom_actors[1].target=0;doom_actors[1].cooldown=0;tick(10,(Input){0});assert(doom_player.health==100);tick(1,(Input){0});int loss=100-doom_player.health;assert(loss>=3&&loss<=45&&loss%3==0);puts("shotgunner windup passed");return 0;}
 if(!strcmp(which,"melee-wall")){portal(0,0,0);doom_sector_floors[1]=0;doom_sector_ceilings[1]=0;doom_player.x=16;doom_player.sector=1;doom_actor_count=2;doom_actors[0].flags=64;doom_actors[1].x=-16;doom_actors[1].type=3002;doom_actors[1].flags=35;doom_actors[1].health=150;doom_actors[1].target=0;doom_actors[1].cooldown=0;tick(65,(Input){0});assert(doom_player.health==100);puts("melee wall passed");return 0;}
 if(!strcmp(which,"elevated-occlusion")){portal(64,192,0);doom_sector_floors[1]=64;doom_sector_ceilings[1]=192;doom_player.x=-96;doom_player.sector=0;doom_actor_count=2;doom_actors[0].flags=64;doom_actors[1].x=64;doom_actors[1].z=192;doom_actors[1].flags=3;doom_actors[1].health=20;tick(90,(Input){.buttons=2});assert(doom_actors[1].health==20);puts("elevated occlusion passed");return 0;}
 if(!strcmp(which,"elevated-hit")){portal(64,192,0);doom_sector_floors[1]=64;doom_sector_ceilings[1]=192;doom_player.x=-96;doom_player.sector=0;doom_actor_count=2;doom_actors[0].flags=64;doom_actors[1].x=64;doom_actors[1].z=64;doom_actors[1].flags=3;doom_actors[1].health=20;tick(90,(Input){.buttons=2});assert(doom_actors[1].health<=0);puts("elevated hit passed");return 0;}
 if(!strcmp(which,"weapon-timing")){doom_actor_count=0;tick(4,(Input){.buttons=2});assert(doom_player.bullets==50);tick(1,(Input){.buttons=2});assert(doom_player.bullets==49);tick(13,(Input){.buttons=2});assert(doom_player.bullets==49);tick(1,(Input){.buttons=2});assert(doom_player.bullets==48);puts("weapon timing passed");return 0;}
 if(!strcmp(which,"switch-texture")){doom_actor_count=0;doom_player.x=80;assert(!memcmp(doom_world_side_texture(1,2),"SW1BRCOM",8));tick(1,(Input){.buttons=1});assert(!memcmp(doom_world_side_texture(1,2),"SW2BRCOM",8));char path[]="/tmp/asm-doom-button-XXXXXX";int fd=mkstemp(path);assert(fd>=0);close(fd);unlink(path);assert(doom_world_save(path)==0);tick(35,(Input){0});assert(!memcmp(doom_world_side_texture(1,2),"SW1BRCOM",8));assert(doom_world_restore(path)==0);assert(!memcmp(doom_world_side_texture(1,2),"SW2BRCOM",8));tick(35,(Input){0});assert(!memcmp(doom_world_side_texture(1,2),"SW1BRCOM",8));unlink(path);puts("switch texture passed");return 0;}
 if(!strcmp(which,"light-off-brighter")){portal(0,128,139);put16(lines,6*14+8,1);put16(sectors,26+24,1);put16(sectors,20,255);doom_sector_floors[1]=0;doom_sector_ceilings[1]=128;doom_player.x=-32;doom_player.sector=0;doom_actor_count=0;doom_sector_lights[1]=160;tick(1,(Input){.buttons=1});assert(doom_sector_lights[1]==160);puts("light off does not brighten passed");return 0;}
 if(!strcmp(which,"light")){portal(0,128,139);put16(lines,6*14+8,1);put16(sectors,26+24,1);put16(sectors,20,80);doom_sector_floors[1]=0;doom_sector_ceilings[1]=128;doom_player.x=-32;doom_player.sector=0;doom_actor_count=0;doom_sector_lights[1]=160;tick(1,(Input){.buttons=1});assert(doom_sector_lights[1]==80);puts("light passed");return 0;}
 if(!strcmp(which,"gun-switch")){portal(0,0,46);put16(lines,6*14+8,1);put16(sectors,26+24,1);doom_sector_floors[1]=0;doom_sector_ceilings[1]=0;doom_player.x=-32;doom_player.sector=0;doom_actor_count=0;tick(1,(Input){.buttons=1});tick(10,(Input){0});assert(doom_sector_ceilings[1]==0);tick(1,(Input){.buttons=2});tick(70,(Input){0});assert(doom_sector_ceilings[1]>=100);puts("gun switch passed");return 0;}
 if(!strcmp(which,"monster-only-player")){portal(0,128,126);put16(lines,6*14+8,1);put16(sectors,26+24,1);doom_sector_floors[1]=0;doom_sector_ceilings[1]=128;doom_player.x=-32;doom_player.sector=0;doom_actor_count=1;doom_actors[0].type=14;doom_actors[0].flags=64;doom_actors[0].x=64;doom_actors[0].y=64;tick(20,(Input){.forward=4});assert(doom_player.y==0);puts("monster-only player passed");return 0;}
 if(!strcmp(which,"monster-teleport")){portal(0,128,126);put16(lines,6*14+8,1);put16(sectors,26+24,1);doom_sector_floors[1]=0;doom_sector_ceilings[1]=128;doom_player.x=80;doom_player.sector=1;doom_actor_count=2;doom_actors[0].type=14;doom_actors[0].flags=64;doom_actors[0].x=64;doom_actors[0].y=64;doom_actors[1].x=-32;doom_actors[1].y=0;doom_actors[1].flags=35;doom_actors[1].target=0;doom_actors[1].cooldown=1000;tick(55,(Input){0});assert(doom_actors[1].y>16);puts("monster teleport passed");return 0;}
 if(!strcmp(which,"start-markers")){assert(doom_actor_count==2);doom_actors[0].flags=64;doom_actors[1].flags=64;tick(1,(Input){.forward=4});assert(doom_player.x==.78125f);puts("start markers passed");return 0;}
 if(!strcmp(which,"drops")){doom_actors[0].flags=64;doom_actors[1].flags=3;tick(80,(Input){.buttons=2});int found=0;for(unsigned i=0;i<doom_actor_count;i++)found|=doom_actors[i].type==2007&&(doom_actors[i].flags&4);assert(found);puts("drops passed");return 0;}
 if(!strcmp(which,"stairs")){chain(7,0,0,0);tick(1,(Input){.buttons=1});tick(110,(Input){0});assert(doom_sector_floors[0]==8&&doom_sector_floors[1]==16&&doom_sector_floors[2]==24);puts("stairs passed");return 0;}
 if(!strcmp(which,"turbo-stairs")){chain(127,0,0,0);tick(1,(Input){.buttons=1});tick(16,(Input){0});assert(doom_sector_floors[0]==16&&doom_sector_floors[1]==32&&doom_sector_floors[2]==48);puts("turbo stairs passed");return 0;}
 if(!strcmp(which,"donut")){chain(9,64,0,32);tick(1,(Input){.buttons=1});tick(70,(Input){0});assert(doom_sector_floors[0]==32&&doom_sector_floors[1]==32&&doom_sector_floors[2]==32);puts("donut passed");return 0;}
 if(!strcmp(which,"lift")){portal(64,192,62);doom_sector_floors[1]=64;doom_sector_ceilings[1]=192;doom_player.x=-32;doom_player.sector=0;doom_actor_count=0;tick(1,(Input){.buttons=1});tick(17,(Input){0});assert(doom_sector_floors[1]==0);tick(110,(Input){0});assert(doom_sector_floors[1]>0);tick(30,(Input){0});assert(doom_sector_floors[1]==64);puts("lift passed");return 0;}
 if(!strcmp(which,"crusher")){portal(0,128,6);put16(lines,6*14+8,1);put16(sectors,26+24,1);doom_sector_floors[1]=0;doom_sector_ceilings[1]=128;doom_player.x=-32;doom_player.sector=0;doom_actor_count=0;tick(12,(Input){.forward=4});tick(20,(Input){0});assert(doom_sector_ceilings[1]<128&&doom_sector_floors[1]==0);tick(100,(Input){0});assert(doom_player.health<100);puts("crusher passed");return 0;}
 if(!strcmp(which,"solid-actor")){doom_actors[0].flags=64;doom_actors[1].flags=1;tick(30,(Input){.forward=4});assert(doom_player.x<=44.01f);puts("solid actor passed");return 0;}
 if(!strcmp(which,"occlusion")){portal(0,0,0);doom_sector_floors[1]=0;doom_sector_ceilings[1]=0;doom_player.x=-64;doom_player.sector=0;doom_actor_count=2;doom_actors[0].flags=64;doom_actors[1].x=64;doom_actors[1].y=0;doom_actors[1].flags=3;doom_actors[1].health=20;tick(80,(Input){.buttons=2});assert(doom_actors[1].health==20);puts("occlusion passed");return 0;}
 if(!strcmp(which,"rocket")){doom_actors[0].flags=64;doom_actors[1].flags=3;doom_player.weapon=5;doom_player.rockets=2;doom_player.owned|=32;tick(1,(Input){.buttons=2});tick(12,(Input){0});assert(doom_actors[1].health<=0);assert(doom_player.rockets==1);assert(doom_player.health<100);puts("rocket passed");return 0;}
 if(!strcmp(which,"barrel")){doom_actors[0]=doom_actors[1];doom_actors[0].type=2035;doom_actors[0].x=64;doom_actors[0].health=20;doom_actors[0].flags=3;doom_actors[1].x=100;doom_actors[1].health=20;doom_actors[1].flags=35;doom_actors[1].cooldown=1000;doom_player.weapon=3;doom_player.shells=2;tick(20,(Input){.buttons=2});assert(doom_actors[0].health<=0&&doom_actors[1].health<=0);assert(doom_player.health<100);puts("barrel passed");return 0;}
 if(!strcmp(which,"restart")){doom_actor_count=0;doom_player.health=0;doom_player.x=73;tick(1,(Input){.buttons=2});assert(doom_player.health==100&&doom_player.x==0);puts("restart passed");return 0;}
 if(!strcmp(which,"save")){char path[]="/tmp/asm-doom-world-XXXXXX";int fd=mkstemp(path);assert(fd>=0);close(fd);unlink(path);doom_actor_count=0;tick(8,(Input){.forward=4});float x=doom_player.x;assert(doom_world_save(path)==0);doom_player.health=91;assert(doom_world_save(path)==0);doom_player.health=12;tick(8,(Input){.strafe=4});assert(doom_world_restore(path)==0);assert(doom_player.x==x&&doom_player.y==0&&doom_player.health==91);fd=open(path,O_WRONLY);assert(fd>=0);assert(write(fd,"BAD",3)==3);close(fd);doom_player.health=73;assert(doom_world_restore(path)==-1);assert(doom_player.health==73);assert(doom_world_save(path)==-1);unlink(path);assert(symlink("/etc/passwd",path)==0);assert(doom_world_restore(path)==-1);assert(doom_world_save(path)==-1);unlink(path);puts("save passed");return 0;}
 return 2;
}

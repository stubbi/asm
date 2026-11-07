/* SPDX-License-Identifier: GPL-2.0-or-later
 * Behavioral integration fixture; all simulation is in world.s. */
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>
typedef struct {float x,y,z,angle;int health,armor,bullets,shells,rockets,cells,weapon;unsigned keys;int sector;float eye;int kills,items,secrets,wtics;unsigned owned;int flash;char reserved[48];} Player;
typedef struct {float forward,strafe,turn;unsigned buttons;int weapon,menu,save,reserved;} Input;
extern Player doom_player;
extern unsigned doom_actor_count,doom_sector_count,doom_tic;
extern unsigned char doom_actors[];
extern float *doom_sector_floors,*doom_sector_ceilings;
extern int doom_wad_init(const void *,size_t),doom_world_init(const char *),doom_point_sector(float,float),doom_world_save(const char *),doom_world_restore(const char *);
extern const char *doom_world_map(void);
extern void doom_world_tick(Input *),doom_resources_free(void);
void doom_sound(unsigned id,const char *name){(void)id;(void)name;}
int main(int argc,char **argv){
 assert(argc==2);FILE *f=fopen(argv[1],"rb");assert(f);assert(fseek(f,0,SEEK_END)==0);long n=ftell(f);rewind(f);unsigned char *z=malloc(n);assert(z&&fread(z,1,n,f)==(size_t)n);fclose(f);uLongf size=64*1024*1024;unsigned char *wad=malloc(size);assert(wad&&uncompress(wad,&size,z,n)==Z_OK);free(z);assert(doom_wad_init(wad,size)==0);
 for(int e=1;e<=4;e++)for(int m=1;m<=9;m++){
  char map[8];snprintf(map,sizeof map,"E%dM%d",e,m);assert(doom_world_init(map)==0);assert(!strcmp(doom_world_map(),map));assert(doom_player.health==100);assert(doom_player.sector>=0&&(unsigned)doom_player.sector<doom_sector_count);assert(doom_point_sector(doom_player.x,doom_player.y)==doom_player.sector);assert(doom_player.z==doom_sector_floors[doom_player.sector]);assert(doom_actor_count<=4096);
  Input input={0};for(int i=0;i<5;i++)doom_world_tick(&input);assert(doom_tic==5);input=(Input){.forward=4,.strafe=2,.turn=.02,.buttons=2};for(int i=0;i<10;i++)doom_world_tick(&input);assert(isfinite(doom_player.x)&&isfinite(doom_player.y)&&isfinite(doom_player.z));assert(doom_player.health>=0&&doom_player.health<=200);assert(doom_player.sector>=0&&(unsigned)doom_player.sector<doom_sector_count);
 }
 assert(doom_world_init("E1M1")==0);Input input={.turn=.01,.forward=2};for(int i=0;i<12;i++)doom_world_tick(&input);char dir[]="/tmp/asm-doom-campaign-XXXXXX";assert(mkdtemp(dir));char path[256];snprintf(path,sizeof path,"%s/save.bin",dir);Player before=doom_player;unsigned count=doom_actor_count;unsigned char *actors=malloc(count*80);assert(actors);memcpy(actors,doom_actors,count*80);assert(doom_world_save(path)==0);assert(doom_world_init("E2M3")==0);assert(doom_world_restore(path)==0);assert(!strcmp(doom_world_map(),"E1M1"));assert(!memcmp(&before,&doom_player,128));assert(doom_actor_count==count&&!memcmp(actors,doom_actors,count*80));doom_player.health=73;assert(doom_world_save(path)==0);doom_player.health=12;assert(doom_world_restore(path)==0&&doom_player.health==73);unlink(path);rmdir(dir);free(actors);doom_resources_free();free(wad);puts("36 campaign map spawns/ticks and cross-map save restoration passed");return 0;
}

/* SPDX-License-Identifier: GPL-2.0-or-later
 * Native acceptance driver, not a game implementation.
 * Each attempt loads an actual campaign map, selects only a camera heading,
 * then submits four ordinary forward inputs to the assembly world tick.
 * It never changes positions, actor flags, health, inventory, or map records.
 * Scope: movement from 36 starts at eight headings; no campaign completion. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

enum { DIRECTIONS=8, MOVE_TICKS=4, MAX_WAD_BYTES=64*1024*1024,
       MAX_ACTORS=4096, MAX_SECTORS=32768 };
typedef struct {
    float forward,strafe,turn;
    uint32_t buttons;
    int32_t weapon,menu,save;
    uint32_t reserved;
} Input;
extern unsigned char doom_player[128],doom_actors[MAX_ACTORS*80];
extern uint32_t doom_actor_count,doom_sector_count,doom_skill;
extern float *doom_sector_floors,*doom_sector_ceilings;
extern int doom_wad_init(const void *,size_t),doom_world_init(const char *);
extern void doom_world_tick(const Input *),doom_resources_free(void);

/* This headless test has no audio device. Sound selection stays in assembly. */
void doom_sound(unsigned id,const char *name){(void)id;(void)name;}

static float field(const unsigned char *record,unsigned offset){
    float value;memcpy(&value,record+offset,sizeof value);return value;
}
static int finite_state(const char *map,unsigned direction,unsigned tick){
    static const unsigned player_float[]={0,4,8,12,52};
    static const unsigned actor_float[]={0,4,8,12,16,20,68,72};
    for(unsigned i=0;i<sizeof player_float/sizeof *player_float;i++){
        unsigned offset=player_float[i];
        if(!isfinite(field(doom_player,offset))){
            fprintf(stderr,"FAIL %s direction=%u tick=%u player_float_offset=%u is not finite\n",
                    map,direction,tick,offset);return 0;
        }
    }
    if(doom_actor_count>MAX_ACTORS||doom_sector_count>MAX_SECTORS||
       !doom_sector_floors||!doom_sector_ceilings){
        fprintf(stderr,"FAIL %s direction=%u tick=%u invalid world array bounds\n",map,direction,tick);
        return 0;
    }
    for(unsigned actor=0;actor<doom_actor_count;actor++){
        for(unsigned i=0;i<sizeof actor_float/sizeof *actor_float;i++){
            unsigned offset=actor_float[i];
            if(!isfinite(field(doom_actors+actor*80,offset))){
                fprintf(stderr,"FAIL %s direction=%u tick=%u actor=%u float_offset=%u is not finite\n",
                        map,direction,tick,actor,offset);return 0;
            }
        }
    }
    for(unsigned sector=0;sector<doom_sector_count;sector++){
        if(!isfinite(doom_sector_floors[sector])||!isfinite(doom_sector_ceilings[sector])){
            fprintf(stderr,"FAIL %s direction=%u tick=%u sector=%u height is not finite\n",
                    map,direction,tick,sector);return 0;
        }
    }
    return 1;
}

static unsigned char *load_data(const char *path,size_t *length){
    FILE *file=fopen(path,"rb");if(!file)return NULL;
    if(fseek(file,0,SEEK_END)){fclose(file);return NULL;}
    long compressed_bytes=ftell(file);
    if(compressed_bytes<=0||compressed_bytes>MAX_WAD_BYTES){fclose(file);return NULL;}
    rewind(file);
    unsigned char *compressed=malloc((size_t)compressed_bytes),*wad=malloc(MAX_WAD_BYTES);
    if(!compressed||!wad){free(compressed);free(wad);fclose(file);return NULL;}
    size_t read_bytes=fread(compressed,1,(size_t)compressed_bytes,file);
    int close_result=fclose(file);uLongf wad_bytes=MAX_WAD_BYTES;
    int result=read_bytes==(size_t)compressed_bytes&&!close_result?
               uncompress(wad,&wad_bytes,compressed,(uLong)compressed_bytes):Z_DATA_ERROR;
    free(compressed);
    if(result!=Z_OK){free(wad);return NULL;}
    *length=(size_t)wad_bytes;return wad;
}

int main(int argc,char **argv){
    if(argc!=2){fputs("Usage: campaign-movement FREEDOOM1.wad.zlib\n",stderr);return 2;}
    _Static_assert(sizeof(Input)==32,"Input must match the native module ABI");
    size_t bytes=0;unsigned char *wad=load_data(argv[1],&bytes);
    if(!wad||doom_wad_init(wad,bytes)){
        fputs("FAIL cannot load bundled WAD through native resource parser\n",stderr);free(wad);return 2;
    }
    const float quarter_turn=0.78539816339744830962f,two_pi=6.28318530717958647692f;
    const Input forward={.forward=4.0f};
    unsigned maps=0,attempts=0,ticks=0,failures=0;
    for(unsigned episode=1;episode<=4;episode++)for(unsigned level=1;level<=9;level++){
        char map[8];snprintf(map,sizeof map,"E%uM%u",episode,level);
        unsigned moved=0,map_failed=0;float maximum=0,spawn_x=0,spawn_y=0;
        float initial_x=0,initial_y=0,initial_angle=0;
        for(unsigned direction=0;direction<DIRECTIONS;direction++){
            if(doom_world_init(map)){
                fprintf(stderr,"FAIL %s direction=%u native initialization failed\n",map,direction);
                map_failed=1;continue;
            }
            attempts++;
            if(!finite_state(map,direction,0)){map_failed=1;continue;}
            spawn_x=field(doom_player,0);spawn_y=field(doom_player,4);
            float spawn_angle=field(doom_player,12);
            if(!direction){initial_x=spawn_x;initial_y=spawn_y;initial_angle=spawn_angle;}
            else if(spawn_x!=initial_x||spawn_y!=initial_y||spawn_angle!=initial_angle){
                fprintf(stderr,"FAIL %s direction=%u fresh initialization changed the starting pose\n",map,direction);
                map_failed=1;
            }
            float angle=fmodf(spawn_angle+direction*quarter_turn,two_pi);
            memcpy(doom_player+12,&angle,sizeof angle);
            for(unsigned tick=1;tick<=MOVE_TICKS;tick++){
                doom_world_tick(&forward);ticks++;
                if(!finite_state(map,direction,tick)){map_failed=1;break;}
            }
            float dx=field(doom_player,0)-spawn_x,dy=field(doom_player,4)-spawn_y;
            float distance=hypotf(dx,dy);
            if(distance>0.0001f)moved++;
            if(distance>maximum)maximum=distance;
        }
        maps++;
        if(!moved){
            fprintf(stderr,"FAIL %s no ordinary forward displacement in eight directions at spawn=(%.3f,%.3f)\n",
                    map,spawn_x,spawn_y);map_failed=1;
        }
        if(map_failed)failures++;
        printf("%s %s moved=%u/8 max_distance=%.6f\n",map_failed?"FAIL":"PASS",map,moved,maximum);
    }
    printf("campaign starts: maps=%u attempts=%u forward_ticks=%u skill=%u failed_maps=%u\n",
           maps,attempts,ticks,doom_skill,failures);
    doom_resources_free();free(wad);return failures?1:0;
}

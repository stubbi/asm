/* SPDX-License-Identifier: GPL-2.0-or-later
 * Native integration driver only: decompress data, call engine, export pixels. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
extern int doom_wad_init(const void *,size_t),doom_world_init(const char *);
extern void doom_render(uint32_t *),doom_render_free(void),doom_resources_free(void);
extern void doom_render_menu(uint32_t *,int);
extern unsigned char doom_player[128];
extern unsigned doom_actor_count;
void doom_sound(unsigned id,const char *name){(void)id;(void)name;}
static void export_frame(const char *dir,const char *map,const char *suffix,const uint32_t *fb){
    char file[512];int len=snprintf(file,sizeof file,"%s/doom-%s%s.ppm",dir,map,suffix);
    assert(len>0&&(size_t)len<sizeof file);
    FILE *f=fopen(file,"wb");assert(f);fprintf(f,"P6\n320 200\n255\n");
    for(int i=0;i<64000;i++){unsigned char p[3]={fb[i]>>16,fb[i]>>8,fb[i]};assert(fwrite(p,1,3,f)==3);}
    assert(fclose(f)==0);printf("framebuffer=%s\n",file);
}
int main(int argc,char **argv){
    assert(argc>=4);
    FILE *f=fopen(argv[1],"rb");assert(f);assert(!fseek(f,0,SEEK_END));
    long n=ftell(f);assert(n>0);rewind(f);unsigned char *compressed=malloc(n);
    assert(compressed&&fread(compressed,1,n,f)==(size_t)n);fclose(f);
    uLongf bytes=64*1024*1024;unsigned char *wad=malloc(bytes);assert(wad);
    assert(uncompress(wad,&bytes,compressed,n)==Z_OK);free(compressed);
    assert(doom_wad_init(wad,bytes)==0);
    uint32_t *guard=malloc((64000+2)*4),*fb=guard+1;assert(guard);
    for(int e=1;e<=4;e++)for(int m=1;m<=9;m++){
        char map[8];snprintf(map,sizeof map,"E%dM%d",e,m);
        assert(doom_world_init(map)==0);guard[0]=guard[64001]=0x12345678;
        doom_render(fb);assert(guard[0]==0x12345678&&guard[64001]==0x12345678);
        unsigned changes=0;for(int i=1;i<53760;i++)changes+=fb[i]!=fb[i-1];
        assert(changes>200);for(int i=0;i<64000;i++)assert((fb[i]>>24)==255);
        int export=0;for(int i=3;i<argc;i++)export|=!strcmp(map,argv[i]);
        if(export){
            export_frame(argv[2],map,"",fb);doom_render_menu(fb,0);
            export_frame(argv[2],map,"-menu",fb);
            printf("%s player=(%.0f,%.0f) actors=%u\n",map,*(float *)doom_player,*(float *)(doom_player+4),doom_actor_count);
        }
    }
    doom_render_free();doom_resources_free();free(guard);free(wad);
    puts("36 native campaign framebuffers passed");return 0;
}

/* Native behavioral test driver only. The engine is handwritten assembly. */
#include <SDL3/SDL.h>
#include <assert.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { float forward, strafe, turn; uint32_t buttons; int weapon, menu, save; uint32_t reserved; } Input;
extern int doom_platform_init(void), doom_platform_poll(Input *);
extern void doom_platform_present(uint32_t *), doom_platform_shutdown(void), doom_platform_sleep(unsigned);
extern uint64_t doom_platform_ticks(void);
extern const char *doom_platform_error(void);
extern int doom_platform_audio_available(void);
extern void doom_platform_capture(unsigned);
extern void doom_sound(unsigned, const char *), doom_music(const char *);
/* Internal deterministic mixer entry point; no SDL calls and no device required. */
extern void doom_audio_mix(int16_t *, unsigned);
uint32_t doom_paused;
static uint8_t ds[72], mus[] = {'M','U','S',26, 9,0, 16,0, 1,0,0,0,0,0,0,0,
                              0x90,0xc5,127,14, 0x80,69,14, 0xe0,0};
static uint8_t bad[] = {'M','U','S',26,255,255,255,255,0,0,0,0,0,0,0,0};
static uint8_t midi[] = {
    'M','T','h','d',0,0,0,6,0,1,0,2,0,96,
    'M','T','r','k',0,0,0,11,0,0xff,0x51,3,7,0xa1,0x20,0,0xff,0x2f,0,
    'M','T','r','k',0,0,0,15,0,0xc0,0,0,0x90,69,127,96,0x80,69,0,0,0xff,0x2f,0
};
static uint8_t *extra;
static size_t extra_size;
typedef struct { void *data; uint64_t bytes; } Lump;
typedef struct { int result; unsigned broken; } Probe;
extern Probe platform_abi_call(void *, uintptr_t, uintptr_t, uintptr_t);
static int checked_call(void *function, uintptr_t a, uintptr_t b, uintptr_t c) {
    Probe probe=platform_abi_call(function,a,b,c);
    if (probe.broken) fprintf(stderr,"callee-save failure mask: %x\n",probe.broken);
    assert(!probe.broken); return probe.result;
}
Lump doom_lump(const char *name) {
    if (!strcmp(name,"DSTEST")) return (Lump){ds,sizeof(ds)};
    if (!strcmp(name,"D_TEST")) return (Lump){mus,sizeof(mus)};
    if (!strcmp(name,"D_BAD")) return (Lump){bad,sizeof(bad)};
    if (!strcmp(name,"D_MIDI")) return (Lump){midi,sizeof(midi)};
    if (!strcmp(name,"D_EXTRA")) return (Lump){extra,extra_size};
    return (Lump){0,0};
}
static void key(SDL_Scancode code, int down) {
    SDL_Event event = {0}; event.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
    event.key.scancode = code; event.key.down = down; assert(SDL_PushEvent(&event));
}
static int audible(const int16_t *pcm, size_t count) {
    for (size_t i=0;i<count;i++) if (pcm[i]) return 1;
    return 0;
}
int main(int argc, char **argv) {
    Input in; int16_t pcm[4096];
    ds[0]=3; ds[2]=0x11; ds[3]=0x2b; ds[4]=64;
    for(unsigned i=0;i<64;i++) ds[i+8]=(i&8)?220:32;
    if (argc>1 && !strcmp(argv[1],"--headless")) {
        checked_call(doom_platform_capture,1,0,0); checked_call(doom_platform_capture,0,0,0);
        doom_sound(0,"DSTEST"); doom_music("D_TEST"); doom_music(NULL);
        doom_platform_shutdown(); doom_platform_shutdown(); puts("headless audio safe"); return 0;
    }
    if (argc>1 && !strcmp(argv[1],"--failure")) {
        assert(doom_platform_init()==-1); assert(strlen(doom_platform_error()));
        doom_platform_shutdown(); puts("video failure reported"); return 0;
    }
    assert(checked_call(doom_platform_init,0,0,0)==0);
    if (argc>1 && !strcmp(argv[1],"--muted")) {
        assert(!doom_platform_audio_available()); assert(strlen(doom_platform_error()));
        doom_sound(0,"DSTEST"); doom_music("D_TEST"); doom_audio_mix(pcm,64);
        assert(!audible(pcm,128)); doom_platform_shutdown(); puts("audio failure permits muted play"); return 0;
    }
    assert(doom_platform_audio_available());
    checked_call(doom_platform_capture,0,0,0);
    checked_call(doom_platform_capture,1,0,0);
    doom_platform_poll(&in);
    key(SDL_SCANCODE_W,1); key(SDL_SCANCODE_D,1); key(SDL_SCANCODE_LSHIFT,1);
    assert(!doom_platform_poll(&in)); assert(in.forward==8 && in.strafe==8 && (in.buttons&4));
    key(SDL_SCANCODE_W,0); key(SDL_SCANCODE_D,0); key(SDL_SCANCODE_LSHIFT,0);
    key(SDL_SCANCODE_3,1); assert(!doom_platform_poll(&in)); assert(in.weapon==3 && !in.forward);
    SDL_Event event={0}; event.type=SDL_EVENT_MOUSE_MOTION; event.motion.xrel=10;
    assert(SDL_PushEvent(&event)); event.type=SDL_EVENT_MOUSE_BUTTON_DOWN; event.button.button=1;
    assert(SDL_PushEvent(&event)); assert(!doom_platform_poll(&in)); assert(in.turn<0 && (in.buttons&2));
    event.type=SDL_EVENT_MOUSE_BUTTON_UP; assert(SDL_PushEvent(&event));
    assert(!doom_platform_poll(&in)); assert(!(in.buttons&2));
    key(SDL_SCANCODE_ESCAPE,1); assert(!doom_platform_poll(&in)); assert(in.menu==1);
    key(SDL_SCANCODE_F5,1); assert(!doom_platform_poll(&in)); assert(in.save==1);
    key(SDL_SCANCODE_F9,1); assert(!doom_platform_poll(&in)); assert(in.save==2);
    event.type=SDL_EVENT_WINDOW_FOCUS_LOST; assert(SDL_PushEvent(&event));
    assert(!doom_platform_poll(&in)); assert(doom_paused==1 && !in.forward && !(in.buttons&2));
    doom_paused=0;
    doom_sound(0,"DSTEST"); memset(pcm,0,sizeof(pcm)); doom_audio_mix(pcm,1024); assert(audible(pcm,2048));
    memset(pcm,0,sizeof(pcm)); doom_audio_mix(pcm,1024); assert(!audible(pcm,2048));
    doom_music("D_TEST"); memset(pcm,0,sizeof(pcm)); doom_audio_mix(pcm,1024); assert(audible(pcm,2048));
    doom_music(NULL); doom_audio_mix(pcm,1024); assert(!audible(pcm,2048));
    doom_music("D_BAD"); doom_audio_mix(pcm,1024); assert(!audible(pcm,2048));
    doom_music("D_MIDI"); doom_audio_mix(pcm,1024); assert(audible(pcm,2048));
    checked_call(doom_music,(uintptr_t)"D_MIDI",0,0);
    for(unsigned iteration=0;iteration<100;iteration++) {
        assert(checked_call(doom_platform_poll,(uintptr_t)&in,0,0)==0);
        doom_platform_sleep(2);
    }
    checked_call(doom_audio_mix,(uintptr_t)pcm,1024,0);
    doom_music(NULL);
    for(size_t length=0;length<sizeof(mus);length++) {
        extra=mus; extra_size=length; doom_music("D_EXTRA");
        doom_audio_mix(pcm,64); assert(!audible(pcm,128));
    }
    for(size_t length=0;length<14;length++) {
        extra=midi; extra_size=length; doom_music("D_EXTRA");
        doom_audio_mix(pcm,64); assert(!audible(pcm,128));
    }
    /* Hostile score bytes have a fixed seed and bounded input and output. */
    uint8_t fuzz[128]; uint32_t seed=0x91a54731;
    extra=fuzz; extra_size=sizeof(fuzz);
    for(unsigned sample=0;sample<1024;sample++) {
        for(unsigned i=0;i<sizeof(fuzz);i++) {
            seed^=seed<<13; seed^=seed>>17; seed^=seed<<5; fuzz[i]=seed;
        }
        memcpy(fuzz,mus,16); fuzz[4]=sizeof(fuzz)-16;
        doom_music("D_EXTRA"); doom_audio_mix(pcm,64);
    }
    doom_music(NULL);
    ds[4]=255; doom_sound(0,"DSTEST"); doom_audio_mix(pcm,64); assert(!audible(pcm,128)); ds[4]=64;
    ds[0]=2; doom_sound(0,"DSTEST"); doom_audio_mix(pcm,64); assert(!audible(pcm,128)); ds[0]=3;
    pcm[0]=1234; doom_audio_mix(pcm,4097); assert(pcm[0]==1234);
    doom_sound(0,"MISSING"); doom_audio_mix(pcm,1024); assert(!audible(pcm,2048));
    if (argc>2 && !strcmp(argv[1],"--music")) {
        FILE *file=fopen(argv[2],"rb"); assert(file);
        assert(!fseek(file,0,SEEK_END)); long bytes=ftell(file); assert(bytes>0 && bytes<=1024*1024);
        rewind(file); extra=malloc((size_t)bytes); extra_size=(size_t)bytes; assert(extra);
        assert(fread(extra,1,extra_size,file)==extra_size); fclose(file);
        checked_call(doom_music,(uintptr_t)"D_EXTRA",0,0); uint64_t energy=0;
        for(unsigned block=0;block<100;block++) {
            doom_audio_mix(pcm,1024);
            for(unsigned i=0;i<2048;i++) energy+=(uint64_t)abs(pcm[i]);
        }
        assert(energy>0);
        for(unsigned iteration=0;iteration<100;iteration++) {
            assert(checked_call(doom_platform_poll,(uintptr_t)&in,0,0)==0);
            doom_platform_sleep(2);
        }
        doom_music(NULL); free(extra); extra=NULL;
        printf("bundled music PCM energy: %llu\n",(unsigned long long)energy);
    }
    uint32_t *frame=malloc(320*200*4); assert(frame);
    for(unsigned i=0;i<320*200;i++) frame[i]=0xff000000 | ((i%320)*255/319<<16) | ((i/320)*255/199);
    uint64_t before=doom_platform_ticks(); doom_platform_sleep(2); assert(doom_platform_ticks()>=before);
    checked_call(doom_platform_present,(uintptr_t)frame,0,0); free(frame);
    event.type=SDL_EVENT_QUIT; assert(SDL_PushEvent(&event)); assert(doom_platform_poll(&in)==1);
    checked_call(doom_platform_shutdown,0,0,0); doom_platform_shutdown(); puts("platform input/audio/lifecycle passed");
    return 0;
}

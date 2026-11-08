/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include "kobo_fb.h"
#include "kobo_input.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static void stop_signal(int n) { (void)n; stopping = 1; }
static int64_t milliseconds(void)
{
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static unsigned get16(const unsigned char *p) { return ((unsigned)p[0] << 8) | p[1]; }
static uint32_t get32(const unsigned char *p)
{ return ((uint32_t)p[0]<<24) | ((uint32_t)p[1]<<16) | ((uint32_t)p[2]<<8) | p[3]; }
static void put16(unsigned char *p, unsigned v) { p[0]=(unsigned char)(v>>8); p[1]=(unsigned char)v; }
static void put32(unsigned char *p, uint32_t v)
{ p[0]=(unsigned char)(v>>24); p[1]=(unsigned char)(v>>16); p[2]=(unsigned char)(v>>8); p[3]=(unsigned char)v; }
static int transfer(int fd, void *data, size_t len, int writing, int64_t deadline)
{
    unsigned char *p = data;
    while (len && !stopping) {
        struct pollfd pollfd; int64_t left = deadline - milliseconds(); int rc; ssize_t n;
        if (left <= 0) { errno = ETIMEDOUT; return -1; }
        pollfd.fd = fd; pollfd.events = writing ? POLLOUT : POLLIN; pollfd.revents = 0;
        rc = poll(&pollfd, 1, (int)left);
        if (rc < 0 && errno == EINTR) continue;
        if (rc <= 0) { if (!rc) errno = ETIMEDOUT; return -1; }
        if (!(pollfd.revents & pollfd.events)) { errno = ECONNRESET; return -1; }
        n = writing ? send(fd, p, len, MSG_NOSIGNAL | MSG_DONTWAIT) : recv(fd, p, len, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n <= 0) { if (!n) errno = ECONNRESET; return -1; }
        p += n; len -= (size_t)n;
    }
    return len ? -1 : 0;
}
static int read_until(int fd, void *p, size_t n, int64_t deadline)
{ return transfer(fd, p, n, 0, deadline); }
static int write_until(int fd, const void *p, size_t n, int64_t deadline)
{ return transfer(fd, (void *)p, n, 1, deadline); }
struct format { unsigned bytes, depth, big, rm, gm, bm, rs, gs, bs; };
static void default_format(struct format *f)
{ f->bytes=2; f->depth=16; f->big=0; f->rm=31; f->gm=63; f->bm=31; f->rs=11; f->gs=5; f->bs=0; }
static int parse_format(const unsigned char *p, struct format *f)
{
    uint32_t rmask, gmask, bmask; unsigned rbits, gbits, bbits;
    if ((p[0] != 16 && p[0] != 24 && p[0] != 32) || p[2] > 1 || p[3] != 1) return -1;
    f->bytes=p[0]/8; f->depth=p[1]; f->big=p[2];
    f->rm=get16(p+4); f->gm=get16(p+6); f->bm=get16(p+8);
    f->rs=p[10]; f->gs=p[11]; f->bs=p[12];
    if (f->bytes==2) {
        if (f->depth!=16 || f->rm!=31 || f->gm!=63 || f->bm!=31) return -1;
        rbits=5; gbits=6; bbits=5;
    } else {
        if (f->depth!=24 || f->rm!=255 || f->gm!=255 || f->bm!=255) return -1;
        rbits=gbits=bbits=8;
    }
    if (f->rs+rbits>p[0] || f->gs+gbits>p[0] || f->bs+bbits>p[0]) return -1;
    rmask=(uint32_t)f->rm<<f->rs; gmask=(uint32_t)f->gm<<f->gs; bmask=(uint32_t)f->bm<<f->bs;
    return ((rmask & gmask) || (rmask & bmask) || (gmask & bmask)) ? -1 : 0;
}
static int handshake(int fd, unsigned w, unsigned h)
{
    unsigned char buf[64]; int64_t deadline=milliseconds()+5000;
    static const char version[]="RFB 003.008\n", name[]="Kobo Android framebuffer";
    if (write_until(fd, version, 12, deadline) || read_until(fd, buf, 12, deadline) || memcmp(buf,version,12)) return -1;
    buf[0]=1; buf[1]=1;
    if (write_until(fd,buf,2,deadline) || read_until(fd,buf,1,deadline) || buf[0]!=1) return -1;
    memset(buf,0,4);
    if (write_until(fd,buf,4,deadline) || read_until(fd,buf,1,deadline) || buf[0]>1) return -1;
    memset(buf,0,24); put16(buf,w); put16(buf+2,h);
    buf[4]=16; buf[5]=16; buf[7]=1; put16(buf+8,31); put16(buf+10,63); put16(buf+12,31);
    buf[14]=11; buf[15]=5; put32(buf+20,sizeof(name)-1);
    return write_until(fd,buf,24,deadline) || write_until(fd,name,sizeof(name)-1,deadline) ? -1 : 0;
}
struct request { unsigned x,y,w,h; int incremental,pending; };
static int message(int fd, struct format *fmt, struct request *q,
                   struct kobo_input *input, unsigned width, unsigned height, int *valid)
{
    unsigned char b[512], type; unsigned n,j; int64_t deadline=milliseconds()+5000;
    if (read_until(fd,&type,1,deadline)) return -1;
    switch(type) {
    case 0:
        if (read_until(fd,b,19,deadline) || parse_format(b+3,fmt)) return -1;
        *valid=0; return 0;
    case 2: {
        int raw=0;
        if (read_until(fd,b,3,deadline)) return -1;
        n=get16(b+1); if (n>128) return -1;
        for(j=0;j<n;++j) { if(read_until(fd,b,4,deadline))return -1; if(!get32(b))raw=1; }
        /* Raw encoding is universally supported by RFB, including an empty list. */
        (void)raw; return 0;
    }
    case 3:
        if (read_until(fd,b,9,deadline) || b[0]>1) return -1;
        q->incremental=b[0]; q->x=get16(b+1); q->y=get16(b+3); q->w=get16(b+5); q->h=get16(b+7);
        if(q->x>width || q->y>height || q->w>width-q->x || q->h>height-q->y) return -1;
        q->pending=1; return 0;
    case 4:
        if(read_until(fd,b,7,deadline) || b[0]>1)return -1;
        return kobo_input_key(input,get32(b+3),b[0]);
    case 5:
        if(read_until(fd,b,5,deadline))return -1;
        return kobo_input_pointer(input,b[0],get16(b+1),get16(b+3));
    case 6:
        if(read_until(fd,b,7,deadline))return -1;
        n=get32(b+3); if(n>65536)return -1;
        while(n) { unsigned chunk=n>sizeof(b)?sizeof(b):n;
            if(read_until(fd,b,chunk,deadline))return -1;
            n-=chunk;
        }
        return 0;
    default: return -1;
    }
}
/* Expand RGB565 to 8 bit per channel exactly like the old per-pixel code. */
static uint8_t expand5[32], expand6[64];
static void init_expand(void)
{
    unsigned i;
    for(i=0;i<32;++i) expand5[i]=(uint8_t)((i<<3)|(i>>2));
    for(i=0;i<64;++i) expand6[i]=(uint8_t)((i<<2)|(i>>4));
}
static void convert_row(unsigned char *out, const unsigned char *src, unsigned count, const struct format *f)
{
    unsigned x;
    /* Fast path 1: client wants the native RGB565 little-endian layout -> plain copy. */
    if(f->bytes==2 && !f->big && f->rs==11 && f->gs==5 && f->bs==0) { memcpy(out,src,(size_t)count*2); return; }
    /* Fast path 2: 32 bit true colour (what RFB clients normally ask for). One table
     * lookup per channel and one 32 bit store instead of a per-byte shuffle loop. */
    if(f->bytes==4) {
        uint32_t *o=(uint32_t *)(void *)out; /* out is 4 byte aligned: header is 16 bytes */
        for(x=0;x<count;++x) {
            uint32_t value=(uint32_t)src[0] | ((uint32_t)src[1]<<8);
            uint32_t px=((uint32_t)expand5[(value>>11)&31]<<f->rs) |
                        ((uint32_t)expand6[(value>>5)&63]<<f->gs) |
                        ((uint32_t)expand5[value&31]<<f->bs);
            o[x]=f->big ? __builtin_bswap32(px) : px;
            src+=2;
        }
        return;
    }
    for(x=0;x<count;++x) {
        uint32_t value=(uint32_t)src[0] | ((uint32_t)src[1]<<8), r=(value>>11)&31, g=(value>>5)&63, b=value&31;
        unsigned j;
        if(f->bytes!=2) { r=(r<<3)|(r>>2); g=(g<<2)|(g>>4); b=(b<<3)|(b>>2); }
        value=(r<<f->rs)|(g<<f->gs)|(b<<f->bs);
        for(j=0;j<f->bytes;++j) out[j]=(unsigned char)(value>>(8*(f->big?f->bytes-1-j:j)));
        src+=2; out+=f->bytes;
    }
}
/* Find the changed region of the request: first/last differing row and, inside it, the
 * narrowest 4-byte-aligned column span. Narrow rectangles mean fewer bytes on the socket
 * and, much more importantly, less dithering/refresh work in the KOReader client. */
static int diff_region(const unsigned char *page, const unsigned char *last, size_t stride,
                       const struct request *q, unsigned *first, unsigned *end,
                       unsigned *x0, unsigned *x1)
{
    unsigned y; size_t x_start=(size_t)q->x*2, x_end=((size_t)q->x+q->w)*2;
    size_t lo=x_end, hi=x_start; int any=0;
    for(y=q->y;y<q->y+q->h;++y) {
        const unsigned char *a=page+(size_t)y*stride, *b=last+(size_t)y*stride;
        size_t i=x_start, j=x_end;
        if(!memcmp(a+x_start,b+x_start,x_end-x_start)) continue;
        /* Row differs: trim equal 4-byte chunks from both ends (cheap, bounded by row). */
        while(i+4<=x_end && !memcmp(a+i,b+i,4)) i+=4;
        while(j>i+4 && !memcmp(a+j-4,b+j-4,4)) j-=4;
        if(!any) { *first=y; any=1; }
        *end=y+1;
        if(i<lo) lo=i;
        if(j>hi) hi=j;
    }
    if(!any) return 0;
    /* Round to whole pixels and clamp to the request. */
    *x0=(unsigned)(lo/2); *x1=(unsigned)((hi+1)/2);
    if(*x0<q->x) *x0=q->x;
    if(*x1>q->x+q->w) *x1=q->x+q->w;
    return 1;
}
/* out must hold 16 + width*height*4 bytes. All rows of one update leave in ONE send. */
static int update(int fd, struct kobo_fb *fb, const struct format *fmt, struct request *q,
                  unsigned char *last, int *valid, unsigned char *out)
{
    struct kobo_fb_meta m; unsigned y,first=q->y,end=q->y+q->h,x0=q->x,x1=q->x+q->w;
    unsigned stride=fb->meta->width*2; const unsigned char *page; int64_t deadline; size_t n;
    unsigned char *p;
    if(!q->pending)return 0;
    if(kobo_fb_snapshot(fb->meta,&m))return 0;
    if(m.magic!=KOBO_FB_MAGIC || m.abi_version!=KOBO_FB_ABI || m.width!=fb->meta->width ||
       m.height!=fb->meta->height || m.stride!=stride || m.yoffset>m.height) { errno=EINVAL; return -1; }
    page=fb->pixels+(size_t)m.yoffset*stride;
    if(q->w && q->h && q->incremental && *valid) {
        if(!diff_region(page,last,stride,q,&first,&end,&x0,&x1)) return 0; /* Defer; continue polling input. */
    }
    deadline=milliseconds()+5000;
    if(!q->w || !q->h) { unsigned char empty[4]; memset(empty,0,sizeof(empty)); q->pending=0; return write_until(fd,empty,4,deadline); }
    memset(out,0,16);
    put16(out+2,1); put16(out+4,x0); put16(out+6,first);
    put16(out+8,x1-x0); put16(out+10,end-first); /* encoding 0: raw */
    p=out+16;
    for(y=first;y<end;++y) {
        size_t off=(size_t)y*stride+(size_t)x0*2;
        /* Remember precisely what was transmitted, then convert from that snapshot. */
        memcpy(last+off,page+off,(size_t)(x1-x0)*2);
        convert_row(p,last+off,x1-x0,fmt);
        p+=(size_t)(x1-x0)*fmt->bytes;
    }
    n=(size_t)(p-out);
    if(write_until(fd,out,n,deadline))return -1;
    if(x0==0 && first==0 && x1==m.width && end==m.height)*valid=1;
    q->pending=0; return 0;
}
static void release_keys(struct kobo_input *i)
{
    unsigned code;
    if(i->touching) kobo_input_pointer(i,0,0,0);
    /* Disconnect must never leave a virtual key held in Android. */
    if(i->keyboard>=0) for(code=1;code<sizeof(i->keys);++code) if(i->keys[code]) {
        struct input_event e; memset(&e,0,sizeof(e)); e.type=EV_KEY; e.code=(unsigned short)code;
        ssize_t sent = write(i->keyboard,&e,sizeof(e));
        if (sent != (ssize_t)sizeof(e)) break;
        e.type=EV_SYN; e.code=SYN_REPORT;
        sent = write(i->keyboard,&e,sizeof(e));
        if (sent != (ssize_t)sizeof(e)) break;
        i->keys[code]=0;
    }
}
/* A frame is only compared when Android flipped a page (frame_counter/yoffset moved).
 * Direct mmap writes do not change the counter, so a cheap safety compare still runs
 * every SAFETY_MS. Before this, the whole 960 KB frame was memcmp'ed up to 1000 times
 * per second, which stole CPU from SurfaceFlinger and capped Android's own frame rate. */
#define SAFETY_MS 10
/* Ohne Seitenwechsel seit IDLE_MS wird nur noch selten verglichen und langsamer gepollt: im Leerlauf
 * (E-Ink zeigt meist ein stehendes Bild) soll kobo-vnc Android keine CPU wegnehmen. */
#define IDLE_MS 400
#define IDLE_SAFETY_MS 80
#define IDLE_POLL_MS 12
static int serve_client(int fd,struct kobo_fb *fb,struct kobo_input *input)
{
    struct format fmt; struct request q; unsigned char *last,*out; int valid=0,rc=-1;
    uint32_t seen_counter=0,seen_yoffset=0; int64_t last_diff=0,last_moved=0; int have_seen=0;
    size_t out_bytes=16+(size_t)fb->meta->width*fb->meta->height*4;
    default_format(&fmt); memset(&q,0,sizeof(q));
    if(handshake(fd,fb->meta->width,fb->meta->height))return -1;
    last=calloc(1,fb->bytes/2); out=malloc(out_bytes);
    if(!last || !out) { free(last); free(out); return -1; }
    { int sb=1<<20; setsockopt(fd,SOL_SOCKET,SO_SNDBUF,&sb,sizeof(sb)); }
    while(!stopping) {
        struct pollfd p; int n; p.fd=fd; p.events=POLLIN; p.revents=0;
        /* Pending request: wake up every 2 ms to notice a page flip. Idle: sleep longer. */
        n=poll(&p,1,q.pending?(milliseconds()-last_moved>IDLE_MS?IDLE_POLL_MS:2):20);
        if(n<0) { if(errno==EINTR)continue; break; }
        if(n>0) {
            if(!(p.revents&POLLIN))break;
            if(message(fd,&fmt,&q,input,fb->meta->width,fb->meta->height,&valid))break;
        }
        if(q.pending) {
            struct kobo_fb_meta m; int64_t now=milliseconds(); int run=1;
            if(q.incremental && valid && !kobo_fb_snapshot(fb->meta,&m)) {
                int moved=!have_seen || m.frame_counter!=seen_counter || m.yoffset!=seen_yoffset;
                if(moved) { seen_counter=m.frame_counter; seen_yoffset=m.yoffset; have_seen=1; last_moved=now; }
                run=moved || now-last_diff>=(now-last_moved>IDLE_MS?IDLE_SAFETY_MS:SAFETY_MS);
            }
            if(run) { last_diff=now; if(update(fd,fb,&fmt,&q,last,&valid,out))break; }
        }
    }
    free(last); free(out); release_keys(input); return rc;
}
static void usage(FILE *f)
{
    fprintf(f,"Usage: kobo-vnc --shared DIR --input-dir DIR [--port 5963] [--width N --height N]\n"
        "       kobo-vnc --check\n"
        "       kobo-vnc --shared DIR --no-input [--port N] [--width N --height N]\n"
        "RFB 3.8 raw RGB565/RGB888, one client, IPv4 127.0.0.1 ONLY. No authentication;\n"
        "use an SSH tunnel and trust local processes. --no-input is explicit off-device\n"
        "testing only, never an automatic fallback. Dimensions default to 600x800 or\n"
        "KOBO_FB_WIDTH/KOBO_FB_HEIGHT (1..4096). Existing shared dimensions must match.\n"
        "--check probes Binder protocol 7/8, ashmem size, uinput creation and namespaces.\n"
        "Probe paths: KOBO_BINDER_DEVICE and KOBO_ASHMEM_DEVICE.\n");
}
static int number(const char *s,unsigned max,unsigned *out)
{
    char *end; unsigned long v; errno=0; v=strtoul(s,&end,10);
    if(errno || !*s || *end || !v || v>max)return -1;
    *out=(unsigned)v; return 0;
}
int main(int argc,char **argv)
{
    const char *dir=NULL,*input_dir=NULL; uint32_t w,h; unsigned port=5963; int no_input=0,check=0;
    int i,listener=-1,result=1; struct kobo_fb fb; struct kobo_input input; struct sockaddr_in address;
    memset(&fb,0,sizeof(fb)); fb.pixels_fd=fb.meta_fd=-1;
    memset(&input,0,sizeof(input)); input.touch=input.keyboard=-1;
    if(kobo_fb_dimensions(&w,&h)) { fprintf(stderr,"invalid KOBO_FB_WIDTH/HEIGHT\n"); return 2; }
    for(i=1;i<argc;++i) {
        if(!strcmp(argv[i],"--help")) { usage(stdout); return 0; }
        else if(!strcmp(argv[i],"--check"))check=1;
        else if(!strcmp(argv[i],"--no-input"))no_input=1;
        else if(i+1<argc && !strcmp(argv[i],"--shared"))dir=argv[++i];
        else if(i+1<argc && !strcmp(argv[i],"--input-dir"))input_dir=argv[++i];
        else if(i+1<argc && !strcmp(argv[i],"--port")) { if(number(argv[++i],65535,&port))goto bad; }
        else if(i+1<argc && !strcmp(argv[i],"--width")) { if(number(argv[++i],KOBO_FB_MAX_DIM,&w))goto bad; }
        else if(i+1<argc && !strcmp(argv[i],"--height")) { if(number(argv[++i],KOBO_FB_MAX_DIM,&h))goto bad; }
        else goto bad;
    }
    if(check) { if(no_input)goto bad; return kobo_probe(); }
    if(!dir || (!no_input && !input_dir) || (no_input && input_dir))goto bad;
    init_expand();
    signal(SIGINT,stop_signal); signal(SIGTERM,stop_signal); signal(SIGPIPE,SIG_IGN);
    if(mkdir(dir,0755)<0 && errno!=EEXIST) { perror("shared directory"); goto done; }
    if(kobo_fb_create(dir,w,h,&fb)) { perror("framebuffer initialization"); goto done; }
    /* Launcher runs as root; SF (system:graphics) must be able to open both files. */
    if(geteuid()==0 && (fchown(fb.pixels_fd,1000,1003)<0 || fchown(fb.meta_fd,1000,1003)<0)) {
        perror("framebuffer ownership"); goto done;
    }
    if(fchmod(fb.pixels_fd,0660)<0 || fchmod(fb.meta_fd,0660)<0) { perror("framebuffer permissions"); goto done; }
    if(!no_input && kobo_input_create(&input,input_dir,w,h)) { perror("private uinput creation/discovery"); goto done; }
    listener=socket(AF_INET,SOCK_STREAM,0);
    if(listener<0) { perror("socket"); goto done; }
    { int one=1; setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one)); }
    fcntl(listener,F_SETFD,FD_CLOEXEC);
    memset(&address,0,sizeof(address)); address.sin_family=AF_INET; address.sin_port=htons((uint16_t)port);
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(bind(listener,(struct sockaddr *)&address,sizeof(address))<0 || listen(listener,1)<0) { perror("loopback listener"); goto done; }
    fprintf(stderr,"kobo-vnc: 127.0.0.1:%u, %ux%u RGB565 double buffer%s\n",port,w,h,no_input?" (input disabled explicitly)":"");
    result=0;
    while(!stopping) {
        struct pollfd p; int n,client,one=1; struct sockaddr_in peer; socklen_t plen=sizeof(peer);
        p.fd=listener; p.events=POLLIN; p.revents=0; n=poll(&p,1,500);
        if(n<0 && errno==EINTR)continue;
        if(n<0) { perror("listener poll"); result=1; break; }
        if(!n)continue;
        if(!(p.revents&POLLIN)) { result=1; break; }
        client=accept(listener,(struct sockaddr *)&peer,&plen);
        if(client<0) { if(errno==EINTR)continue; perror("accept"); continue; }
        if(peer.sin_addr.s_addr!=htonl(INADDR_LOOPBACK)) { close(client); continue; }
        fcntl(client,F_SETFD,FD_CLOEXEC); setsockopt(client,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
        { struct timeval timeout; timeout.tv_sec=5; timeout.tv_usec=0;
          setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
          setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout)); }
        (void)serve_client(client,&fb,&input); close(client);
    }
done:
    if(listener>=0)close(listener);
    kobo_input_destroy(&input); kobo_fb_release(&fb); return result;
bad:
    usage(stderr); return 2;
}

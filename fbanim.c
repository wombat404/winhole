/* fbanim: plays raw frames centered on /dev/fb0.
 * frames file: argv[1], default /anim/frames.bin.
 * exits cleanly if /dev/fb0 is missing (headless).
 * build static: gcc -static -O2 fbanim.c -o fbanim
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/fb.h>

static volatile sig_atomic_t running = 1;
static void on_term(int s) { (void)s; running = 0; }

int main(int argc, char **argv)
{
    signal(SIGTERM, on_term);
    signal(SIGINT,  on_term);

    const char *path = (argc > 1 && argv[1][0]) ? argv[1] : "/anim/frames.bin";

    FILE *fp = fopen(path, "rb");
    if (!fp) return 0;
    uint32_t hdr[3];
    if (fread(hdr, sizeof(uint32_t), 3, fp) != 3) { fclose(fp); return 0; }
    uint32_t W = hdr[0], H = hdr[1], N = hdr[2];
    if (!W || !H || !N) { fclose(fp); return 0; }
    size_t fsz = (size_t)W * H * 4;
    unsigned char *frames = malloc(fsz * N);
    if (!frames) { fclose(fp); return 0; }
    if (fread(frames, fsz, N, fp) != N) { free(frames); fclose(fp); return 0; }
    fclose(fp);

    int fd = open("/dev/fb0", O_RDWR);
    if (fd < 0) { free(frames); return 0; }

    struct fb_var_screeninfo vi;
    struct fb_fix_screeninfo fi;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &vi) < 0 ||
        ioctl(fd, FBIOGET_FSCREENINFO, &fi) < 0) {
        close(fd); free(frames); return 0;
    }
    int bpp = vi.bits_per_pixel;
    int Bpp = bpp / 8;
    size_t maplen = (size_t)fi.line_length * vi.yres_virtual;
    unsigned char *fb = mmap(NULL, maplen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (fb == MAP_FAILED) { close(fd); free(frames); return 0; }

    int ox = ((int)vi.xres - (int)W) / 2;
    int oy = ((int)vi.yres - (int)H) / 2;
    struct timespec ts = { 0, 80 * 1000 * 1000 }; /* ~12.5 fps */

    while (running) {
        for (uint32_t fr = 0; fr < N && running; fr++) {
            unsigned char *src = frames + (size_t)fr * fsz;
            for (uint32_t y = 0; y < H; y++) {
                int sy = oy + (int)y;
                if (sy < 0 || sy >= (int)vi.yres) continue;
                unsigned char *row = fb + (size_t)sy * fi.line_length;
                unsigned char *s = src + (size_t)y * W * 4;
                for (uint32_t x = 0; x < W; x++) {
                    int sx = ox + (int)x;
                    if (sx < 0 || sx >= (int)vi.xres) continue;
                    unsigned char r = s[x*4+0], g = s[x*4+1], b = s[x*4+2];
                    uint32_t val =
                        ((uint32_t)(r >> (8 - vi.red.length))   << vi.red.offset)   |
                        ((uint32_t)(g >> (8 - vi.green.length)) << vi.green.offset) |
                        ((uint32_t)(b >> (8 - vi.blue.length))  << vi.blue.offset);
                    unsigned char *px = row + (size_t)sx * Bpp;
                    for (int k = 0; k < Bpp; k++) px[k] = (val >> (k * 8)) & 0xff;
                }
            }
            nanosleep(&ts, NULL);
        }
    }
    /* clear only the animation rect, leave the rest of the VT text intact */
    for (uint32_t y = 0; y < H; y++) {
        int sy = oy + (int)y;
        if (sy < 0 || sy >= (int)vi.yres) continue;
        unsigned char *row = fb + (size_t)sy * fi.line_length;
        for (uint32_t x = 0; x < W; x++) {
            int sx = ox + (int)x;
            if (sx < 0 || sx >= (int)vi.xres) continue;
            unsigned char *px = row + (size_t)sx * Bpp;
            for (int k = 0; k < Bpp; k++) px[k] = 0;
        }
    }
    munmap(fb, maplen);
    close(fd);
    free(frames);
    return 0;
}

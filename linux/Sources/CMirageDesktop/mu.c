// Virtual input devices (uinput): a keyboard and an absolute pointer with a wheel, as a VM's tablet is. Every compositor
// and the login screen take them like plugged-in hardware. Needs root (/dev/uinput).
#include "md.h"

#include <fcntl.h>
#include <linux/uinput.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

struct mu_input {
    int kbd, ptr;
    pthread_mutex_t lock;
    int acc_v, acc_h;   // high-resolution wheel left over below one click
};

static void emit(int fd, int type, int code, int value) {
    struct input_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = type; ev.code = code; ev.value = value;
    ssize_t n = write(fd, &ev, sizeof ev);
    (void)n;
}
static void syn(int fd) { emit(fd, EV_SYN, SYN_REPORT, 0); }

static int create(int fd, const char *name, char *err, size_t err_len) {
    struct uinput_setup us;
    memset(&us, 0, sizeof us);
    us.id.bustype = BUS_VIRTUAL; us.id.vendor = 0x1209; us.id.product = 0x4d52; us.id.version = 1;
    snprintf(us.name, sizeof us.name, "%s", name);
    if (ioctl(fd, UI_DEV_SETUP, &us) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) { snprintf(err, err_len, "cannot create %s", name); return -1; }
    return 0;
}

mu_input *mu_input_open(char *err, size_t err_len) {
    int kbd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    int ptr = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (kbd < 0 || ptr < 0) {
        snprintf(err, err_len, "cannot open /dev/uinput (needs root and the uinput module)");
        if (kbd >= 0) close(kbd);
        if (ptr >= 0) close(ptr);
        return NULL;
    }
    ioctl(kbd, UI_SET_EVBIT, EV_KEY);
    ioctl(kbd, UI_SET_EVBIT, EV_SYN);
    for (int k = 1; k < 256; k++) ioctl(kbd, UI_SET_KEYBIT, k);

    ioctl(ptr, UI_SET_EVBIT, EV_KEY);
    ioctl(ptr, UI_SET_EVBIT, EV_SYN);
    ioctl(ptr, UI_SET_EVBIT, EV_ABS);
    ioctl(ptr, UI_SET_EVBIT, EV_REL);
    int buttons[] = { BTN_LEFT, BTN_RIGHT, BTN_MIDDLE, BTN_SIDE, BTN_EXTRA };
    for (size_t i = 0; i < sizeof buttons / sizeof *buttons; i++) ioctl(ptr, UI_SET_KEYBIT, buttons[i]);
    int rels[] = { REL_WHEEL, REL_HWHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES };
    for (size_t i = 0; i < sizeof rels / sizeof *rels; i++) ioctl(ptr, UI_SET_RELBIT, rels[i]);
    struct uinput_abs_setup ax = { .code = ABS_X, .absinfo = { .minimum = 0, .maximum = 65535 } };
    struct uinput_abs_setup ay = { .code = ABS_Y, .absinfo = { .minimum = 0, .maximum = 65535 } };
    ioctl(ptr, UI_ABS_SETUP, &ax);
    ioctl(ptr, UI_ABS_SETUP, &ay);

    if (create(kbd, "Mirage Keyboard", err, err_len) < 0 || create(ptr, "Mirage Pointer", err, err_len) < 0) {
        close(kbd); close(ptr); return NULL;
    }
    mu_input *u = calloc(1, sizeof *u);
    u->kbd = kbd; u->ptr = ptr;
    pthread_mutex_init(&u->lock, NULL);
    return u;
}

void mu_pointer_move(mu_input *u, double x, double y) {
    if (x < 0) x = 0; if (x > 1) x = 1;
    if (y < 0) y = 0; if (y > 1) y = 1;
    pthread_mutex_lock(&u->lock);
    emit(u->ptr, EV_ABS, ABS_X, (int)(x * 65535 + 0.5));
    emit(u->ptr, EV_ABS, ABS_Y, (int)(y * 65535 + 0.5));
    syn(u->ptr);
    pthread_mutex_unlock(&u->lock);
}

void mu_pointer_button(mu_input *u, int evdev_button, int pressed) {
    pthread_mutex_lock(&u->lock);
    emit(u->ptr, EV_KEY, evdev_button, pressed ? 1 : 0);
    syn(u->ptr);
    pthread_mutex_unlock(&u->lock);
}

void mu_wheel(mu_input *u, int v120, int h120) {
    pthread_mutex_lock(&u->lock);
    // evdev: REL_WHEEL positive scrolls up, REL_HWHEEL positive scrolls right; md.h's convention is down/right positive.
    if (v120) {
        emit(u->ptr, EV_REL, REL_WHEEL_HI_RES, -v120);
        u->acc_v += -v120;
        while (u->acc_v >= 120) { emit(u->ptr, EV_REL, REL_WHEEL, 1); u->acc_v -= 120; }
        while (u->acc_v <= -120) { emit(u->ptr, EV_REL, REL_WHEEL, -1); u->acc_v += 120; }
    }
    if (h120) {
        emit(u->ptr, EV_REL, REL_HWHEEL_HI_RES, h120);
        u->acc_h += h120;
        while (u->acc_h >= 120) { emit(u->ptr, EV_REL, REL_HWHEEL, 1); u->acc_h -= 120; }
        while (u->acc_h <= -120) { emit(u->ptr, EV_REL, REL_HWHEEL, -1); u->acc_h += 120; }
    }
    syn(u->ptr);
    pthread_mutex_unlock(&u->lock);
}

void mu_key(mu_input *u, uint32_t evdev_key, int pressed) {
    pthread_mutex_lock(&u->lock);
    emit(u->kbd, EV_KEY, (int)evdev_key, pressed ? 1 : 0);
    syn(u->kbd);
    pthread_mutex_unlock(&u->lock);
}

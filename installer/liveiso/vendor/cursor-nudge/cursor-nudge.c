/*
 * june-cursor-nudge - make wlroots/cage render the pointer cursor.
 *
 * cage does not expose the wlr virtual-pointer protocol, so a Wayland client
 * cannot wake the cursor.  wlroots only attaches/draws the cursor after it
 * sees a pointer-device event, which is why unplugging/replugging the mouse
 * fixes it.  This helper creates a tiny uinput mouse, emits one relative
 * move, and stays alive so the virtual pointer (and therefore the cursor
 * image) remains attached for the whole session.
 *
 * Runs as root (needs /dev/uinput).  Exits on SIGTERM/SIGINT, which destroys
 * the uinput device automatically when the fd closes.
 */
#include <fcntl.h>
#include <linux/uinput.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static int uinput_fd = -1;

static void cleanup(int sig)
{
    (void)sig;
    if (uinput_fd >= 0) {
        ioctl(uinput_fd, UI_DEV_DESTROY);
        close(uinput_fd);
    }
    _exit(0);
}

static int open_uinput(void)
{
    int fd, i;

    for (i = 0; i < 30; i++) {
        fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
        if (fd >= 0)
            return fd;
        usleep(100000);
    }
    return -1;
}

int main(void)
{
    struct uinput_setup setup;
    struct input_event ev;

    signal(SIGTERM, cleanup);
    signal(SIGINT, cleanup);

    uinput_fd = open_uinput();
    if (uinput_fd < 0) {
        perror("open /dev/uinput");
        return 1;
    }

    ioctl(uinput_fd, UI_SET_EVBIT, EV_REL);
    ioctl(uinput_fd, UI_SET_RELBIT, REL_X);
    ioctl(uinput_fd, UI_SET_RELBIT, REL_Y);
    ioctl(uinput_fd, UI_SET_EVBIT, EV_KEY);
    ioctl(uinput_fd, UI_SET_KEYBIT, BTN_LEFT);

    memset(&setup, 0, sizeof(setup));
    setup.id.bustype = BUS_USB;
    setup.id.vendor = 0x1d6b;
    setup.id.product = 0x0104;
    snprintf(setup.name, sizeof(setup.name), "June installer cursor");

    if (ioctl(uinput_fd, UI_DEV_SETUP, &setup) < 0 ||
        ioctl(uinput_fd, UI_DEV_CREATE) < 0) {
        perror("create uinput device");
        return 1;
    }

    usleep(300000);
    memset(&ev, 0, sizeof(ev));
    ev.type = EV_REL;
    ev.code = REL_X;
    ev.value = 1;
    write(uinput_fd, &ev, sizeof(ev));
    memset(&ev, 0, sizeof(ev));
    ev.type = EV_REL;
    ev.code = REL_Y;
    ev.value = 1;
    write(uinput_fd, &ev, sizeof(ev));
    memset(&ev, 0, sizeof(ev));
    ev.type = EV_SYN;
    ev.code = SYN_REPORT;
    write(uinput_fd, &ev, sizeof(ev));

    for (;;)
        pause();

    return 0;
}

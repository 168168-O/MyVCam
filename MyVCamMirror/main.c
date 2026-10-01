/*
 * Copy /var/mobile/Documents/MyVCam/test.mp4 into the rootless prefix.
 *
 * Runs as root from launchd (and once from postinst). It is not injected
 * into Camera. Camera can read /var/jb and cannot read Documents.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <syslog.h>
#include <unistd.h>

static const char kSourceVideo[] = "/var/mobile/Documents/MyVCam/test.mp4";
static const char kSourceDisable[] = "/var/mobile/Documents/MyVCam/disable";
static const char kDestDir[] = "/var/jb/var/mobile/Library/MyVCam";
static const char kDestVideo[] = "/var/jb/var/mobile/Library/MyVCam/test.mp4";
static const char kDestVideoTemp[] = "/var/jb/var/mobile/Library/MyVCam/test.mp4.tmp";
static const char kDestDisable[] = "/var/jb/var/mobile/Library/MyVCam/disable";

static void mkdir_parents(const char *dir) {
    char tmp[512];
    size_t length = 0;

    if (dir == NULL) {
        return;
    }
    length = strlen(dir);
    if (length == 0 || length >= sizeof(tmp)) {
        return;
    }
    memcpy(tmp, dir, length + 1);
    for (size_t index = 1; index < length; index++) {
        if (tmp[index] != '/') {
            continue;
        }
        tmp[index] = '\0';
        if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
            syslog(LOG_NOTICE, "[MyVCam mirror] mkdir %s failed errno=%d", tmp, errno);
        }
        tmp[index] = '/';
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
        syslog(LOG_NOTICE, "[MyVCam mirror] mkdir %s failed errno=%d", tmp, errno);
    }
}

static int copy_file(const char *source, const char *destination, const char *temporary) {
    int input = -1;
    int output = -1;
    char buffer[1 << 16];
    ssize_t count = 0;
    int result = -1;

    input = open(source, O_RDONLY);
    if (input < 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] open %s failed errno=%d", source, errno);
        return -1;
    }
    output = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (output < 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] open %s failed errno=%d", temporary, errno);
        close(input);
        return -1;
    }

    while ((count = read(input, buffer, sizeof(buffer))) > 0) {
        ssize_t written = 0;
        while (written < count) {
            ssize_t step = write(output, buffer + written, (size_t)(count - written));
            if (step < 0) {
                if (errno == EINTR) {
                    continue;
                }
                syslog(LOG_NOTICE, "[MyVCam mirror] write failed errno=%d", errno);
                goto done;
            }
            written += step;
        }
    }
    if (count < 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] read failed errno=%d", errno);
        goto done;
    }
    if (fsync(output) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] fsync failed errno=%d", errno);
        goto done;
    }
    if (rename(temporary, destination) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] rename failed errno=%d", errno);
        goto done;
    }
    if (chmod(destination, 0644) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] chmod failed errno=%d", errno);
    }
    syslog(LOG_NOTICE, "[MyVCam mirror] copied %s", destination);
    result = 0;

done:
    if (result != 0) {
        unlink(temporary);
    }
    close(output);
    close(input);
    return result;
}

static int regular_file(const char *path) {
    struct stat info;
    if (path == NULL || lstat(path, &info) != 0) {
        return 0;
    }
    return S_ISREG(info.st_mode);
}

int main(void) {
    openlog("myvcam-mirror", LOG_PID, LOG_USER);
    mkdir_parents(kDestDir);

    if (regular_file(kSourceDisable)) {
        int marker = open(kDestDisable, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (marker >= 0) {
            close(marker);
            syslog(LOG_NOTICE, "[MyVCam mirror] disable marker written");
        } else {
            syslog(LOG_NOTICE, "[MyVCam mirror] disable marker failed errno=%d", errno);
        }
    } else {
        unlink(kDestDisable);
    }

    if (!regular_file(kSourceVideo)) {
        unlink(kDestVideo);
        unlink(kDestVideoTemp);
        syslog(LOG_NOTICE, "[MyVCam mirror] no regular file at %s", kSourceVideo);
        closelog();
        return 0;
    }

    if (copy_file(kSourceVideo, kDestVideo, kDestVideoTemp) != 0) {
        unlink(kDestVideo);
        unlink(kDestVideoTemp);
    }
    closelog();
    return 0;
}

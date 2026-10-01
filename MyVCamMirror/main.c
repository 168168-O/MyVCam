/*
 * Copy /var/mobile/Documents/MyVCam/test.mp4 to paths Camera can open.
 *
 * Runs as root from launchd (KeepAlive --watch) and once from postinst.
 * It is not injected into Camera. A sandboxed run cannot see Documents;
 * that case must not delete a mirror a root run already wrote.
 *
 * Two destinations:
 *   /var/jb/var/mobile/Library/MyVCam/test.mp4
 *   <com.apple.camera data container>/Library/MyVCam/test.mp4
 * The container path does not need Dopamine's /var/jb sandbox extension.
 * mirror.status in both directories records euid, mode, and errno.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <syslog.h>
#include <unistd.h>

static const char kSourceVideo[] = "/var/mobile/Documents/MyVCam/test.mp4";
static const char kSourceDisable[] = "/var/mobile/Documents/MyVCam/disable";
static const char kDestDir[] = "/var/jb/var/mobile/Library/MyVCam";
static const char kDestVideo[] = "/var/jb/var/mobile/Library/MyVCam/test.mp4";
static const char kDestVideoTemp[] = "/var/jb/var/mobile/Library/MyVCam/test.mp4.tmp";
static const char kDestDisable[] = "/var/jb/var/mobile/Library/MyVCam/disable";
static const char kLockPath[] = "/var/jb/var/mobile/Library/MyVCam/mirror.lock";
static const char kContainerRecord[] = "/var/jb/var/mobile/Library/MyVCam/container.path";
static const char kCameraIdentifier[] = "com.apple.camera";
static const char kMetadataName[] = ".com.apple.mobile_container_manager.metadata.plist";

static char gContainerDir[PATH_MAX];
static char gContainerVideo[PATH_MAX];
static char gContainerVideoTemp[PATH_MAX];
static char gContainerDisable[PATH_MAX];
static int gContainerReady = 0;
static time_t gCopiedMtime = 0;
static off_t gCopiedSize = -1;

static void mkdir_parents(const char *dir) {
    char tmp[PATH_MAX];
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

static void owner_ids(uid_t *uidOut, gid_t *gidOut) {
    struct stat info;
    uid_t uid = 501;
    gid_t gid = 501;

    if (stat("/var/mobile", &info) == 0) {
        uid = info.st_uid;
        gid = info.st_gid;
    }
    if (uidOut != NULL) {
        *uidOut = uid;
    }
    if (gidOut != NULL) {
        *gidOut = gid;
    }
}

static void publish_mode(const char *path, uid_t uid, gid_t gid) {
    if (path == NULL) {
        return;
    }
    if (chmod(path, 0644) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] chmod %s failed errno=%d", path, errno);
    }
    if (chown(path, uid, gid) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] chown %s failed errno=%d", path, errno);
    }
}

static int copy_file(const char *source, const char *destination, const char *temporary, uid_t uid, gid_t gid) {
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
    if (fchmod(output, 0644) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] fchmod failed errno=%d", errno);
    }
    if (fchown(output, uid, gid) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] fchown failed errno=%d", errno);
    }
    if (rename(temporary, destination) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] rename failed errno=%d", errno);
        goto done;
    }
    publish_mode(destination, uid, gid);
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

static int identifier_is_camera(const char *buffer, size_t length) {
    const char *needle = kCameraIdentifier;
    size_t needleLength = strlen(needle);

    if (buffer == NULL || length < needleLength) {
        return 0;
    }
    for (size_t index = 0; index + needleLength <= length; index++) {
        char previous = 0;
        char next = 0;
        if (memcmp(buffer + index, needle, needleLength) != 0) {
            continue;
        }
        previous = index > 0 ? buffer[index - 1] : '\0';
        next = (index + needleLength) < length ? buffer[index + needleLength] : '\0';
        if ((previous >= 'A' && previous <= 'Z') ||
            (previous >= 'a' && previous <= 'z') ||
            (previous >= '0' && previous <= '9') ||
            previous == '.' || previous == '-' || previous == '_') {
            continue;
        }
        if ((next >= 'A' && next <= 'Z') ||
            (next >= 'a' && next <= 'z') ||
            (next >= '0' && next <= '9') ||
            next == '.' || next == '-' || next == '_') {
            continue;
        }
        return 1;
    }
    return 0;
}

static int plist_is_camera(const char *path) {
    int fd = -1;
    char buffer[4096];
    char *stored = NULL;
    size_t used = 0;
    size_t capacity = 0;
    int matched = 0;
    ssize_t count = 0;

    fd = open(path, O_RDONLY);
    if (fd < 0) {
        return 0;
    }
    while ((count = read(fd, buffer, sizeof(buffer))) > 0) {
        if (used + (size_t)count > (256u * 1024u)) {
            break;
        }
        if (used + (size_t)count + 1 > capacity) {
            size_t grown = capacity == 0 ? 8192u : capacity * 2u;
            char *next = NULL;
            while (grown < used + (size_t)count + 1) {
                grown *= 2u;
            }
            next = realloc(stored, grown);
            if (next == NULL) {
                break;
            }
            stored = next;
            capacity = grown;
        }
        memcpy(stored + used, buffer, (size_t)count);
        used += (size_t)count;
    }
    close(fd);
    if (stored != NULL) {
        stored[used] = '\0';
        matched = identifier_is_camera(stored, used);
        free(stored);
    }
    return matched;
}

static int remember_container(const char *dir) {
    int video = 0;
    int temp = 0;
    int disable = 0;

    if (dir == NULL || dir[0] != '/') {
        return 0;
    }
    video = snprintf(gContainerVideo, sizeof(gContainerVideo), "%s/Library/MyVCam/test.mp4", dir);
    temp = snprintf(gContainerVideoTemp, sizeof(gContainerVideoTemp), "%s/Library/MyVCam/test.mp4.tmp", dir);
    disable = snprintf(gContainerDisable, sizeof(gContainerDisable), "%s/Library/MyVCam/disable", dir);
    if (video <= 0 || temp <= 0 || disable <= 0 ||
        (size_t)video >= sizeof(gContainerVideo) ||
        (size_t)temp >= sizeof(gContainerVideoTemp) ||
        (size_t)disable >= sizeof(gContainerDisable)) {
        gContainerReady = 0;
        return 0;
    }
    snprintf(gContainerDir, sizeof(gContainerDir), "%s/Library/MyVCam", dir);
    gContainerReady = 1;
    return 1;
}

static void find_camera_container(void) {
    static const char *roots[] = {
        "/var/containers/Data/System",
        "/private/var/containers/Data/System",
        "/var/mobile/Containers/Data/System",
    };
    static int loggedMissing = 0;
    char metadata[PATH_MAX];

    if (gContainerReady) {
        return;
    }

    for (size_t rootIndex = 0; rootIndex < sizeof(roots) / sizeof(roots[0]); rootIndex++) {
        DIR *directory = opendir(roots[rootIndex]);
        struct dirent *entry = NULL;
        if (directory == NULL) {
            continue;
        }
        while ((entry = readdir(directory)) != NULL) {
            int wrote = 0;
            if (entry->d_name[0] == '.') {
                continue;
            }
            wrote = snprintf(metadata, sizeof(metadata), "%s/%s/%s",
                             roots[rootIndex], entry->d_name, kMetadataName);
            if (wrote <= 0 || (size_t)wrote >= sizeof(metadata)) {
                continue;
            }
            if (!plist_is_camera(metadata)) {
                continue;
            }
            wrote = snprintf(metadata, sizeof(metadata), "%s/%s", roots[rootIndex], entry->d_name);
            if (wrote > 0 && (size_t)wrote < sizeof(metadata) && remember_container(metadata)) {
                syslog(LOG_NOTICE, "[MyVCam mirror] camera container %s", gContainerDir);
                closedir(directory);
                return;
            }
        }
        closedir(directory);
    }
    if (!loggedMissing) {
        loggedMissing = 1;
        syslog(LOG_NOTICE, "[MyVCam mirror] camera container not found");
    }
}

static void write_text_file(const char *path, const char *text, uid_t uid, gid_t gid) {
    int fd = -1;
    size_t length = 0;
    ssize_t written = 0;

    if (path == NULL || text == NULL) {
        return;
    }
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] status open %s failed errno=%d", path, errno);
        return;
    }
    length = strlen(text);
    while ((size_t)written < length) {
        ssize_t step = write(fd, text + written, length - (size_t)written);
        if (step < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        written += step;
    }
    if (fchmod(fd, 0644) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] status chmod failed errno=%d", errno);
    }
    if (fchown(fd, uid, gid) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] status chown failed errno=%d", errno);
    }
    close(fd);
}

static int mode_of(const char *path) {
    struct stat info;
    if (path == NULL || stat(path, &info) != 0) {
        return 0;
    }
    return (int)info.st_mode;
}

static void write_status(uid_t uid,
                         gid_t gid,
                         int copied,
                         off_t bytes,
                         int sourceErrno,
                         int copyErrno) {
    char line[PATH_MAX * 2];
    int wrote = 0;
    const char *container = gContainerReady ? gContainerVideo : "-";
    int mode = mode_of(kDestVideo);
    static char previous[PATH_MAX * 2];

    wrote = snprintf(line, sizeof(line),
                     "euid=%d uid=%d copied=%d bytes=%lld mode=%o source_errno=%d copy_errno=%d dest=%s container=%s\n",
                     (int)geteuid(),
                     (int)getuid(),
                     copied,
                     (long long)bytes,
                     mode,
                     sourceErrno,
                     copyErrno,
                     kDestVideo,
                     container);
    if (wrote <= 0 || (size_t)wrote >= sizeof(line)) {
        return;
    }
    if (strcmp(previous, line) == 0) {
        return;
    }
    memcpy(previous, line, (size_t)wrote + 1);
    printf("%s", line);
    fflush(stdout);
    write_text_file("/var/jb/var/mobile/Library/MyVCam/mirror.status", line, uid, gid);
    if (gContainerReady) {
        char statusPath[PATH_MAX];
        int statusWrote = snprintf(statusPath, sizeof(statusPath), "%s/mirror.status", gContainerDir);
        if (statusWrote > 0 && (size_t)statusWrote < sizeof(statusPath)) {
            write_text_file(statusPath, line, uid, gid);
        }
        write_text_file(kContainerRecord, gContainerVideo, uid, gid);
    }
    syslog(LOG_NOTICE, "[MyVCam mirror] %s", line);
}

static int source_stat(const char *path, struct stat *info, int *errOut) {
    if (stat(path, info) == 0) {
        if (errOut != NULL) {
            *errOut = 0;
        }
        return 1;
    }
    if (errOut != NULL) {
        *errOut = errno;
    }
    return 0;
}

static void sync_disable(uid_t uid, gid_t gid) {
    struct stat info;
    int err = 0;

    if (source_stat(kSourceDisable, &info, &err) && S_ISREG(info.st_mode)) {
        struct stat existing;
        if (stat(kDestDisable, &existing) != 0) {
            int marker = open(kDestDisable, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (marker >= 0) {
                close(marker);
                publish_mode(kDestDisable, uid, gid);
                syslog(LOG_NOTICE, "[MyVCam mirror] disable marker written");
            }
        }
        if (gContainerReady && stat(gContainerDisable, &existing) != 0) {
            int marker = open(gContainerDisable, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (marker >= 0) {
                close(marker);
                publish_mode(gContainerDisable, uid, gid);
            }
        }
        return;
    }
    if (err == ENOENT) {
        unlink(kDestDisable);
        if (gContainerReady) {
            unlink(gContainerDisable);
        }
    }
}

static void mirror_once(void) {
    uid_t uid = 501;
    gid_t gid = 501;
    struct stat source;
    struct stat destination;
    int sourceErrno = 0;
    int copyErrno = 0;
    int copied = 0;
    off_t bytes = 0;
    int lockFd = -1;
    int same = 0;
    int jbOk = 0;
    static int lastMissingErrno = -1;

    mkdir_parents(kDestDir);
    owner_ids(&uid, &gid);
    find_camera_container();
    if (gContainerReady) {
        mkdir_parents(gContainerDir);
    }

    lockFd = open(kLockPath, O_CREAT | O_RDWR, 0644);
    if (lockFd >= 0) {
        while (flock(lockFd, LOCK_EX) != 0) {
            if (errno != EINTR) {
                break;
            }
        }
    }

    sync_disable(uid, gid);

    memset(&source, 0, sizeof(source));
    if (!source_stat(kSourceVideo, &source, &sourceErrno) || !S_ISREG(source.st_mode) || source.st_size <= 0) {
        int missing = sourceErrno == EPERM || sourceErrno == EACCES;
        int absent = sourceErrno == ENOENT || (sourceErrno == 0 && !S_ISREG(source.st_mode));
        if (absent) {
            unlink(kDestVideo);
            unlink(kDestVideoTemp);
            if (gContainerReady) {
                unlink(gContainerVideo);
                unlink(gContainerVideoTemp);
            }
            gCopiedMtime = 0;
            gCopiedSize = -1;
        }
        if (lastMissingErrno != sourceErrno) {
            lastMissingErrno = sourceErrno;
            if (missing) {
                syslog(LOG_NOTICE, "[MyVCam mirror] cannot stat %s errno=%d; leaving destination", kSourceVideo, sourceErrno);
            } else {
                syslog(LOG_NOTICE, "[MyVCam mirror] no regular file at %s errno=%d", kSourceVideo, sourceErrno);
            }
        }
        write_status(uid, gid, 0, 0, sourceErrno, 0);
        goto done;
    }
    lastMissingErrno = -1;

    if (stat(kDestVideo, &destination) == 0 &&
        destination.st_size == source.st_size &&
        source.st_mtime == gCopiedMtime &&
        source.st_size == gCopiedSize) {
        same = 1;
    }
    if (!same) {
        if (copy_file(kSourceVideo, kDestVideo, kDestVideoTemp, uid, gid) != 0) {
            copyErrno = errno;
        } else {
            jbOk = 1;
            gCopiedMtime = source.st_mtime;
            gCopiedSize = source.st_size;
        }
    } else {
        jbOk = 1;
        publish_mode(kDestVideo, uid, gid);
    }

    if (gContainerReady) {
        struct stat containerInfo;
        int containerSame = stat(gContainerVideo, &containerInfo) == 0 &&
            containerInfo.st_size == source.st_size;
        if (!containerSame) {
            if (copy_file(kSourceVideo, gContainerVideo, gContainerVideoTemp, uid, gid) != 0) {
                if (copyErrno == 0) {
                    copyErrno = errno;
                }
            }
        } else {
            publish_mode(gContainerVideo, uid, gid);
        }
    }

    copied = jbOk || (gContainerReady && mode_of(gContainerVideo) != 0);
    bytes = copied ? source.st_size : 0;
    write_status(uid, gid, copied, bytes, sourceErrno, copyErrno);

done:
    if (lockFd >= 0) {
        flock(lockFd, LOCK_UN);
        close(lockFd);
    }
}

int main(int argc, char **argv) {
    int watch = 0;

    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--watch") == 0) {
            watch = 1;
        }
    }

    openlog("myvcam-mirror", LOG_PID, LOG_USER);
    syslog(LOG_NOTICE, "[MyVCam mirror] start euid=%d uid=%d watch=%d",
           (int)geteuid(), (int)getuid(), watch);
    do {
        mirror_once();
        if (!watch) {
            break;
        }
        sleep(1);
    } while (1);
    closelog();
    return 0;
}

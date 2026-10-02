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
static const char kRuntimeStatus[] = "/var/jb/var/mobile/Library/MyVCam/runtime.status";
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
    {
        struct stat sourceInfo;
        struct stat destInfo;
        int sourceExists = stat(kSourceVideo, &sourceInfo) == 0 && S_ISREG(sourceInfo.st_mode);
        int destExists = stat(kDestVideo, &destInfo) == 0 && S_ISREG(destInfo.st_mode);
        long long destSize = destExists ? (long long)destInfo.st_size : 0;
        int reported = copyErrno != 0 ? copyErrno : sourceErrno;
        syslog(LOG_NOTICE,
               "[MyVCam 0.2.8] source=%s dest=%s source_exists=%d dest_exists=%d dest_size=%lld copy_ok=%d errno=%d error_domain=NSPOSIXErrorDomain error_code=%d",
               kSourceVideo,
               kDestVideo,
               sourceExists,
               destExists,
               destSize,
               copied,
               reported,
               reported);
    }
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

static void ensure_status_file(const char *path, uid_t uid, gid_t gid) {
    struct stat info;
    int fd = -1;

    if (path == NULL || path[0] == '\0') {
        return;
    }
    if (stat(path, &info) != 0) {
        fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0666);
        if (fd >= 0) {
            if (fchmod(fd, 0666) != 0) {
                syslog(LOG_NOTICE, "[MyVCam mirror] chmod %s failed errno=%d", path, errno);
            }
            if (fchown(fd, uid, gid) != 0) {
                syslog(LOG_NOTICE, "[MyVCam mirror] chown %s failed errno=%d", path, errno);
            }
            close(fd);
        }
        return;
    }
    if (chmod(path, 0666) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] chmod %s failed errno=%d", path, errno);
    }
    if (chown(path, uid, gid) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] chown %s failed errno=%d", path, errno);
    }
}

static void publish_runtime_status(uid_t uid, gid_t gid) {
    char containerStatus[PATH_MAX];
    char temporary[PATH_MAX];
    struct stat source;
    struct stat dest;
    int wrote = 0;

    ensure_status_file(kRuntimeStatus, uid, gid);
    if (!gContainerReady) {
        return;
    }
    wrote = snprintf(containerStatus, sizeof(containerStatus), "%s/runtime.status", gContainerDir);
    if (wrote <= 0 || (size_t)wrote >= sizeof(containerStatus)) {
        return;
    }
    ensure_status_file(containerStatus, uid, gid);
    if (stat(containerStatus, &source) != 0 || !S_ISREG(source.st_mode) || source.st_size <= 0) {
        return;
    }
    if (stat(kRuntimeStatus, &dest) == 0 &&
        S_ISREG(dest.st_mode) &&
        dest.st_size == source.st_size &&
        dest.st_mtime >= source.st_mtime) {
        return;
    }
    wrote = snprintf(temporary, sizeof(temporary), "%s.tmp", kRuntimeStatus);
    if (wrote <= 0 || (size_t)wrote >= sizeof(temporary)) {
        return;
    }
    if (copy_file(containerStatus, kRuntimeStatus, temporary, uid, gid) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] runtime.status copy failed errno=%d", errno);
        return;
    }
    if (chmod(kRuntimeStatus, 0666) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] runtime.status chmod failed errno=%d", errno);
    }
    if (chown(kRuntimeStatus, uid, gid) != 0) {
        syslog(LOG_NOTICE, "[MyVCam mirror] runtime.status chown failed errno=%d", errno);
    }
    syslog(LOG_NOTICE, "[MyVCam 0.2.13] runtime.status publish bytes=%lld", (long long)source.st_size);
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
    publish_runtime_status(uid, gid);

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

static unsigned myvcam_be32(const unsigned char *bytes) {
    return ((unsigned)bytes[0] << 24) | ((unsigned)bytes[1] << 16) |
           ((unsigned)bytes[2] << 8) | (unsigned)bytes[3];
}

static unsigned myvcam_le32(const unsigned char *bytes) {
    return (unsigned)bytes[0] | ((unsigned)bytes[1] << 8) |
           ((unsigned)bytes[2] << 16) | ((unsigned)bytes[3] << 24);
}

/* One slice of the installed tweak. Prints nothing on failure. */
static int myvcam_slice_info(const unsigned char *base,
                             size_t size,
                             char *arch,
                             size_t archLength,
                             unsigned *pageShift,
                             unsigned *sigFlags,
                             int *hasUuid) {
    size_t off = 32;
    unsigned ncmds = 0;
    unsigned subtype = 0;
    unsigned low = 0;
    const char *name = NULL;

    if (base == NULL || size < 32 || arch == NULL || archLength < 8) {
        return 0;
    }
    if (myvcam_le32(base) != 0xFEEDFACFu) {
        return 0;
    }
    if (myvcam_le32(base + 4) != 0x0100000Cu) {
        return 0;
    }
    subtype = myvcam_le32(base + 8);
    ncmds = myvcam_le32(base + 16);
    low = subtype & 0xffu;
    if (low == 0) {
        name = "arm64";
    } else if (low == 2) {
        name = "arm64e";
    } else {
        name = "other";
    }
    if ((size_t)snprintf(arch, archLength, "%s:0x%x", name, subtype) >= archLength) {
        return 0;
    }
    *pageShift = 0;
    *sigFlags = 0;
    *hasUuid = 0;
    for (unsigned index = 0; index < ncmds; index++) {
        unsigned cmd = 0;
        unsigned cmdsize = 0;
        if (off + 8 > size) {
            return 0;
        }
        cmd = myvcam_le32(base + off);
        cmdsize = myvcam_le32(base + off + 4);
        if (cmdsize < 8 || off + cmdsize > size) {
            return 0;
        }
        if (cmd == 0x1bu && cmdsize >= 24) {
            *hasUuid = 1;
        } else if (cmd == 0x1du && cmdsize >= 16) {
            unsigned dataoff = myvcam_le32(base + off + 8);
            unsigned datasize = myvcam_le32(base + off + 12);
            if ((size_t)dataoff + 12 <= size && (size_t)dataoff + datasize <= size) {
                const unsigned char *blob = base + dataoff;
                unsigned count = 0;
                if (myvcam_be32(blob) == 0xFADE0CC0u) {
                    count = myvcam_be32(blob + 8);
                    for (unsigned slot = 0; slot < count; slot++) {
                        unsigned typ = 0;
                        unsigned rel = 0;
                        if (12u + (slot + 1u) * 8u > datasize) {
                            break;
                        }
                        typ = myvcam_be32(blob + 12 + slot * 8);
                        rel = myvcam_be32(blob + 16 + slot * 8);
                        if (typ == 0 && rel + 40 <= datasize) {
                            const unsigned char *directory = blob + rel;
                            if (myvcam_be32(directory) == 0xFADE0C02u) {
                                *sigFlags = myvcam_be32(directory + 12);
                                *pageShift = directory[39];
                            }
                        }
                    }
                }
            }
        }
        off += cmdsize;
    }
    return 1;
}

/* --machinfo <dylib> writes one line for package.installed. Not runtime.status. */
static int myvcam_machinfo(const char *path) {
    int fd = -1;
    struct stat info;
    unsigned char *buf = NULL;
    size_t size = 0;
    ssize_t got = 0;
    char parts[4][64];
    int count = 0;
    unsigned pageShift = 0;
    unsigned sigFlags = 0;
    int hasUuid = 1;
    int saw = 0;

    if (path == NULL || path[0] == '\0') {
        return 1;
    }
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        return 1;
    }
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 ||
        info.st_size > (8 * 1024 * 1024)) {
        close(fd);
        return 1;
    }
    size = (size_t)info.st_size;
    buf = malloc(size);
    if (buf == NULL) {
        close(fd);
        return 1;
    }
    got = 0;
    while ((size_t)got < size) {
        ssize_t step = read(fd, buf + got, size - (size_t)got);
        if (step < 0) {
            if (errno == EINTR) {
                continue;
            }
            free(buf);
            close(fd);
            return 1;
        }
        if (step == 0) {
            break;
        }
        got += step;
    }
    close(fd);
    if ((size_t)got != size) {
        free(buf);
        return 1;
    }

    if (size >= 8 && myvcam_be32(buf) == 0xCAFEBABEu) {
        unsigned nfat = myvcam_be32(buf + 4);
        if (nfat == 0 || nfat > 4) {
            free(buf);
            return 1;
        }
        for (unsigned index = 0; index < nfat; index++) {
            unsigned offset = 0;
            unsigned sliceSize = 0;
            unsigned slicePage = 0;
            unsigned sliceFlags = 0;
            int sliceUuid = 0;
            if (8u + (index + 1u) * 20u > size) {
                free(buf);
                return 1;
            }
            offset = myvcam_be32(buf + 8 + index * 20 + 8);
            sliceSize = myvcam_be32(buf + 8 + index * 20 + 12);
            if ((size_t)offset + sliceSize > size) {
                free(buf);
                return 1;
            }
            if (!myvcam_slice_info(buf + offset, sliceSize, parts[count], sizeof(parts[count]),
                                   &slicePage, &sliceFlags, &sliceUuid)) {
                free(buf);
                return 1;
            }
            if (!saw || (parts[count][0] == 'a' && strstr(parts[count], "arm64e") == parts[count])) {
                pageShift = slicePage;
                sigFlags = sliceFlags;
            }
            if (!sliceUuid) {
                hasUuid = 0;
            }
            saw = 1;
            count++;
            if (count == 4) {
                break;
            }
        }
    } else {
        if (!myvcam_slice_info(buf, size, parts[0], sizeof(parts[0]), &pageShift, &sigFlags, &hasUuid)) {
            free(buf);
            return 1;
        }
        count = 1;
        saw = 1;
    }
    free(buf);
    if (!saw || count == 0 || pageShift == 0) {
        return 1;
    }
    printf("mach=%s", parts[0]);
    for (int index = 1; index < count; index++) {
        printf("+%s", parts[index]);
    }
    printf(" pagesz=%u sig=0x%x uuid=%d\n",
           (pageShift < 31) ? (1u << pageShift) : 0u,
           sigFlags,
           hasUuid ? 1 : 0);
    return 0;
}

int main(int argc, char **argv) {
    int watch = 0;

    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--machinfo") == 0) {
            const char *target = (index + 1 < argc) ? argv[index + 1] : NULL;
            return myvcam_machinfo(target);
        }
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

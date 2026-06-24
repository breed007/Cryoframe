//
//  fs_snapshot_spike.c — M1 de-risk: the real fs_snapshot_* syscall path.
//
//  Promotes the M0 tmutil/mount_apfs scaffold to the syscalls the root helper
//  will use. Proves create / mount / list / unmount / delete work from root
//  with deterministic naming (app.cryoframe.snap.<unix-ts>), and leaves a mount
//  in place so a separate non-root FDA process can prove the split read.
//
//  build:  clang -O2 -Wall -o fs_snapshot_spike fs_snapshot_spike.c
//  use (root):
//    ./fs_snapshot_spike create            -> prints SNAP= and MOUNTPOINT=
//    ./fs_snapshot_spike list              -> lists app.cryoframe.snap.* snapshots
//    ./fs_snapshot_spike teardown <mnt> <snap>
//
//  NOT the shipping mechanism — this is the C surface the Swift helper wraps.
//
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/attr.h>
#include <sys/snapshot.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>

#define DATA_VOL   "/System/Volumes/Data"
#define SNAP_PREFIX "app.cryoframe.snap."
#define MNT_BASE   "/private/var/run/app.cryoframe/mnt"
// read-only is implicit for a snapshot mount; add hygiene + keep out of Finder.
#define MOUNT_FLAGS (SNAPSHOT_MNT_DONTBROWSE | SNAPSHOT_MNT_NOSUID | SNAPSHOT_MNT_NODEV)

static int die(const char *what) {
    fprintf(stderr, "[fail] %s: %s (errno %d)\n", what, strerror(errno), errno);
    return 1;
}

// mkdir -p, each component 0755 so a non-root user can traverse to the mount.
static int mkpath(const char *path) {
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

static int open_data_vol(void) {
    int fd = open(DATA_VOL, O_RDONLY);
    if (fd < 0) die("open " DATA_VOL);
    return fd;
}

static int cmd_create(void) {
    int dirfd = open_data_vol();
    if (dirfd < 0) return 1;

    char name[128], mnt[256];
    long ts = (long)time(NULL);
    snprintf(name, sizeof(name), "%s%ld", SNAP_PREFIX, ts);
    snprintf(mnt, sizeof(mnt), "%s/%ld", MNT_BASE, ts);

    if (fs_snapshot_create(dirfd, name, 0) != 0) { close(dirfd); return die("fs_snapshot_create"); }
    fprintf(stderr, "[ ok ] created snapshot %s\n", name);

    if (mkpath(mnt) != 0) { close(dirfd); return die("mkpath mountpoint"); }

    if (fs_snapshot_mount(dirfd, mnt, name, MOUNT_FLAGS) != 0) {
        fprintf(stderr, "[fail] fs_snapshot_mount: %s (errno %d)\n", strerror(errno), errno);
        fs_snapshot_delete(dirfd, name, 0);   // don't leak the snapshot on mount failure
        close(dirfd);
        return 1;
    }
    fprintf(stderr, "[ ok ] mounted read-only at %s\n", mnt);
    close(dirfd);

    // machine-parseable lines for the orchestrator:
    printf("SNAP=%s\n", name);
    printf("MOUNTPOINT=%s\n", mnt);
    return 0;
}

// fs_snapshot_list with ATTR_CMN_NAME — the reconcile primitive.
static int cmd_list(void) {
    int dirfd = open_data_vol();
    if (dirfd < 0) return 1;

    struct attrlist alist;
    memset(&alist, 0, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.commonattr  = ATTR_CMN_NAME;

    size_t bufsize = 64 * 1024;
    char *buf = malloc(bufsize);
    if (!buf) { close(dirfd); return die("malloc"); }

    int count = fs_snapshot_list(dirfd, &alist, buf, bufsize, 0);
    close(dirfd);
    if (count < 0) { free(buf); return die("fs_snapshot_list"); }

    int ours = 0;
    char *p = buf;
    for (int i = 0; i < count; i++) {
        uint32_t entry_len = *(uint32_t *)p;
        // layout: [u32 len][attribute_set_t returned][attrreference_t name]...
        char *field = p + sizeof(uint32_t) + sizeof(attribute_set_t);
        attrreference_t *nameref = (attrreference_t *)field;
        const char *nm = field + nameref->attr_dataoffset;
        int mine = strncmp(nm, SNAP_PREFIX, strlen(SNAP_PREFIX)) == 0;
        printf("%s %s\n", mine ? "[ours]" : "      ", nm);
        if (mine) ours++;
        p += entry_len;
    }
    free(buf);
    fprintf(stderr, "[ ok ] %d snapshot(s) total, %d ours\n", count, ours);
    return 0;
}

static int cmd_teardown(const char *mnt, const char *snap) {
    // delete guard: never delete a snapshot that isn't ours.
    if (strncmp(snap, SNAP_PREFIX, strlen(SNAP_PREFIX)) != 0) {
        fprintf(stderr, "[fail] refusing to delete foreign snapshot: %s\n", snap);
        return 1;
    }
    int rc = 0;
    if (unmount(mnt, 0) != 0) { rc |= die("unmount"); }
    else fprintf(stderr, "[ ok ] unmounted %s\n", mnt);
    rmdir(mnt);  // best effort

    int dirfd = open_data_vol();
    if (dirfd < 0) return 1;
    if (fs_snapshot_delete(dirfd, snap, 0) != 0) rc |= die("fs_snapshot_delete");
    else fprintf(stderr, "[ ok ] deleted snapshot %s\n", snap);
    close(dirfd);
    return rc;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s create | list | teardown <mountpoint> <snapname>\n", argv[0]);
        return 2;
    }
    if (geteuid() != 0) {
        fprintf(stderr, "[fail] must run as root (fs_snapshot_* syscalls)\n");
        return 1;
    }
    if (strcmp(argv[1], "create") == 0)   return cmd_create();
    if (strcmp(argv[1], "list") == 0)     return cmd_list();
    if (strcmp(argv[1], "teardown") == 0) {
        if (argc != 4) { fprintf(stderr, "usage: %s teardown <mountpoint> <snapname>\n", argv[0]); return 2; }
        return cmd_teardown(argv[2], argv[3]);
    }
    fprintf(stderr, "unknown command: %s\n", argv[1]);
    return 2;
}

/* Copyright 2020 Google Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include <ftw.h>
#include <errno.h>
#include <string.h>

#define INCLUDED_BY_MAIN_MODULE 1
#include "config.h"
#include "gpg.h"
#include "../common/types.h"
#include "../common/iobuf.h"
#include "keydb.h"
#include "keyedit.h"
#include "../common/util.h"
#include "main.h"
#include "call-dirmngr.h"
#include "trustdb.h"

#include <sys/stat.h>
#include <fcntl.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/mount.h>

// 8kb should be enough ;-)
#define MAX_LEN 0x2000

static bool initialized = false;
ctrl_t ctrlGlobal;
int fd;
char *filename;

//hack not to include gpg.c which has main function
int g10_errors_seen = 0;
int assert_signer_true = 0;
int assert_pubkey_algo_false = 0;

void
g10_exit( int rc )
{
    gcry_control (GCRYCTL_UPDATE_RANDOM_SEED_FILE);
    gcry_control (GCRYCTL_TERM_SECMEM );
    exit (rc);
}

static void
gpg_deinit_default_ctrl (ctrl_t ctrl)
{
#ifdef USE_TOFU
    tofu_closedbs (ctrl);
#endif
    gpg_dirmngr_deinit_session_data (ctrl);

    keydb_release (ctrl->cached_getkey_kdb);
}

static void
my_gcry_logger (void *dummy, int level, const char *format, va_list arg_ptr)
{
    return;
}

/* rm -rf, depth-first.  The OSS-Fuzz original walked with ftw() and unlinked
 * only FTW_F entries, so the rmdir() below failed on any homedir GnuPG had put a
 * subdirectory in (private-keys-v1.d, openpgp-revocs.d) and left the tree behind.
 * nftw(FTW_DEPTH) visits children first, so remove() handles files and dirs. */
static int remove_cb(const char *fpath, const struct stat *sb, int typeflag,
                     struct FTW *ftwbuf)
{
    (void)sb; (void)typeflag; (void)ftwbuf;
    remove(fpath);
    return 0;
}

static void rmrfdir(char *path)
{
    nftw(path, remove_cb, 16, FTW_DEPTH | FTW_PHYS);
}

/* ---------------------------------------------------------------------------
 * Per-process GnuPG home directory  (MAYHEM: replaces the OSS-Fuzz original's
 * hardcoded "/tmp/fuzzdir<target>").
 *
 * The original path was a compile-time constant shared by every process running
 * this target.  Mayhem, like libFuzzer's own -jobs mode, runs several worker
 * processes per target, so they raced on one home directory: each worker
 * rmrfdir()s the directory the others are using and re-creates it, taking the
 * trustdb and its lock file with it.  tdbio.c's take_write_lock() is documented
 * as terminating the process when the lock cannot be created ("If a lock file
 * can't be created the function terminates the process"), so the losing worker
 * log_fatal()s -> exit(2) inside the public_key_list() call below.  That call is
 * in this one-time warm-up block, BEFORE any fuzzed byte is read, so libFuzzer
 * reports "fuzz target exited" against whatever input happened to be running:
 * a harness artifact with a misleading reproducer attached, not a GnuPG bug.
 *
 * One mkdtemp() directory per process removes the sharing, and honors TMPDIR
 * rather than writing outside whatever scratch area the runner handed us.
 * Removed at exit.
 * ------------------------------------------------------------------------- */
static char fuzz_homedir[512];

static void fuzz_homedir_cleanup(void)
{
    if (fuzz_homedir[0])
        rmrfdir(fuzz_homedir);
}

/* Setup failures are fatal here.  The original returned 0 from each of them,
 * which leaves a target that runs at full speed with no keyring, no trustdb and
 * no coverage -- from the outside indistinguishable from a healthy run. */
static void fuzz_die(const char *what)
{
    fprintf(stderr, "fuzz harness: %s failed: %s\n", what, strerror(errno));
    abort();
}

static void fuzz_homedir_init(void)
{
    const char *tmp = getenv("TMPDIR");

    if (tmp == NULL || tmp[0] == '\0')
        tmp = "/tmp";
    if (snprintf(fuzz_homedir, sizeof(fuzz_homedir), "%s/gnupg-fuzz-XXXXXX", tmp)
        >= (int)sizeof(fuzz_homedir)) {
        fprintf(stderr, "fuzz harness: TMPDIR too long\n");
        abort();
    }
    if (mkdtemp(fuzz_homedir) == NULL)
        fuzz_die("mkdtemp");
    atexit(fuzz_homedir_cleanup);
}

int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {
    if (! initialized) {
        ctrlGlobal = (ctrl_t) malloc(sizeof(*ctrlGlobal));
        if (!ctrlGlobal) {
            exit(1);
        }
        /* per-process homedir + input file; see fuzz_homedir_init() above */
        fuzz_homedir_init();
        if (asprintf(&filename, "%s/fuzz.gpg", fuzz_homedir) < 0 || !filename)
            fuzz_die("asprintf");
        fd = open(filename, O_RDWR | O_CREAT, 0666);
        if (fd == -1)
            fuzz_die("open");
        gnupg_set_homedir(fuzz_homedir);
        if (keydb_add_resource ("pubring" EXTSEP_S GPGEXT_GPG, KEYDB_RESOURCE_FLAG_DEFAULT) != GPG_ERR_NO_ERROR) {
            fprintf(stderr, "fuzz harness: keydb_add_resource failed\n");
            abort();
        }
        if (setup_trustdb (1, NULL) != GPG_ERR_NO_ERROR) {
            fprintf(stderr, "fuzz harness: setup_trustdb failed\n");
            abort();
        }
        //populate the per-process homedir as ~/.gnupg
        strlist_t sl = NULL;
        public_key_list (ctrlGlobal, sl, 0, 0);
        free_strlist(sl);
        //no output for stderr
        log_set_file("/dev/null");
        gcry_set_log_handler (my_gcry_logger, NULL);
        gnupg_initialize_compliance (GNUPG_MODULE_NAME_GPG);
        initialized = true;
    }

    memset(ctrlGlobal, 0, sizeof(*ctrlGlobal));
    ctrlGlobal->magic = SERVER_CONTROL_MAGIC;
    if (Size > MAX_LEN) {
        // limit maximum size to avoid long computing times
        Size = MAX_LEN;
    }

    if (ftruncate(fd, Size) == -1) {
        return 0;
    }
    if (lseek (fd, 0, SEEK_SET) < 0) {
        return 0;
    }
    if (write (fd, Data, Size) != Size) {
        return 0;
    }

    import_keys (ctrlGlobal, &filename, 1, NULL, IMPORT_REPAIR_KEYS, 0, NULL);
    gpg_deinit_default_ctrl (ctrlGlobal);
    /*memset(ctrlGlobal, 0, sizeof(*ctrlGlobal));
    ctrlGlobal->magic = SERVER_CONTROL_MAGIC;
    PKT_public_key pk;
    get_pubkey_fromfile (ctrlGlobal, &pk, filename);
    release_public_key_parts (&pk);
    gpg_deinit_default_ctrl (ctrlGlobal);*/

    return 0;
}

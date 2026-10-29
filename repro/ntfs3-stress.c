// SPDX-License-Identifier: GPL-2.0
/*
 * ntfs3-stress - reproducers for ntfs3 deadlocks.
 *
 *   ntfs3-stress resident <dir> [-p pairs] [-g a|t|f] [-t secs]
 *	Deadlock D1: folio lock vs ni_lock while a small (MFT-resident) file
 *	grows past the resident limit.  Each pair runs:
 *	  writer: create file, grow it to 4 KiB; the step that crosses ~700
 *	          bytes converts $DATA resident -> nonresident (ni_lock ->
 *	          run_lock -> folio_lock(0) in attr_make_nonresident).
 *	          -g a: append 64-byte chunks (write path, default)
 *	          -g t: ftruncate up in 64-byte steps (setattr path)
 *	          -g f: fallocate 4 KiB (fallocate path)
 *	  reader: drop page cache, pread(0)  (read_folio holds folio_lock(0) and
 *	          then takes run_lock/ni_lock in attr_data_get_block)
 *
 *   ntfs3-stress resmmap <dir> [-p pairs] [-t secs]
 *	Writeback side of D1, plus a data check.  Each pair runs:
 *	  worker: write 300 bytes 'A' (resident), overwrite them with 'B' via a
 *	          shared mmap (folio 0 dirty, resident copy still 'A'), append
 *	          2000 bytes 'C' (converts), then fsync, drop cache, read back
 *	          and verify B...BC...C.
 *	  syncer: fdatasync the file in a loop (writepages holds folio_lock(0)
 *	          and takes ni_lock for resident files).
 *
 *   ntfs3-stress dirstorm <dir> [-j threads] [-n names] [-t secs] [-x op]
 *	Random mix of namespace + data operations on a small shared name set
 *	(create/unlink/rename/link/symlink/mkdir/rmdir/readdir/stat/chmod/
 *	xattr/truncate/append/mmap/fallocate/fsync) - the shape of many agents
 *	or git worktrees hammering the same tree.  Mostly useful for lockdep.
 *	-x <op> skips op number <op> of the switch in storm(); repeatable.
 *
 * Exit status: 0 when the run finishes (no hang), 1 if resmmap read back
 * wrong data or dirstorm got SIGBUS inside i_size.  A deadlock shows up as the process never finishing (D
 * state); the VM harness detects that.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>

static const char *base;
static int nthreads = 8, nnames = 32, secs = 60, npairs = 4;
static unsigned exclude; /* bitmask of dirstorm ops to skip (-x) */
static char grow = 'a'; /* resident: how the writer grows the file (-g) */
static atomic_int stop;
static atomic_ulong ops, bad, sigbus;

/*
 * dirstorm mmaps files that other threads truncate, so SIGBUS past EOF is
 * expected.  Catch it; report it only if the offset is still inside i_size
 * and the file's ctime did not change since it was mapped (no truncate or
 * write raced with the access).
 */
static __thread sigjmp_buf bus_jmp;
static __thread volatile sig_atomic_t bus_armed;

static void on_sigbus(int sig)
{
	if (bus_armed)
		siglongjmp(bus_jmp, 1);
	signal(sig, SIG_DFL);
	raise(sig);
}

static void die(const char *m)
{
	perror(m);
	exit(2);
}

static unsigned rnd(unsigned *s)
{
	*s = *s * 1103515245 + 12345;
	return *s >> 8;
}

/* ---------------------------------------------------------------- D1 */

struct pair {
	int id;
	char path[4096];
};

static void *res_writer(void *arg)
{
	struct pair *p = arg;
	char chunk[64];

	memset(chunk, 'a' + p->id % 26, sizeof(chunk));
	while (!stop) {
		unlink(p->path);
		int fd = open(p->path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
		if (fd < 0)
			die("open writer");
		/* Start non-empty so the reader has something to read. */
		if (write(fd, chunk, sizeof(chunk)) != sizeof(chunk))
			die("write");
		for (int k = 2; k <= 4096 / (int)sizeof(chunk) && !stop; k++) {
			if (grow == 'a') {
				if (write(fd, chunk, sizeof(chunk)) != sizeof(chunk))
					die("write");
			} else if (grow == 't') {
				if (ftruncate(fd, k * sizeof(chunk)))
					die("ftruncate");
			} else {
				/* fallocate converts the file at once. */
				usleep(200);
				if (fallocate(fd, 0, 0, 4096))
					die("fallocate");
				break;
			}
		}
		close(fd);
		ops++;
	}
	return NULL;
}

static void *res_reader(void *arg)
{
	struct pair *p = arg;
	char buf[4096];

	while (!stop) {
		int fd = open(p->path, O_RDONLY);
		if (fd < 0)
			continue;
		posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
		if (pread(fd, buf, sizeof(buf), 0) < 0)
			die("pread");
		close(fd);
	}
	return NULL;
}

static void *mm_worker(void *arg)
{
	struct pair *p = arg;
	static const size_t na = 300, nc = 2000;
	char a[300], c[2000], buf[4096];

	memset(a, 'A', na);
	memset(c, 'C', nc);
	while (!stop) {
		unlink(p->path);
		int fd = open(p->path, O_CREAT | O_RDWR | O_TRUNC, 0644);
		if (fd < 0)
			die("open worker");
		if (pwrite(fd, a, na, 0) != (ssize_t)na)
			die("pwrite A");
		char *m = mmap(NULL, na, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		if (m == MAP_FAILED)
			die("mmap");
		memset(m, 'B', na);
		if (pwrite(fd, c, nc, na) != (ssize_t)nc)
			die("pwrite C");
		munmap(m, na);
		if (fsync(fd))
			die("fsync");
		posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
		ssize_t n = pread(fd, buf, sizeof(buf), 0);
		size_t i;
		for (i = 0; i < na + nc; i++)
			if (n != (ssize_t)(na + nc) || buf[i] != (i < na ? 'B' : 'C'))
				break;
		if (i != na + nc && bad++ < 10)
			printf("DATA MISMATCH %s: size %zd, byte %zu is '%c' (want '%c')\n",
			       p->path, n, i, i < (size_t)n ? buf[i] : '?',
			       i < na ? 'B' : 'C');
		close(fd);
		ops++;
	}
	return NULL;
}

static void *mm_syncer(void *arg)
{
	struct pair *p = arg;

	while (!stop) {
		int fd = open(p->path, O_RDONLY);
		if (fd < 0)
			continue;
		fdatasync(fd);
		close(fd);
	}
	return NULL;
}

static void run_pairs(void *(*a)(void *), void *(*b)(void *), const char *what)
{
	pthread_t th[2 * npairs];
	struct pair pairs[npairs];

	for (int i = 0; i < npairs; i++) {
		pairs[i].id = i;
		snprintf(pairs[i].path, sizeof(pairs[i].path), "%s/res%d", base, i);
		pthread_create(&th[2 * i], NULL, a, &pairs[i]);
		pthread_create(&th[2 * i + 1], NULL, b, &pairs[i]);
	}
	for (int t = 0; t < secs; t++) {
		sleep(1);
		printf("t=%ds %s=%lu bad=%lu\n", t + 1, what, (unsigned long)ops,
		       (unsigned long)bad);
		fflush(stdout);
	}
	stop = 1;
	for (int i = 0; i < 2 * npairs; i++)
		pthread_join(th[i], NULL);
}

/* ---------------------------------------------------------- dirstorm */

#define NDIRS 4

static void name(char *buf, unsigned *s)
{
	sprintf(buf, "%s/d%u/n%u", base, rnd(s) % NDIRS, rnd(s) % nnames);
}

static void *storm(void *arg)
{
	unsigned s = (unsigned)(long)arg * 7919 + time(NULL);
	char a[4096], b[4096], buf[8192];

	memset(buf, 'x', sizeof(buf));
	while (!stop) {
		int fd;
		struct stat st;

		name(a, &s);
		name(b, &s);
		unsigned op = rnd(&s) % 20;

		if (exclude & (1u << op))
			continue;
		switch (op) {
		case 0:
		case 1:
			fd = open(a, O_CREAT | O_WRONLY | O_TRUNC, 0644);
			if (fd >= 0) {
				if (write(fd, buf, rnd(&s) % sizeof(buf)) < 0) {}
				close(fd);
			}
			break;
		case 2:
			unlink(a);
			break;
		case 3:
		case 4:
			rename(a, b);
			break;
		case 5:
			link(a, b);
			break;
		case 6:
			symlink("target", a);
			break;
		case 7:
			if (mkdir(a, 0755) == 0 && rnd(&s) % 2) {
				snprintf(b, sizeof(b), "%s/inner", a);
				fd = open(b, O_CREAT | O_WRONLY, 0644);
				if (fd >= 0)
					close(fd);
			}
			break;
		case 8:
			rmdir(a);
			break;
		case 9: {
			snprintf(b, sizeof(b), "%s/d%u", base, rnd(&s) % NDIRS);
			DIR *d = opendir(b);
			if (d) {
				struct dirent *de;
				while ((de = readdir(d))) {
					snprintf(a, sizeof(a), "%s/%s", b, de->d_name);
					lstat(a, &st);
				}
				closedir(d);
			}
			break;
		}
		case 10:
			chmod(a, 0600 | (rnd(&s) % 2 ? 0044 : 0));
			break;
		case 11:
			setxattr(a, "user.agent", buf, rnd(&s) % 300, 0);
			break;
		case 12:
			truncate(a, rnd(&s) % 6000);
			break;
		case 13:
			fd = open(a, O_WRONLY | O_APPEND);
			if (fd >= 0) {
				if (write(fd, buf, 1 + rnd(&s) % 200) < 0) {}
				if (rnd(&s) % 4 == 0)
					fdatasync(fd);
				close(fd);
			}
			break;
		case 14:
			fd = open(a, O_RDWR);
			if (fd >= 0) {
				if (fstat(fd, &st) == 0 && st.st_size > 0 &&
				    S_ISREG(st.st_mode)) {
					size_t len = st.st_size;
					struct timespec ctime0 = st.st_ctim;
					char *m = mmap(NULL, len,
						       PROT_READ | PROT_WRITE,
						       MAP_SHARED, fd, 0);
					if (m != MAP_FAILED) {
						off_t k = rnd(&s) % len;

						bus_armed = 1;
						if (!sigsetjmp(bus_jmp, 1)) {
							m[k]++;
							if (rnd(&s) % 2)
								msync(m, len, MS_SYNC);
						} else if (!fstat(fd, &st) && k < st.st_size &&
							   st.st_ctim.tv_sec == ctime0.tv_sec &&
							   st.st_ctim.tv_nsec == ctime0.tv_nsec) {
							/* Not truncated/rewritten meanwhile. */
							if (bad++ < 10)
								printf("SIGBUS at %lld, inside i_size %lld\n",
								       (long long)k, (long long)st.st_size);
						} else {
							sigbus++;
						}
						bus_armed = 0;
						munmap(m, len);
					}
				}
				close(fd);
			}
			break;
		case 15:
			fd = open(a, O_WRONLY);
			if (fd >= 0) {
				fallocate(fd, 0, 0, 1 + rnd(&s) % 16384);
				close(fd);
			}
			break;
		case 16:
			fd = open(a, O_RDONLY);
			if (fd >= 0) {
				posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
				if (read(fd, buf, sizeof(buf)) < 0) {}
				close(fd);
			}
			break;
		case 17:
			fd = open(a, O_RDONLY);
			if (fd >= 0) {
				fsync(fd);
				close(fd);
			}
			break;
		case 18:
			renameat2(AT_FDCWD, a, AT_FDCWD, b, RENAME_NOREPLACE);
			break;
		case 19:
			stat(a, &st);
			break;
		}
		ops++;
	}
	return NULL;
}

static void *syncer(void *arg)
{
	(void)arg;
	while (!stop) {
		sync();
		usleep(200000);
	}
	return NULL;
}

static void run_dirstorm(void)
{
	pthread_t th[nthreads + 1];
	char d[4096];

	signal(SIGBUS, on_sigbus);
	for (int i = 0; i < NDIRS; i++) {
		snprintf(d, sizeof(d), "%s/d%d", base, i);
		mkdir(d, 0755);
	}
	for (long i = 0; i < nthreads; i++)
		pthread_create(&th[i], NULL, storm, (void *)i);
	pthread_create(&th[nthreads], NULL, syncer, NULL);
	for (int t = 0; t < secs; t++) {
		sleep(1);
		printf("t=%ds ops=%lu sigbus_past_eof=%lu bad=%lu\n", t + 1,
		       (unsigned long)ops, (unsigned long)sigbus,
		       (unsigned long)bad);
		fflush(stdout);
	}
	stop = 1;
	for (int i = 0; i <= nthreads; i++)
		pthread_join(th[i], NULL);
}

int main(int argc, char **argv)
{
	int opt;

	if (argc < 3) {
		fprintf(stderr, "usage: %s resident|resmmap|dirstorm <dir> [-p pairs] [-g a|t|f] "
				"[-j threads] [-n names] [-t secs] [-x op]\n", argv[0]);
		return 2;
	}
	base = argv[2];
	optind = 3;
	while ((opt = getopt(argc, argv, "p:j:n:t:x:g:")) != -1) {
		switch (opt) {
		case 'p': npairs = atoi(optarg); break;
		case 'j': nthreads = atoi(optarg); break;
		case 'n': nnames = atoi(optarg); break;
		case 't': secs = atoi(optarg); break;
		case 'x': exclude |= 1u << atoi(optarg); break;
		case 'g': grow = optarg[0]; break;
		default: return 2;
		}
	}
	mkdir(base, 0755);
	if (!strcmp(argv[1], "resident"))
		run_pairs(res_writer, res_reader, "files");
	else if (!strcmp(argv[1], "resmmap"))
		run_pairs(mm_worker, mm_syncer, "files");
	else if (!strcmp(argv[1], "dirstorm"))
		run_dirstorm();
	else
		return 2;
	printf("done, no hang, %lu data mismatches\n", (unsigned long)bad);
	return bad ? 1 : 0;
}

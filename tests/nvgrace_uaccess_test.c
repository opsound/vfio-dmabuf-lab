// SPDX-License-Identifier: GPL-2.0-only
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <linux/vfio.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define PCI_COMMAND 0x04
#define TEST_REGION VFIO_PCI_BAR4_REGION_INDEX
#define WRITER_WAIT_MS 1500

struct vfio_test_device {
	int container_fd;
	int group_fd;
	int device_fd;
	uint64_t memory_offset;
	uint64_t memory_size;
	uint64_t config_offset;
	uint64_t bar0_offset;
	uint16_t command;
};

struct io_thread_ctx {
	int fd;
	void *buffer;
	uint64_t offset;
	bool write;
	ssize_t result;
	int error;
};

struct writer_thread_ctx {
	int fd;
	uint64_t offset;
	uint16_t command;
	atomic_bool done;
	ssize_t result;
	int error;
};

struct mmap_thread_ctx {
	int fd;
	uint64_t offset;
	atomic_bool done;
	void *result;
	int error;
};

static void fail(const char *message)
{
	fprintf(stderr, "FAIL: %s: %s\n", message, strerror(errno));
	exit(EXIT_FAILURE);
}

static void fail_msg(const char *message)
{
	fprintf(stderr, "FAIL: %s\n", message);
	exit(EXIT_FAILURE);
}

static struct vfio_region_info get_region(int fd, uint32_t index)
{
	struct vfio_region_info region = {
		.argsz = sizeof(region),
		.index = index,
	};

	if (ioctl(fd, VFIO_DEVICE_GET_REGION_INFO, &region))
		fail("VFIO_DEVICE_GET_REGION_INFO");
	return region;
}

static struct vfio_test_device open_vfio(const char *bdf, const char *group)
{
	struct vfio_group_status status = { .argsz = sizeof(status) };
	struct vfio_test_device dev = {
		.container_fd = -1,
		.group_fd = -1,
		.device_fd = -1,
	};
	struct vfio_region_info memory;
	struct vfio_region_info config;
	struct vfio_region_info bar0;
	char path[128];

	dev.container_fd = open("/dev/vfio/vfio", O_RDWR);
	if (dev.container_fd < 0)
		fail("open VFIO container");
	if (ioctl(dev.container_fd, VFIO_GET_API_VERSION) != VFIO_API_VERSION)
		fail_msg("unexpected VFIO API version");
	if (ioctl(dev.container_fd, VFIO_CHECK_EXTENSION, VFIO_TYPE1_IOMMU) != 1)
		fail_msg("VFIO type1 IOMMU unavailable");

	snprintf(path, sizeof(path), "/dev/vfio/%s", group);
	dev.group_fd = open(path, O_RDWR);
	if (dev.group_fd < 0)
		fail("open VFIO group");
	if (ioctl(dev.group_fd, VFIO_GROUP_GET_STATUS, &status))
		fail("VFIO_GROUP_GET_STATUS");
	if (!(status.flags & VFIO_GROUP_FLAGS_VIABLE))
		fail_msg("VFIO group is not viable");
	if (ioctl(dev.group_fd, VFIO_GROUP_SET_CONTAINER, &dev.container_fd))
		fail("VFIO_GROUP_SET_CONTAINER");
	if (ioctl(dev.container_fd, VFIO_SET_IOMMU, VFIO_TYPE1_IOMMU))
		fail("VFIO_SET_IOMMU");

	dev.device_fd = ioctl(dev.group_fd, VFIO_GROUP_GET_DEVICE_FD, bdf);
	if (dev.device_fd < 0)
		fail("VFIO_GROUP_GET_DEVICE_FD");

	memory = get_region(dev.device_fd, TEST_REGION);
	config = get_region(dev.device_fd, VFIO_PCI_CONFIG_REGION_INDEX);
	bar0 = get_region(dev.device_fd, VFIO_PCI_BAR0_REGION_INDEX);
	if (memory.size < (uint64_t)getpagesize())
		fail_msg("nvgrace test memory region is too small");
	if (bar0.size < (uint64_t)getpagesize() ||
	    !(bar0.flags & VFIO_REGION_INFO_FLAG_MMAP))
		fail_msg("EDU BAR0 is not mappable");
	dev.memory_offset = memory.offset;
	dev.memory_size = memory.size;
	dev.config_offset = config.offset;
	dev.bar0_offset = bar0.offset;

	if (pread(dev.device_fd, &dev.command, sizeof(dev.command),
		  dev.config_offset + PCI_COMMAND) != sizeof(dev.command))
		fail("read PCI command");

	printf("device=%s group=%s usemem_size=%#llx command=%#x\n",
	       bdf, group, (unsigned long long)dev.memory_size, dev.command);
	return dev;
}

static void close_vfio(struct vfio_test_device *dev)
{
	close(dev->device_fd);
	close(dev->group_fd);
	close(dev->container_fd);
}

static void *io_thread(void *opaque)
{
	struct io_thread_ctx *ctx = opaque;

	errno = 0;
	if (ctx->write)
		ctx->result = pwrite(ctx->fd, ctx->buffer, getpagesize(),
				     ctx->offset);
	else
		ctx->result = pread(ctx->fd, ctx->buffer, getpagesize(),
				    ctx->offset);
	ctx->error = errno;
	return NULL;
}

static void *writer_thread(void *opaque)
{
	struct writer_thread_ctx *ctx = opaque;

	errno = 0;
	ctx->result = pwrite(ctx->fd, &ctx->command, sizeof(ctx->command),
			     ctx->offset + PCI_COMMAND);
	ctx->error = errno;
	atomic_store_explicit(&ctx->done, true, memory_order_release);
	return NULL;
}

static void *mmap_thread(void *opaque)
{
	struct mmap_thread_ctx *ctx = opaque;

	errno = 0;
	ctx->result = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE,
			   MAP_SHARED, ctx->fd, ctx->offset);
	ctx->error = errno;
	if (ctx->result != MAP_FAILED)
		munmap(ctx->result, getpagesize());
	atomic_store_explicit(&ctx->done, true, memory_order_release);
	return NULL;
}

static bool wait_for_done(atomic_bool *done)
{
	struct timespec delay = { .tv_nsec = 10 * 1000 * 1000 };
	int elapsed;

	for (elapsed = 0; elapsed < WRITER_WAIT_MS; elapsed += 10) {
		if (atomic_load_explicit(done, memory_order_acquire))
			return true;
		nanosleep(&delay, NULL);
	}
	return atomic_load_explicit(done, memory_order_acquire);
}

static void resolve_fault(int uffd, void *page)
{
	struct uffdio_copy copy = {
		.dst = (uintptr_t)page,
		.len = getpagesize(),
	};
	void *source;

	source = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE,
		      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (source == MAP_FAILED)
		fail("mmap userfault source");
	memset(source, 0x5a, getpagesize());
	copy.src = (uintptr_t)source;
	if (ioctl(uffd, UFFDIO_COPY, &copy))
		fail("UFFDIO_COPY");
	munmap(source, getpagesize());
}

static void run_fault_case(struct vfio_test_device *dev, bool write,
			   bool expect_writer_blocked)
{
	struct uffdio_register reg = {
		.mode = UFFDIO_REGISTER_MODE_MISSING,
	};
	struct uffdio_api api = { .api = UFFD_API };
	struct uffd_msg event;
	struct pollfd pollfd;
	struct io_thread_ctx io = {
		.fd = dev->device_fd,
		.offset = dev->memory_offset,
		.write = write,
	};
	struct writer_thread_ctx writer = {
		.fd = dev->device_fd,
		.offset = dev->config_offset,
		.command = dev->command,
	};
	pthread_t io_tid;
	pthread_t writer_tid;
	bool writer_completed;
	int uffd;

	io.buffer = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (io.buffer == MAP_FAILED)
		fail("mmap test page");

	/* The fault originates in kernel uaccess, so USER_MODE_ONLY is invalid. */
	uffd = syscall(SYS_userfaultfd, O_CLOEXEC | O_NONBLOCK);
	if (uffd < 0)
		fail("userfaultfd");
	if (ioctl(uffd, UFFDIO_API, &api))
		fail("UFFDIO_API");
	reg.range.start = (uintptr_t)io.buffer;
	reg.range.len = getpagesize();
	if (ioctl(uffd, UFFDIO_REGISTER, &reg))
		fail("UFFDIO_REGISTER");

	atomic_init(&writer.done, false);
	if (pthread_create(&io_tid, NULL, io_thread, &io))
		fail_msg("pthread_create I/O thread");

	pollfd.fd = uffd;
	pollfd.events = POLLIN;
	if (poll(&pollfd, 1, 5000) != 1)
		fail_msg("timed out waiting for userfaultfd event");
	if (read(uffd, &event, sizeof(event)) != sizeof(event))
		fail("read userfaultfd event");
	if (event.event != UFFD_EVENT_PAGEFAULT)
		fail_msg("unexpected userfaultfd event");

	if (pthread_create(&writer_tid, NULL, writer_thread, &writer))
		fail_msg("pthread_create config writer");
	writer_completed = wait_for_done(&writer.done);

	printf("%s: writer %s while user fault is unresolved\n",
	       write ? "write" : "read",
	       writer_completed ? "completed" : "blocked");

	resolve_fault(uffd, io.buffer);
	pthread_join(io_tid, NULL);
	pthread_join(writer_tid, NULL);

	if (writer.result != sizeof(writer.command)) {
		errno = writer.error;
		fail("PCI command write");
	}
	if (io.result != getpagesize()) {
		errno = io.error;
		fail(write ? "nvgrace write" : "nvgrace read");
	}
	if (writer_completed == expect_writer_blocked)
		fail_msg(expect_writer_blocked ?
			 "writer unexpectedly completed in legacy mode" :
			 "writer remained blocked in fixed mode");

	reg.range.start = (uintptr_t)io.buffer;
	reg.range.len = getpagesize();
	if (ioctl(uffd, UFFDIO_UNREGISTER, &reg.range))
		fail("UFFDIO_UNREGISTER");
	close(uffd);
	munmap(io.buffer, getpagesize());
}

static void run_export_case(struct vfio_test_device *dev,
			    bool expect_mmap_blocked)
{
	struct uffdio_register reg = {
		.mode = UFFDIO_REGISTER_MODE_MISSING,
	};
	struct uffdio_api api = { .api = UFFD_API };
	struct uffd_msg event;
	struct pollfd pollfd;
	struct io_thread_ctx io = {
		.fd = dev->device_fd,
		.offset = dev->memory_offset,
	};
	struct writer_thread_ctx writer = {
		.fd = dev->device_fd,
		.offset = dev->config_offset,
		.command = dev->command,
	};
	struct mmap_thread_ctx map = {
		.fd = dev->device_fd,
		.offset = dev->bar0_offset,
	};
	struct timespec settle = { .tv_nsec = 100 * 1000 * 1000 };
	pthread_t io_tid;
	pthread_t writer_tid;
	pthread_t mmap_tid;
	bool writer_completed;
	bool mmap_completed;
	int uffd;

	io.buffer = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (io.buffer == MAP_FAILED)
		fail("mmap test page");

	uffd = syscall(SYS_userfaultfd, O_CLOEXEC | O_NONBLOCK);
	if (uffd < 0)
		fail("userfaultfd");
	if (ioctl(uffd, UFFDIO_API, &api))
		fail("UFFDIO_API");
	reg.range.start = (uintptr_t)io.buffer;
	reg.range.len = getpagesize();
	if (ioctl(uffd, UFFDIO_REGISTER, &reg))
		fail("UFFDIO_REGISTER");

	atomic_init(&writer.done, false);
	atomic_init(&map.done, false);
	if (pthread_create(&io_tid, NULL, io_thread, &io))
		fail_msg("pthread_create I/O thread");

	pollfd.fd = uffd;
	pollfd.events = POLLIN;
	if (poll(&pollfd, 1, 5000) != 1)
		fail_msg("timed out waiting for userfaultfd event");
	if (read(uffd, &event, sizeof(event)) != sizeof(event))
		fail("read userfaultfd event");
	if (event.event != UFFD_EVENT_PAGEFAULT)
		fail_msg("unexpected userfaultfd event");

	/*
	 * Queue a memory_lock writer behind the faulting nvgrace read before
	 * mmap enters DMA-BUF export.  A same-value MSE write is enough to take
	 * memory_lock(W), without changing the final device state.
	 */
	if (pthread_create(&writer_tid, NULL, writer_thread, &writer))
		fail_msg("pthread_create config writer");
	nanosleep(&settle, NULL);
	writer_completed = atomic_load_explicit(&writer.done,
						memory_order_acquire);
	if (pthread_create(&mmap_tid, NULL, mmap_thread, &map))
		fail_msg("pthread_create mmap thread");
	mmap_completed = wait_for_done(&map.done);

	printf("export: writer %s, mmap %s while user fault is unresolved\n",
	       writer_completed ? "completed" : "blocked",
	       mmap_completed ? "completed" : "blocked");
	if (mmap_completed == expect_mmap_blocked)
		fail_msg(expect_mmap_blocked ?
			 "mmap unexpectedly completed with legacy export locking" :
			 "mmap blocked with shadow-state export locking");

	resolve_fault(uffd, io.buffer);
	pthread_join(io_tid, NULL);
	pthread_join(writer_tid, NULL);
	pthread_join(mmap_tid, NULL);

	if (writer_completed)
		fail_msg("config writer did not queue behind nvgrace read");
	if (writer.result != sizeof(writer.command)) {
		errno = writer.error;
		fail("PCI command write");
	}
	if (io.result != getpagesize()) {
		errno = io.error;
		fail("nvgrace read");
	}
	if (map.result == MAP_FAILED) {
		errno = map.error;
		fail("VFIO BAR mmap");
	}
	reg.range.start = (uintptr_t)io.buffer;
	reg.range.len = getpagesize();
	if (ioctl(uffd, UFFDIO_UNREGISTER, &reg.range))
		fail("UFFDIO_UNREGISTER");
	close(uffd);
	munmap(io.buffer, getpagesize());
}

int main(int argc, char **argv)
{
	struct vfio_test_device dev;
	bool expect_blocked;

	if (argc != 5 || (strcmp(argv[3], "uaccess") &&
			 strcmp(argv[3], "export")) ||
	    (strcmp(argv[4], "blocked") && strcmp(argv[4], "progress"))) {
		fprintf(stderr,
			"usage: %s BDF GROUP uaccess|export blocked|progress\n",
			argv[0]);
		return EXIT_FAILURE;
	}
	expect_blocked = !strcmp(argv[4], "blocked");

	dev = open_vfio(argv[1], argv[2]);
	if (!strcmp(argv[3], "uaccess")) {
		run_fault_case(&dev, false, expect_blocked);
		run_fault_case(&dev, true, expect_blocked);
	} else {
		run_export_case(&dev, expect_blocked);
	}
	close_vfio(&dev);

	printf("PASS: nvgrace %s %s mode\n", argv[3], argv[4]);
	return EXIT_SUCCESS;
}

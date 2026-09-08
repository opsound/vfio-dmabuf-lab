// SPDX-License-Identifier: GPL-2.0-only
#define _GNU_SOURCE

/*
 * Reproducer for the VFIO BAR fault/reset lock inversion reported at:
 * https://lore.kernel.org/20260821193502.92431-1-vipinsh@google.com/
 *
 * The first access to each mmap establishes mmap_lock -> memory_lock in
 * vfio_pci_mmap_huge_fault().  VFIO_DEVICE_RESET then establishes
 * memory_lock -> group->mutex through pci_dev_reset_iommu_prepare().
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <linux/vfio.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

struct bar_mapping {
	void *address;
	size_t length;
	unsigned int index;
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

static int open_vfio_device(const char *bdf, const char *group,
			    int *container_fd, int *group_fd)
{
	struct vfio_group_status status = { .argsz = sizeof(status) };
	char path[128];
	int device_fd;

	*container_fd = open("/dev/vfio/vfio", O_RDWR);
	if (*container_fd < 0)
		fail("open VFIO container");
	if (ioctl(*container_fd, VFIO_GET_API_VERSION) != VFIO_API_VERSION)
		fail_msg("unexpected VFIO API version");
	if (ioctl(*container_fd, VFIO_CHECK_EXTENSION, VFIO_TYPE1_IOMMU) != 1)
		fail_msg("VFIO type1 IOMMU unavailable");

	snprintf(path, sizeof(path), "/dev/vfio/%s", group);
	*group_fd = open(path, O_RDWR);
	if (*group_fd < 0)
		fail("open VFIO group");
	if (ioctl(*group_fd, VFIO_GROUP_GET_STATUS, &status))
		fail("VFIO_GROUP_GET_STATUS");
	if (!(status.flags & VFIO_GROUP_FLAGS_VIABLE))
		fail_msg("VFIO group is not viable");
	if (ioctl(*group_fd, VFIO_GROUP_SET_CONTAINER, container_fd))
		fail("VFIO_GROUP_SET_CONTAINER");
	if (ioctl(*container_fd, VFIO_SET_IOMMU, VFIO_TYPE1_IOMMU))
		fail("VFIO_SET_IOMMU");

	device_fd = ioctl(*group_fd, VFIO_GROUP_GET_DEVICE_FD, bdf);
	if (device_fd < 0)
		fail("VFIO_GROUP_GET_DEVICE_FD");
	return device_fd;
}

static void prime_perf_mmap_lock_dependency(void)
{
	struct perf_event_attr attr = {
		.type = PERF_TYPE_SOFTWARE,
		.size = sizeof(attr),
		.config = PERF_COUNT_SW_CPU_CLOCK,
	};
	void *result;
	int perf_fd;

	/*
	 * Leave the destination page untouched so perf_read() faults it while
	 * holding the perf event context mutex.  The event must be CPU-bound
	 * (pid -1): only per-CPU event contexts use the cpuctx_mutex lockdep
	 * class that the hard-lockup CPU-hotplug callback also acquires.
	 * Together, this deterministically records the middle of the
	 * dependency chain reported by Vipin.
	 */
	perf_fd = syscall(SYS_perf_event_open, &attr, -1, 0, -1, 0);
	if (perf_fd < 0)
		fail("perf_event_open");
	result = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE,
		      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (result == MAP_FAILED)
		fail("mmap perf read buffer");
	if (read(perf_fd, result, sizeof(uint64_t)) != sizeof(uint64_t))
		fail("read perf event");
	if (munmap(result, getpagesize()))
		fail("munmap perf read buffer");
	close(perf_fd);
}

static void prime_kernfs_mmap_lock_dependency(void)
{
	char dots[64];
	void *result;
	long first;
	long second;
	int directory_fd;

	/*
	 * The report also observed cpu_hotplug_lock -> kernfs_rwsem ->
	 * mmap_lock.  kernfs_fop_readdir() emits "." and ".." before taking
	 * kernfs_rwsem, so drain the dot entries with a small first call and
	 * then read the remaining entries into a fresh page.  The second
	 * call's page fault happens while kernfs_rwsem is held for read, so
	 * the minimal guest records the latter edge.
	 */
	directory_fd = open("/sys/devices/system/cpu", O_RDONLY | O_DIRECTORY);
	if (directory_fd < 0)
		fail("open CPU sysfs directory");
	first = syscall(SYS_getdents64, directory_fd, dots, sizeof(dots));
	if (first <= 0)
		fail("getdents64 CPU sysfs dot entries");
	result = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE,
		      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (result == MAP_FAILED)
		fail("mmap getdents64 buffer");
	second = syscall(SYS_getdents64, directory_fd, result, getpagesize());
	printf("VFIO_RESET_KERNFS_BYTES=first:%ld second:%ld\n", first,
	       second);
	if (second < 0)
		fail("getdents64 CPU sysfs directory");
	if (!second)
		fprintf(stderr,
			"WARN: no sysfs entries left for kernfs priming\n");
	if (munmap(result, getpagesize()))
		fail("munmap getdents64 buffer");
	close(directory_fd);
}

static uint16_t read_u16(const unsigned char *config, unsigned int offset)
{
	return (uint16_t)(config[offset] |
			  ((unsigned int)config[offset + 1] << 8));
}

static uint32_t read_u32(const unsigned char *config, unsigned int offset)
{
	return (uint32_t)config[offset] |
	       ((uint32_t)config[offset + 1] << 8) |
	       ((uint32_t)config[offset + 2] << 16) |
	       ((uint32_t)config[offset + 3] << 24);
}

static void check_pci_reset_caps(const char *bdf)
{
	unsigned char config[4096];
	unsigned int offset;
	unsigned int iterations;
	bool pcie = false;
	bool ats = false;
	bool flr = false;
	char path[128];
	ssize_t length;
	int fd;

	snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/config", bdf);
	fd = open(path, O_RDONLY);
	if (fd < 0)
		fail("open PCI config space");
	length = read(fd, config, sizeof(config));
	if (length < 0)
		fail("read PCI config space");
	close(fd);

	if (length >= 0x38 && (read_u16(config, 0x06) & 0x10)) {
		offset = config[0x34] & 0xfc;
		iterations = 0;
		while (offset && length >= (ssize_t)(offset + 4) &&
		       iterations++ < 64) {
			if (config[offset] == 0x10) {
				pcie = true;
				flr = (read_u32(config, offset + 4) &
				       0x10000000U) != 0;
			}
			offset = config[offset + 1] & 0xfc;
		}
	}
	if (length >= 0x104) {
		offset = 0x100;
		iterations = 0;
		while (offset && length >= (ssize_t)(offset + 4) &&
		       iterations++ < 64) {
			uint32_t header = read_u32(config, offset);

			if ((header & 0xffff) == 0x000f)
				ats = true;
			offset = (header >> 20) & 0xffc;
		}
	}

	printf("VFIO_RESET_PCI_CAPS=%04x:%04x pcie=%s ats=%s flr=%s\n",
	       length >= 4 ? read_u16(config, 0x00) : 0,
	       length >= 4 ? read_u16(config, 0x02) : 0,
	       pcie ? "yes" : "no", ats ? "yes" : "no",
	       flr ? "yes" : "no");
	if (!ats)
		fail_msg("VFIO device lacks ATS; reset cannot take group->mutex");
}

static unsigned int fault_mmapable_bars(int device_fd,
					struct bar_mapping *mappings)
{
	unsigned int count = 0;
	unsigned int index;

	for (index = VFIO_PCI_BAR0_REGION_INDEX;
	     index <= VFIO_PCI_BAR5_REGION_INDEX; index++) {
		struct vfio_region_info region = {
			.argsz = sizeof(region),
			.index = index,
		};
		volatile unsigned char value;
		void *address;

		if (ioctl(device_fd, VFIO_DEVICE_GET_REGION_INFO, &region))
			continue;
		if (!(region.flags & VFIO_REGION_INFO_FLAG_MMAP) || !region.size ||
		    region.size > SIZE_MAX)
			continue;

		address = mmap(NULL, (size_t)region.size, PROT_READ | PROT_WRITE,
			       MAP_SHARED, device_fd, (off_t)region.offset);
		if (address == MAP_FAILED)
			continue;

		printf("VFIO_RESET_FAULT_BAR=%u address=%p size=%#llx\n",
		       index, address, (unsigned long long)region.size);
		value = *(volatile unsigned char *)address;
		(void)value;

		mappings[count].address = address;
		mappings[count].length = (size_t)region.size;
		mappings[count].index = index;
		count++;
	}

	return count;
}

int main(int argc, char **argv)
{
	struct bar_mapping mappings[VFIO_PCI_BAR5_REGION_INDEX + 1] = {};
	struct vfio_device_info info = { .argsz = sizeof(info) };
	unsigned int mapping_count;
	unsigned int index;
	int container_fd = -1;
	int group_fd = -1;
	int device_fd;

	if (argc != 3) {
		fprintf(stderr, "usage: %s PCI_BDF IOMMU_GROUP\n", argv[0]);
		return EXIT_FAILURE;
	}

	check_pci_reset_caps(argv[1]);
	device_fd = open_vfio_device(argv[1], argv[2], &container_fd,
				     &group_fd);
	if (ioctl(device_fd, VFIO_DEVICE_GET_INFO, &info))
		fail("VFIO_DEVICE_GET_INFO");
	if (!(info.flags & VFIO_DEVICE_FLAGS_RESET))
		fail_msg("VFIO device does not support reset");

	prime_perf_mmap_lock_dependency();
	prime_kernfs_mmap_lock_dependency();
	mapping_count = fault_mmapable_bars(device_fd, mappings);
	if (!mapping_count)
		fail_msg("VFIO device has no faultable mmap BAR");

	printf("VFIO_RESET_IOCTL_START mappings=%u\n", mapping_count);
	if (ioctl(device_fd, VFIO_DEVICE_RESET))
		fail("VFIO_DEVICE_RESET");
	printf("VFIO_RESET_IOCTL_DONE\n");

	for (index = 0; index < mapping_count; index++)
		if (munmap(mappings[index].address, mappings[index].length))
			fail("munmap VFIO BAR");
	close(device_fd);
	close(group_fd);
	close(container_fd);
	return EXIT_SUCCESS;
}

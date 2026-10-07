// SPDX-License-Identifier: GPL-2.0-only
/*
 * Shared VFIO cdev + iommufd setup for the lab's guest test programs.
 * Included with #include "vfio_test_common.h"; gcc resolves the quoted
 * include from this file's own directory, so no extra -I flag is needed.
 */
#ifndef VFIO_TEST_COMMON_H
#define VFIO_TEST_COMMON_H

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/iommufd.h>
#include <linux/vfio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

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

/* The PCI device's cdev is the only vfioN entry in its vfio-dev dir. */
static void vfio_cdev_path(const char *bdf, char *path, size_t size)
{
	char dir_path[PATH_MAX];
	struct dirent *entry;
	DIR *dir;

	snprintf(dir_path, sizeof(dir_path),
		 "/sys/bus/pci/devices/%s/vfio-dev", bdf);
	dir = opendir(dir_path);
	if (!dir)
		fail("open vfio-dev directory");
	while ((entry = readdir(dir))) {
		if (!strncmp(entry->d_name, "vfio", 4)) {
			snprintf(path, size, "/dev/vfio/devices/%s",
				 entry->d_name);
			closedir(dir);
			return;
		}
	}
	closedir(dir);
	fail_msg("no VFIO cdev for device");
}

/*
 * Open the device's cdev, bind it to a new iommufd and attach it to an
 * empty IOAS.  The caller closes the device fd before *iommufd.
 */
static int open_vfio_device(const char *bdf, int *iommufd)
{
	struct vfio_device_bind_iommufd bind = { .argsz = sizeof(bind) };
	struct vfio_device_attach_iommufd_pt attach = {
		.argsz = sizeof(attach),
	};
	struct iommu_ioas_alloc alloc = { .size = sizeof(alloc) };
	char path[PATH_MAX];
	int device_fd;

	vfio_cdev_path(bdf, path, sizeof(path));
	device_fd = open(path, O_RDWR);
	if (device_fd < 0)
		fail("open VFIO cdev");

	*iommufd = open("/dev/iommu", O_RDWR);
	if (*iommufd < 0)
		fail("open /dev/iommu");

	bind.iommufd = *iommufd;
	if (ioctl(device_fd, VFIO_DEVICE_BIND_IOMMUFD, &bind))
		fail("VFIO_DEVICE_BIND_IOMMUFD");
	if (ioctl(*iommufd, IOMMU_IOAS_ALLOC, &alloc))
		fail("IOMMU_IOAS_ALLOC");
	attach.pt_id = alloc.out_ioas_id;
	if (ioctl(device_fd, VFIO_DEVICE_ATTACH_IOMMUFD_PT, &attach))
		fail("VFIO_DEVICE_ATTACH_IOMMUFD_PT");
	return device_fd;
}

#endif /* VFIO_TEST_COMMON_H */

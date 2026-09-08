// SPDX-License-Identifier: GPL-2.0-only
/*
 * Shared VFIO container setup for the lab's guest test programs.
 * Included with #include "vfio_test_common.h"; gcc resolves the quoted
 * include from this file's own directory, so no extra -I flag is needed.
 */
#ifndef VFIO_TEST_COMMON_H
#define VFIO_TEST_COMMON_H

#include <errno.h>
#include <fcntl.h>
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

#endif /* VFIO_TEST_COMMON_H */

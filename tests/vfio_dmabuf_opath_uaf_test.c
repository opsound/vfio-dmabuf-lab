// SPDX-License-Identifier: GPL-2.0-only
#define _GNU_SOURCE

/*
 * Export a VFIO dma-buf, hold its dentry with an O_PATH fd, close the
 * dma-buf fd, then close the device.  The dma-buf's file is freed but
 * its ->release() waits for the O_PATH fd, so vfio_pci_dma_buf_cleanup()
 * walks an entry whose dmabuf->file points at freed memory.
 *
 * The sleep lets CONFIG_SLUB_RCU_DEBUG free the struct file after an
 * RCU grace period, so KASAN reports the access.
 */

#include <stdint.h>

#include "vfio_test_common.h"

int main(int argc, char **argv)
{
	struct {
		struct vfio_device_feature feature;
		struct vfio_device_feature_dma_buf dmabuf;
		struct vfio_region_dma_range range;
	} buf = {
		.feature.argsz = sizeof(buf),
		.feature.flags = VFIO_DEVICE_FEATURE_GET |
				 VFIO_DEVICE_FEATURE_DMA_BUF,
		.dmabuf.region_index = VFIO_PCI_BAR0_REGION_INDEX,
		.dmabuf.open_flags = O_RDWR,
		.dmabuf.nr_ranges = 1,
		.range.length = 4096,
	};
	int container_fd, group_fd, dev_fd, dmabuf_fd;
	char path[64];

	if (argc != 3)
		fail_msg("usage: vfio_dmabuf_opath_uaf_test PCI_BDF IOMMU_GROUP");
	dev_fd = open_vfio_device(argv[1], argv[2], &container_fd, &group_fd);

	dmabuf_fd = ioctl(dev_fd, VFIO_DEVICE_FEATURE, &buf);
	if (dmabuf_fd < 0)
		fail("export dma-buf");
	snprintf(path, sizeof(path), "/proc/self/fd/%d", dmabuf_fd);
	if (open(path, O_PATH) < 0)
		fail("open O_PATH");
	close(dmabuf_fd);
	usleep(100 * 1000);
	close(dev_fd);

	printf("VFIO_OPATH_UAF_DONE\n");
	return EXIT_SUCCESS;
}

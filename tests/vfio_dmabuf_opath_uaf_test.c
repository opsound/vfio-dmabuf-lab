// SPDX-License-Identifier: GPL-2.0-only
#define _GNU_SOURCE

/*
 * Export a VFIO dma-buf, hold its dentry with an O_PATH fd, close the
 * dma-buf fd, wait for an RCU grace period, then disable PCI memory
 * decoding so vfio_pci_dma_buf_move() walks vdev->dmabufs.
 *
 * With CONFIG_SLUB_RCU_DEBUG, KASAN poisons the freed struct file after
 * the grace period, so an unfixed kernel reports a use-after-free from
 * get_file_active(&priv->dmabuf->file). A second dma-buf stays open
 * throughout so the walk also visits a live entry.
 *
 * Finally, keep one released dma-buf held across the device close, so
 * vfio_pci_dma_buf_cleanup() has to deal with an entry whose file is
 * gone, and drop the O_PATH fd afterwards so ->release() runs last.
 */

#include <stdint.h>
#include <time.h>

#include "vfio_test_common.h"

#define PCI_COMMAND 0x04
#define PCI_COMMAND_MEMORY 0x2
#define ITERATIONS 10

static int export_dmabuf(int dev_fd, uint32_t region, uint64_t len)
{
	struct {
		struct vfio_device_feature feature;
		struct vfio_device_feature_dma_buf dmabuf;
		struct vfio_region_dma_range range;
	} buf = {
		.feature.argsz = sizeof(buf),
		.feature.flags = VFIO_DEVICE_FEATURE_GET |
				 VFIO_DEVICE_FEATURE_DMA_BUF,
		.dmabuf.region_index = region,
		.dmabuf.open_flags = O_RDWR | O_CLOEXEC,
		.dmabuf.nr_ranges = 1,
		.range.length = len,
	};

	return ioctl(dev_fd, VFIO_DEVICE_FEATURE, &buf);
}

static void write_cmd(int dev_fd, uint64_t cfg, uint16_t cmd)
{
	if (pwrite(dev_fd, &cmd, sizeof(cmd), cfg + PCI_COMMAND) != sizeof(cmd))
		fail("write PCI_COMMAND");
}

int main(int argc, char **argv)
{
	struct vfio_region_info region, config = { .argsz = sizeof(config) };
	struct timespec gp = { .tv_nsec = 200 * 1000 * 1000 };
	int container_fd, group_fd, dev_fd, live_fd, held_fd, held_opath_fd;
	char held_path[64];
	unsigned int index;
	uint16_t cmd;
	int i;

	if (argc != 3)
		fail_msg("usage: vfio_dmabuf_opath_uaf_test PCI_BDF IOMMU_GROUP");
	dev_fd = open_vfio_device(argv[1], argv[2], &container_fd, &group_fd);

	for (index = VFIO_PCI_BAR0_REGION_INDEX;
	     index <= VFIO_PCI_BAR5_REGION_INDEX; index++) {
		memset(&region, 0, sizeof(region));
		region.argsz = sizeof(region);
		region.index = index;
		if (!ioctl(dev_fd, VFIO_DEVICE_GET_REGION_INFO, &region) &&
		    (region.flags & VFIO_REGION_INFO_FLAG_MMAP) &&
		    region.size >= (uint64_t)getpagesize())
			break;
	}
	if (index > VFIO_PCI_BAR5_REGION_INDEX)
		fail_msg("no mmapable BAR");

	config.index = VFIO_PCI_CONFIG_REGION_INDEX;
	if (ioctl(dev_fd, VFIO_DEVICE_GET_REGION_INFO, &config))
		fail("VFIO_DEVICE_GET_REGION_INFO config");
	if (pread(dev_fd, &cmd, sizeof(cmd), config.offset + PCI_COMMAND) !=
	    sizeof(cmd))
		fail("read PCI_COMMAND");

	live_fd = export_dmabuf(dev_fd, index, getpagesize());
	if (live_fd < 0)
		fail("export live dma-buf");
	printf("VFIO_OPATH_UAF_BAR=%u command=%#x\n", index, cmd);

	for (i = 0; i < ITERATIONS; i++) {
		char path[64];
		int fd, opath_fd;

		fd = export_dmabuf(dev_fd, index, getpagesize());
		if (fd < 0)
			fail("export dma-buf");
		snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
		opath_fd = open(path, O_PATH | O_CLOEXEC);
		if (opath_fd < 0)
			fail("open O_PATH hold");
		close(fd);
		nanosleep(&gp, NULL);

		write_cmd(dev_fd, config.offset, cmd & ~PCI_COMMAND_MEMORY);
		write_cmd(dev_fd, config.offset, cmd);
		close(opath_fd);
	}

	held_fd = export_dmabuf(dev_fd, index, getpagesize());
	if (held_fd < 0)
		fail("export held dma-buf");
	snprintf(held_path, sizeof(held_path), "/proc/self/fd/%d", held_fd);
	held_opath_fd = open(held_path, O_PATH | O_CLOEXEC);
	if (held_opath_fd < 0)
		fail("open O_PATH hold across close");
	close(held_fd);
	nanosleep(&gp, NULL);

	close(live_fd);
	close(dev_fd);
	close(group_fd);
	close(container_fd);
	nanosleep(&gp, NULL);
	close(held_opath_fd);
	nanosleep(&gp, NULL);
	printf("VFIO_OPATH_UAF_DONE iters=%d\n", ITERATIONS);
	return EXIT_SUCCESS;
}

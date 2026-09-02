// SPDX-License-Identifier: GPL-2.0-only
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define BDF "0000:01:00.0"

static int write_text(const char *path, const char *value)
{
	ssize_t length = strlen(value);
	int fd;

	fd = open(path, O_WRONLY);
	if (fd < 0) {
		perror(path);
		return -1;
	}
	if (write(fd, value, length) != length) {
		perror(path);
		close(fd);
		return -1;
	}
	close(fd);
	return 0;
}

static int mount_one(const char *source, const char *target, const char *type)
{
	if (!mount(source, target, type, 0, NULL) || errno == EBUSY)
		return 0;
	perror(target);
	return -1;
}

static int link_basename(const char *path, char *result, size_t result_size)
{
	char target[PATH_MAX];
	char *base;
	ssize_t length;

	length = readlink(path, target, sizeof(target) - 1);
	if (length < 0) {
		perror(path);
		return -1;
	}
	target[length] = '\0';
	base = strrchr(target, '/');
	base = base ? base + 1 : target;
	if (strlen(base) + 1 > result_size)
		return -1;
	strcpy(result, base);
	return 0;
}

static int bind_driver(const char *driver)
{
	char path[PATH_MAX];
	char actual[128];

	snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s", BDF);
	if (access(path, F_OK)) {
		fprintf(stderr, "PCI device %s not found\n", BDF);
		return -1;
	}
	snprintf(path, sizeof(path),
		 "/sys/bus/pci/devices/%s/driver_override", BDF);
	if (write_text(path, driver))
		return -1;
	if (write_text("/sys/bus/pci/drivers_probe", BDF))
		return -1;
	snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/driver", BDF);
	if (link_basename(path, actual, sizeof(actual)))
		return -1;
	if (strcmp(actual, driver)) {
		fprintf(stderr, "%s bound to %s, expected %s\n", BDF, actual,
			driver);
		return -1;
	}
	return 0;
}

static int iommu_group(char *group, size_t group_size)
{
	char path[PATH_MAX];

	snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/iommu_group", BDF);
	return link_basename(path, group, group_size);
}

static int run_program(char *const argv[])
{
	int status;
	pid_t pid;

	pid = fork();
	if (pid < 0) {
		perror("fork");
		return -1;
	}
	if (!pid) {
		execv(argv[0], argv);
		perror(argv[0]);
		_exit(127);
	}
	if (waitpid(pid, &status, 0) != pid) {
		perror("waitpid");
		return -1;
	}
	if (!WIFEXITED(status)) {
		fprintf(stderr, "%s terminated abnormally\n", argv[0]);
		return -1;
	}
	return WEXITSTATUS(status);
}

static int run_nvgrace_case(const char *group, const char *operation,
			    const char *expectation)
{
	char *const argv[] = {
		"/nvgrace_uaccess_test", BDF, (char *)group,
		(char *)operation, (char *)expectation, NULL,
	};

	return run_program(argv);
}

static int prepare_nvgrace(char *group, size_t group_size)
{
	if (access("/sys/module/nvgrace_gpu_vfio_pci", F_OK)) {
		fprintf(stderr, "nvgrace driver is not built in\n");
		return -1;
	}
	if (bind_driver("nvgrace_gpu_vfio_pci") ||
	    iommu_group(group, group_size))
		return -1;
	printf("NVGRACE_TEST_BDF=%s group=%s\n", BDF, group);
	return 0;
}

static int run_nvgrace_v6(void)
{
	char group[32];
	int iteration;

	if (prepare_nvgrace(group, sizeof(group)))
		return 1;

	/*
	 * The variant driver may legitimately hold memory_lock across user
	 * access.  Confirm that a config writer queues behind that access.
	 */
	if (run_nvgrace_case(group, "uaccess", "blocked"))
		return 1;

	/* Prove mmap/export progresses even with that writer queued. */
	for (iteration = 1; iteration <= 10; iteration++)
		if (run_nvgrace_case(group, "export", "progress"))
			return 1;
	return 0;
}

static int run_dmabuf(void)
{
	char group[32];
	int iteration;

	if (bind_driver("vfio-pci") || iommu_group(group, sizeof(group)))
		return 1;
	printf("VFIO_DMABUF_BDF=%s group=%s\n", BDF, group);
	for (iteration = 1; iteration <= 10; iteration++) {
		char *const argv[] = {
			"/vfio_dmabuf_mmap_test", "-r", BDF, "-g", group, NULL,
		};

		printf("VFIO_DMABUF_ITERATION=%d\n", iteration);
		if (run_program(argv))
			return 1;
	}
	return 0;
}

static int run_nvgrace_v5(void)
{
	char group[32];

	if (prepare_nvgrace(group, sizeof(group)))
		return 1;
	printf("NVGRACE_V5_CONTROL_START bdf=%s group=%s\n", BDF,
	       group);
	if (run_nvgrace_case(group, "export", "blocked"))
		return 1;
	fprintf(stderr, "v5 export unexpectedly returned\n");
	return 1;
}

static void finish(const char *marker, int status)
{
	printf("%s=%s\n", marker, status ? "FAIL" : "PASS");
	fflush(NULL);
	sync();
	if (write_text("/proc/sysrq-trigger", "o"))
		reboot(RB_POWER_OFF);
	for (;;)
		pause();
}

int main(int argc, char **argv)
{
	const char *mode;
	int status = 1;

	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
	mkdir("/proc", 0755);
	mkdir("/sys", 0755);
	mkdir("/dev", 0755);
	if (mount_one("proc", "/proc", "proc") ||
	    mount_one("sysfs", "/sys", "sysfs") ||
	    mount_one("devtmpfs", "/dev", "devtmpfs"))
		finish("VFIO_LAB_RESULT", 1);

	if (argc != 2) {
		fprintf(stderr, "usage: /init TEST_MODE\n");
		finish("VFIO_LAB_RESULT", 1);
	}
	mode = argv[1];
	printf("VFIO_TEST_MODE=%s\n", mode);

	if (!strcmp(mode, "nvgrace-v6")) {
		status = run_nvgrace_v6();
		finish("NVGRACE_V6_RESULT", status);
	} else if (!strcmp(mode, "nvgrace-v5")) {
		status = run_nvgrace_v5();
		finish("NVGRACE_V5_RESULT", status);
	} else if (!strcmp(mode, "dmabuf")) {
		status = run_dmabuf();
		finish("VFIO_DMABUF_RESULT", status);
	} else {
		fprintf(stderr, "unknown vfio_test mode: %s\n", mode);
		finish("VFIO_LAB_RESULT", 1);
	}
	return 1;
}

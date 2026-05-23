# Build RunCam Wifilink Images

This guide explains how to build the `runcam_wifilink` image locally with
Podman. This is the recommended path on macOS because Buildroot expects a Linux
userspace.

## Requirements

- macOS or Linux
- Podman
- At least 50 GB for the Podman machine
- 8 GB RAM minimum

On macOS:

```sh
brew install podman
podman machine init --cpus 6 --memory 8192 --disk-size 50
podman machine start
```

Check that the VM has enough real free space:

```sh
podman machine ssh podman-machine-default df -h /
```

If it still shows a 20 GB filesystem after creating or resizing the VM, grow the
partition and filesystem inside the VM:

```sh
podman machine ssh podman-machine-default sudo growpart /dev/vda 4
podman machine ssh podman-machine-default sudo xfs_growfs /
podman machine ssh podman-machine-default df -h /
```

## Build

From the repository root:

```sh
./build-podman.sh runcam_wifilink_defconfig 2>&1 | tee build-runcam.log
```

The wrapper builds inside Podman Linux volumes and copies final artifacts back
to the host.

At the end of a successful build, the log should contain:

```text
Build completed successfully!
Copied final images to /artifacts/runcam_wifilink_defconfig/images
```

Final images are written to:

```sh
output/runcam_wifilink_defconfig/images/
```

Expected files include:

```text
runcam_wifilink_sdcard.img          complete SD card image
runcam_wifilink_boot.scr            boot script
runcam_wifilink_u-boot.bin          U-Boot image
runcam_wifilink_emmc_bootloader.img eMMC bootloader image
runcam_wifilink_rootfs.squashfs     root filesystem
runcam_wifilink.tar.gz              rootfs, U-Boot, and checksums archive
*.md5sum                            checksums
```

For a normal SD card flash, use:

```text
output/runcam_wifilink_defconfig/images/runcam_wifilink_sdcard.img
```

On macOS, identify the target disk carefully before flashing:

```sh
diskutil list
diskutil unmountDisk /dev/diskN
sudo dd if=output/runcam_wifilink_defconfig/images/runcam_wifilink_sdcard.img of=/dev/rdiskN bs=4m status=progress
sync
diskutil eject /dev/diskN
```

Replace `diskN` with the SD card device. Using the wrong device will overwrite
that disk.

## Memory Tuning

The build includes large host packages such as LLVM/Clang. On an 8 GB Podman VM,
too much parallelism can trigger the Linux OOM killer.

The Podman wrapper defaults to:

```sh
BUILDROOT_JLEVEL=2
```

If `host-clang` fails with an OOM, retry with:

```sh
./build-podman.sh --jlevel 1 runcam_wifilink_defconfig 2>&1 | tee build-runcam.log
```

You can confirm an OOM from inside the VM:

```sh
podman machine ssh podman-machine-default sudo dmesg | tail -200
```

Look for lines like:

```text
cc1plus invoked oom-killer
Out of memory: Killed process ... cc1plus
```

## Cache Behavior

The first build is slow because Buildroot downloads and compiles the toolchain,
host tools, kernel, U-Boot, GStreamer, LLVM/Clang, PixelPilot, and drivers.

Future builds are faster because the wrapper reuses Podman volumes:

```text
openipc-sbc-gs-src
openipc-sbc-gs-output
```

Simple changes to overlays or scripts, such as `gsmenu.sh`, should rebuild much
faster than the initial full build.

## Fast Incremental Image Update

After a successful full build, do not clean the Buildroot output volume for
small changes. Reuse the existing cache and rebuild only the affected package
before regenerating the final images.

For example, after changing `package/pixelpilot/files/gsmenu.sh`:

```sh
PODMAN_MIN_FREE_MB=15000 ./build-podman.sh --jlevel 6 runcam_wifilink_defconfig pixelpilot-reinstall
PODMAN_MIN_FREE_MB=15000 ./build-podman.sh --jlevel 6 runcam_wifilink_defconfig
```

The first command forces Buildroot to reinstall the already-built `pixelpilot`
package into the target root filesystem. This copies the updated
`/usr/bin/gsmenu.sh` without rebuilding the whole dependency graph.

The second command runs the normal `all` target. With the cache already warm,
Buildroot should skip package compilation and go directly to finalizing the
target, regenerating:

```text
rootfs.squashfs
sdcard.img
runcam_wifilink_sdcard.img
runcam_wifilink.tar.gz
```

Use `--jlevel 6` only if the Podman VM has enough RAM. If the VM has 8 GB and
starts swapping or killing compiler processes, use `--jlevel 2` or `--jlevel 1`.

The lower `PODMAN_MIN_FREE_MB=15000` threshold is only for incremental rebuilds.
A cold/full build should keep the default free-space check because Buildroot can
temporarily need much more disk space.

To verify that the modified file is installed in the Buildroot target:

```sh
podman run --rm \
  -v "$PWD:/host-src:ro" \
  -v openipc-sbc-gs-output:/build-output \
  openipc-sbc-gs-build:debian12 \
  bash -lc 'sha256sum /host-src/package/pixelpilot/files/gsmenu.sh /build-output/runcam_wifilink_defconfig/target/usr/bin/gsmenu.sh'
```

Both hashes should match.

To verify the file inside the generated `rootfs.squashfs`:

```sh
podman run --rm \
  -v openipc-sbc-gs-output:/build-output \
  openipc-sbc-gs-build:debian12 \
  bash -lc '/build-output/runcam_wifilink_defconfig/host/bin/unsquashfs -cat /build-output/runcam_wifilink_defconfig/images/rootfs.squashfs usr/bin/gsmenu.sh | sha256sum'
```

If a package failed and needs to be rebuilt cleanly, run the corresponding
Buildroot clean target through the wrapper, then start the build again. Example:

```sh
./build-podman.sh runcam_wifilink_defconfig lrzsz-dirclean
./build-podman.sh runcam_wifilink_defconfig 2>&1 | tee build-runcam.log
```

Do not remove these volumes unless you want a clean rebuild:

```sh
podman volume rm openipc-sbc-gs-src openipc-sbc-gs-output
```

## Backup And Restore The Local Build Cache

The fast local rebuild cache lives inside the Podman machine, in these named
volumes:

```text
openipc-sbc-gs-src
openipc-sbc-gs-output
```

If the Podman machine is deleted, corrupted, or recreated, these volumes are
lost. Create a backup after a successful full build so it can be restored later.

Show current cache size:

```sh
support/podman/cache.sh info
```

Create a backup archive on the host:

```sh
support/podman/cache.sh backup
```

By default, archives are written to:

```text
cache-backups/openipc-sbc-gs-cache-YYYYmmdd-HHMMSS.tar.zst
```

For safer storage, write the archive to an external disk:

```sh
support/podman/cache.sh backup /Volumes/External/openipc-sbc-gs-cache.tar.zst
```

The backup command also writes a matching SHA256 file:

```text
openipc-sbc-gs-cache.tar.zst.sha256
```

Restore after recreating the Podman machine:

```sh
podman machine init --cpus 6 --memory 8192 --disk-size 50
podman machine start
support/podman/cache.sh restore /Volumes/External/openipc-sbc-gs-cache.tar.zst
```

Then run an incremental build normally:

```sh
PODMAN_MIN_FREE_MB=15000 ./build-podman.sh --jlevel 6 runcam_wifilink_defconfig
```

Important: this mechanism is a proactive backup. If the Podman VM is already so
broken that `podman` cannot read its volumes anymore, the cache can only be
restored from an archive that was created earlier.

## Common Failures

### No Space Left on Device

Symptoms:

```text
tar: ... Cannot mkdir: No space left on device
unable to open database file
```

Check the real VM filesystem size:

```sh
podman machine ssh podman-machine-default df -h /
```

If needed, grow it:

```sh
podman machine ssh podman-machine-default sudo growpart /dev/vda 4
podman machine ssh podman-machine-default sudo xfs_growfs /
```

If Podman remains unstable after a full disk, recreate the machine:

```sh
podman machine stop podman-machine-default
podman machine rm -f podman-machine-default
podman machine init --cpus 6 --memory 8192 --disk-size 50
podman machine start
```

### host-tar Refuses to Configure as Root

Symptoms:

```text
configure: error: you should not run configure as root
```

The wrapper sets:

```sh
FORCE_UNSAFE_CONFIGURE=1
```

If this happens with an old container or stale environment, rerun:

```sh
./build-podman.sh --rebuild-image runcam_wifilink_defconfig
```

### No Final Images Found

Symptoms:

```text
No final images found in /build-output/runcam_wifilink_defconfig/images
The Buildroot output exists, but the image build did not complete.
```

This means Buildroot failed before generating final images. Check the last error:

```sh
tail -80 build-runcam.log
```

### lrzsz Fails on strtol

Symptoms:

```text
xstrtol.h:11:19: error: implicit declaration of function 'strtol'
```

The repository includes a Buildroot hook in `external.mk` that patches
`lrzsz-0.12.21rc` after extraction. If the package was already extracted before
this fix, clean only this package and rerun the build:

```sh
./build-podman.sh runcam_wifilink_defconfig lrzsz-dirclean
./build-podman.sh runcam_wifilink_defconfig 2>&1 | tee build-runcam.log
```

## GitHub Actions

This repository also contains a workflow dedicated to RunCam Wifilink:

```text
.github/workflows/runcam_wifilink.yml
```

It can be started manually from the GitHub Actions tab through
`workflow_dispatch`.

GitHub hosted runners have a hard 6 hour job limit. A cold RunCam build may hit
that limit before it can save any cache. The workflow caches Buildroot downloads
and ccache after a successful job, so the first successful run is the one that
initializes the GitHub cache for later runs.

The GitHub cache is separate from the local Podman volumes. A successful local
Podman build does not populate the GitHub Actions cache, and a fork cannot
directly reuse the private cache from the upstream repository.

#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONTAINERFILE="$ROOT_DIR/support/podman/Containerfile"
IMAGE_NAME="${PODMAN_BUILD_IMAGE:-openipc-sbc-gs-build:debian12}"
SOURCE_VOLUME="${PODMAN_SOURCE_VOLUME:-openipc-sbc-gs-src}"
BUILD_OUTPUT_VOLUME="${PODMAN_OUTPUT_VOLUME:-openipc-sbc-gs-output}"
DEFCONFIG="${DEFCONFIG:-runcam_wifilink_defconfig}"
BUILDROOT_JLEVEL="${BUILDROOT_JLEVEL:-2}"
TARGET="all"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output}"
REBUILD_IMAGE=0
SHELL_MODE=0
MIN_FREE_MB="${PODMAN_MIN_FREE_MB:-30000}"

usage() {
    cat <<EOF
Usage: $0 [options] [defconfig] [target]

Options:
  -d, --defconfig NAME   Buildroot defconfig to use.
                         Default: ${DEFCONFIG}
  -t, --target NAME      Buildroot target passed to build.sh.
                         Default: all
  -o, --output DIR       Host directory where final images are copied.
                         Default: ./output
      --jlevel N         Buildroot package parallelism.
                         Default: ${BUILDROOT_JLEVEL}
      --rebuild-image    Rebuild the Podman build image.
      --shell            Open a shell inside the build container.
  -h, --help             Show this help.

Examples:
  $0 runcam_wifilink_defconfig
  $0 openipc_bonnet_defconfig
  $0 radxa_zero3_defconfig menuconfig
  DEFCONFIG=emax_wyvern-link_defconfig $0
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -d|--defconfig)
            DEFCONFIG="$2"
            shift 2
            ;;
        -t|--target)
            TARGET="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --rebuild-image)
            REBUILD_IMAGE=1
            shift
            ;;
        --jlevel)
            BUILDROOT_JLEVEL="$2"
            shift 2
            ;;
        --shell)
            SHELL_MODE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *_defconfig)
            DEFCONFIG="$1"
            shift
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

if ! command -v podman >/dev/null 2>&1; then
    echo "podman not found. Install Podman first."
    exit 1
fi

if ! podman info >/dev/null 2>&1; then
    if [ "$(uname -s)" = "Darwin" ]; then
        cat <<EOF
Podman is installed, but the Linux VM is not running.

On macOS, initialize and start a Podman machine first:
  podman machine init --cpus 6 --memory 8192 --disk-size 50
  podman machine start

Then run this script again.
EOF
    else
        echo "Podman is installed, but it is not usable by the current user."
    fi
    exit 1
fi

check_podman_machine_space() {
    local df_line total_mb avail_mb

    df_line="$(podman machine ssh podman-machine-default df -Pm / 2>/dev/null | awk 'NR == 2 {print $2 " " $4}' || true)"
    [ -z "$df_line" ] && return 0

    total_mb="${df_line%% *}"
    avail_mb="${df_line##* }"

    if [ "$avail_mb" -lt "$MIN_FREE_MB" ]; then
        cat <<EOF
Podman VM has too little free space for a Buildroot image build.

Current VM root filesystem:
  total: ${total_mb} MiB
  free:  ${avail_mb} MiB

Buildroot needs much more free space. On macOS, if you already ran
'podman machine set --disk-size 50' but df still shows ~20G, grow the
partition and filesystem inside the VM:

  podman machine ssh podman-machine-default sudo growpart /dev/vda 4
  podman machine ssh podman-machine-default sudo xfs_growfs /
  podman machine ssh podman-machine-default df -h /

If that fails, recreate the VM with a larger disk:

  podman machine stop
  podman machine rm -f podman-machine-default
  podman machine init --cpus 6 --memory 8192 --disk-size 50
  podman machine start

Then rerun:
  $0 $DEFCONFIG $TARGET
EOF
        exit 1
    fi
}

check_podman_machine_space

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"

HOST_SOURCE_DIR="/host-src"
HOST_ARTIFACT_DIR="/artifacts"
VOLUME_ARGS=(-v "$ROOT_DIR:$HOST_SOURCE_DIR:ro")
VOLUME_ARGS+=(-v "$SOURCE_VOLUME:/src")
VOLUME_ARGS+=(-v "$BUILD_OUTPUT_VOLUME:/build-output")
VOLUME_ARGS+=(-v "$OUTPUT_DIR:$HOST_ARTIFACT_DIR")

if [ "$REBUILD_IMAGE" = "1" ] || ! podman image exists "$IMAGE_NAME"; then
    podman build -t "$IMAGE_NAME" -f "$CONTAINERFILE" "$ROOT_DIR/support/podman"
fi

TTY_ARGS=()
if [ -t 0 ] && [ -t 1 ]; then
    TTY_ARGS=(-it)
fi

RUN_ARGS=(
    --rm
    "${TTY_ARGS[@]}"
    "${VOLUME_ARGS[@]}"
    -w /src
    -e "DEFCONFIG=$DEFCONFIG"
    -e "BUILDROOT_JLEVEL=$BUILDROOT_JLEVEL"
    -e "FORCE_UNSAFE_CONFIGURE=1"
    -e "HOME=/tmp/openipc-build-home"
    -e "HOST_UID=$(id -u)"
    -e "HOST_GID=$(id -g)"
)

if [ "$SHELL_MODE" = "1" ]; then
    exec podman run "${RUN_ARGS[@]}" "$IMAGE_NAME" bash -lc '
        rsync -a --delete \
            --exclude buildroot \
            --exclude "buildroot-*" \
            --exclude output \
            "$1/" /src/
        git config --global --add safe.directory /src >/dev/null 2>&1 || true
        exec bash -l
    ' _ "$HOST_SOURCE_DIR"
fi

exec podman run "${RUN_ARGS[@]}" "$IMAGE_NAME" bash -lc '
    mkdir -p "$HOME"
    rsync -a --delete \
        --exclude buildroot \
        --exclude "buildroot-*" \
        --exclude output \
        "$3/" /src/
    git config --global --add safe.directory /src >/dev/null 2>&1 || true
    ./build.sh -o /build-output "$2"
    mkdir -p "$1/$DEFCONFIG"
    if find "/build-output/$DEFCONFIG/images" -maxdepth 1 -type f 2>/dev/null | grep -q .; then
        rsync -a --delete "/build-output/$DEFCONFIG/images/" "$1/$DEFCONFIG/images/"
        chown -R "$HOST_UID:$HOST_GID" "$1/$DEFCONFIG" >/dev/null 2>&1 || true
        echo "Copied final images to $1/$DEFCONFIG/images"
    else
        echo "No final images found in /build-output/$DEFCONFIG/images" >&2
        echo "The Buildroot output exists, but the image build did not complete." >&2
        exit 1
    fi
' _ "$HOST_ARTIFACT_DIR" "$TARGET" "$HOST_SOURCE_DIR"

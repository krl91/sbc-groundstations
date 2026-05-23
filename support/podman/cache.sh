#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
CONTAINERFILE="$ROOT_DIR/support/podman/Containerfile"
IMAGE_NAME="${PODMAN_BUILD_IMAGE:-openipc-sbc-gs-build:debian12}"
SOURCE_VOLUME="${PODMAN_SOURCE_VOLUME:-openipc-sbc-gs-src}"
BUILD_OUTPUT_VOLUME="${PODMAN_OUTPUT_VOLUME:-openipc-sbc-gs-output}"
BACKUP_DIR="${PODMAN_CACHE_BACKUP_DIR:-$ROOT_DIR/cache-backups}"

usage() {
    cat <<EOF
Usage: $0 <command> [archive]

Commands:
  backup [archive]    Save Podman Buildroot cache volumes to a .tar.zst archive.
                      Default archive:
                      cache-backups/openipc-sbc-gs-cache-YYYYmmdd-HHMMSS.tar.zst

  restore <archive>   Restore Podman Buildroot cache volumes from an archive.
                      Existing volume contents are replaced.

  info                Show current cache volume sizes.

Environment:
  PODMAN_BUILD_IMAGE       Build container image. Default: $IMAGE_NAME
  PODMAN_SOURCE_VOLUME     Source/cache volume. Default: $SOURCE_VOLUME
  PODMAN_OUTPUT_VOLUME     Build output volume. Default: $BUILD_OUTPUT_VOLUME
  PODMAN_CACHE_BACKUP_DIR  Backup directory. Default: $BACKUP_DIR

Examples:
  $0 backup
  $0 backup /Volumes/External/openipc-cache.tar.zst
  $0 restore /Volumes/External/openipc-cache.tar.zst
  $0 info
EOF
}

ensure_podman() {
    if ! command -v podman >/dev/null 2>&1; then
        echo "podman not found. Install Podman first." >&2
        exit 1
    fi

    if ! podman info >/dev/null 2>&1; then
        echo "Podman is not usable. Start or recreate the Podman machine first." >&2
        exit 1
    fi
}

ensure_image() {
    if ! podman image exists "$IMAGE_NAME"; then
        podman build -t "$IMAGE_NAME" -f "$CONTAINERFILE" "$ROOT_DIR/support/podman"
    fi
}

ensure_volume_exists() {
    local volume="$1"
    if ! podman volume inspect "$volume" >/dev/null 2>&1; then
        echo "Missing Podman volume: $volume" >&2
        echo "Run a build first, or restore from a backup archive." >&2
        exit 1
    fi
}

ensure_volume_present() {
    local volume="$1"
    podman volume inspect "$volume" >/dev/null 2>&1 || podman volume create "$volume" >/dev/null
}

backup_cache() {
    local archive="${1:-}"
    local archive_dir archive_name

    ensure_podman
    ensure_image
    ensure_volume_exists "$SOURCE_VOLUME"
    ensure_volume_exists "$BUILD_OUTPUT_VOLUME"

    if [ -z "$archive" ]; then
        mkdir -p "$BACKUP_DIR"
        archive="$BACKUP_DIR/openipc-sbc-gs-cache-$(date +%Y%m%d-%H%M%S).tar.zst"
    fi

    mkdir -p "$(dirname "$archive")"
    archive_dir="$(cd "$(dirname "$archive")" && pwd -P)"
    archive_name="$(basename "$archive")"

    podman run --rm \
        -v "$SOURCE_VOLUME:/cache/src:ro" \
        -v "$BUILD_OUTPUT_VOLUME:/cache/build-output:ro" \
        -v "$archive_dir:/backup" \
        "$IMAGE_NAME" \
        bash -lc '
            set -euo pipefail
            cd /cache
            tar --numeric-owner -I "zstd -T0 -19" -cf "/backup/$1" src build-output
            sha256sum "/backup/$1" > "/backup/$1.sha256"
        ' _ "$archive_name"

    echo "Cache backup written to: $archive"
    echo "Checksum written to: $archive.sha256"
}

restore_cache() {
    local archive="${1:-}"
    local archive_dir archive_name

    if [ -z "$archive" ]; then
        echo "restore requires an archive path." >&2
        usage
        exit 1
    fi

    if [ ! -f "$archive" ]; then
        echo "Backup archive not found: $archive" >&2
        exit 1
    fi

    ensure_podman
    ensure_image

    archive_dir="$(cd "$(dirname "$archive")" && pwd -P)"
    archive_name="$(basename "$archive")"

    ensure_volume_present "$SOURCE_VOLUME"
    ensure_volume_present "$BUILD_OUTPUT_VOLUME"

    podman run --rm \
        -v "$SOURCE_VOLUME:/restore/src" \
        -v "$BUILD_OUTPUT_VOLUME:/restore/build-output" \
        -v "$archive_dir:/backup:ro" \
        "$IMAGE_NAME" \
        bash -lc '
            set -euo pipefail
            workdir="$(mktemp -d)"
            trap "rm -rf \"$workdir\"" EXIT

            tar -I zstd -xf "/backup/$1" -C "$workdir"
            test -d "$workdir/src"
            test -d "$workdir/build-output"

            find /restore/src -mindepth 1 -maxdepth 1 -exec rm -rf {} +
            find /restore/build-output -mindepth 1 -maxdepth 1 -exec rm -rf {} +

            rsync -a "$workdir/src/" /restore/src/
            rsync -a "$workdir/build-output/" /restore/build-output/
        ' _ "$archive_name"

    echo "Cache restored from: $archive"
    echo "Restored volumes:"
    echo "  $SOURCE_VOLUME"
    echo "  $BUILD_OUTPUT_VOLUME"
}

cache_info() {
    ensure_podman
    ensure_image

    ensure_volume_present "$SOURCE_VOLUME"
    ensure_volume_present "$BUILD_OUTPUT_VOLUME"

    podman run --rm \
        -v "$SOURCE_VOLUME:/cache/src:ro" \
        -v "$BUILD_OUTPUT_VOLUME:/cache/build-output:ro" \
        "$IMAGE_NAME" \
        bash -lc '
            du -sh /cache/src /cache/build-output
            find /cache/build-output -maxdepth 2 -type d -name images -print
        '
}

case "${1:-}" in
    backup)
        shift
        backup_cache "${1:-}"
        ;;
    restore)
        shift
        restore_cache "${1:-}"
        ;;
    info)
        cache_info
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        echo "Unknown command: $1" >&2
        usage
        exit 1
        ;;
esac

#!/bin/sh
set -eu

usage() {
	printf 'Usage: %s INPUT.mp4 OUTPUT.mp4 [START_SECONDS [DURATION_SECONDS]]\n' "$0" >&2
	printf 'Creates a separate 640x480 H.264 web copy. The source is never changed.\n' >&2
}

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
	usage
	exit 2
fi

input=$1
output=$2
start=${3:-0}
duration=${4:-}

if [ ! -f "$input" ]; then
	printf 'Input video not found: %s\n' "$input" >&2
	exit 1
fi

if [ -e "$output" ]; then
	printf 'Output already exists; choose a new path: %s\n' "$output" >&2
	exit 1
fi

if ! command -v avconvert >/dev/null 2>&1; then
	printf 'This script needs macOS avconvert.\n' >&2
	exit 1
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/rocket-video.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
intermediate="$temporary_directory/compressed.m4v"

set -- --source "$input" --preset PresetAppleM4ViPod --output "$intermediate" --start "$start"
if [ -n "$duration" ]; then
	set -- "$@" --duration "$duration"
fi
avconvert "$@"

# The iPod preset writes an M4V container; passthrough remuxes it to MP4 without
# another encode, retaining the smaller H.264/AAC streams.
avconvert --source "$intermediate" --preset PresetPassthrough --output "$output"
printf 'Created %s\n' "$output"
du -h "$output"

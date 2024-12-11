#!/bin/bash

# Configuration
HLS_DIR="${1:-/home/http/www/live}"  # Default path, override with first argument
MAX_AGE_MINUTES="${2:-2}"                   # Default 30 minutes, override with second argument
PLAYLIST_PATTERN="*.m3u8"
SEGMENT_PATTERN="*.ts"

cleanup_segments() {
    local dir="$1"
    local max_age="$2"

    # Find all m3u8 playlists
    find "$dir" -name "$PLAYLIST_PATTERN" -type f | while read -r playlist; do
        # Get the base name for this stream
        stream_base=$(basename "$playlist" .m3u8)
        
        # Get list of segments currently referenced in the playlist
        referenced_segments=$(grep -o "${stream_base}_[0-9]*.ts" "$playlist" || true)
        
        # Find all ts files matching this stream's pattern
        find "$dir" -name "${stream_base}_*.ts" -type f | while read -r segment; do
            segment_base=$(basename "$segment")
            
            # Check if segment is older than MAX_AGE_MINUTES
            if [[ $(find "$segment" -mmin +$max_age -type f) ]]; then
                # Check if segment is not in the playlist
                if ! echo "$referenced_segments" | grep -q "$segment_base"; then
                    echo "Removing old segment: $segment_base"
                    rm -f "$segment"
                fi
            fi
        done
    done
}

# Validate directory exists
if [ ! -d "$HLS_DIR" ]; then
    echo "Error: Directory $HLS_DIR does not exist"
    exit 1
fi

# Validate MAX_AGE_MINUTES is a number
if ! [[ "$MAX_AGE_MINUTES" =~ ^[0-9]+$ ]]; then
    echo "Error: MAX_AGE_MINUTES must be a number"
    exit 1
fi

echo "Starting cleanup in $HLS_DIR (removing segments older than $MAX_AGE_MINUTES minutes)"
cleanup_segments "$HLS_DIR" "$MAX_AGE_MINUTES"

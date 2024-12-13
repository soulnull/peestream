#!/bin/bash

# =======================
# Stream Manager with EPG
# =======================

# -----------------------
# Configuration Variables
# -----------------------
SHUFFLE=false
EPG_BUFFER_HOURS=96        # Hours of EPG buffer to maintain
TIME_OFFSET=90              # 2 minutes offset in seconds
EPG_SYNC_INTERVAL=7200       # Check EPG sync every 2 hours (in seconds)
MAX_DRIFT_SECONDS=300        # Maximum allowed drift (5 minutes) before correction
DURATION_CACHE_DIR="/mnt/2tb/247/duration_cache"
HLS_DIR="/home/http/www/live"
EPG_FILE="/home/http/www/247.xml"
EPG_LOCK_FILE="/tmp/247_epg.lock"
FFMPEG_PID=""
LAST_EPG_SYNC_CHECK=0
INITIAL_EPG_GENERATED=false

mkdir -p "$DURATION_CACHE_DIR"
mkdir -p "$HLS_DIR"

# -----------------------
# Command Line Parsing
# -----------------------
STREAM_NAME=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--shuffle)
            SHUFFLE=true
            shift
            ;;
        *)
            if [ -z "$STREAM_NAME" ]; then
                STREAM_NAME="$1"
            else
                echo "Unknown argument: $1"
                echo "Usage: $0 [-s|--shuffle] <stream_name>"
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$STREAM_NAME" ]; then
    echo "Usage: $0 [-s|--shuffle] <stream_name>"
    exit 1
fi

PLAYLIST="/mnt/2tb/247/${STREAM_NAME}.txt"
if [ ! -f "$PLAYLIST" ]; then
    echo "Error: Playlist not found at $PLAYLIST"
    exit 1
fi

if [ ! -s "$PLAYLIST" ]; then
    echo "Error: Playlist is empty at $PLAYLIST"
    exit 1
fi

TEMP_PLAYLIST="/tmp/${STREAM_NAME}_current.txt"
SHUFFLE_PLAYLIST="/tmp/${STREAM_NAME}_shuffled.txt"
TEMP_EPG_FILE="/tmp/${STREAM_NAME}_epg.xml"

# -----------------------
# Cleanup on Exit
# -----------------------
cleanup() {
    echo "Cleaning up..."
    FFMPEG_PID_VAR="FFMPEG_PID_$(echo "$STREAM_NAME" | tr '-' '_')"
        ffmpeg_pid_value=$(eval "echo \$$FFMPEG_PID_VAR")
        if [ -n "$ffmpeg_pid_value" ]; then
            echo "Terminating FFmpeg process (PID: $ffmpeg_pid_value)..."
            kill -TERM "$ffmpeg_pid_value" 2>/dev/null || true
            wait "$ffmpeg_pid_value" 2>/dev/null || true
        fi
    rm -f "$TEMP_PLAYLIST" "$SHUFFLE_PLAYLIST" "$TEMP_EPG_FILE"
    exit 0
}
trap cleanup EXIT INT TERM

# -----------------------
# Helper Functions
# -----------------------

extract_title() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    filename="${filename%.*}"
    # Remove parentheses and brackets
    filename=$(echo "$filename" | sed 's/([^)]*)//g; s/\[[^]]*\]//g')
    # Escape &
    filename=$(echo "$filename" | sed 's/&/\&amp;/g')
    # Trim whitespace
    filename=$(echo "$filename" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    echo "$filename"
}

get_video_duration() {
    local video_path="$1"
    local cache_file="${DURATION_CACHE_DIR}/$(basename "$video_path").duration"

    if [ -f "$cache_file" ] && [ $(( $(date +%s) - $(stat -c %Y "$cache_file") )) -lt $((30*24*3600)) ]; then
        cat "$cache_file"
        return 0
    fi

    local duration
    duration=$(ffprobe -v error -select_streams v:0 -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$video_path" 2>/dev/null) || true

    if [[ ! "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        duration=1200 # default 20 minutes if unknown
    fi

    echo "$duration" > "$cache_file"
    echo "$duration"
}

get_total_epg_duration() {
    local channel_id="${STREAM_NAME}247"
    local current_time=$(date +%s)

    if [ -f "$EPG_FILE" ]; then
        local latest_stop
        latest_stop=$(grep -oP '(?<=stop=")\d{14}' "$EPG_FILE" | tail -n 1)
        if [ -n "$latest_stop" ]; then
            local latest_timestamp
            latest_timestamp=$(date -u -d "${latest_stop:0:4}-${latest_stop:4:2}-${latest_stop:6:2} ${latest_stop:8:2}:${latest_stop:10:2}:${latest_stop:12:2}" +%s)
            echo $((latest_timestamp - current_time))
            return
        fi
    fi
    echo 0
}

generate_epg() {
    local drift="$1"
    local start_timestamp=$(date +%s)
    local current_timestamp=$((start_timestamp + TIME_OFFSET))
    local channel_id="${STREAM_NAME}247"
    local hours_needed=$EPG_BUFFER_HOURS
    local target_duration=$((hours_needed * 3600))
    local iterations=0
    local max_iterations=1000

    # TEMP_EPG_FILE should only contain channel and programmes, no XML header or <tv> tags.
    cat > "$TEMP_EPG_FILE" <<EOF
    <channel id="${channel_id}">
        <display-name>${channel_id}</display-name>
    </channel>
EOF

    # Build up enough EPG data
    while true; do
        iterations=$((iterations+1))
        if [ $iterations -gt $max_iterations ]; then
            echo "Warning: Maximum EPG generation iterations reached"
            break
        fi

        # Use PLAYBACK_PLAYLIST to read the playlist for EPG generation
        while IFS= read -r video_path; do
            [[ -z "$video_path" ]] && continue
            duration=$(get_video_duration "$video_path")
            duration=${duration%.*}
            local start_time=$(date -u -d "@${current_timestamp}" +"%Y%m%d%H%M%S")
            current_timestamp=$((current_timestamp + duration))
            local stop_time=$(date -u -d "@${current_timestamp}" +"%Y%m%d%H%M%S")
            local title=$(extract_title "$video_path")

            cat >> "$TEMP_EPG_FILE" <<EOF
    <programme start="${start_time} +0000" stop="${stop_time} +0000" channel="${channel_id}">
        <title>${title}</title>
    </programme>
EOF
        # Read from PLAYBACK_PLAYLIST (either shuffled or unshuffled)
        done < "$PLAYBACK_PLAYLIST"

        local total_duration=$((current_timestamp - (start_timestamp + TIME_OFFSET)))
        if [ $total_duration -ge $target_duration ]; then
            break
        fi
    done

    (
        flock -x 200
        # Ensure EPG file exists
        if [ ! -f "$EPG_FILE" ]; then
            cat > "$EPG_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<tv generator-info-name="247-epg-generator">
</tv>
EOF
        fi

        # Remove previous entries for this channel
        sed -i "/<channel id=\"${channel_id}\">/,/<\/channel>/d" "$EPG_FILE"
        sed -i "/<programme.*channel=\"${channel_id}\"/,/<\/programme>/d" "$EPG_FILE"

        # Remove the closing </tv> tag
        sed -i '/<\/tv>/d' "$EPG_FILE"

        # Append new channel and programme entries
        cat "$TEMP_EPG_FILE" >> "$EPG_FILE"

        # Re-add closing </tv>
        echo "</tv>" >> "$EPG_FILE"
    ) 200>"$EPG_LOCK_FILE"

    INITIAL_EPG_GENERATED=true
}

process_video() {
    local video_path="$1"
    if [[ ! -f "$video_path" ]]; then
        echo "Error: File not found - $video_path"
        return 1
    fi

    # Log the last played file
    echo "$video_path" > "${HLS_DIR}/${STREAM_NAME}_last_played.txt"

    echo "Streaming: $video_path"
    local duration
    duration=$(get_video_duration "$video_path")
    duration=${duration%.*}

    ffmpeg -nostdin -loglevel error -re -y -i "$video_path" \
        -c copy \
        -f hls \
        -hls_time 10 \
        -sn \
        -hls_list_size 5 \
        -hls_flags delete_segments+append_list \
        -hls_segment_filename "${HLS_DIR}/${STREAM_NAME}_%03d.ts" \
        "${HLS_DIR}/${STREAM_NAME}.m3u8" &

    FFMPEG_PID_VAR="FFMPEG_PID_$(echo "$STREAM_NAME" | tr '-' '_')"
    declare "$FFMPEG_PID_VAR"="$!"

    local elapsed=0
    local ffmpeg_pid_value
    ffmpeg_pid_value=$(eval "echo \$$FFMPEG_PID_VAR")
    while kill -0 "$ffmpeg_pid_value" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed+1))
        if [ "$elapsed" -ge "$duration" ]; then
            break
        fi
    done

    local ffmpeg_exit_status=0
    if ! wait "$ffmpeg_pid_value"; then
        ffmpeg_exit_status=$?
        echo "Warning: FFmpeg encountered an error (code $ffmpeg_exit_status) while processing $video_path"
    fi

    # Use the unique variable to send the TERM signal
    kill -TERM "$ffmpeg_pid_value" 2>/dev/null || true
    wait "$ffmpeg_pid_value" 2>/dev/null || true

    # Return the exit status of FFmpeg
    return $ffmpeg_exit_status
}

check_epg_sync() {
    if [ "$INITIAL_EPG_GENERATED" = false ]; then
        return
    fi

    local current_time=$(date +%s)
    if [ $((current_time - LAST_EPG_SYNC_CHECK)) -lt $EPG_SYNC_INTERVAL ]; then
        return
    fi
    LAST_EPG_SYNC_CHECK=$current_time

    # For synchronization, find the first program for this channel
    local channel_id="${STREAM_NAME}247"
    local first_program_start
    first_program_start=$(grep -oP "(?<=<programme start=\")\\d{14}(?=.*channel=\"${channel_id}\")" "$EPG_FILE" | head -1)

    if [ -z "$first_program_start" ]; then
        echo "Warning: No programmes found for channel ${channel_id} in EPG."
        return
    fi

    local epg_timestamp
    epg_timestamp=$(date -u -d "${first_program_start:0:4}-${first_program_start:4:2}-${first_program_start:6:2} ${first_program_start:8:2}:${first_program_start:10:2}:${first_program_start:12:2}" +%s)

    local expected_timestamp=$((current_time + TIME_OFFSET))
    local drift=$((epg_timestamp - expected_timestamp))

    if [ "${drift#-}" -gt "$MAX_DRIFT_SECONDS" ]; then
        echo "EPG drift detected: ${drift} seconds. Regenerating EPG..."
        TIME_OFFSET=$((TIME_OFFSET + drift))
        generate_epg "$drift"
        echo "EPG regenerated with adjusted timing."
    else
        echo "EPG synchronization within limits (drift: ${drift} seconds)."
    fi
}

prepare_playlist() {
    # Create a temporary playlist without shuffling initially
    grep -v '^[[:space:]]*$' "$PLAYLIST" > "$TEMP_PLAYLIST"

    if [ ! -s "$TEMP_PLAYLIST" ]; then
        echo "Error: No valid entries found in playlist."
        cat "$PLAYLIST"
        exit 1
    fi

    # Shuffle for playback if enabled
    if [ "$SHUFFLE" = true ]; then
        echo "Shuffling playlist for playback..."
        shuf "$TEMP_PLAYLIST" > "$SHUFFLE_PLAYLIST"
        # Use the shuffled playlist for playback and EPG generation
        PLAYBACK_PLAYLIST="$SHUFFLE_PLAYLIST"
    else
        # Use the original temporary playlist for playback and EPG generation
        PLAYBACK_PLAYLIST="$TEMP_PLAYLIST"
    fi

    # Generate EPG *after* shuffling (if shuffling is enabled)
    generate_epg

    echo "Current playlist contains $(wc -l < "$PLAYBACK_PLAYLIST") entries."
}

# -----------------------
# Main Execution
# -----------------------
echo "Starting stream '$STREAM_NAME'"
echo "Playlist: $PLAYLIST"
echo "HLS output: $HLS_DIR"
[ "$SHUFFLE" = true ] && echo "Shuffle mode enabled."
echo "Original playlist entries: $(grep -v '^[[:space:]]*$' "$PLAYLIST" | wc -l)"

# Create last_played file
touch "${HLS_DIR}/${STREAM_NAME}_last_played.txt"

LAST_EPG_SYNC_CHECK=$(date +%s)  # Initialize the timestamp

while true; do
    prepare_playlist

    # Read last played file if it exists
    last_played_file="${HLS_DIR}/${STREAM_NAME}_last_played.txt"
    start_index=0
    if [ -f "$last_played_file" ]; then
        last_played_video=$(cat "$last_played_file")
        echo "Resuming from: $last_played_video"

        # Find the index of the last played video in the PLAYBACK_PLAYLIST
        index=0
        while IFS= read -r video_path; do
            if [ "$video_path" = "$last_played_video" ]; then
                start_index=$index
                break
            fi
            index=$((index+1))
        done < "$PLAYBACK_PLAYLIST"
    fi

    # Loop through the playlist starting from the appropriate index
    index=0
    PLAYBACK_INDEX=0
    while IFS= read -r video_path; do
        if (( PLAYBACK_INDEX < start_index )); then
            PLAYBACK_INDEX=$((PLAYBACK_INDEX+1))
            continue  # Skip until we reach the starting index
        fi

        if ! process_video "$video_path"; then
            echo "Skipping to next video due to error."
            index=$((index+1))
            continue  # Skip to the next video
        fi

        # Check EPG sync at intervals
        current_time=$(date +%s)
        if (( (current_time - LAST_EPG_SYNC_CHECK) >= EPG_SYNC_INTERVAL )); then
            check_epg_sync
            LAST_EPG_SYNC_CHECK=$current_time  # Update the timestamp
        fi

        index=$((index+1))
        PLAYBACK_INDEX=$((PLAYBACK_INDEX+1))
    done < "$PLAYBACK_PLAYLIST"

    # Reset start_index and clear the last_played file
    start_index=0
    > "${HLS_DIR}/${STREAM_NAME}_last_played.txt" # Method 1 - Truncate File
    #rm "${HLS_DIR}/${STREAM_NAME}_last_played.txt" # Method 2 - Delete File (ONLY USE ONE OF THESE)

    echo "Playlist completed. Checking EPG buffer..."
    current_epg_duration=$(get_total_epg_duration)
    if [ "$current_epg_duration" -lt $((EPG_BUFFER_HOURS * 3600)) ]; then
        echo "Extending EPG by regenerating..."
        generate_epg
    fi

    echo "Starting next streaming cycle..."

done

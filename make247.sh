#!/bin/bash

# Check for required arguments
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <folder_path> <category>"
    echo "Example: $0 '/mnt/bigboy/movies/The Whitest Kids U Know' comedy"
    exit 1
fi

# Configuration
FOLDER_PATH="$1"
CATEGORY="$2"
BASE_DIR="/mnt/2tb/247"
PLAYLIST_FILE="/home/http/www/hdhr.m3u"
SYSTEMD_DIR="/etc/systemd/system"
IMAGES_DIR="/home/http/www/images"
FANART_API_KEY=""  # Replace with your Fanart.tv API key
TMDB_API_KEY=""  # Keep TMDB for initial search

# Ensure required tools are installed
command -v curl >/dev/null 2>&1 || { echo "curl is required but not installed. Aborting." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed. Aborting." >&2; exit 1; }

# Function to generate feed name from title
generate_feed_name() {
    local title="$1"
    # Remove leading "the", "a", etc and strip out problematic characters
    local cleaned_title=$(echo "$title" | sed -E 's/^(the|a|an) //i' | tr -cd '[:alnum:] ')
    local first_word=$(echo "$cleaned_title" | awk '{print $1}')
    local last_word=$(echo "$cleaned_title" | awk '{print $NF}')
    
    # Take first 3 letters of first and last words
    echo "${first_word:0:3}${last_word:0:3}"
}

# Function to natural sort files
natural_sort_files() {
    cd "$1" || exit 1
    find "$(realpath .)" -type f \( -name "*.mkv" -o -name "*.mp4" \) | sort -V
}

# Function to fetch show image from Fanart.tv
fetch_show_image() {
    local show_name="$1"
    local output_file="$2"
    local encoded_name=$(echo "$show_name" | sed 's/ /%20/g')
    
    echo "Searching for show: $show_name (encoded: $encoded_name)"
    
    # First, get TMDB ID with more detailed search
    local tmdb_search_url="https://api.themoviedb.org/3/search/tv?api_key=$TMDB_API_KEY&query=$encoded_name"
    echo "TMDB Search URL: $tmdb_search_url"
    
    local search_result=$(curl -s "$tmdb_search_url")
    
    # Print out the first few results for debugging
    echo "First few TMDB results:"
    echo "$search_result" | jq -r '.results[] | "ID: \(.id), Name: \(.name), First Air Date: \(.first_air_date)"' | head -n 5
    
    # Try to get exact match first
    local tmdb_id=$(echo "$search_result" | jq -r --arg name "$show_name" '.results[] | select(.name|ascii_downcase == ($name|ascii_downcase)) | .id' | head -n 1)
    
    # If no exact match, try partial match
    if [ -z "$tmdb_id" ] || [ "$tmdb_id" = "null" ]; then
        echo "No exact match found, trying first result..."
        tmdb_id=$(echo "$search_result" | jq -r '.results[0].id')
    fi
    
    echo "Selected TMDB ID: $tmdb_id"
    
    if [ "$tmdb_id" != "null" ] && [ -n "$tmdb_id" ]; then
        echo "Using TMDB ID, querying Fanart.tv..."
        
        # Query Fanart.tv with TMDB ID
        local fanart_url="http://webservice.fanart.tv/v3/tv/$tmdb_id"
        echo "Fanart.tv URL: $fanart_url"
        
        local fanart_result=$(curl -s \
            -H "api-key: $FANART_API_KEY" \
            "$fanart_url")
        
        # Check if we got an error response
        if echo "$fanart_result" | jq -e '.status == "error"' > /dev/null; then
            echo "Fanart.tv error: $(echo "$fanart_result" | jq -r '.["error message"]')"
            
            # Try alternative TMDB IDs if available
            echo "Trying alternative TMDB IDs..."
            local alt_tmdb_id=$(echo "$search_result" | jq -r '.results[1].id // empty')
            if [ -n "$alt_tmdb_id" ]; then
                echo "Trying alternative TMDB ID: $alt_tmdb_id"
                fanart_url="http://webservice.fanart.tv/v3/tv/$alt_tmdb_id"
                fanart_result=$(curl -s \
                    -H "api-key: $FANART_API_KEY" \
                    "$fanart_url")
            fi
        fi
        
        echo "Fanart.tv Result: $fanart_result"
        
        # Try to get HD clearlogo first
        local logo_url=$(echo "$fanart_result" | jq -r '.hdtvlogo[0].url // .clearlogo[0].url // empty')
        echo "HD/Clear Logo URL: $logo_url"
        
        if [ -n "$logo_url" ]; then
            echo "Found HD/Clear logo, downloading..."
            curl -s "$logo_url" -o "$output_file"
            return 0
        fi
        
        # Fallback to TV logo
        logo_url=$(echo "$fanart_result" | jq -r '.tvlogo[0].url // empty')
        echo "TV Logo URL fallback: $logo_url"
        
        if [ -n "$logo_url" ]; then
            echo "Found TV logo, downloading..."
            curl -s "$logo_url" -o "$output_file"
            return 0
        fi
    fi
    
    echo "No TV logos found, trying movie search..."
    
    # Try movie search as fallback
    local movie_search_url="https://api.themoviedb.org/3/search/movie?api_key=$TMDB_API_KEY&query=$encoded_name"
    search_result=$(curl -s "$movie_search_url")
    tmdb_id=$(echo "$search_result" | jq -r '.results[0].id')
    
    if [ "$tmdb_id" != "null" ] && [ -n "$tmdb_id" ]; then
        echo "Found movie TMDB ID: $tmdb_id, querying Fanart.tv..."
        
        local fanart_movie_url="http://webservice.fanart.tv/v3/movies/$tmdb_id"
        local fanart_result=$(curl -s \
            -H "api-key: $FANART_API_KEY" \
            "$fanart_movie_url")
        
        # Try to get HD movie logo
        local logo_url=$(echo "$fanart_result" | jq -r '.hdmovielogo[0].url // .movielogo[0].url // empty')
        echo "Movie Logo URL: $logo_url"
        
        if [ -n "$logo_url" ]; then
            echo "Found movie logo, downloading..."
            curl -s "$logo_url" -o "$output_file"
            return 0
        fi
    fi
    
    echo "No logos found in any source"
    return 1
}
# Get the base name of the folder (show name)
SHOW_NAME=$(basename "$FOLDER_PATH")
FEED_NAME=$(generate_feed_name "$SHOW_NAME")

# Create the file list
natural_sort_files "$FOLDER_PATH" > "$BASE_DIR/${FEED_NAME}.txt"

# Create systemd service file
cat > "$SYSTEMD_DIR/${FEED_NAME}.service" << EOF
[Unit]
Description=$SHOW_NAME 24/7
After=network.target

[Service]
User=blumpkin
Type=simple
ExecStart=$BASE_DIR/stream.sh $FEED_NAME
Restart=on-failure
After=NetworkManager.service

[Install]
WantedBy=multi-user.target
EOF

# Use systemd-escape to ensure the service name is valid
SERVICE_NAME=$(systemd-escape "${FEED_NAME}.service")

# Enable and start the service
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

# Function to check if entry already exists in playlist
entry_exists() {
    grep -q "tvg-id=\"$FEED_NAME247\"" "$PLAYLIST_FILE"
    return $?
}

# Create images directory if it doesn't exist
mkdir -p "$IMAGES_DIR"

# Fetch and save show image
IMAGE_FILE="$IMAGES_DIR/${FEED_NAME}247.jpg"
if ! fetch_show_image "$SHOW_NAME" "$IMAGE_FILE"; then
    echo "Warning: Could not fetch show image. Using default image URL."
    LOGO_URL="http://192.168.1.23/images/default247.jpg"
else
    LOGO_URL="http://192.168.1.23/images/${FEED_NAME}247.jpg"
fi

# Add playlist entry if it doesn't exist
if ! entry_exists; then
    cat >> "$PLAYLIST_FILE" << EOF

#EXTINF:-1 tvg-chno="70" tvg-id="${FEED_NAME}247" tvg-logo="$LOGO_URL" group-title="24/7 ${CATEGORY^}",$SHOW_NAME
http://192.168.1.23/live/${FEED_NAME}.m3u8
EOF
fi

echo "Setup completed for $SHOW_NAME"
echo "Feed name: $FEED_NAME"
echo "Service name: ${SERVICE_NAME}"
echo "Image path: $IMAGE_FILE"
echo "Playlist entry added to $PLAYLIST_FILE"

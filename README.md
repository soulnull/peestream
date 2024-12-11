# peestream
PeeStream is a 24/7 linear TV channel generator that remuxes existing files into HLS chunks for streaming. 

# features
PeeStream uses ffprobe to identify/cache the lengths of files for EPG data. Yes, EPG data! Since file playback can be subject to interruptions/drifting, there is a syncing logic that will non-destructively edit the xml file to keep it within 5 minutes of the program (can be adjusted).

# usage
You'll want an API key from TVDB to download/cache clearart for the m3u. You'll want nginx. You'll want to make a tmpfs in a publicly accessible location (for the HLS chunks).
First, run ./make247.sh against a folder and specify a category (for the M3U playlist). It'll create a text file of all of the media files in that folder/subfolder, sorted in order, create a systemd service, enable the systemd service, start the systemd service, add itself to the specified m3u.
This runs ./stream.sh (with an optional shuffle mode called with -s) that caches the lengths of each file (to avoid hammering the drive) and uses that to create an EPG XML (default is 96 hours) and will non-destructively add itself to an existing XML.

# limitations
DTS audio is not compatible with HLS, so DTS audio cannot be used. <br>
HLS only supports webvtt, and only one track, so no subtitles (yet?).

# future plans
There was a live audio transcode with cache using fifo pipes so it only needed to transcode the audio once and stored the result, losslessly remuxing it in with the original. This was buggy and prone to crashing, so it was removed for now. I want to bring it back, but.. We'll see.<br>
Figuring out subtitle logic (embedded, external, en, eng, English, etc) is on the to-do list, but I'm not ready to tackle that yet.<br>
A stream manager. Currently, each stream has to be started/stopped as individual systemd services. I don't like this, scales poorly. Restarting 40 streams is annoying. The goal is to create a basic wrapper with a startall stopall restartall option that acts as a front-end at some point.<br>
Improving the resume functionality. Currently it caches the last played file to a text file in the hls directory (to avoid hammering my SSD with a bunch of tiny writes), so resuming only restarts the previous file it stopped on. This is just so modifying the script didn't restart all of my shows to season 1 episode 1 every frikkin time I changed something.<br>
I will wrap hlsclean.sh into the main loop logic to keep track of the chunks ffmpeg "forgot" to delete, but for now, just run that as a systemd every 15 minutes or so to keep the tmpfs from filling up with old stale chunks.
code {
  white-space : pre-wrap !important;
}

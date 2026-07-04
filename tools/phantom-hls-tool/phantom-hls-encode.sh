#!/usr/bin/env bash
#
# phantom-hls-encode.sh
# ProRes master -> fMP4 HLS ladder (1080p + 720p)
#
# Quality: calibrated from test-quality.mp4 (CRF 16, avg 2.7 Mbps, 14:22 runtime).
# Master already has controlled film grain -> banding solved at source, so AQ is kept light.
# No 540p: terminal content is unreadable at 540p ("an unreadable video is worse than none").
# Cache-rule compatible: .m4s segments (1-year cache) + .m3u8 manifests (bypass).
#
# Usage:
#   ./phantom-hls-encode.sh <input.mov> <output-dir> [<name>]
#
set -euo pipefail

INPUT="${1:?Usage: $0 <input.mov> <output-dir> [name]}"
OUTDIR="${2:?output-dir is required}"
NAME="${3:-video}"

mkdir -p "$OUTDIR"

# ---- GOP / segment ----
FPS=30
SEG_SECONDS=4
GOP=$(( FPS * SEG_SECONDS ))   # 120

# ---- x264 quality settings (tuned for the grain already baked into the master) ----
# aq-mode=3       : adaptive quantization, smarter bit allocation in dark regions
# aq-strength=1.0 : LIGHT — master already has grain, banding is solved at source
# psy-rd=1.0,0.15 : psychovisual RD, preserves sharp detail (terminal text)
# deblock=-1,-1   : loosens deblocking, keeps edges (text) crisp
# High profile    : enables 8x8 transform (gradient-friendly)
X264_TUNE="aq-mode=3:aq-strength=1.0:psy-rd=1.0,0.15:deblock=-1,-1"

# ---- Color (Rec.709 SDR, project standard) ----
COLOR="-pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709"

# ---- Ladder: name | resolution | crf | maxrate | bufsize ----
# capped-CRF: CRF targets quality, maxrate caps the peaks.
# Test data: CRF 16 -> avg 2.7 Mbps. maxrate set high enough to not clip peaks.
LADDER=(
  "1080p|1920x1080|16|8000k|16000k"
  "720p|1280x720|18|5000k|10000k"
)

VARIANT_PLAYLISTS=()
BANDWIDTHS=()
RESOLUTIONS=()

for entry in "${LADDER[@]}"; do
  IFS='|' read -r rname res crf maxrate bufsize <<< "$entry"
  echo ">>> Encoding $rname ($res, crf=$crf, maxrate=$maxrate)..."

  rdir="$OUTDIR/$rname"
  mkdir -p "$rdir"

  ffmpeg -y -i "$INPUT" \
    -vf "scale=${res/x/:}:flags=lanczos" \
    -c:v libx264 \
    -profile:v high \
    -preset veryslow \
    -crf "$crf" \
    -maxrate "$maxrate" \
    -bufsize "$bufsize" \
    -x264-params "$X264_TUNE:keyint=$GOP:min-keyint=$GOP:scenecut=0" \
    $COLOR \
    -c:a aac -b:a 192k -ac 2 \
    -force_key_frames "expr:gte(t,n_forced*$SEG_SECONDS)" \
    -hls_time "$SEG_SECONDS" \
    -hls_playlist_type vod \
    -hls_segment_type fmp4 \
    -hls_fmp4_init_filename "init.mp4" \
    -hls_segment_filename "$rdir/seg_%04d.m4s" \
    -hls_flags independent_segments \
    "$rdir/playlist.m3u8"

  bw=$(( ${maxrate%k} * 1000 ))
  VARIANT_PLAYLISTS+=("$rname/playlist.m3u8")
  BANDWIDTHS+=("$bw")
  RESOLUTIONS+=("$res")
done

# ---- master.m3u8 ----
echo ">>> Generating master.m3u8..."
{
  echo "#EXTM3U"
  echo "#EXT-X-VERSION:7"
  for i in "${!VARIANT_PLAYLISTS[@]}"; do
    echo "#EXT-X-STREAM-INF:BANDWIDTH=${BANDWIDTHS[$i]},RESOLUTION=${RESOLUTIONS[$i]}"
    echo "${VARIANT_PLAYLISTS[$i]}"
  done
} > "$OUTDIR/master.m3u8"

echo ""
echo "=== ENCODE COMPLETE ==="
echo "Output: $OUTDIR"
echo "Master: $OUTDIR/master.m3u8"
echo ""
find "$OUTDIR" -type f | sort
echo ""
echo "Total size:"; du -sh "$OUTDIR"
echo ""
echo "=== NEXT STEP: upload to R2 ==="
echo "# Segments + init (long cache):"
echo "rclone copy \"$OUTDIR\" r2-phantom-media:phantom-media/$NAME \\"
echo "  --exclude \"*.m3u8\" \\"
echo "  --header-upload \"Cache-Control: public, max-age=31536000, immutable\" \\"
echo "  --s3-no-check-bucket --progress"
echo ""
echo "# Manifests (.m3u8, correct content-type):"
echo "rclone copy \"$OUTDIR\" r2-phantom-media:phantom-media/$NAME \\"
echo "  --include \"*.m3u8\" \\"
echo "  --header-upload \"Content-Type: application/vnd.apple.mpegurl\" \\"
echo "  --header-upload \"Cache-Control: no-cache\" \\"
echo "  --s3-no-check-bucket --progress"
echo ""
echo "# Verify:"
echo "curl -sI https://media.phantom.tc/$NAME/master.m3u8 | grep -i 'content-type\\|cache-control'"
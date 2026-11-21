# The parts of FFmpeg that Mikage's engines use; scripts/build-ffmpeg-ios.sh
# enables these and nothing else. Every engine shares this one build:
#
# - KiriKiri (krmovie layer/overlay movies, and the wuffmpeg sound decoder
#   that takes the files its WAV, Vorbis and Opus decoders refuse)
# - ONScripter (mpegplay, movie and avi)
# - openArtemis (every movie that isn't Ogg Theora)
# - Ren'Py (all sound and music, and movies)
# - Siglus (the H.264 High 10 frames in UCI images)
#
# Add a decoder here when a game needs one. Its demuxer usually has to be
# added too, and a parser if the container doesn't frame packets itself.

FFMPEG_VIDEO_DECODERS=(
    # MP4 / MOV, and Siglus UCI images (High 10 is software-only)
    h264 hevc
    # .mpg (MPEG-1 and MPEG-2 program streams)
    mpeg1video mpeg2video
    # Windows Media
    wmv1 wmv2 wmv3 vc1
    # AVI from the DivX / Video for Windows years
    mpeg4 h263 msmpeg4v1 msmpeg4v2 msmpeg4v3 cinepak msvideo1 msrle
    indeo3 indeo4 indeo5 mjpeg rawvideo
    # Ogg and WebM (Ren'Py, some KiriKiri Z games)
    theora vp8 vp9
)

FFMPEG_AUDIO_DECODERS=(
    aac mp1 mp1float mp2 mp2float mp3 mp3float ac3 eac3
    vorbis opus flac alac
    wmav1 wmav2 wmapro
    pcm_u8 pcm_s16le pcm_s16be pcm_s24le pcm_s32le pcm_f32le pcm_alaw pcm_mulaw
    adpcm_ms adpcm_ima_wav
)

FFMPEG_DEMUXERS=(
    mov mpegps mpegts mpegvideo m4v h264 hevc
    asf avi matroska ogg
    aac ac3 mp3 flac wav aiff
)

FFMPEG_PARSERS=(
    h264 hevc mpegvideo mpeg4video vc1 mjpeg vp8 vp9
    aac ac3 mpegaudio vorbis opus flac
)

# Hardware decoding for engines that ask for it (none does yet).
FFMPEG_HWACCELS=(
    h264_videotoolbox hevc_videotoolbox vp9_videotoolbox
)

FFMPEG_PROTOCOLS=(
    # ONScripter opens loose movie files by path.
    file
)

# configure flags for the lists above. Plain arrays only: macOS ships bash 3.2.
FFMPEG_COMPONENT_FLAGS=()
for name in "${FFMPEG_VIDEO_DECODERS[@]}" "${FFMPEG_AUDIO_DECODERS[@]}"; do FFMPEG_COMPONENT_FLAGS+=("--enable-decoder=${name}"); done
for name in "${FFMPEG_DEMUXERS[@]}"; do FFMPEG_COMPONENT_FLAGS+=("--enable-demuxer=${name}"); done
for name in "${FFMPEG_PARSERS[@]}"; do FFMPEG_COMPONENT_FLAGS+=("--enable-parser=${name}"); done
for name in "${FFMPEG_PROTOCOLS[@]}"; do FFMPEG_COMPONENT_FLAGS+=("--enable-protocol=${name}"); done
unset name

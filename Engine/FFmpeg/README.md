# Shared FFmpeg

`scripts/build-ffmpeg-ios.sh` builds FFmpeg 7.1.2 from the release tarball as `build/FFmpeg.xcframework`: one dynamic framework per SDK, embedded once in the app. KiriKiri, ONScripter, openArtemis, Ren'Py and Siglus link it instead of each carrying a static copy. The framework's `Headers/` holds the usual `libavcodec/`, `libavformat/`, `libavutil/`, `libswresample/` and `libswscale/` trees, and only the `av*`/`sw*` API is exported.

Only what the engines use is built: the decoders, demuxers, parsers and protocol listed in `components.sh`, plus VideoToolbox hwaccels for H.264, HEVC and VP9. To support a new format, add its decoder there (and its demuxer, and a parser if the container needs one).

`patches/0001-aarch64-swscale-ifc-comments.patch` is vcpkg's `0020-fix-aarch64-libswscale.patch`, which the KiriKiri vcpkg build applied before.

FFmpeg is LGPL-2.1-or-later in this configuration (no `--enable-gpl` or `--enable-nonfree`).

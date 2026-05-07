# Enable x264enc (H.264 software encoder) required by wendy-agent video streaming fallback.
# x264 has a commercial LICENSE_FLAGS; accepted globally in wendyos.conf.
PACKAGECONFIG:append = " x264"

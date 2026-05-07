# Enable vp8enc + webmmux (VP8 fallback) required by wendy-agent video streaming.
# libvpx is available from meta-openembedded/meta-oe.
PACKAGECONFIG:append = " vpx"

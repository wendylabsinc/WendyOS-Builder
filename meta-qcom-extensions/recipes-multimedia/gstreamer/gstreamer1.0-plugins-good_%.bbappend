# Drop the two meta-qcom format-table patches that no longer apply to oe-core's
# gstreamer, and keep the five that do.
#
# 0001 (QC08C) and 0010 (QC10C) each insert one row into gst_v4l2_formats[] in
# sys/v4l2/gstv4l2object.c. Their context lines all carry
# "GST_V4L2_RAW | GST_V4L2_MPLANE", but gstreamer 1.28.5 removed the MPLANE flag
# from exactly those rows, so neither hunk can anchor. Verified by dry-run: only
# these two fail; 0002/0004/0006/0007/0008 apply cleanly and are left in place,
# so the V4L2 encoder/decoder fixes (colorimetry, aligned allocation, empty
# bytesused buffers, GAP handling) are retained.
#
# Cost of dropping them: the v4l2 elements do not advertise Qualcomm's compressed
# UBWC formats, so hardware decode/encode falls back to plain NV12 rather than the
# bandwidth-efficient compressed path. Video still works; multi-stream bandwidth
# headroom is lower.
#
# Not fixable by waiting for upstream: both patches are Upstream-Status: Denied
# (freedesktop rejected NV12_Q08C), so meta-qcom carries them permanently and has
# to rebase them for 1.28.5. Re-test on every SRCREV_QCOM or oe-core gstreamer
# bump and delete this file once they apply again.
SRC_URI:remove = " \
    file://0001-v4l2-Add-support-for-V4L2_PIX_FMT_QC08C-format.patch \
    file://0010-v4l2-Add-support-for-V4L2_PIX_FMT_QC10C-format.patch \
    "

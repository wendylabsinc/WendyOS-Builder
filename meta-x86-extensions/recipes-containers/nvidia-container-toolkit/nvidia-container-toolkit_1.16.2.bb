SUMMARY = "NVIDIA Container Toolkit (nvidia-ctk) for CDI device generation"
DESCRIPTION = "The NVIDIA Container Toolkit CLI (nvidia-ctk) and runtime. On WendyOS \
x86 it is used to generate the CDI spec (/etc/cdi/nvidia.yaml) that containerd and \
nerdctl consume for GPU access. Device enumeration goes through NVML, which is \
shipped by nvidia-userspace, so the legacy libnvidia-container path is not needed."
HOMEPAGE = "https://github.com/NVIDIA/nvidia-container-toolkit"

LICENSE = "Apache-2.0 & MIT & ISC & MPL-2.0 & (Apache-2.0 | MIT) & BSD-3-Clause"
LIC_FILES_CHKSUM = " \
    file://src/${GO_IMPORT}/LICENSE;md5=3b83ef96387f14655fc854ddc3c6bd57 \
    file://src/${GO_IMPORT}/vendor/tags.cncf.io/container-device-interface/LICENSE;md5=86d3f3a95c324c9479bd8986968f4327 \
    file://src/${GO_IMPORT}/vendor/github.com/davecgh/go-spew/LICENSE;md5=c06795ed54b2a35ebeeb543cd3a73e56 \
    file://src/${GO_IMPORT}/vendor/github.com/fsnotify/fsnotify/LICENSE;md5=8bae8b116e2cfd723492b02d9a212fe2 \
    file://src/${GO_IMPORT}/vendor/github.com/NVIDIA/go-nvml/LICENSE;md5=3b83ef96387f14655fc854ddc3c6bd57 \
    file://src/${GO_IMPORT}/vendor/github.com/opencontainers/runtime-spec/LICENSE;md5=b355a61a394a504dacde901c958f662c \
    file://src/${GO_IMPORT}/vendor/github.com/opencontainers/runtime-tools/LICENSE;md5=b355a61a394a504dacde901c958f662c \
    file://src/${GO_IMPORT}/vendor/github.com/pelletier/go-toml/LICENSE;md5=e49b63d868761700c5df76e7946d0bd7 \
    file://src/${GO_IMPORT}/vendor/github.com/pmezard/go-difflib/LICENSE;md5=e9a2ebb8de779a07500ddecca806145e \
    file://src/${GO_IMPORT}/vendor/github.com/sirupsen/logrus/LICENSE;md5=8dadfef729c08ec4e631c4f6fc5d43a0 \
    file://src/${GO_IMPORT}/vendor/github.com/stretchr/testify/LICENSE;md5=188f01994659f3c0d310612333d2a26f \
    file://src/${GO_IMPORT}/vendor/github.com/syndtr/gocapability/LICENSE;md5=a7304f5073e7be4ba7bffabbf9f2bbca \
    file://src/${GO_IMPORT}/vendor/github.com/urfave/cli/v2/LICENSE;md5=51992c80b05795f59c22028d39f9b74c \
    file://src/${GO_IMPORT}/vendor/github.com/NVIDIA/go-nvlib/LICENSE;md5=3b83ef96387f14655fc854ddc3c6bd57 \
    file://src/${GO_IMPORT}/vendor/golang.org/x/mod/LICENSE;md5=7998cb338f82d15c0eff93b7004d272a \
    file://src/${GO_IMPORT}/vendor/golang.org/x/sys/LICENSE;md5=7998cb338f82d15c0eff93b7004d272a \
    file://src/${GO_IMPORT}/vendor/gopkg.in/yaml.v2/LICENSE;md5=e3fc50a88d0a364313df4b21ef20c29e \
    file://src/${GO_IMPORT}/vendor/gopkg.in/yaml.v3/LICENSE;md5=3c91c17266710e16afdbb2b6d15c761c \
    file://src/${GO_IMPORT}/vendor/sigs.k8s.io/yaml/LICENSE;md5=0ceb9ff3b27d3a8cf451ca3785d73c71 \
    "

GO_IMPORT = "github.com/NVIDIA/nvidia-container-toolkit"
GO_INSTALL = "${GO_IMPORT}/cmd/..."

# blacksail's go.bbclass defines GO_SRCURI_DESTSUFFIX; provide the same value as
# a fallback so the clone lands at ${S}/src/${GO_IMPORT} (the GOPATH layout the
# go class builds from). Mirrors recipes-core/wendyos-update.
GO_SRCURI_DESTSUFFIX ?= "${@os.path.join(os.path.basename(d.getVar('S')), 'src', d.getVar('GO_IMPORT')) + '/'}"

SRC_URI = "git://${GO_IMPORT};protocol=https;branch=release-1.16;destsuffix=${GO_SRCURI_DESTSUFFIX}"
SRCREV = "a5a5833c14a15fd9c86bcece85d5ec6621b65652"

# Build offline from the committed vendor/ tree (reproducible, no module fetch).
GOBUILDFLAGS:append = " -mod=vendor -buildvcs=false"

# go-nvml resolves NVML symbols at runtime, which needs lazy dynamic binding.
SECURITY_LDFLAGS = ""
LDFLAGS += "-Wl,-z,lazy"
GO_LINKSHARED = ""
GO_EXTRA_LDFLAGS:append = " \
    -X ${GO_IMPORT}/internal/info.version=${GITPKGVTAG} \
    -X ${GO_IMPORT}/internal/info.gitCommit=${GITPKGV} \
    "

COMPATIBLE_MACHINE = "genericx86-64-wendyos"

REQUIRED_DISTRO_FEATURES = "virtualization"

inherit go-mod gitpkgv features_check

# nvidia-ctk cdi generate enumerates the GPU through NVML (nvidia-userspace).
RDEPENDS:${PN} = "nvidia-userspace"

# go_do_install puts the whole source tree in -dev (not shipped in the image);
# its test scripts and packaging rules reference bash/make, so satisfy the QA
# file-rdeps check.
RDEPENDS:${PN}-dev += "bash make"

do_install:append() {
    ln -sf nvidia-container-runtime-hook ${D}${bindir}/nvidia-container-toolkit
}

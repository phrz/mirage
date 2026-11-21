# The Linux host's release build (x86_64 or aarch64, the builder's own): Ubuntu 26.04 with Swift, the system libraries'
# headers, msquic built static. linux/release.sh runs it on a Linux machine with Docker (default: bigrig, over SSH) and
# takes the stripped binary out; the build number and commit come in as arguments, so the checkout is never stamped.
FROM swift:6.4.3-resolute AS base
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
        cmake ninja-build pkg-config git perl ca-certificates binutils \
        libpipewire-0.3-dev libglib2.0-dev libx265-dev libnuma-dev libdrm-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*
ARG MSQUIC=v2.6.4
RUN git clone -q --depth 1 -b "$MSQUIC" --recurse-submodules --shallow-submodules https://github.com/microsoft/msquic.git /opt/msquic \
    && cmake -S /opt/msquic -B /opt/msquic/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DQUIC_BUILD_SHARED=OFF -DQUIC_BUILD_TOOLS=OFF \
        -DQUIC_BUILD_TEST=OFF -DQUIC_BUILD_PERF=OFF -DQUIC_ENABLE_LOGGING=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=/usr/local \
    && cmake --build /opt/msquic/build && cmake --install /opt/msquic/build && rm -rf /opt/msquic

FROM base AS build
WORKDIR /src
# Package manifests first: the dependency fetch is cached until they change.
COPY linux/Package.swift linux/Package.resolved* linux/
COPY Sources Sources
COPY linux/Sources linux/Sources
ARG BUILD=0
ARG COMMIT=dev
RUN sed -i -e "s/static let number = [0-9]*/static let number = $BUILD/" -e "s/static let commit = \"[^\"]*\"/static let commit = \"$COMMIT\"/" \
        linux/Sources/mirage-host/LinuxBuild.swift \
    && cd linux && swift build -c release --static-swift-stdlib \
    && mkdir -p /out && cp "$(swift build -c release --show-bin-path)/mirage-host" /out/mirage-host && strip /out/mirage-host \
    && /out/mirage-host version

# syntax=docker/dockerfile:1
#
# Build image for Legends of Azeroth - Pandaria 5.4.8 (TrinityCore-based MoP core).
#
# Package list mirrors the project's own CI (.github/workflows/linux_gcc.yml), which builds
# successfully on ubuntu-24.04 with: libboost-all-dev g++-13 libreadline-dev libbz2-dev.
# Everything else (StormLib, zlib, bzip2, g3dlite, jemalloc, SFMT, utf8cpp, recastnavigation,
# gsoap) is vendored under dep/ and compiled from source, so no extra system packages are
# needed for those.

FROM ubuntu:24.04 AS build

ARG BUILD_TYPE=Release
ARG CMAKE_INSTALL_PREFIX=/azerothcore
# Build flags, see cmake/options.cmake. Playerbots is OFF by default: it needs its own
# database and the project recommends disabling Eluna when bots are enabled (see AGENTS.md).
ARG WITH_TOOLS=1
ARG WITH_SCRIPTS=1
ARG WITH_ELUNA=1
ARG WITH_PLAYERBOTS=0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        ca-certificates \
        pkg-config \
        libboost-all-dev \
        libreadline-dev \
        libbz2-dev \
        libssl-dev \
        default-libmysqlclient-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/core
# Copy only what cmake/make actually need (not docker/, sql/, docs, etc.) so editing
# unrelated files (docker-compose.yml, entrypoint.sh, README...) never busts the cache
# for this expensive step -- only a real source change does.
COPY CMakeLists.txt PreLoad.cmake revision.h.in.cmake ./
COPY cmake/ cmake/
COPY dep/ dep/
COPY modules/ modules/
COPY src/ src/

RUN mkdir -p /usr/src/core/build && cd /usr/src/core/build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
        -DCMAKE_INSTALL_PREFIX="${CMAKE_INSTALL_PREFIX}" \
        -DSERVERS=1 \
        -DSCRIPTS="${WITH_SCRIPTS}" \
        -DTOOLS="${WITH_TOOLS}" \
        -DELUNA="${WITH_ELUNA}" \
        -DPLAYERBOTS="${WITH_PLAYERBOTS}" && \
    make -j"$(nproc)" && \
    make install && \
    cp -r "${CMAKE_INSTALL_PREFIX}/etc" "${CMAKE_INSTALL_PREFIX}/etc.dist-backup"


FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ARG CMAKE_INSTALL_PREFIX=/azerothcore

RUN apt-get update && apt-get install -y --no-install-recommends \
        libssl3 \
        libreadline8 \
        libbz2-1.0 \
        libmysqlclient21 \
        libboost-filesystem1.83.0 \
        libboost-program-options1.83.0 \
        ca-certificates \
        default-mysql-client \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build ${CMAKE_INSTALL_PREFIX} /azerothcore
COPY sql/base /azerothcore/sql/base
COPY sql/updates /azerothcore/sql/updates
COPY docker/entrypoint.sh /azerothcore/entrypoint.sh
RUN chmod +x /azerothcore/entrypoint.sh && \
    mkdir -p /azerothcore/run

ENV PATH="/azerothcore/bin:${PATH}"
WORKDIR /azerothcore
ENTRYPOINT ["/azerothcore/entrypoint.sh"]
CMD ["worldserver"]

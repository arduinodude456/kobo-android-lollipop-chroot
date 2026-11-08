# Host repo sync deliberately runs outside this Python 2 / glibc 2.19 image.
ARG LEGACY_IMAGE=ubuntu:14.04@sha256:881afbae521c910f764f7187dbfbca3cc10c26f8bafa458c76dda009a901c29d
FROM ${LEGACY_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive LANG=C LC_ALL=C
RUN printf '%s\n' \
    'deb http://old-releases.ubuntu.com/ubuntu/ trusty main restricted universe multiverse' \
    'deb http://old-releases.ubuntu.com/ubuntu/ trusty-updates main restricted universe multiverse' \
    'deb http://old-releases.ubuntu.com/ubuntu/ trusty-security main restricted universe multiverse' \
    > /etc/apt/sources.list \
 && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99archive \
 && dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
    openjdk-7-jdk python python-mako python-markdown \
    build-essential gcc-4.8 g++-4.8 gcc-multilib g++-multilib \
    git-core gnupg flex bison gperf zip unzip curl ca-certificates \
    zlib1g-dev lib32z1-dev libc6-dev-i386 lib32ncurses5-dev \
    libncurses5:i386 libstdc++6:i386 zlib1g:i386 \
    libx11-dev x11proto-core-dev libgl1-mesa-dev libsdl1.2-dev \
    libxml2-utils xsltproc libssl-dev bc rsync file patch \
 && rm -rf /var/lib/apt/lists/*
ENV JAVA_HOME=/usr/lib/jvm/java-7-openjdk-amd64
ENV PATH=/usr/lib/jvm/java-7-openjdk-amd64/bin:$PATH
# No modern host compiler or glibc is bind-mounted into this environment.
WORKDIR /aosp

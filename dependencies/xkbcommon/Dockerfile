FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517
ADD --chmod=0644 --checksum=sha256:f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9 https://curl.se/ca/cacert-2026-08-13.pem /etc/ssl/certs/ca-certificates.crt
RUN chmod 0755 /etc/ssl /etc/ssl/certs && sed -i '/^Types:/a Snapshot: yes' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get -o Acquire::https::CaInfo=/etc/ssl/certs/ca-certificates.crt -o APT::Update::Error-Mode=any --snapshot 20260909T000000Z update \
    && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::https::CaInfo=/etc/ssl/certs/ca-certificates.crt --snapshot 20260909T000000Z install -y --no-install-recommends \
       xz-utils pkg-config ca-certificates python3 bison ninja-build libxcb1-dev libxcb-xkb-dev \
    && rm -rf /var/lib/apt/lists/*
ADD --chmod=0644 --checksum=sha256:70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz /tmp/zig.tar.xz
RUN mkdir /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz

ADD --checksum=sha256:88afe0c20e52030218924ac37d0c81c59b4b5f3ae3752c8c6d7470c7d365886c https://files.pythonhosted.org/packages/48/91/d58a3eb45ed54bf32b96806dd2f4efd407f7a9675953e15e8ef257840a0d/meson-1.12.0.tar.gz /tmp/meson.tar.gz
RUN mkdir /opt/meson && tar -xzf /tmp/meson.tar.gz -C /opt/meson --strip-components=1
ENV PYTHONPATH=/opt/meson

FROM ubuntu:24.04@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517
ADD --chmod=0644 --checksum=sha256:f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9 https://curl.se/ca/cacert-2026-08-13.pem /etc/ssl/certs/ca-certificates.crt
RUN chmod 0755 /etc/ssl /etc/ssl/certs && sed -i '/^Types:/a Snapshot: yes' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get -o Acquire::https::CaInfo=/etc/ssl/certs/ca-certificates.crt -o APT::Update::Error-Mode=any --snapshot 20260909T000000Z update \
    && DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::https::CaInfo=/etc/ssl/certs/ca-certificates.crt --snapshot 20260909T000000Z install -y --no-install-recommends \
       ca-certificates python3 \
    && rm -rf /var/lib/apt/lists/*

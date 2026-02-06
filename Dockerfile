FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        curl \
        iproute2 \
        iptables \
        net-tools \
        tcpdump \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY ssh-guard.sh /usr/local/bin/ssh-guard
COPY sendmail.sh /usr/local/bin/sendmail.sh
COPY install.sh /usr/local/bin/install.sh

RUN chmod +x /usr/local/bin/ssh-guard \
    /usr/local/bin/sendmail.sh \
    /usr/local/bin/install.sh

ENTRYPOINT ["/usr/local/bin/ssh-guard"]
CMD ["start"]

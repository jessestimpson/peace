# A node of the Jepsen test: Erlang, an SSH server and the tools that the
# Jepsen nemeses use.
FROM erlang:28-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server iptables iproute2 psmisc procps sudo curl tar \
        bzip2 gzip gcc libc6-dev faketime \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /root/.ssh \
    && (update-alternatives --set iptables /usr/sbin/iptables-legacy || true) \
    && printf 'PermitRootLogin yes\nPubkeyAuthentication yes\nPasswordAuthentication no\nMaxStartups 100:30:200\nMaxSessions 100\n' \
        > /etc/ssh/sshd_config.d/jepsen.conf

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]

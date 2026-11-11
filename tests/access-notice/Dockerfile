FROM debian:bookworm-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential libpam0g-dev openssh-server openssh-client python3 python3-pexpect \
    && rm -rf /var/lib/apt/lists/*
COPY recipes-security/wendyos-access-notice/files/ /src/
COPY recipes-connectivity/openssh/files/usg-notice-sshd.conf /src/
COPY tests/access-notice/ /tests/
RUN cc -Wall -Wextra -Werror -fPIC -shared /src/pam_wendy_notice.c -lpam -o /usr/lib/$(gcc -dumpmachine)/security/pam_wendy_notice.so \
    && cc -Wall -Wextra -Werror /tests/pam-probe.c -lpam -o /tests/pam-probe \
    && mkdir -p /usr/share/wendyos-access-notice /run/sshd \
    && cp /src/usg-notice /usr/share/wendyos-access-notice/usg-notice
CMD ["python3", "/tests/integration.py"]

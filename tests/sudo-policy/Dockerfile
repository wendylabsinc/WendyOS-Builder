FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends sudo python3 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/sh wendy \
    && useradd --create-home --shell /bin/sh unrelated \
    && passwd --lock root
COPY recipes-extended/sudo/files/wendyos-sudoers /etc/sudoers.d/wendy
RUN chmod 0440 /etc/sudoers.d/wendy && visudo --check
COPY tests/sudo-policy/test_policy.py /test_policy.py
ENTRYPOINT ["python3", "/test_policy.py"]

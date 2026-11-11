FROM debian:bookworm-slim
ENV WENDY_PAM_TEST_CONTAINER=1
RUN apt-get update && apt-get install -y --no-install-recommends \
        passwd libpam-pwquality cracklib-runtime python3 \
    && rm -rf /var/lib/apt/lists/*
COPY recipes-extended/pam/files/pam.d/common-password /etc/pam.d/common-password
COPY recipes-extended/wendyos-user/wendyos-user_1.0.bb /test/wendyos-user.bb
COPY tests/local-credentials/test_credentials.py /test/test_credentials.py
CMD ["python3", "/test/test_credentials.py"]

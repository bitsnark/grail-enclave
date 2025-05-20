FROM python:3.12-alpine
ENV PYTHONUNBUFFERED=1
RUN apk add --no-cache libsecp256k1
ADD ./enclave-server /enclave-server
RUN pip install ./enclave-server
WORKDIR /enclave-server
RUN cat <<'EOF' > /enclave-server/run.sh
#!/bin/sh
python -m signer
EOF
RUN chmod +x /enclave-server/run.sh
CMD ["/enclave-server/run.sh"]

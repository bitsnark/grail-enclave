FROM python:3.12-alpine
RUN apk add --no-cache libsecp256k1
ADD ./enclave-server /enclave-server
RUN pip install ./enclave-server
WORKDIR /enclave-server
CMD ["python", "-m", "signer"]

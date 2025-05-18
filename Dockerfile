FROM python:3.12-alpine
ADD ./enclave-server /enclave-server
RUN pip install ./enclave-server
WORKDIR /enclave-server
CMD ["python", "-m", "signer"]

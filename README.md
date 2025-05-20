# Grail Enclave

A trusted environment that signs Bitcoin transactions when provided with valid zk-SNARK proofs of BTC lock and xBTC burn.

## Overview

The enclave is signed and attested by the AWS Nitro Hypervisor, so we can fully trust it. The parent (host) is under the control of the operator, so it must never be trusted.

The enclave runs the Python `./enclave-server/signer` package which listens for commands on a vsock socket. The parent runs a `kms-vsock` proxy which securely relays requests from the enclave to Amazon's KMS, the `./parent-manager/allfather` package which initializes the enclave and exposes its signing capabilities to the outside world through WSGI, and of course the AWS Nitro Enclaves itself - all of which is managed by `grail-pro.service`.

Enclaves generate their own private keys and only expose them in a KMS encrypted format to the parent. The `./kms-policy` is set to only allow attested enclaves to decrypt the keys and to never allow anyone to change this, so the encrypted keys can be safely backed up and published.

Operators register the enclaves with the `grail-pro` smart contract, which is responsible for managing the list of trusted and attested enclaves and their keys.

## Trust and Key Policy

The smart contract trusts the Nitro Hypervisor to attest for the signing enclaves.

The operator also trusts the Nitro Hypervisor's attestation, and sets his KMS policy to only allow decryption requests made by well attested enclaves.

The Hypervisor can attest for different "measurements", which are hashes of different "plattform configuration registers" or PCRs:
- PCR0: The enclave image itself
- PCR1: The enclave's kernel and boot ramdisk
- PCR2: The application running inside the enclave
- PCR3: The IAM role of the enclave's parent
- PCR4: The ID of the enclave's parent
- PCR8: An optional certificate signed by the enclave's parent

0, 1 and 2 are critical, and have to be checked by both the contract and the KMS.

3 is completely under the operator's control, and is probably unimportant to the contract (although it can be used to implement a whitelist). It can be used by the KMS to only allow decryption requests from enclaves belonging to a specific operator account; otherwise anyone in the world can run an enclave with the ability to decrypt his keys (which may be a good thing).

4 is just bad and should not be used.

5 might be interesting to the contract, giving the operator a clean way to sign his ownership of an enclave and its key.

## Storage of Encrypted Keys

The encrypted keys need to be backed up so that they can be used to recover the enclave in case of a failure, or create more enclaves with the same key for load balancing. If the KMS is not set to enforce PCR3, meaning that the operator is letting any operator run an enclave on his behalf (this can add to trust and reduce the need for slashing and transaction recycling, although it is always possible for the operator to shut down his KMS).

In any events, only well attested enclaves can decrypt the keys, so they can be safely stored pretty much anywhere and if they are published it might even make sense to store them in the smart contract itself.

## Life Cycle

The enclave is started by `grail-pro.service` which runs `kms-vsock`, starts the enclave and passes control to the parent manager. Once the enclave starts it waits for the parent manager to initialize it with a `set_key` command before doing anything else.

If the `GRAIL_PUBKEY` environment variable is set, the parent manager gets the matching KMS encrypted private key from the key storage (throwing and logging an error if no match is found) and passes it to the enclave with the `set_key` command (in which case it also verifies that the enclave derives the correct public key from the encrypted private key, throwing an error if it doesn't). If the `GRAIL_PUBKEY` environment variable is not set it calls `set_key` with no arguments and a new key is generated and encrypted.

In both cases, the enclave returns a signed attestation from the Hypervisor, a KMS encrypted private key and its matching (plane text) public key, which the parent logs and the operator monitors.

Lastly, the parent manager starts listening for requests coming in from HTTP clients (through a WSGI application server) to pass `sign` requests to the enclave, containing unsigned Bitcoin transactions to sign and zk-SNARK proofs of BTC locking or of xBTC burn. This too is logged and monitored.

## Enclave Commands

### `set_key`

This command sets the secret key of the enclave and is called only once, directly from the parent, right after startup.

If no arguments are provided, the enclave generates a new key for future `sign` operations, and then retrieves a public key from the KMS and uses it to encrypt the new key for export. If an encrypted key is provided, the enclave decrypts it using KMS and uses it on future `sign` operations.

In both cases the enclave will derive a public key from the private key and request a signed attestation from the Hypervisor, returning all three elements to the parent: the KMS encrypted private key, the public key and the attestation.

Note: If this is a new key it needs to be registered (and staked) with the `grail-pro` smart contract, which checks the attestation. This process can be automated, in which case we will probably use the enclave to sign the transaction (and the operator will fund a wallet it controls with whatever fees it requires), but for now we assume the operator performs this expensive operation using their own wallet. All the data required to perform the registration is returned to the parent manager which logs it.

Example request:
```json
{
    "command": "set_key",
    "args": {
        "encrypted_key": "<base64-encoded-encrypted-key>"
    }
}
```

Example response:
```json
{
    "public_key": "<base64-encoded-public-key>"
    "encrypted_key": "<base64-encoded-encrypted-key>",
    "attestation": "<base64-encoded-attestation>"
}
```

### `sign`

This command is initiated by an HTTP client which sends a JSON request containing an unsigned peg-in or peg-out transaction (passed in PSBT format) and a zk-SNARK proof of BTC lock or xBTC burn to the parent manager. The parent manager forwards the request to the enclave through the vsock socket and the enclave verifies the proof and signs the transaction (or returns an error). The signed transaction (or the error) is then returned to the parent manager which returns it to the HTTP client.

Example request:
```json
{
    "command": "sign",
    "args": {
        "type": "peg-in",
        "peg-in-id": "<base64-encoded-peg-in-id>",
        "proof": "<base64-encoded-proof>",
        "psbt": "<base64-encoded-psbt>"
    }
}
```

Example response:
```json
{
    "signature": "<base64-encoded-signature>"
}
```

## Transaction and Proof Types

The enclave can sign two types of transactions:

- `peg-in`: A transaction that mints xBTC using a Charmed minting NFT. Requires a proof that the txid of the PSBT that awaits signage will mint an amount of Charmed xBTC as specified in the peg-in corresponding the provided ID, and that matching funds were locked to the peg-in's specified list of public keys.
- `peg-out`: A transaction that unlocks funds from the grail-pro multisig. Requires a proof that the txid of the PSBT that awaits signage will spend the funds locked in the peg-in corresponding the provided ID, and that a matching amount of xBTC was burned.

## Deploying the Enclave

Start with a clean Amazon Linux 2023 m5.xlarge instance, with 360GB of storage, with the enclave options enabled (`--enclave-options 'Enabled=true'`).

Clone this repository and run the following commands:

```sh
sudo ./install.sh
```

This creates a new `grail` user, installs required dependencies, builds the enclave image and sets up the service.

You can verify that everything is working by running the following commands:

```sh
systemctl status grail-pro.service
```

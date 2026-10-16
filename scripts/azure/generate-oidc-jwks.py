#!/usr/bin/env python3
"""
Generate a JWKS (JSON Web Key Set) from an RSA public key file.
Used to publish the Kind cluster's OIDC JWKS endpoint for Azure Workload Identity.

Usage:
    python3 generate-oidc-jwks.py --public-key sa.pub --output jwks.json
"""
import argparse
import base64
import json
import struct
import sys


def int_to_base64url(n: int) -> str:
    length = (n.bit_length() + 7) // 8
    data = n.to_bytes(length, byteorder="big")
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def load_rsa_public_key(path: str):
    """Load RSA public key using only stdlib (no cryptography library needed)."""
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.backends import default_backend

        with open(path, "rb") as f:
            key = serialization.load_pem_public_key(f.read(), backend=default_backend())
        pub = key.public_key() if hasattr(key, "public_key") else key
        nums = pub.public_numbers()
        return nums.n, nums.e
    except ImportError:
        pass

    # Fallback: parse PEM/DER manually using only stdlib
    with open(path, "r") as f:
        pem = f.read()

    lines = [l for l in pem.splitlines() if not l.startswith("-----")]
    der = base64.b64decode("".join(lines))
    n, e = _parse_rsa_public_key_der(der)
    return n, e


def _parse_rsa_public_key_der(der: bytes):
    """
    Minimal DER parser for SubjectPublicKeyInfo (RSA).
    Handles the PKCS#8 SubjectPublicKeyInfo format produced by openssl rsa -pubout.
    """
    def read_length(data, pos):
        b = data[pos]
        pos += 1
        if b & 0x80:
            n = b & 0x7F
            length = int.from_bytes(data[pos:pos+n], "big")
            pos += n
        else:
            length = b
        return length, pos

    def read_tlv(data, pos):
        tag = data[pos]; pos += 1
        length, pos = read_length(data, pos)
        value = data[pos:pos+length]
        return tag, value, pos + length

    # SubjectPublicKeyInfo SEQUENCE
    tag, seq_val, _ = read_tlv(der, 0)
    assert tag == 0x30, "Expected SEQUENCE"

    # AlgorithmIdentifier SEQUENCE — skip it
    tag, alg_val, pos = read_tlv(seq_val, 0)
    assert tag == 0x30, "Expected AlgorithmIdentifier SEQUENCE"

    # BIT STRING containing the RSAPublicKey
    tag, bits_val, _ = read_tlv(seq_val, pos)
    assert tag == 0x03, "Expected BIT STRING"

    # Skip the unused-bits byte at the start of BIT STRING
    rsa_der = bits_val[1:]

    # RSAPublicKey SEQUENCE
    tag, rsa_seq, _ = read_tlv(rsa_der, 0)
    assert tag == 0x30, "Expected RSAPublicKey SEQUENCE"

    # modulus INTEGER
    tag, n_bytes, pos = read_tlv(rsa_seq, 0)
    assert tag == 0x02, "Expected INTEGER (modulus)"
    n = int.from_bytes(n_bytes, "big")

    # publicExponent INTEGER
    tag, e_bytes, _ = read_tlv(rsa_seq, pos)
    assert tag == 0x02, "Expected INTEGER (exponent)"
    e = int.from_bytes(e_bytes, "big")

    return n, e


def make_jwks(n: int, e: int, kid: str = "sa-signing-key") -> dict:
    """Build a JWKS document from RSA modulus and exponent."""
    return {
        "keys": [
            {
                "kty": "RSA",
                "use": "sig",
                "alg": "RS256",
                "kid": kid,
                "n": int_to_base64url(n),
                "e": int_to_base64url(e),
            }
        ]
    }


def main():
    parser = argparse.ArgumentParser(description="Generate JWKS from RSA public key")
    parser.add_argument("--public-key", required=True, help="Path to RSA public key PEM file")
    parser.add_argument("--output", required=True, help="Output JWKS JSON file path")
    parser.add_argument("--kid", default="sa-signing-key", help="Key ID (default: sa-signing-key)")
    args = parser.parse_args()

    try:
        n, e = load_rsa_public_key(args.public_key)
    except Exception as ex:
        print(f"ERROR: Failed to load public key from {args.public_key}: {ex}", file=sys.stderr)
        sys.exit(1)

    jwks = make_jwks(n, e, kid=args.kid)

    with open(args.output, "w") as f:
        json.dump(jwks, f, indent=2)

    print(f"JWKS written to {args.output} ({len(jwks['keys'])} key(s))")


if __name__ == "__main__":
    main()

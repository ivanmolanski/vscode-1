#!/usr/bin/env python3
"""Generate OCI API key pair and compute fingerprint."""
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend
import hashlib, binascii

# Generate key
private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048, backend=default_backend())

# Save private key
with open(r"C:\Users\dalkeith\.oci\oci_api_key.pem", "wb") as f:
    f.write(private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    ))

# Save public key
public_key = private_key.public_key()
with open(r"C:\Users\dalkeith\.oci\oci_api_key_public.pem", "wb") as f:
    f.write(public_key.public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo
    ))

# Compute fingerprint
der_bytes = public_key.public_bytes(encoding=serialization.Encoding.DER, format=serialization.PublicFormat.SubjectPublicKeyInfo)
md5_hash = hashlib.md5(der_bytes).digest()
fingerprint = ":".join(f"{b:02x}" for b in md5_hash)
print(f"Private key: C:\\Users\\dalkeith\\.oci\\oci_api_key.pem")
print(f"Public key:  C:\\Users\\dalkeith\\.oci\\oci_api_key_public.pem")
print(f"Fingerprint: {fingerprint}")

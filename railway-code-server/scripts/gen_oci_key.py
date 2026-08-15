#!/usr/bin/env python3
"""Generate OCI API key pair and compute fingerprint."""
import hashlib
import os
from pathlib import Path

from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

# Determine output directory
oci_dir = Path.home() / ".oci"
oci_dir.mkdir(mode=0o700, exist_ok=True)
oci_dir.chmod(0o700)

private_path = oci_dir / "oci_api_key.pem"
public_path = oci_dir / "oci_api_key_public.pem"

# Generate key
private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048, backend=default_backend())

# Save private key with restricted permissions — create file first then write
private_bytes = private_key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
)
fd = os.open(str(private_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
try:
    os.fchmod(fd, 0o600)
    os.write(fd, private_bytes)
finally:
    os.close(fd)

# Save public key
public_key = private_key.public_key()
public_path.write_bytes(
    public_key.public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
)

# Compute fingerprint
der_bytes = public_key.public_bytes(
    encoding=serialization.Encoding.DER,
    format=serialization.PublicFormat.SubjectPublicKeyInfo,
)
fingerprint = ":".join(f"{b:02x}" for b in hashlib.md5(der_bytes, usedforsecurity=False).digest())
print(f"Private key: {private_path}")
print(f"Public key:  {public_path}")
print(f"Fingerprint: {fingerprint}")

#!/usr/bin/env python3
import argparse
import base64
import hashlib
import struct
import sys
from pathlib import Path

FIELD_PRIME = 2**255 - 19
GROUP_ORDER = 2**252 + 27742317777372353535851937790883648493
ROOT_KEY_TYPE = "ROOT PUBLIC KEY"
SIGNING_KEY_TYPE = "SIGNING PUBLIC KEY"
PUBLIC_KEY_SIZE = 32
SIGNATURE_SIZE = 64


def _inverse(value):
    return pow(value, FIELD_PRIME - 2, FIELD_PRIME)


CURVE_D = -121665 * _inverse(121666) % FIELD_PRIME
SQRT_MINUS_ONE = pow(2, (FIELD_PRIME - 1) // 4, FIELD_PRIME)
IDENTITY = (0, 1, 1, 0)


def _point_add(left, right):
    a = (left[1] - left[0]) * (right[1] - right[0]) % FIELD_PRIME
    b = (left[1] + left[0]) * (right[1] + right[0]) % FIELD_PRIME
    c = 2 * left[3] * right[3] * CURVE_D % FIELD_PRIME
    d = 2 * left[2] * right[2] % FIELD_PRIME
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % FIELD_PRIME, g * h % FIELD_PRIME, f * g % FIELD_PRIME, e * h % FIELD_PRIME)


def _point_multiply(scalar, point):
    result = IDENTITY
    while scalar > 0:
        if scalar & 1:
            result = _point_add(result, point)
        point = _point_add(point, point)
        scalar >>= 1
    return result


def _points_equal(left, right):
    if (left[0] * right[2] - right[0] * left[2]) % FIELD_PRIME:
        return False
    return (left[1] * right[2] - right[1] * left[2]) % FIELD_PRIME == 0


def _recover_x(y, sign):
    if y >= FIELD_PRIME:
        return None
    x_squared = (y * y - 1) * _inverse(CURVE_D * y * y + 1) % FIELD_PRIME
    if x_squared == 0:
        return None if sign else 0
    x = pow(x_squared, (FIELD_PRIME + 3) // 8, FIELD_PRIME)
    if (x * x - x_squared) % FIELD_PRIME:
        x = x * SQRT_MINUS_ONE % FIELD_PRIME
    if (x * x - x_squared) % FIELD_PRIME:
        return None
    if (x & 1) != sign:
        x = FIELD_PRIME - x
    return x


def _decompress(encoded):
    if len(encoded) != PUBLIC_KEY_SIZE:
        return None
    y = int.from_bytes(encoded, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % FIELD_PRIME)


_BASE_Y = 4 * _inverse(5) % FIELD_PRIME
_BASE_X = _recover_x(_BASE_Y, 0)
BASE_POINT = (_BASE_X, _BASE_Y, 1, _BASE_X * _BASE_Y % FIELD_PRIME)


def ed25519_verify(public_key, message, signature):
    if len(public_key) != PUBLIC_KEY_SIZE or len(signature) != SIGNATURE_SIZE:
        return False
    public_point = _decompress(public_key)
    if public_point is None:
        return False
    encoded_r = signature[:32]
    r_point = _decompress(encoded_r)
    if r_point is None:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= GROUP_ORDER:
        return False
    digest = hashlib.sha512(encoded_r + public_key + message).digest()
    h = int.from_bytes(digest, "little") % GROUP_ORDER
    left = _point_multiply(s, BASE_POINT)
    right = _point_add(r_point, _point_multiply(h, public_point))
    return _points_equal(left, right)


def verify_any(keys, message, signature):
    return any(ed25519_verify(key, message, signature) for key in keys)


class VerificationError(Exception):
    pass


def parse_pem_keys(data, expected_type):
    begin = f"-----BEGIN {expected_type}-----"
    end = f"-----END {expected_type}-----"
    keys = []
    lines = data.decode("ascii").splitlines()
    index = 0
    while index < len(lines):
        line = lines[index].strip()
        if not line:
            index += 1
            continue
        if line != begin:
            raise VerificationError(f"unexpected PEM line, want {begin!r}: {line!r}")
        index += 1
        body = []
        while index < len(lines) and lines[index].strip() != end:
            body.append(lines[index].strip())
            index += 1
        if index == len(lines):
            raise VerificationError(f"missing {end!r}")
        key = base64.b64decode("".join(body), validate=True)
        if len(key) != PUBLIC_KEY_SIZE:
            raise VerificationError(f"key has {len(key)} bytes, want {PUBLIC_KEY_SIZE}")
        keys.append(key)
        index += 1
    if not keys:
        raise VerificationError(f"no {expected_type} found")
    return keys


def load_root_keys(roots_dir):
    pem_files = sorted(Path(roots_dir).glob("*.pem"))
    if not pem_files:
        raise VerificationError(f"no root keys in {roots_dir}")
    keys = []
    for pem_file in pem_files:
        keys.extend(parse_pem_keys(pem_file.read_bytes(), ROOT_KEY_TYPE))
    return keys


def package_message(package_path):
    hasher = hashlib.blake2s()
    size = 0
    with open(package_path, "rb") as package:
        for chunk in iter(lambda: package.read(1 << 20), b""):
            hasher.update(chunk)
            size += len(chunk)
    return hasher.digest() + struct.pack("<Q", size)


def verify_release(roots_dir, signing_keys_path, signing_keys_sig_path, package_path, package_sig_path):
    roots = load_root_keys(roots_dir)
    signing_bundle = Path(signing_keys_path).read_bytes()
    if not verify_any(roots, signing_bundle, Path(signing_keys_sig_path).read_bytes()):
        raise VerificationError("signing key bundle is not signed by a pinned root key")
    signing_keys = parse_pem_keys(signing_bundle, SIGNING_KEY_TYPE)
    message = package_message(package_path)
    if not verify_any(signing_keys, message, Path(package_sig_path).read_bytes()):
        raise VerificationError("package signature does not match any current signing key")


def main(argv):
    parser = argparse.ArgumentParser(description="Verify a Tailscale package with the distsign key chain.")
    parser.add_argument("--roots", required=True, help="directory with pinned ROOT PUBLIC KEY files")
    parser.add_argument("--signing-keys", required=True, help="distsign.pub from pkgs.tailscale.com")
    parser.add_argument("--signing-keys-sig", required=True, help="distsign.pub.sig")
    parser.add_argument("--package", required=True, help="downloaded package")
    parser.add_argument("--package-sig", required=True, help="package .sig file")
    args = parser.parse_args(argv)
    try:
        verify_release(args.roots, args.signing_keys, args.signing_keys_sig, args.package, args.package_sig)
    except (VerificationError, OSError, ValueError) as error:
        print(f"signature check failed: {error}", file=sys.stderr)
        return 1
    print("signature ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

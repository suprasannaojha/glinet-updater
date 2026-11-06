import hashlib
import struct
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

import distsign_verify as distsign

FIXTURES = REPO_ROOT / "tests" / "fixtures"
ROOTS = REPO_ROOT / "keys" / "tailscale"

RFC8032_VECTORS = [
    (
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        "",
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
    ),
    (
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
        "72",
        "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
    ),
    (
        "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
        "af82",
        "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
    ),
]


def vector(index):
    public, message, signature = RFC8032_VECTORS[index]
    return bytes.fromhex(public), bytes.fromhex(message), bytes.fromhex(signature)


def flip_byte(data, position):
    changed = bytearray(data)
    changed[position] ^= 0x01
    return bytes(changed)


class Ed25519Tests(unittest.TestCase):
    def test_rfc8032_vectors_verify(self):
        for index in range(len(RFC8032_VECTORS)):
            with self.subTest(vector=index + 1):
                self.assertTrue(distsign.ed25519_verify(*vector(index)))

    def test_changed_message_fails(self):
        public, message, signature = vector(2)
        self.assertFalse(distsign.ed25519_verify(public, flip_byte(message, 0), signature))

    def test_changed_signature_fails(self):
        public, message, signature = vector(1)
        self.assertFalse(distsign.ed25519_verify(public, message, flip_byte(signature, 5)))
        self.assertFalse(distsign.ed25519_verify(public, message, flip_byte(signature, 40)))

    def test_other_key_fails(self):
        _, message, signature = vector(0)
        other_public, _, _ = vector(1)
        self.assertFalse(distsign.ed25519_verify(other_public, message, signature))

    def test_wrong_sizes_fail(self):
        public, message, signature = vector(0)
        self.assertFalse(distsign.ed25519_verify(public[:31], message, signature))
        self.assertFalse(distsign.ed25519_verify(public, message, signature[:63]))


class KeyChainTests(unittest.TestCase):
    def test_pinned_root_keys_parse(self):
        self.assertEqual(len(distsign.load_root_keys(ROOTS)), 2)

    def test_signing_key_bundle_is_signed_by_a_pinned_root(self):
        bundle = (FIXTURES / "distsign.pub").read_bytes()
        signature = (FIXTURES / "distsign.pub.sig").read_bytes()
        self.assertTrue(distsign.verify_any(distsign.load_root_keys(ROOTS), bundle, signature))
        self.assertGreaterEqual(len(distsign.parse_pem_keys(bundle, distsign.SIGNING_KEY_TYPE)), 1)

    def test_changed_signing_key_bundle_is_rejected(self):
        bundle = (FIXTURES / "distsign.pub").read_bytes() + b"\n"
        signature = (FIXTURES / "distsign.pub.sig").read_bytes()
        self.assertFalse(distsign.verify_any(distsign.load_root_keys(ROOTS), bundle, signature))

    def test_root_key_is_not_accepted_as_signing_key(self):
        root_pem = next(ROOTS.glob("*.pem")).read_bytes()
        with self.assertRaises(distsign.VerificationError):
            distsign.parse_pem_keys(root_pem, distsign.SIGNING_KEY_TYPE)

    def test_package_message_is_blake2s_and_little_endian_length(self):
        with tempfile.NamedTemporaryFile() as package:
            package.write(b"abc")
            package.flush()
            expected = hashlib.blake2s(b"abc").digest() + struct.pack("<Q", 3)
            self.assertEqual(distsign.package_message(package.name), expected)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=1)

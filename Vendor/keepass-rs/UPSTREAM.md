Source: https://crates.io/crates/keepass/0.17.0
Repository: https://github.com/sseemayer/keepass-rs
Published crate version 0.17.0; MIT license preserved in LICENSE.
Published .crate SHA-256: 8025344cf174f72cccbac2a99640a8d1e82cf46922d57e06a45a32e49edfed16.
This source is vendored with the changes below; registry dependency versions and
checksums are pinned by KDBXHelper/Cargo.lock.

SSH Hub changes (2026-10-20):
- crypt/kdf.rs and crypt/mod.rs reject AES KDF >100 million rounds and Argon2
  >256 MiB, >100 iterations or >16 lanes before starting the KDF.
- compression.rs bounds decompressed payload to 32 MiB.
- Cargo.toml omits the unused, empty deprecated block-modes 0.9 crate.

The isolated helper also bounds the encrypted file to 64 MiB, key files to 1 MiB,
JSON frames, catalog size and lifetime.

SSH Hub editing changes (3.4.0):
- preserving.rs and the shared dump_kdbx4_payload writer retain the original XML
  tree and attachment IDs when editing KDBX4.0/4.1. New container random values
  are generated on save, with original KDF/cipher settings and header custom data.
  Protected XML values are re-encrypted in document order. A full decrypted
  round-trip comparison precedes file replacement. Unknown XML is retained;
  ambiguous identities/fields, DTD/entities and unsupported structures reject edits.
  Normal Database::save remains restricted to KDBX4.1. The helper owns fingerprint
  checks, exclusive staging, encrypted backup and atomic replacement; it never
  emits plaintext XML or keys into files, logs or arguments. KDBX3 remains read-only.
No original license text has been changed.

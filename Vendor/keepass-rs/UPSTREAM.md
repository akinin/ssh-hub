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
JSON frames, catalog size and lifetime. The production helper has no save feature.
No original license text has been changed.

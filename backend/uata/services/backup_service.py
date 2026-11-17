"""Encrypted backup / restore and full data wipe.

Backup file format (``.uatabak``)::

    magic      8 bytes   b"UATABAK1"
    header_len 4 bytes   big-endian uint32
    header     JSON      {"kdf": "scrypt", "n":…, "r":…, "p":…, "salt": hex, "nonce_prefix": hex, "chunk": int}
    chunks     repeated  [len uint32][AES-256-GCM ciphertext+tag]

The plaintext is a ZIP archive containing ``manifest.json``, ``uata.sqlite3`` and
``files/…``. Each chunk is encrypted with a nonce of ``nonce_prefix || counter``
and associated data ``header || counter || is_last`` so chunks cannot be
reordered, dropped or truncated without detection. The key is derived from the
user's passphrase with scrypt; the passphrase is never stored.

Backups contain: strategies, documents, extracted knowledge, settings, the
learning (audit) log, signals, trade results and test results — i.e. the whole
database plus the file store — so they can move between PC and phone.
"""

from __future__ import annotations

import json
import os
import shutil
import struct
import tempfile
import zipfile
from pathlib import Path
from typing import BinaryIO

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

from uata.config import ENGINE_VERSION, Paths
from uata.db.database import Database, audit, utcnow

MAGIC = b"UATABAK1"
CHUNK = 4 * 1024 * 1024
SCRYPT_N, SCRYPT_R, SCRYPT_P = 2 ** 15, 8, 1
MIN_PASSPHRASE = 10


class BackupError(Exception):
    pass


def _derive(passphrase: str, salt: bytes, n: int, r: int, p: int) -> bytes:
    return Scrypt(salt=salt, length=32, n=n, r=r, p=p).derive(passphrase.encode("utf-8"))


def encrypt_stream(src: BinaryIO, dst: BinaryIO, passphrase: str) -> None:
    salt, prefix = os.urandom(16), os.urandom(8)
    header = json.dumps({"kdf": "scrypt", "n": SCRYPT_N, "r": SCRYPT_R, "p": SCRYPT_P,
                         "salt": salt.hex(), "nonce_prefix": prefix.hex(), "chunk": CHUNK}).encode()
    aead = AESGCM(_derive(passphrase, salt, SCRYPT_N, SCRYPT_R, SCRYPT_P))
    dst.write(MAGIC + struct.pack(">I", len(header)) + header)
    counter = 0
    current = src.read(CHUNK)
    while True:
        nxt = src.read(CHUNK)
        last = not nxt
        aad = header + struct.pack(">I?", counter, last)
        ct = aead.encrypt(prefix + struct.pack(">I", counter), current, aad)
        dst.write(struct.pack(">I", len(ct)) + ct)
        if last:
            break
        current, counter = nxt, counter + 1


def decrypt_stream(src: BinaryIO, dst: BinaryIO, passphrase: str) -> None:
    if src.read(len(MAGIC)) != MAGIC:
        raise BackupError("not a UATA backup file")
    (hlen,) = struct.unpack(">I", src.read(4))
    if hlen > 4096:
        raise BackupError("corrupt header")
    header = src.read(hlen)
    meta = json.loads(header)
    if meta.get("kdf") != "scrypt":
        raise BackupError("unsupported key derivation")
    aead = AESGCM(_derive(passphrase, bytes.fromhex(meta["salt"]), meta["n"], meta["r"], meta["p"]))
    prefix = bytes.fromhex(meta["nonce_prefix"])
    counter = 0
    while True:
        raw_len = src.read(4)
        if len(raw_len) < 4:
            raise BackupError("backup is truncated")
        (clen,) = struct.unpack(">I", raw_len)
        ct = src.read(clen)
        if len(ct) != clen:
            raise BackupError("backup is truncated")
        nonce = prefix + struct.pack(">I", counter)
        try:
            # is the chunk the last one? try 'last' only if the stream ends here
            peek_last = src.read(1) == b""
            if not peek_last:
                src.seek(-1, os.SEEK_CUR)
            pt = aead.decrypt(nonce, ct, header + struct.pack(">I?", counter, peek_last))
        except InvalidTag:
            raise BackupError("wrong passphrase or corrupted backup") from None
        dst.write(pt)
        if peek_last:
            return
        counter += 1


class BackupService:
    def __init__(self, db: Database, paths: Paths):
        self.db = db
        self.paths = paths

    # ------------------------------------------------------------ export
    def create(self, passphrase: str, dest: Path | None = None) -> Path:
        if len(passphrase) < MIN_PASSPHRASE:
            raise BackupError(f"passphrase must be at least {MIN_PASSPHRASE} characters")
        stamp = utcnow().replace(":", "").replace("-", "").split(".")[0]
        dest = Path(dest) if dest else self.paths.backups_dir / f"uata-backup-{stamp}.uatabak"
        with tempfile.TemporaryDirectory(dir=self.paths.root) as tmp:
            tmpdir = Path(tmp)
            db_copy = tmpdir / "uata.sqlite3"
            self.db.backup_to(db_copy)
            files = [p for p in self.paths.files_dir.rglob("*") if p.is_file() and not p.name.startswith(".")]
            with self.db.session() as conn:
                schema = Database.schema_version(conn)
            manifest = {"format": 1, "created_at": utcnow(), "engine_version": ENGINE_VERSION,
                        "schema_version": schema, "file_count": len(files)}
            zpath = tmpdir / "payload.zip"
            with zipfile.ZipFile(zpath, "w", compression=zipfile.ZIP_DEFLATED) as z:
                z.writestr("manifest.json", json.dumps(manifest, indent=2))
                z.write(db_copy, "uata.sqlite3")
                for f in files:
                    z.write(f, "files/" + f.relative_to(self.paths.files_dir).as_posix())
            part = dest.with_suffix(dest.suffix + ".part")
            with zpath.open("rb") as src, part.open("wb") as out:
                encrypt_stream(src, out, passphrase)
            part.replace(dest)
        with self.db.session() as conn:
            audit(conn, "user", "backup.create", file=dest.name, files=len(files))
        return dest

    def list_backups(self) -> list[dict]:
        return [{"name": p.name, "size_bytes": p.stat().st_size}
                for p in sorted(self.paths.backups_dir.glob("*.uatabak"), reverse=True)]

    # ------------------------------------------------------------ import
    def restore(self, backup_file: Path, passphrase: str) -> dict:
        """Replace all local data with the backup content (after validating it fully)."""
        with tempfile.TemporaryDirectory(dir=self.paths.root) as tmp:
            tmpdir = Path(tmp)
            zpath = tmpdir / "payload.zip"
            with Path(backup_file).open("rb") as src, zpath.open("wb") as out:
                decrypt_stream(src, out, passphrase)
            extract = tmpdir / "x"
            with zipfile.ZipFile(zpath) as z:
                for name in z.namelist():  # zip-slip protection
                    target = (extract / name).resolve()
                    if not str(target).startswith(str(extract.resolve()) + os.sep):
                        raise BackupError(f"unsafe path in backup: {name}")
                z.extractall(extract)
            manifest = json.loads((extract / "manifest.json").read_text())
            if manifest.get("format") != 1:
                raise BackupError("unsupported backup format")
            restored_db = Database(extract / "uata.sqlite3")
            if not restored_db.integrity_ok():
                raise BackupError("database in backup failed integrity check")

            # swap in: database file first (remove WAL/SHM), then the file store
            for suffix in ("", "-wal", "-shm"):
                Path(str(self.paths.db_file) + suffix).unlink(missing_ok=True)
            shutil.copy2(extract / "uata.sqlite3", self.paths.db_file)
            shutil.rmtree(self.paths.files_dir, ignore_errors=True)
            if (extract / "files").exists():
                shutil.copytree(extract / "files", self.paths.files_dir)
            self.paths.ensure()
        version = self.db.migrate()  # upgrade older backups to the current schema
        with self.db.session() as conn:
            audit(conn, "user", "backup.restore", file=Path(backup_file).name,
                  from_schema=manifest.get("schema_version"))
        return {"restored": True, "manifest": manifest, "schema_version": version}

    # ------------------------------------------------------------ wipe
    def wipe_all(self, include_backups: bool = False) -> None:
        """Delete every piece of user data and start with an empty database."""
        for suffix in ("", "-wal", "-shm"):
            Path(str(self.paths.db_file) + suffix).unlink(missing_ok=True)
        shutil.rmtree(self.paths.files_dir, ignore_errors=True)
        if include_backups:
            shutil.rmtree(self.paths.backups_dir, ignore_errors=True)
        self.paths.ensure()
        self.db.migrate()

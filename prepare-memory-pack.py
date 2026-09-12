#!/usr/bin/env python3
"""Prepare the bundled memory-pack helper and its local provenance/notices."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent
SUPPORT = ROOT / "artifacts" / "MemoryPackSupport"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_tree_hash(source: Path) -> str:
    digest = hashlib.sha256()
    ignored = {"target", ".git"}
    for directory, folders, files in os.walk(source):
        folders[:] = sorted(folder for folder in folders if folder not in ignored)
        for name in sorted(files):
            path = Path(directory) / name
            relative = path.relative_to(source).as_posix().encode()
            digest.update(len(relative).to_bytes(8, "big"))
            digest.update(relative)
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
    return digest.hexdigest()


def license_text(package: dict) -> str:
    package_dir = Path(package["manifest_path"]).parent
    candidates = []
    declared_file = package.get("license_file")
    if declared_file:
        candidates.append(package_dir / declared_file)
    for candidate in sorted(package_dir.iterdir()):
        if candidate.is_file() and candidate.name.upper().startswith(("LICENSE", "COPYING", "NOTICE")):
            candidates.append(candidate)
    texts = []
    seen = set()
    for path in candidates:
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        texts.append(f"--- {path.name} ---\n{path.read_text(errors='replace').rstrip()}")
    if not texts:
        declared = package.get("license") or package.get("license_file") or "License not declared in cargo metadata"
        texts.append(f"Declared license: {declared}")
    return "\n\n".join(texts)


def write_atomic(path: Path, data: bytes, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if mode is not None:
            os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="memory-pack Cargo package directory")
    parser.add_argument("--build", action="store_true", help="build target/release/memory-pack with cargo build --release --locked")
    args = parser.parse_args()

    source = args.source.expanduser().resolve()
    manifest = source / "Cargo.toml"
    lockfile = source / "Cargo.lock"
    binary = source / "target" / "release" / "memory-pack"
    packer_license = source / "LICENSE"
    if not manifest.is_file() or not lockfile.is_file():
        raise SystemExit(f"--source must contain Cargo.toml and Cargo.lock: {source}")
    if args.build:
        subprocess.run(["cargo", "build", "--release", "--locked"], cwd=source, check=True)
    if not binary.is_file():
        raise SystemExit(f"Release helper missing: {binary}\nBuild it with: cargo build --release --locked (or rerun with --build)")
    if not packer_license.is_file():
        raise SystemExit(f"Packer license missing: {packer_license}")

    metadata = json.loads(subprocess.check_output(["cargo", "metadata", "--locked", "--offline", "--format-version", "1"], cwd=source, text=True))
    packages = sorted(metadata["packages"], key=lambda package: (package["name"], package["version"]))
    root_package = next((package for package in packages if package["name"] == "memory-pack"), None)
    repository = root_package.get("repository") if root_package else None
    notices = [
        "Memory Pack bundled dependency notices",
        f"Repository: {repository or 'declared in Cargo metadata'}",
        "",
        "--- memory-pack ---",
        packer_license.read_text(errors="replace").rstrip(),
    ]
    for package in packages:
        notices.extend(["", f"--- {package['name']} {package['version']} ({package.get('license') or 'license declared in package metadata'}) ---", license_text(package)])

    provenance = {
        "format": "memory-pack-support/1",
        "repository": repository,
        "binarySha256": sha256_file(binary),
        "cargoLockSha256": sha256_file(lockfile),
        "sourceTreeSha256": source_tree_hash(source),
        "package": {"name": root_package["name"], "version": root_package["version"], "license": root_package.get("license")} if root_package else None,
        "dependencies": [{"name": package["name"], "version": package["version"], "license": package.get("license")} for package in packages if package["name"] != "memory-pack"],
    }
    SUPPORT.mkdir(parents=True, exist_ok=True)
    write_atomic(SUPPORT / "memory-pack", binary.read_bytes(), 0o755)
    write_atomic(SUPPORT / "THIRD_PARTY_NOTICES.txt", ("\n".join(notices) + "\n").encode())
    write_atomic(SUPPORT / "provenance.json", (json.dumps(provenance, indent=2, sort_keys=True) + "\n").encode())
    write_atomic(SUPPORT / "cargo-metadata.json", (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode())
    print(SUPPORT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

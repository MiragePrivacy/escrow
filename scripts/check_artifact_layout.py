#!/usr/bin/env python3
"""Reject creation layouts unsupported by the pinned bytecode obfuscator."""

from pathlib import Path


def check_layout(creation: bytes, runtime: bytes, name: str) -> None:
    if not runtime or not creation.endswith(runtime):
        raise ValueError(f"{name}: creation bytecode must end with its embedded runtime")
    if len(runtime) > 24_576:
        raise ValueError(f"{name}: runtime exceeds the EIP-170 size limit")


def main() -> None:
    artifacts = Path(__file__).resolve().parents[1] / "artifacts"
    for name in ("erc20", "native", "batch", "native_zk", "batch_zk"):
        creation = bytes.fromhex((artifacts / f"{name}_deployment.hex").read_text().strip().removeprefix("0x"))
        runtime = bytes.fromhex((artifacts / f"{name}_runtime.hex").read_text().strip().removeprefix("0x"))
        check_layout(creation, runtime, name)
    print("All artifact layouts end with their embedded runtime and fit EIP-170.")


if __name__ == "__main__":
    main()

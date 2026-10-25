"""Enforce the final-review moonc floor, independently of the moon build-tool version."""
import re
import subprocess


def check_version(output):
    match = re.search(r"(?m)^moonc\s+v?(\d+)\.(\d+)\.(\d+)([^\s]*)", output)
    if match is None:
        raise ValueError("Could not identify the moonc compiler version")
    version = tuple(map(int, match.group(1, 2, 3)))
    if version < (0, 10, 14) or match.group(4).startswith("-"):
        raise ValueError("Requires stable moonc >= 0.10.14")
    return ".".join(map(str, version))


if __name__ == "__main__":
    result = subprocess.run(["moon", "version", "--all"], check=True, capture_output=True, text=True)
    print(result.stdout, end="")
    print(f"PASS: moonc {check_version(result.stdout)} meets the 0.10.14 compiler floor")

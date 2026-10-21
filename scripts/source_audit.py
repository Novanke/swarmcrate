"""Conservative root-library source audit; no test/docs/generated/dependency/FFI code."""
from pathlib import Path
import json
import re

root = Path(__file__).resolve().parents[1]
rows = []
for file in sorted(root.glob("*.mbt")):
    if file.name.endswith(("_test.mbt", "_wbtest.mbt")):
        continue
    text = file.read_text(encoding="utf-8-sig")
    if "/*" in text:
        raise SystemExit("Update lexical audit before counting block comments")
    nonblank = body = 0
    for block in re.split(r"(?m)^///\|\s*$", text):
        lines = [line.strip() for line in block.splitlines() if line.strip() and not line.lstrip().startswith("//")]
        nonblank += len(lines)
        if not lines or not re.match(r"(?:pub\s+|priv\s+)?fn\b", lines[0]):
            continue
        inside = False
        for line in lines:
            if not inside:
                inside = "{" in line
                continue  # Exclude the complete signature/opening line, including inline bodies.
            if not re.fullmatch(r"[\s{}\[\](),;]+", line):
                body += 1
    if nonblank:
        rows.append({"file": file.name, "nonblank_code": nonblank, "function_body": body})
result = {"scope": "root library only; excludes tests, docs, generated interfaces, dependencies, host bridge, CLI and scripts",
          "files": rows, "nonblank_code": sum(row["nonblank_code"] for row in rows),
          "function_body": sum(row["function_body"] for row in rows)}
print(json.dumps(result, indent=2))
assert result["function_body"] >= 500, "Core implementation body is below the requested minimum"

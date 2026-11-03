#!/usr/bin/env python3
"""Filter/rewrite PHPUnit clover XML so Sonar can match repo-relative paths.

Container paths look like:
  /opt/processmaker/ProcessMaker/...
  /opt/processmaker/vendor/processmaker/<pkg>/...
  /opt/packages/<pkg>/...

Only keep files for the repo under review (CI_PROJECT) and strip the
container prefix so paths match the checked-out project tree.
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET


def prefixes_for_project(project: str) -> list[tuple[str, str]]:
    """Return (absolute_prefix, replacement) pairs to keep/rewrite."""
    if project == "processmaker":
        return [("/opt/processmaker/ProcessMaker/", "ProcessMaker/")]

    return [
        (f"/opt/processmaker/vendor/processmaker/{project}/", ""),
        (f"/opt/packages/{project}/", ""),
    ]


def rewrite(input_path: str, output_path: str, project: str) -> int:
    tree = ET.parse(input_path)
    root = tree.getroot()
    keep = prefixes_for_project(project)
    kept = 0
    dropped = 0

    for parent in root.iter():
        # Clover nests <file> under <package> (and sometimes project).
        files = list(parent.findall("file"))
        if not files:
            continue
        for file_el in files:
            name = file_el.get("name") or ""
            matched = None
            for prefix, replacement in keep:
                if name.startswith(prefix):
                    matched = replacement + name[len(prefix) :]
                    break
            if matched is None:
                parent.remove(file_el)
                dropped += 1
            else:
                file_el.set("name", matched)
                kept += 1

    tree.write(output_path, encoding="UTF-8", xml_declaration=True)
    print(f"coverage rewrite project={project} kept={kept} dropped={dropped} -> {output_path}")
    if kept == 0:
        print("warning: no coverage files matched project prefixes", file=sys.stderr)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--project", required=True, help="CI_PROJECT / repo name")
    args = parser.parse_args()
    return rewrite(args.input, args.output, args.project)


if __name__ == "__main__":
    raise SystemExit(main())

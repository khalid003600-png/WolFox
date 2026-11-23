#!/usr/bin/env python3
"""Set WolFox display metadata and, optionally, the app's process executable name."""

from __future__ import annotations

import pathlib
import plistlib
import re
import sys


NAME_KEYS = ("CFBundleDisplayName", "CFBundleName")


def _plist_format(data: bytes) -> plistlib.PlistFormat:
    return plistlib.FMT_BINARY if data.startswith(b"bplist00") else plistlib.FMT_XML


def _write_plist(path: pathlib.Path, value: dict, original: bytes) -> None:
    path.write_bytes(plistlib.dumps(value, fmt=_plist_format(original), sort_keys=False))


def _set_text_strings_names(path: pathlib.Path, display_name: str) -> bool:
    text = path.read_text(encoding="utf-8")
    escaped = display_name.replace("\\", "\\\\").replace('"', '\\"')
    pattern = re.compile(
        r'(?m)(^[ \t]*"(?:CFBundleDisplayName|CFBundleName)"[ \t]*=[ \t]*")'
        r'((?:\\.|[^"\\\r\n])*)'
        r'("[ \t]*;[ \t]*$)'
    )
    updated, count = pattern.subn(
        lambda match: match.group(1) + escaped + match.group(3), text
    )
    if count:
        path.write_text(updated, encoding="utf-8")
    return bool(count)


def _set_localized_names(app: pathlib.Path, display_name: str) -> None:
    localized = set(app.glob("*.lproj/InfoPlist.strings"))
    localized.update(app.glob("Resources/*.lproj/InfoPlist.strings"))
    for path in sorted(localized):
        original = path.read_bytes()
        try:
            value = plistlib.loads(original)
        except Exception:
            _set_text_strings_names(path, display_name)
            continue
        if not isinstance(value, dict):
            _set_text_strings_names(path, display_name)
            continue
        for key in NAME_KEYS:
            value[key] = display_name
        _write_plist(path, value, original)


def set_app_display_name(
    app: pathlib.Path,
    display_name: str,
    executable_name: str | None = None,
) -> None:
    app = app.resolve()
    info_path = app / "Info.plist"
    if not info_path.is_file():
        raise FileNotFoundError(f"Missing app Info.plist: {info_path}")

    original = info_path.read_bytes()
    try:
        info = plistlib.loads(original)
    except Exception as error:
        raise ValueError(f"Could not read app Info.plist: {info_path}") from error
    if not isinstance(info, dict):
        raise ValueError(f"App Info.plist is not a dictionary: {info_path}")

    for key in NAME_KEYS:
        info[key] = display_name

    renamed_from: pathlib.Path | None = None
    renamed_to: pathlib.Path | None = None
    if executable_name is not None:
        if not executable_name.strip() or pathlib.Path(executable_name).name != executable_name:
            raise ValueError("executable name must be a non-empty filename")
        current = info.get("CFBundleExecutable")
        if not isinstance(current, str) or not current:
            raise ValueError("Info.plist does not contain CFBundleExecutable")
        if current != executable_name:
            renamed_from = app / current
            renamed_to = app / executable_name
            if not renamed_from.is_file():
                raise FileNotFoundError(f"Missing current executable: {renamed_from}")
            if renamed_to.exists():
                raise FileExistsError(f"Target executable already exists: {renamed_to}")
            info["CFBundleExecutable"] = executable_name
            renamed_from.rename(renamed_to)

    try:
        _write_plist(info_path, info, original)
    except BaseException:
        if renamed_from is not None and renamed_to is not None and renamed_to.exists():
            renamed_to.rename(renamed_from)
        raise

    _set_localized_names(app, display_name)


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4):
        print(
            "usage: set_app_display_name.py YouTube.app WolFox [WolFox-process-name]",
            file=sys.stderr,
        )
        return 2
    app = pathlib.Path(argv[1])
    display_name = argv[2]
    executable_name = argv[3] if len(argv) == 4 else None
    if not display_name.strip():
        print("display name must not be empty", file=sys.stderr)
        return 2
    set_app_display_name(app, display_name, executable_name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

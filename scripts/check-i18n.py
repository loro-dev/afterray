#!/usr/bin/env python3
"""Static completeness checks for AfterRay UI chrome i18n.

The Swift compiler already rejects a missing AfterRayCopy field. This script
catches the rest: locale lists drifting apart, empty catalog strings, views
reading English-default model APIs, and hardcoded chrome literals.

Usage: scripts/check-i18n.sh
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
ALLOWLIST_PATH = REPO / "scripts" / "i18n-allowlist.tsv"

UI_LANGUAGE_SWIFT = REPO / "swift/AfterRayRecall/Sources/L10n/AfterRayUILanguage.swift"
COPY_DIR = REPO / "swift/AfterRayRecall/Sources/L10n"
PLIST = REPO / "apps/AfterRay/Resources/Info.plist"
RESOURCES = REPO / "apps/AfterRay/Resources"
BUILD_RELEASE = REPO / "scripts/build-release.sh"
RUN_V0 = REPO / "scripts/run-v0.sh"

SHIPPED_ROOTS = [
    REPO / "swift/AfterRayRecall/Sources",
    REPO / "apps/AfterRay/Sources",
]

# English-default wrappers live here on purpose (XCTest pins). Views must call
# the copy: overload instead.
LEAK_DEFINITION_FILES = {
    "ChatModels.swift",
    "ModelDownloadQueue.swift",
    "RecallHotKey.swift",
    "ComputeActivity.swift",
    "ImmersiveQueryMode.swift",
    "RecallModels.swift",
    "DaySummary.swift",
}

LEAK_PATTERNS = [
    (re.compile(r"progress\.title(?!\s*\()"), "progress.title — use title(copy)"),
    (re.compile(r"\.stageLabel(?!\s*\()"), "stageLabel — use stageLabel(copy)"),
    (re.compile(r"\.sizeText(?!\s*\()"), "sizeText — use sizeText(copy)"),
    (re.compile(r"\.etaText(?!\s*\()"), "etaText — use etaText(copy)"),
    (re.compile(r"\.systemConflictNote(?!\s*\()"), "systemConflictNote — use systemConflictNote(copy)"),
    (re.compile(r"indicator\.help(?!\s*\()"), "indicator.help — use help(copy)"),
]

# Call-site APIs that show chrome to the user.
CHROME_PREFIX = re.compile(
    r"(?:"
    r"\.help\s*\(|"
    r"\.accessibilityLabel\s*\(|"
    r"\.accessibilityHint\s*\(|"
    r"\.accessibilityValue\s*\(|"
    r"\bText\s*\(|"
    r"\bLabel\s*\(|"
    r"\bButton\s*\(|"
    r"messageText\s*=|"
    r"informativeText\s*=|"
    r"addButton\s*\(\s*withTitle\s*:|"
    r"emptyText\s*:|"
    r"\bhelp\s*:|"
    r"panel\.message\s*=|"
    r"\bmessage\s*=|"
    r"\.label\s*=|"
    r"\.paletteLabel\s*=|"
    r"\.toolTip\s*=|"
    r"\blabel\s*:|"
    r"accessibilityDescription\s*:|"
    r"withTitle\s*:"
    r")"
)

RETURN_STRING = re.compile(r"\breturn\s+$")
LOG_PREFIX = re.compile(
    r"(?:AfterRayLog|NSLog|print|fatalError|precondition|assertionFailure|"
    r"String\s*\(\s*format)\b"
)
SKIP_CHROME_FILES = {
    "AfterRayLog.swift",
}

CASE_RAW = re.compile(r'case\s+\w+\s*=\s*"([^"]+)"')
LOC_LOOP = re.compile(r"for loc in ([^;]+); do")
EMPTY_STRING_FIELD = re.compile(
    r':\s*(?:\{\s*(?:_+(?:\s*,\s*_+)*)?\s*(?:in\s*)?)?""\s*(?:\})?'
)

failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)


def rel(path: pathlib.Path) -> str:
    return path.relative_to(REPO).as_posix()


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def extract_ui_languages(source: str) -> list[str]:
    block = source.split("public enum AfterRayUILanguage", 1)[1]
    block = block.split("public static let autoCode", 1)[0]
    return CASE_RAW.findall(block)


def extract_plist_localizations(text: str) -> list[str]:
    section = text.split("<key>CFBundleLocalizations</key>", 1)[1]
    section = section.split("</array>", 1)[0]
    return re.findall(r"<string>([^<]+)</string>", section)


def extract_script_locales(text: str) -> list[str]:
    match = LOC_LOOP.search(text)
    if not match:
        return []
    return match.group(1).split()


def copy_filename(code: str) -> str:
    return f"AfterRayCopy+{code.replace('-', '')}.swift"


def check_locale_sets() -> None:
    codes = extract_ui_languages(read(UI_LANGUAGE_SWIFT))
    if not codes:
        fail(f"{rel(UI_LANGUAGE_SWIFT)}: could not read AfterRayUILanguage cases")
        return

    plist = extract_plist_localizations(read(PLIST))
    build = extract_script_locales(read(BUILD_RELEASE))
    run = extract_script_locales(read(RUN_V0))
    lproj = sorted(
        p.name[: -len(".lproj")]
        for p in RESOURCES.iterdir()
        if p.is_dir() and p.name.endswith(".lproj")
    )
    catalogs = sorted(
        p.name[len("AfterRayCopy+") : -len(".swift")]
        for p in COPY_DIR.glob("AfterRayCopy+*.swift")
    )
    expected_catalogs = sorted(code.replace("-", "") for code in codes)

    def same(name: str, got: list[str], want: list[str]) -> None:
        if got != want:
            fail(f"{name} mismatch\n  expected: {' '.join(want)}\n  got:      {' '.join(got)}")

    same("Info.plist CFBundleLocalizations", plist, codes)
    same("scripts/build-release.sh locale loop", build, codes)
    same("scripts/run-v0.sh locale loop", run, codes)
    same("apps/AfterRay/Resources/*.lproj", lproj, sorted(codes))
    same("AfterRayCopy+*.swift suffixes", catalogs, expected_catalogs)

    for code in codes:
        catalog = COPY_DIR / copy_filename(code)
        strings = RESOURCES / f"{code}.lproj" / "InfoPlist.strings"
        if not catalog.is_file():
            fail(f"missing catalog {rel(catalog)}")
        if not strings.is_file():
            fail(f"missing {rel(strings)}")


def check_empty_catalog_strings() -> None:
    for path in sorted(COPY_DIR.glob("AfterRayCopy+*.swift")):
        for line_no, line in enumerate(read(path).splitlines(), 1):
            stripped = line.split("//", 1)[0]
            if EMPTY_STRING_FIELD.search(stripped):
                fail(f"{rel(path)}:{line_no}: empty catalog string")


def strip_comments_keep_strings(source: str) -> str:
    """Replace comments with spaces; keep string contents and quotes."""
    out: list[str] = []
    i = 0
    n = len(source)
    while i < n:
        two = source[i : i + 2]
        if two == "//":
            while i < n and source[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if two == "/*":
            i += 2
            out.extend("  ")
            while i < n and source[i : i + 2] != "*/":
                out.append("\n" if source[i] == "\n" else " ")
                i += 1
            if i < n:
                out.extend("  ")
                i += 2
            continue
        if two == '"""':
            out.extend('"""')
            i += 3
            while i < n and source[i : i + 3] != '"""':
                if source[i] == "\\" and i + 1 < n:
                    out.append(source[i])
                    out.append(source[i + 1])
                    i += 2
                    continue
                out.append(source[i])
                i += 1
            if i < n:
                out.extend('"""')
                i += 3
            continue
        ch = source[i]
        if ch == '"':
            out.append(ch)
            i += 1
            while i < n:
                cur = source[i]
                out.append(cur)
                if cur == "\\" and i + 1 < n:
                    out.append(source[i + 1])
                    i += 2
                    continue
                i += 1
                if cur == '"':
                    break
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def iter_string_literals(source: str):
    i = 0
    n = len(source)
    while i < n:
        if source[i : i + 3] == '"""':
            start = i
            i += 3
            while i < n and source[i : i + 3] != '"""':
                if source[i] == "\\" and i + 1 < n:
                    i += 2
                    continue
                i += 1
            end = min(i + 3, n)
            yield start, source[start:end]
            i = end
            continue
        if source[i] == '"':
            start = i
            i += 1
            while i < n:
                if source[i] == "\\" and i + 1 < n:
                    i += 2
                    continue
                if source[i] == '"':
                    i += 1
                    break
                i += 1
            yield start, source[start:i]
            continue
        i += 1


def decode_swift_string(literal: str) -> str:
    inner = literal[3:-3] if literal.startswith('"""') else literal[1:-1]
    inner = re.sub(r"\\\n[ \t]*", "", inner)
    return (
        inner.replace(r"\n", "\n")
        .replace(r"\t", "\t")
        .replace(r"\"", '"')
        .replace(r"\\", "\\")
    )


def collapse_ws(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def strip_interpolations(text: str) -> str:
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        if text[i] == "\\" and i + 1 < n and text[i + 1] == "(":
            depth = 1
            i += 2
            while i < n and depth:
                if text[i] == "(":
                    depth += 1
                elif text[i] == ")":
                    depth -= 1
                i += 1
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


KEY_NAMES = re.compile(
    r"\b(Tab|Esc|Return|Enter|Shift|Option|Command|Control|Space)\b",
    re.IGNORECASE,
)


def is_format_only(decoded: str) -> bool:
    if re.search(r"https?://", decoded):
        return True
    remainder = strip_interpolations(decoded)
    remainder = remainder.replace("AfterRay", "")
    remainder = remainder.replace("afterray", "")
    remainder = remainder.replace("afterrayd", "")
    remainder = KEY_NAMES.sub("", remainder)
    if not re.search(r"[A-Za-z\u00C0-\u024F\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]", remainder):
        return True
    compact = remainder.strip()
    if not compact or " " in compact or "\n" in compact:
        return False
    if re.fullmatch(r"<?\d+[smh]>", compact) or re.fullmatch(r"<?\d+[smh]", compact):
        return True
    if re.fullmatch(r"tok/s", compact, re.IGNORECASE):
        return True
    # SF Symbols and opaque ids: "pause.fill", "gop-poster:abc#1", "Qwen3-ASR".
    if re.fullmatch(r"[A-Za-z0-9_.:#\-]+", compact):
        if "." in compact or ":" in compact or "#" in compact:
            return True
        if compact.islower() or compact.isupper():
            return True
    return False


def line_number(source: str, index: int) -> int:
    return source.count("\n", 0, index) + 1


def shipped_swift_files() -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for root in SHIPPED_ROOTS:
        for path in root.rglob("*.swift"):
            name = path.name
            if name == "AfterRayCopy.swift" or name.startswith("AfterRayCopy+"):
                continue
            files.append(path)
    return sorted(files)


def check_english_default_leaks() -> None:
    for path in shipped_swift_files():
        if path.name in LEAK_DEFINITION_FILES:
            continue
        text = read(path)
        for line_no, line in enumerate(text.splitlines(), 1):
            code = line.split("//", 1)[0]
            for pattern, why in LEAK_PATTERNS:
                if pattern.search(code):
                    fail(f"{rel(path)}:{line_no}: {why}")


def load_allowlist() -> set[tuple[str, str]]:
    allowed: set[tuple[str, str]] = set()
    if not ALLOWLIST_PATH.is_file():
        return allowed
    for raw in ALLOWLIST_PATH.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            fail(f"{rel(ALLOWLIST_PATH)}: bad line: {raw}")
            continue
        allowed.add((parts[0], parts[1].replace("\\n", "\n").replace("\\t", "\t")))
    return allowed


def prefix_before(source: str, index: int) -> str:
    begin = max(0, index - 80)
    return collapse_ws(source[begin:index])


def check_hardcoded_chrome(allowed: set[tuple[str, str]], dump: bool) -> None:
    unused = set(allowed)
    for path in shipped_swift_files():
        if path.name in SKIP_CHROME_FILES:
            continue
        original = read(path)
        source = strip_comments_keep_strings(original)
        for start, literal in iter_string_literals(source):
            decoded = decode_swift_string(literal)
            if is_format_only(decoded):
                continue
            prefix = prefix_before(source, start)
            if LOG_PREFIX.search(prefix):
                continue
            is_chrome = bool(CHROME_PREFIX.search(prefix) or RETURN_STRING.search(prefix))
            if not is_chrome:
                continue
            key = (rel(path), collapse_ws(decoded))
            if key in allowed:
                unused.discard(key)
                continue
            line = line_number(original, start)
            preview = collapse_ws(decoded)
            if len(preview) > 80:
                preview = preview[:77] + "..."
            if dump:
                print(f"{rel(path)}\t{collapse_ws(decoded).replace(chr(9), r'\\t')}\tdebt")
            else:
                fail(f"{rel(path)}:{line}: hardcoded chrome {preview!r}")
    if dump:
        return
    for path, text in sorted(unused):
        fail(f"{rel(ALLOWLIST_PATH)}: unused allowlist entry {path}\t{collapse_ws(text)}")


def main() -> int:
    dump = "--dump-allowlist" in sys.argv
    allowed = set() if dump else load_allowlist()
    if not dump:
        check_locale_sets()
        check_empty_catalog_strings()
        check_english_default_leaks()
    check_hardcoded_chrome(allowed, dump=dump)
    if dump:
        return 0
    if failures:
        print("i18n check failed:\n", file=sys.stderr)
        for item in failures:
            print(f"  {item}", file=sys.stderr)
        print(f"\n{len(failures)} issue(s). Add a catalog field + wire it, or (rarely) scripts/i18n-allowlist.tsv.", file=sys.stderr)
        return 1
    print("i18n check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

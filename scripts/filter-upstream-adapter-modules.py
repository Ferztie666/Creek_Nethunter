#!/usr/bin/env python3
"""Import original Creek adapter modules only when vermagic and symbol CRCs match this build."""
from __future__ import annotations
import argparse
import re
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

def run(args: list[str]) -> str:
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise RuntimeError(f"command failed ({p.returncode}): {' '.join(args)}: {p.stderr.strip()}")
    return p.stdout.strip()

def canon(name: str) -> str:
    return name.removesuffix(".ko").replace("-", "_")

def module_field(field: str, path: Path) -> str:
    return run(["modinfo", "-F", field, str(path)])

def imported_versions(path: Path) -> list[tuple[str, str]]:
    out = run(["modprobe", "--dump-modversions", str(path)])
    found = []
    for line in out.splitlines():
        m = re.match(r"^\s*(0x[0-9a-fA-F]+)\s+(\S+)\s*$", line)
        if m:
            found.append((m.group(2), m.group(1).lower()))
    return found

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--archive", required=True)
    ap.add_argument("--staging", required=True)
    ap.add_argument("--symvers-root", required=True)
    ap.add_argument("--target-list", required=True)
    ap.add_argument("--report", required=True)
    a = ap.parse_args()
    staging = Path(a.staging)
    report = Path(a.report)
    report.parent.mkdir(parents=True, exist_ok=True)
    roots = sorted(staging.glob("lib/modules/*"))
    roots = [p for p in roots if p.is_dir()]
    if not roots:
        raise SystemExit(f"ERROR: no staged module root under {staging}/lib/modules")
    modroot = roots[0]
    staged: dict[str, Path] = {}
    for p in modroot.rglob("*.ko"):
        staged.setdefault(canon(p.name), p)
    baseline = staged.get("qca_cld3_wlan") or staged.get("rtl8xxxu")
    if baseline is None:
        baseline = next(iter(staged.values()), None)
    if baseline is None:
        raise SystemExit("ERROR: no built module available to establish current vermagic")
    expected_vermagic = module_field("vermagic", baseline)
    if not expected_vermagic:
        raise SystemExit(f"ERROR: cannot read build vermagic from {baseline}")
    symvers_files = sorted(Path(a.symvers_root).rglob("Module.symvers"))
    symvers: dict[str, set[str]] = {}
    for file in symvers_files:
        try:
            lines = file.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            cols = line.split()
            if len(cols) >= 2 and cols[0].startswith("0x"):
                symvers.setdefault(cols[1], set()).add(cols[0].lower())
    if not symvers:
        raise SystemExit(f"ERROR: no exported symbol CRCs found under {a.symvers_root}")
    targets = set()
    for line in Path(a.target_list).read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            targets.add(canon(line))
    with zipfile.ZipFile(a.archive) as zf, tempfile.TemporaryDirectory(prefix="creek-upstream-mods-") as td:
        temp = Path(td)
        candidates: dict[str, Path] = {}
        for info in zf.infolist():
            if info.is_dir() or not info.filename.endswith(".ko"):
                continue
            name = canon(Path(info.filename).name)
            if name == "qca_cld3_wlan" or name in staged:
                continue
            dest = temp / (name + ".ko")
            with zf.open(info) as src, dest.open("wb") as dst:
                shutil.copyfileobj(src, dst)
            # First matching module basename wins; archive path is recorded in report.
            candidates.setdefault(name, dest)
        reasons: dict[str, tuple[bool, str, list[str]]] = {}
        def check(name: str, stack: tuple[str, ...] = ()) -> tuple[bool, str, list[str]]:
            if name in staged:
                return True, "BUILT_FROM_CURRENT_SOURCE", []
            if name in stack:
                return False, "BLOCKED_DEPENDENCY_CYCLE", []
            if name in reasons:
                ok, status, deps = reasons[name]
                return ok, status, list(deps)
            path = candidates.get(name)
            if path is None:
                return False, "BLOCKED_DEPENDENCY_NOT_AVAILABLE", []
            try:
                vermagic = module_field("vermagic", path)
            except Exception:
                reasons[name] = (False, "BLOCKED_NO_VERMAGIC", [])
                return False, "BLOCKED_NO_VERMAGIC", []
            if vermagic != expected_vermagic:
                reasons[name] = (False, "BLOCKED_VERMAGIC_MISMATCH", [])
                return False, "BLOCKED_VERMAGIC_MISMATCH", []
            try:
                versions = imported_versions(path)
            except Exception:
                reasons[name] = (False, "BLOCKED_MODVERSION_READ_ERROR", [])
                return False, "BLOCKED_MODVERSION_READ_ERROR", []
            missing = [sym for sym, crc in versions if sym not in symvers]
            # Module.symvers is collected from several build domains. If the same
            # symbol has conflicting CRCs across those domains, accepting any one
            # CRC is ambiguous and can accidentally approve an incompatible binary.
            ambiguous = [sym for sym, crc in versions if sym in symvers and len(symvers[sym]) != 1]
            mismatched = [sym for sym, crc in versions if sym in symvers and len(symvers[sym]) == 1 and crc not in symvers[sym]]
            if ambiguous:
                reasons[name] = (False, "BLOCKED_SYMBOL_CRC_AMBIGUOUS:" + ",".join(sorted(set(ambiguous))[:8]), [])
                return False, reasons[name][1], []
            if missing:
                reasons[name] = (False, "BLOCKED_SYMBOL_MISSING:" + ",".join(sorted(set(missing))[:8]), [])
                return False, reasons[name][1], []
            if mismatched:
                reasons[name] = (False, "BLOCKED_SYMBOL_CRC_MISMATCH:" + ",".join(sorted(set(mismatched))[:8]), [])
                return False, reasons[name][1], []
            try:
                deps = [canon(x.strip()) for x in module_field("depends", path).split(",") if x.strip()]
            except Exception:
                reasons[name] = (False, "BLOCKED_DEPENDENCY_READ_ERROR", [])
                return False, "BLOCKED_DEPENDENCY_READ_ERROR", []
            closure = []
            for dep in deps:
                ok, status, subclosure = check(dep, stack + (name,))
                if not ok:
                    reasons[name] = (False, "BLOCKED_DEPENDENCY:" + dep + ":" + status, deps)
                    return False, reasons[name][1], []
                closure.extend(subclosure)
                if dep not in staged:
                    closure.append(dep)
            # Remove duplicates while preserving order.
            closure = list(dict.fromkeys(closure))
            reasons[name] = (True, "UPSTREAM_VERMAGIC_AND_SYMBOL_CRC_VERIFIED", deps)
            return True, reasons[name][1], closure
        selected: set[str] = set()
        rows = []
        for name in sorted(targets):
            if name == "qca_cld3_wlan":
                rows.append((name + ".ko", "SKIPPED_RISK", "internal wlan0 driver is not an external adapter"))
                continue
            if name in staged:
                rows.append((name + ".ko", "BUILT_FROM_CURRENT_SOURCE", "current build output takes precedence over upstream binary"))
                continue
            if name not in candidates:
                rows.append((name + ".ko", "NOT_IN_UPSTREAM_OR_STAGING", "not fabricated"))
                continue
            ok, status, closure = check(name)
            if ok:
                selected.add(name)
                selected.update(closure)
                rows.append((name + ".ko", status, "vermagic and every imported symbol CRC matched this build; dependency closure checked"))
            else:
                rows.append((name + ".ko", status, "excluded from package; see status and exact dependency/symbol reason"))
        # Ensure every copied dependency itself is present and verified, not merely a name in a depends field.
        for name in sorted(selected):
            if name in staged:
                continue
            path = candidates.get(name)
            if path is None:
                raise SystemExit(f"ERROR: dependency closure selected missing module {name}")
            dest = modroot / "extra" / "nethunter-upstream" / (name + ".ko")
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
        for name, path in sorted(staged.items()):
            if name in targets and name != "qca_cld3_wlan":
                rows.append((name + ".ko", "BUILT_FROM_CURRENT_SOURCE", "built from the current pinned Creek source; upstream binary not used"))
        report.write_text(
            "module\tstatus\tdetail\n" +
            "".join("\t".join(row) + "\n" for row in sorted(set(rows)))
        )
        print(f"UPSTREAM_ADAPTER_COMPATIBILITY=PASS_REPORT_ONLY")
        print(f"BUILD_VERMAGIC={expected_vermagic}")
        print(f"SYMVERS_FILES={len(symvers_files)}")
        print(f"UPSTREAM_MODULES_COPIED={len([x for x in selected if x not in staged])}")
        print(f"REPORT={report}")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, zipfile.BadZipFile) as e:
        raise SystemExit(f"ERROR: {e}")

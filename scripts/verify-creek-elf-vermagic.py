#!/usr/bin/env python3
"""Verify an AArch64 kernel module's .modinfo vermagic without host binutils."""
import argparse
import struct
import sys

ELF_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
SECTION_HEADER = struct.Struct("<IIQQQQIIQQ")
EM_AARCH64 = 183
ET_REL = 1


def _slice(data, offset, size, what):
    if offset < 0 or size < 0 or offset > len(data) or size > len(data) - offset:
        raise ValueError(f"{what} lies outside the ELF file")
    return data[offset:offset + size]


def read_vermagic(data):
    if len(data) < ELF_HEADER.size:
        raise ValueError("file is too small to be an ELF64 object")
    fields = ELF_HEADER.unpack_from(data)
    ident = fields[0]
    if ident[:4] != b"\x7fELF":
        raise ValueError("invalid ELF magic")
    if ident[4] != 2:
        raise ValueError("expected ELFCLASS64")
    if ident[5] != 1:
        raise ValueError("expected little-endian ELF")
    if fields[1] != ET_REL:
        raise ValueError("expected relocatable kernel module (ET_REL)")
    if fields[2] != EM_AARCH64:
        raise ValueError(f"expected AArch64 ELF machine ({EM_AARCH64}), got {fields[2]}")

    shoff, shentsize, shnum, shstrndx = fields[6], fields[11], fields[12], fields[13]
    if shentsize < SECTION_HEADER.size or shnum == 0 or shstrndx >= shnum:
        raise ValueError("invalid or unsupported ELF section-header table")
    _slice(data, shoff, shentsize * shnum, "section-header table")

    sections = []
    for index in range(shnum):
        sections.append(SECTION_HEADER.unpack_from(data, shoff + index * shentsize))
    names_section = sections[shstrndx]
    names = _slice(data, names_section[4], names_section[5], "section-name string table")

    def section_name(offset):
        if offset >= len(names):
            raise ValueError("section name offset is out of range")
        end = names.find(b"\0", offset)
        if end < 0:
            raise ValueError("unterminated section name")
        return names[offset:end]

    modinfo = []
    for section in sections:
        if section_name(section[0]) == b".modinfo":
            modinfo.append(_slice(data, section[4], section[5], ".modinfo section"))
    if len(modinfo) != 1:
        raise ValueError(f"expected exactly one .modinfo section, found {len(modinfo)}")

    entries = [item.decode("ascii", "strict") for item in modinfo[0].split(b"\0") if item]
    values = [item[len("vermagic="):] for item in entries if item.startswith("vermagic=")]
    if len(values) != 1:
        raise ValueError(f"expected exactly one vermagic entry, found {len(values)}")
    return values[0]


def make_test_elf(vermagic):
    names = b"\0.shstrtab\0.modinfo\0"
    info = ("vermagic=" + vermagic + "\0").encode("ascii")
    names_offset = 64
    info_offset = names_offset + len(names)
    shoff = (info_offset + len(info) + 7) & ~7
    header = ELF_HEADER.pack(
        b"\x7fELF" + bytes([2, 1, 1]) + bytes(9),
        ET_REL, EM_AARCH64, 1, 0, 0, shoff, 0, 64, 0, 0, 64, 3, 1
    )
    null_section = bytes(SECTION_HEADER.size)
    shstr = SECTION_HEADER.pack(1, 3, 0, 0, names_offset, len(names), 0, 0, 1, 0)
    mod = SECTION_HEADER.pack(11, 1, 0, 0, info_offset, len(info), 0, 0, 1, 0)
    padding = bytes(shoff - (info_offset + len(info)))
    return header + names + info + padding + null_section + shstr + mod


def self_test():
    expected = "5.15.167-android13-8-test SMP preempt mod_unload modversions aarch64"
    if read_vermagic(make_test_elf(expected)) != expected:
        raise AssertionError("valid ELF fixture did not preserve vermagic")
    try:
        read_vermagic(b"not an ELF")
    except ValueError:
        pass
    else:
        raise AssertionError("invalid ELF fixture unexpectedly passed")
    if read_vermagic(make_test_elf("wrong-release")) != "wrong-release":
        raise AssertionError("mismatch fixture did not parse")
    print("ELF_VERMAGIC_PARSER_SELF_TEST=PASS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("module", nargs="?")
    parser.add_argument("expected_release", nargs="?")
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
            return 0
        if not args.module or not args.expected_release:
            parser.error("module and expected_release are required unless --self-test is used")
        with open(args.module, "rb") as handle:
            actual = read_vermagic(handle.read())
        if not actual.startswith(args.expected_release + " "):
            raise ValueError(
                f"vermagic mismatch: expected prefix '{args.expected_release} ', got '{actual}'"
            )
        print(f"ELF_VERMAGIC=PASS ({actual})")
        return 0
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        print(f"ELF_VERMAGIC=FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

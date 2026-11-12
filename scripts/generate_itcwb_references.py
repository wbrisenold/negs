#!/usr/bin/env python3
"""Build Negs' compact ITCWB reference-color table.

Usage:
  python3 scripts/generate_itcwb_references.py /path/to/RawTherapee/rtengine/colortemp.cc

Requires colour-science. The source reflectance samples and the correlation
idea are derived from RawTherapee's GPL-3.0-or-later ITCWB implementation;
Colour Science supplies the CIE 1931 2-degree observer and D65 integration.
"""

from __future__ import annotations

import re
import struct
import sys
from pathlib import Path

import colour


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    source_path = Path(sys.argv[1])
    source = source_path.read_text()
    fn = source.index("const double* spec_colorforxcyc[]")
    start = source.index("{", fn)
    end = source.index("};", start)
    names_text = re.sub(r"/\*.*?\*/|//[^\n]*", "", source[start + 1 : end], flags=re.S)
    array_names = set(re.findall(r"ColorTemp::\s*(\w+)\[97\]", source))
    ordered_names = [name for name in re.findall(r"\b[A-Za-z_]\w*\b", names_text) if name in array_names]

    arrays = {}
    pattern = re.compile(r"const double\s+ColorTemp::\s*(\w+)\[97\]\s*=\s*\{(.*?)\};", re.S)
    for name, body in pattern.findall(source):
        body = re.sub(r"/\*.*?\*/|//[^\n]*", "", body, flags=re.S)
        values = [float(item) for item in re.findall(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?", body)]
        if len(values) <= 97:
            arrays[name] = values + [0.0] * (97 - len(values))
    if any(name not in arrays for name in ordered_names):
        missing = sorted(set(ordered_names) - set(arrays))
        raise SystemExit(f"Missing spectral samples for: {missing}")
    spectra = [arrays[name] for name in ordered_names]
    if len(spectra) != 429:
        raise SystemExit(f"Expected RawTherapee's 429 reference colors, found {len(spectra)}")

    observer = colour.MSDS_CMFS["CIE 1931 2 Degree Standard Observer"]
    d65 = colour.SDS_ILLUMINANTS["D65"]
    wavelengths = range(350, 831, 5)
    cmf = [observer[wavelength] for wavelength in wavelengths]
    illuminant = [float(d65[wavelength]) for wavelength in wavelengths]
    denominator = sum(illuminant[i] * cmf[i][1] for i in range(97))

    output = Path(__file__).resolve().parents[1] / "crates/spektrafilm-io/src/itcwb_reference_xy.bin"
    with output.open("wb") as handle:
        handle.write(struct.pack("<I", len(spectra)))
        for reflectance in spectra:
            xyz = [
                sum(illuminant[i] * reflectance[i] * cmf[i][channel] for i in range(97)) / denominator
                for channel in range(3)
            ]
            total = sum(xyz)
            handle.write(struct.pack("<ff", xyz[0] / total, xyz[1] / total))
    print(f"Wrote {len(spectra)} spectral reference colors to {output}")


if __name__ == "__main__":
    main()

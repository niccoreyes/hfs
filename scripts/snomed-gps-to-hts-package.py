#!/usr/bin/env python3
"""Package the SNOMED International GPS TSV as a local flat FHIR CodeSystem.

The generated NPM package is stored in the user's cache and imported by the
loopback-only HTS instance started by run-hfs-with-ph-core.sh. GPS has no
hierarchy or relationship data, so the CodeSystem is a fragment.
"""

from __future__ import annotations

import csv
import io
import json
import re
import sys
import tarfile
import zipfile
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: snomed-gps-to-hts-package.py GPS.zip output.tgz YYYYMMDD", file=sys.stderr)
        return 2

    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    release_date = sys.argv[3]
    if not re.fullmatch(r"\d{8}", release_date):
        print(f"invalid GPS release date: {release_date}", file=sys.stderr)
        return 2

    expected_entry = f"SnomedINTL_GPSRelease_PRODUCTION_{release_date}T120000Z.txt"
    code_system_path = destination.with_suffix(".codesystem.json")
    temp_package = destination.with_suffix(".tgz.tmp")

    try:
        with zipfile.ZipFile(source) as archive:
            candidates = [
                name
                for name in archive.namelist()
                if Path(name).name.startswith("SnomedINTL_GPSRelease_PRODUCTION_")
                and name.lower().endswith(".txt")
            ]
            if candidates != [expected_entry]:
                raise ValueError(
                    f"expected one GPS TSV named {expected_entry!r}, found {candidates!r}"
                )

            code_system_path.parent.mkdir(parents=True, exist_ok=True)
            concept_count = 0
            seen_codes: set[str] = set()

            with archive.open(expected_entry) as zipped_tsv:
                text = io.TextIOWrapper(zipped_tsv, encoding="utf-8-sig", newline="")
                reader = csv.DictReader(text, delimiter="\t")
                required_headers = {"ConceptID", "Active", "FSN", "USPreferredTerm"}
                if not reader.fieldnames or not required_headers.issubset(reader.fieldnames):
                    raise ValueError(
                        f"GPS TSV is missing required columns: {sorted(required_headers)}"
                    )

                with code_system_path.open("w", encoding="utf-8", newline="") as out:
                    metadata = {
                        "resourceType": "CodeSystem",
                        "id": f"snomed-gps-{release_date}",
                        "url": "http://snomed.info/sct",
                        "version": (
                            "http://snomed.info/sct/900000000000207008/"
                            f"version/{release_date}"
                        ),
                        "name": f"SnomedCTInternationalGPS{release_date}",
                        "title": f"SNOMED CT Global Patient Set {release_date}",
                        "status": "active",
                        "experimental": False,
                        "date": (
                            f"{release_date[:4]}-{release_date[4:6]}-"
                            f"{release_date[6:8]}T12:00:00Z"
                        ),
                        "publisher": "SNOMED International",
                        "description": (
                            "Flat SNOMED CT Global Patient Set. This GPS release contains "
                            "identifiers, active status, FSNs, and US English preferred terms; "
                            "it does not contain relationships, hierarchies, or subsumption semantics."
                        ),
                        "copyright": (
                            "SNOMED CT is © and ® SNOMED International. SNOMED CT was "
                            "originally created by the College of American Pathologists. "
                            f"SNOMED International Global Patient Set, {release_date}; "
                            "CC BY-ND 4.0: https://creativecommons.org/licenses/by-nd/4.0/"
                        ),
                        "caseSensitive": True,
                        "content": "fragment",
                        "property": [
                            {
                                "code": "inactive",
                                "uri": "http://hl7.org/fhir/concept-properties#inactive",
                                "description": "Whether the concept is inactive",
                                "type": "boolean",
                            }
                        ],
                    }
                    out.write(
                        json.dumps(metadata, ensure_ascii=False, separators=(",", ":"))[:-1]
                    )
                    out.write(',"concept":[')

                    for row in reader:
                        code = (row.get("ConceptID") or "").strip()
                        active = (row.get("Active") or "").strip()
                        fsn = (row.get("FSN") or "").strip()
                        preferred = (row.get("USPreferredTerm") or "").strip()
                        if not code.isdigit() or active not in {"0", "1"} or not fsn or not preferred:
                            raise ValueError(f"malformed GPS row near line {reader.line_num}")
                        if code in seen_codes:
                            raise ValueError(f"duplicate SNOMED code in GPS TSV: {code}")
                        seen_codes.add(code)

                        concept = {
                            "code": code,
                            "display": preferred,
                            "designation": [{"language": "en-US", "value": fsn}],
                        }
                        if active == "0":
                            concept["property"] = [
                                {"code": "inactive", "valueBoolean": True}
                            ]
                        if concept_count:
                            out.write(",")
                        json.dump(concept, out, ensure_ascii=False, separators=(",", ":"))
                        concept_count += 1

                    if concept_count == 0:
                        raise ValueError("GPS TSV contained no concepts")
                    out.write(f'],"count":{concept_count}}}')

            manifest = {
                "name": "snomed.gps.r4",
                "version": release_date,
                "type": "IG",
                "canonical": "http://snomed.info/sct",
                "fhirVersions": ["4.0.1"],
                "license": "CC-BY-ND-4.0",
                "dependencies": {"hl7.fhir.r4.core": "4.0.1"},
                "description": (
                    "Local FHIR CodeSystem representation of the SNOMED International GPS "
                    "for identifier membership and display only."
                ),
            }
            manifest_bytes = json.dumps(
                manifest, ensure_ascii=False, separators=(",", ":")
            ).encode("utf-8")
            with tarfile.open(temp_package, "w:gz") as package:
                manifest_info = tarfile.TarInfo("package/package.json")
                manifest_info.size = len(manifest_bytes)
                manifest_info.mode = 0o644
                manifest_info.mtime = 0
                package.addfile(manifest_info, io.BytesIO(manifest_bytes))
                package.add(str(code_system_path), arcname="package/CodeSystem-snomed-gps.json")
            temp_package.replace(destination)
            code_system_path.unlink()
            print(f"Prepared SNOMED GPS {release_date}: {concept_count:,} flat concepts")
    except (OSError, ValueError, zipfile.BadZipFile, tarfile.TarError) as exc:
        code_system_path.unlink(missing_ok=True)
        temp_package.unlink(missing_ok=True)
        print(f"SNOMED GPS import preparation failed: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

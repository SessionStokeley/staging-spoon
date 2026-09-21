#!/usr/bin/env python3
"""Drive the Intune package build from Python.

Writes the package configuration, runs the PowerShell build, and reads the
JSON it produces. Useful when packaging is part of a larger pipeline or when
you build many applications from one source of truth.

    python examples/build_package.py

Exit code mirrors the build: 0 is production ready, 1 is not.
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUILD = REPO / "build"

CONFIG = {
    "ApplicationName": "Contoso Reader",
    "ApplicationVersion": "4.2.1",
    "PackageVersion": "1.0.0",
    "InstallerType": "EXE",
    "SourceInstaller": "Setup.exe",
    "InstallCommand": 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\\Install.ps1"',
    "UninstallCommand": 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\\Uninstall.ps1"',
    "DetectionMethod": "Script",
    "DetectionScript": "Detection.ps1",
    "InstallBehavior": "System",
    "Architecture": "x64",
    "MinimumOS": "W10_1809",
    "ExpectedExitCodes": [0, 1641, 3010],
    "RebootBehavior": "BasedOnReturnCode",
    "PostInstallExpectation": {
        "File": ["C:\\Program Files\\Contoso\\Reader\\Reader.exe"],
        "UninstallDisplayName": ["Contoso Reader*"],
    },
}


def read_json(path):
    """Return parsed JSON, or None if the build did not produce the file."""
    if not path.is_file():
        return None
    return json.loads(path.read_text(encoding="utf-8-sig"))


def build(source, config, system_context=True):
    """Run the build and return (exit_code, validation_result, intune_config)."""
    powershell = shutil.which("pwsh") or shutil.which("powershell")
    if powershell is None:
        sys.exit("PowerShell not found. Install PowerShell 7 or run on Windows.")

    config_path = REPO / "package.json"
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")

    command = [
        powershell, "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(REPO / "src" / "Build" / "Build-IntunePackage.ps1"),
        "-SourcePath", str(source),
        "-ConfigPath", str(config_path),
        "-OutputPath", str(BUILD),
    ]
    if system_context:
        command.append("-SystemContext")

    # The build streams its phases; let them through rather than capturing.
    completed = subprocess.run(command, cwd=REPO)

    return (
        completed.returncode,
        read_json(BUILD / "TestResults" / "ValidationResult.json"),
        read_json(BUILD / "IntuneConfiguration.json"),
    )


def main():
    exit_code, validation, intune = build(REPO / "source", CONFIG)

    if validation:
        print(f"\nStages ({validation['ExecutionContext']}):")
        for stage in validation["Stages"]:
            code = stage.get("ExitCode")
            suffix = f" (exit {code})" if code is not None else ""
            print(f"  {stage['Result']:<10} {stage['Name']}{suffix}")

    if exit_code == 0 and intune:
        program = intune["ProgramInformation"]
        detection = intune["DetectionRules"]
        print("\nPRODUCTION READY - enter these values in Intune:")
        print(f"  Install command    : {program['InstallCommand']}")
        print(f"  Uninstall command  : {program['UninstallCommand']}")
        print(f"  Install behavior   : {program['InstallBehavior']}")
        print(f"  Restart behavior   : {program['DeviceRestartBehavior']}")
        print(f"  Detection script   : {detection['ScriptFile']}")
        print(f"  Run as 32-bit      : {detection['RunAs32Bit']}")
        print(f"  SHA256             : {intune['Package']['PackageHash']}")
        return 0

    print("\nNOT PRODUCTION READY")

    # The classifier names the failure mode; the report reproduces it.
    if validation and validation.get("Classification"):
        classification = validation["Classification"]
        print(f"  Classification: {classification['Classification']}")
        print(f"  Reason        : {classification['Reason']}")

    report = BUILD / "TestResults" / "FailureReport.md"
    if report.is_file():
        print(f"  Failure report: {report}")

    return 1


if __name__ == "__main__":
    sys.exit(main())

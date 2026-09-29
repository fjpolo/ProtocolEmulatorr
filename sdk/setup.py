#!/usr/bin/env python3
"""Setup script for OmniBus Software SDK."""
from setuptools import setup, find_packages

setup(
    name="omnibus-sdk",
    version="1.0.0",
    description="Official Python SDK for the OmniBus Protocol Emulator ASIC",
    packages=find_packages(),
    install_requires=[
        "pyserial>=3.5"
    ],
    entry_points={
        "console_scripts": [
            "omnibus = omnibus.cli:main",
            "omnibus-load = omnibus.cli:load_cli",
            "omnibus-fuzz = omnibus.cli:fuzz_cli",
            "omnibus-profiler = omnibus.cli:profiler_cli"
        ]
    },
    python_requires=">=3.8"
)

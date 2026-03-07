#!/usr/bin/env python3
# Copyright 2026 Benoit Chesneau
# Licensed under Apache 2.0

"""Build script for hornbeam_http_fast C extension."""

import os
import sys
import platform
from setuptools import setup, Extension

# Compiler flags for optimization
extra_compile_args = ['-O3']

# Platform-specific optimizations
machine = platform.machine().lower()
if sys.platform == 'darwin':
    if machine == 'arm64':
        # Apple Silicon - NEON is automatic
        extra_compile_args.append('-march=armv8-a')
    else:
        # Intel Mac - enable SSE4.2 for SIMD
        extra_compile_args.extend(['-msse4.2', '-mpclmul'])
elif sys.platform.startswith('linux'):
    if machine in ('x86_64', 'amd64'):
        extra_compile_args.extend(['-msse4.2', '-mpclmul'])
    elif machine.startswith('aarch64'):
        extra_compile_args.append('-march=armv8-a')

# Windows MSVC doesn't use these flags
if sys.platform == 'win32':
    extra_compile_args = ['/O2']

# Extension modules
ext_modules = [
    Extension(
        'pico_parser',
        sources=[
            'pico_parser_module.c',
            'picohttpparser/picohttpparser.c'
        ],
        include_dirs=['.'],
        extra_compile_args=extra_compile_args,
    ),
    Extension(
        'pico_parser_fast',
        sources=[
            'pico_parser_fast.c',
            'picohttpparser/picohttpparser.c'
        ],
        include_dirs=['.'],
        extra_compile_args=extra_compile_args,
    )
]

setup(
    name='hornbeam_http_fast',
    version='1.0.0',
    description='Fast HTTP parser using picohttpparser (SIMD-optimized)',
    author='Benoit Chesneau',
    license='Apache-2.0',
    ext_modules=ext_modules,
    python_requires='>=3.8',
    classifiers=[
        'Development Status :: 4 - Beta',
        'Intended Audience :: Developers',
        'License :: OSI Approved :: Apache Software License',
        'Programming Language :: C',
        'Programming Language :: Python :: 3',
        'Topic :: Internet :: WWW/HTTP',
    ],
)

#!/bin/bash
# 450 000 bytes of three-byte UTF-8 on stdout: pipe chunks (64 KiB, not a multiple of 3) must split some characters.
cat >/dev/null
printf '€%.0s' $(seq 1 150000)

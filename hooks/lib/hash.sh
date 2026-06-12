# hash.sh — portable sha256 helper. macOS ships shasum, not sha256sum.
# file_sha256 <path> → prints the hex digest, or empty string on failure.
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    echo ""
  fi
}

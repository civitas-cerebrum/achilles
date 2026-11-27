Seeded mutation corpus for `achilles-spec-lint`.

- `// EXPECT <TB ids>`: the line produces a finding of each listed id (more findings on the line are fine:
  one line can break several rules).
- `// CLEAN`: the line produces no finding of any rule the engine implements.
- `// CLEAN-BLOCKING <TB ids>`: the line produces no blocking finding of those ids.

Every rule promoted to blocking adds its EXPECT lines here; every reported false positive adds a CLEAN line.
The test `tests/bin/spec-lint-corpus.test.mjs` checks the ids of the families the engine implements.

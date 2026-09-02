# Contributing

Issues and pull requests are welcome.

Before submitting a change, run:

```sh
make test
make clean all
codesign --verify --deep --strict camlight.app
```

Keep macOS 13 compatibility unless a change explicitly documents a higher
deployment target. Changes to vendored dependencies should identify the new
upstream tag and commit in both `Vendor/README.md` and
`THIRD_PARTY_NOTICES.md`.

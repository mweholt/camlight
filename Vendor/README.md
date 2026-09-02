# Vendored dependencies

This directory contains source snapshots required for reproducible, standalone
camlight builds:

- `uhubctl`: tag `v2.6.0`, commit `352f5878e999c0a9d5a453b34110479b2056d7e7`
- `libusb`: tag `v1.0.30`, commit `87a55632db62c9bdc58cd31d3ccfa673f1bb017f`

The snapshots are intentionally kept unmodified. camlight compiles the `uhubctl`
command as a private helper and links the required libusb sources directly into
that helper.

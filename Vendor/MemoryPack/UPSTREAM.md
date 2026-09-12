# Memory Pack upstream

This directory vendors the `packer` package from
[Significant-Hobbies/chatgpt-memory-insights](https://github.com/Significant-Hobbies/chatgpt-memory-insights).

The upstream base is commit `815f5cf730ef4cd650c829f74851d04e09a88b2b`.
This vendored copy also includes compatible local changes for StorageDaddy's
date-filtered archive export and source-identity receipt. It is not identical to
that upstream commit.

The package and its vendored dependencies remain governed by their respective
licenses. Memory Pack's license is included in `LICENSE`; dependency versions
and declared licenses are recorded by Cargo metadata during StorageDaddy
packaging.

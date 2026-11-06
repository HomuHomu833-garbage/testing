# testing

Functional tests for [llvm-custom](https://github.com/HomuHomu833/llvm-custom) builds. Each build's `bin/` is laid over Google's official NDK toolchain for the same release and tested there: Linux hosts natively or under qemu-user, Windows hosts (x86_64, i686) under Wine.

Run **Actions > Test LLVM > Run workflow** with the NDK release (`r20b`, `r24-beta1`, ...). Each host build is its own job; the summary job lists OK/FAIL/SKIP per host.

The scripts in `scripts/` also run locally:

```sh
./scripts/test-llvm.sh r24 aarch64-linux-musl
./scripts/test-llvm-win.sh r24
```

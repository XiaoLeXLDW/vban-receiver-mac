# VBAN Receiver 0.4.1 — build 25 binary archive

This tag records the provenance and checksums of the existing macOS build 25
binary. **It is not the application source tree.** GitHub's generated “Source
code” archives for this tag contain these records only. Download the application
ZIP from the [release page](https://github.com/XiaoLeXLDW/vban-receiver-mac/releases/tag/v0.4.1).

The app was originally built from an uncommitted development tree. A complete
matching source snapshot was not retained. No current source commit is claimed
to reproduce it, and newer source changes were not rebuilt into this archive.

The published ZIP is byte-for-byte identical to the saved original build 25
archive; its five bundle files also match the installed application. The binary
version is 0.4.1, build 25, Apple Silicon arm64, macOS 13 or newer. It is ad-hoc
signed and is not Developer ID signed or notarized.

See [build25-manifest.json](build25-manifest.json) for the archive and executable
hashes. Download the ZIP and `.sha256` together, then run:

```sh
shasum -a 256 -c VBAN-Receiver-v0.4.1-build25-arm64-macos.zip.sha256
```

## 中文

这是已存在的 **0.4.1 build 25 原始二进制归档**，并非重新编译的新版。
标签仅保存来源说明与校验值，**不包含对应的完整应用源码**；GitHub 自动生成的
Source code 压缩包也只有这些记录。请从发布页下载应用 ZIP。

原构建来自当时未提交的开发工作区，完整对应源码快照未保留，因此没有把当前主线
或后续实验源码冒充 build 25。发布的 ZIP 与原存档逐字节一致，包内五个文件与
本机安装版本一致。0.3.14 中后来增加的源码修复没有被重新编译进此原始包。

要求 macOS 13+、Apple Silicon；采用 ad-hoc 签名，未使用 Developer ID 或公证。

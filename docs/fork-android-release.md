# Hermes Go Android releases

The fork workflow is separate from the original dsh-go release channels.
It does not upload to the original project, its R2 buckets or mirrors, or
change the existing iOS/HarmonyOS workflows.

1. Enable GitHub Actions in the fork if it is not already enabled. Protect the
   release tag namespace (`v*`) with a ruleset: only release maintainers
   should be able to create tags, and updates/deletions should be blocked.
   The workflow refuses a tag not covered by branch/tag protection or a
   ruleset, or that does not point to the current commit of the fork's `main`.
2. Configure the `android-release` GitHub environment for protected release
   tags only. Add environment secrets `ANDROID_KEYSTORE_BASE64`,
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and
   `ANDROID_KEY_PASSWORD` through GitHub's secret settings. Add environment
   variable `ANDROID_CERT_SHA256`: the 64 hex digits of the trusted release
   certificate, without colons. Use the same private key for future Hermes Go
   releases and keep it out of source control. Do not reuse someone else's
   signing key.
3. At the intended commit, set the version in `app/pubspec.yaml` and sync the
   user guide. After validation, push an explicit `v<version>` tag matching
   the version without `+1`. The build derives Android's version code from the
   commit timestamp in the existing UTC+8 scheme; each new release needs a
   greater code than the last. Use a new version and newer commit for a fix,
   not a moved tag.
4. A push of that protected tag builds arm64, signs with the fork key, verifies
   the certificate and signature schemes, then publishes to the fork's GitHub
   Releases with the APK, `SHA256SUMS`, and `update.json`. Prerelease tags do
   not become the latest release. A manual workflow run only uploads a test
   candidate, never signs with the release key or publishes. Test candidates
   use the development signature and must not be distributed as updates.

The workflow's APK checks only the fork GitHub feed/API, not the original
project, and the Android application ID is unchanged. An original dsh-go APK
signed by a different key cannot be upgraded in place by this fork. Do not
uninstall an existing installation without preserving its data first.

## Android 版自动发版

本分支只发布到 `tsaitang404/hermes-go` 的 GitHub Releases，不写上游镜像或
内测渠道。启用 Actions、保护 `v*` 标签，并在 `android-release` 环境设置
上述四个签名密钥字段和可信证书 SHA-256。推送与 `app/pubspec.yaml` 一致、
指向当前 `main` 的受保护标签后，才会打包、校验证书和签名并发布 arm64。
手动运行只生成测试包，不用正式签名、不发布。应用 ID 未改，签名不同的原版
不能直接覆盖升级；卸载前先备份数据。

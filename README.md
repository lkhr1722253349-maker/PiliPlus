# PiliPlus 定制挂载

本仓库维护听视频歌单、歌词、匿名浏览、扩展倍速及定制更新等改动。应用源码来自 [上游 PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)，由 Actions 按 `upstream.lock` 取出指定提交并叠加 `patches/customization.patch`。定制版从[本仓库的 Releases](https://github.com/lkhr1722253349-maker/PiliPlus/releases)检查和下载更新。

## 跟进上游

1. 在分支上把 `upstream.lock` 改为上游后续提交的完整 SHA。保留 Git 历史，以便 Android 构建编号继续递增。
2. 在干净的临时完整检出中运行 `pwsh -File scripts/assemble.ps1`。脚本会切换检出到合成源码的分离 HEAD。若补丁冲突，构建会停止。在该检出中解决冲突并暂存后，用 `git diff --cached --binary --full-index --output=customization.patch HEAD` 生成基于新上游的补丁，再把补丁带回定制分支。若脚本已成功生成合成提交，可用 `git diff --binary --full-index --output=customization.patch HEAD^2 HEAD` 刷新补丁。
3. 在 Actions 手动运行 **Build**，留空 `tag` 可验证 Android 构建及定制测试。通过后在主分支运行 **Build** 并填写一个新标签，发布到本仓库。

Android 正式包继续使用原定制版的 `SIGN_KEYSTORE_BASE64`、`KEYSTORE_PASSWORD`、`KEY_ALIAS` 和 `KEY_PASSWORD`。使用原签名可延续覆盖安装。发布工作流提供 arm64-v8a 完整包，并在适用时附上差分包。

首次迁移已将定制补丁移植到上游 `d0e0352`，保留上游推荐来源设置及直播媒体通知。应用内功能说明可在合成源码的 `CUSTOMIZATION.md` 查看。

## 首次提交挂载版

从本目录执行以下 PowerShell 命令。它会在旁边建立临时检出，并推送供验证的迁移分支。

```powershell
$overlay = (Get-Location).Path
$checkout = Join-Path (Split-Path $overlay) 'PiliPlus-overlay-migration'
git clone https://github.com/lkhr1722253349-maker/PiliPlus.git $checkout
if ($LASTEXITCODE) { throw 'Clone failed' }
Set-Location $checkout
if ((git rev-parse HEAD).Trim() -ne '91093ee71688ce093405744f7ca4bdea56511922') {
    throw 'The fork has changed since this overlay was generated.'
}
git switch -c build/upstream-overlay
if ($LASTEXITCODE) { throw 'Branch creation failed' }
git rm -r -- .
if ($LASTEXITCODE) { throw 'Failed to prepare the overlay tree' }
foreach ($item in '.github', '.gitattributes', 'LICENSE', 'README.md', 'patches', 'scripts', 'upstream.lock') {
    Copy-Item -LiteralPath (Join-Path $overlay $item) -Destination . -Recurse -Force -ErrorAction Stop
}
git add -A
if ($LASTEXITCODE) { throw 'Staging failed' }
git commit -m 'Build PiliPlus from a pinned upstream and customization overlay'
if ($LASTEXITCODE) { throw 'Commit failed' }
git push -u origin build/upstream-overlay
```

在 GitHub 为该分支开启 PR，即可触发 Android 验证。验证通过后合并到 `main`，再从 `main` 发布签名包。

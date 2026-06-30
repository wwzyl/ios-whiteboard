# CBrain iOS

这是从 `cbrain-android` 重新整理出来的 iOS 原生 SwiftUI 工程。它不是 APK 转换产物，而是兼容原 CBrain 知识库目录格式的 iOS 版本。

当前第一版已包含：

- 导入包含 `graph.json` 和 `notes` 的 CBrain 知识库文件夹
- 浏览节点、父节点、子节点、相关节点
- 搜索标题和笔记正文
- 编辑并保存 `notes/*.md`
- 新增父节点、子节点、相关节点
- 节点改名、软删除
- 写入 `modifys/modify_yyyy-MM-dd.json`
- S3 双向同步、配置检查、从 S3 全量下载
- `.cbrain-sync/manifest.json`、远端锁、冲突文件处理
- GitHub Actions 云端构建 IPA

暂未完成：

- iOS App 图标
- 真机 UI 细节测试

## 在 GitHub 生成 IPA

1. 新建一个 GitHub 仓库。
2. 把本文件夹里的所有内容推送到仓库根目录。
3. 打开仓库的 `Actions`。
4. 运行 `Build iOS IPA`。
5. 下载 artifact：`CBrainIOS-ipa`。

产物路径：

```text
CBrainIOS.ipa
```

这个 IPA 是未签名/免上架用途，适合后续交给 TrollStore 安装测试。

## 本地 Mac 构建

如果之后能使用 Mac：

```bash
bash Scripts/package_ipa.sh
```

生成位置：

```text
build/ipa/CBrainIOS.ipa
```

## 知识库格式

选择的文件夹需要直接包含：

- `graph.json`
- `notes`
- 可选：`modifys` 或 `modifys.json`

iOS 版会把选中的知识库复制到 App 的 Documents 目录下：

```text
CBrain Library
```

编辑保存会写入这份 App 内部副本。

从 S3 全量下载时，也会写入同一个 App 内部目录。

# 预览文件说明

`features-b-preview.tsv` 是一次性对照样本，**不参与构建**，也没有被任何脚本引用。

用途：验证「把 `configs/features.conf` 改成正 Tab 分隔的 `.tsv`」在 GitHub 页面上的实际渲染效果。
内容与 `configs/features.conf` 完全相同，仅把 17 行数据里的竖线换成了 Tab，23 行注释与空行原样保留。

看完即可删除，或用 `git rm docs/features-b-preview.tsv` 移除。

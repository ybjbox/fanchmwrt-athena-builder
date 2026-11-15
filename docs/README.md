# 预览文件说明

三个一次性对照样本，**都不参与构建**，没有被任何脚本引用；看完可整体删除。

| 文件 | 方案 | 格式 | 重点看什么 |
|---|---|---|---|
| `features-b-preview.tsv` | C | 真 Tab、无注释、首行表头 | GitHub 原生表格渲染（列数统一后才能渲染） |
| `features-d-preview.md` | D | Markdown 表格 | 表格 + 分组标题 + 说明，全在同一个文件里 |
| `features-e-preview.yaml` | E | YAML | 结构化层级（packages 列表、source.git/feed 分组） |

数据均来自 `configs/features.conf`（17 条），仅格式不同。

## 关于 B

最初的 B 方案（真 Tab + 保留 23 行注释与空行）已删除：GitHub 表格视图要求每行列数一致，
注释行 1 列、空行 0 列与数据行 6 列混排时拒绝渲染，页面提示
`It looks like row 19 should actually have 1 column, instead of 6 in line 18`。
现在的 `features-b-preview.tsv` 是去注释后的 C 方案。

# 预览文件说明

`features-b-preview.tsv` 是一次性对照样本，**不参与构建**，没有被任何脚本引用。

当前内容为「C 方案」：真 Tab 分隔、**无注释、无空行**，首行为表头，17 行数据，18 行 6 列。

此前尝试的「B 方案」（保留 23 行注释与空行）已被替换——GitHub 的表格视图要求每行列数一致，
注释行 1 列、空行 0 列与数据行 6 列混排时无法渲染，页面会提示
`It looks like row 19 should actually have 1 column, instead of 6 in line 18`。

看完即可删除，或用 `git rm docs/features-b-preview.tsv docs/README.md` 移除。

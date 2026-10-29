# 文档导航

本目录存放**部署流程**文档（`deployment/`）；非部署资料（知识库源数据、脚本说明）分布在各目录，见顶部 [README 第 9 节](../README.md#9-仓库文件说明)。

| 文档 | 内容 | 适用场景 |
| --- | --- | --- |
| [deployment/deployment-log.md](deployment/deployment-log.md) | 阶段一～六的实际执行记录：环境基线、具体命令、踩坑根因、验证数据、运维手册，以及门户开机自启与一键启停（§七之三） | 复现部署、排查问题、交接 |
| [deployment/stage-summary.md](deployment/stage-summary.md) | 阶段一～六的精简总结：进度、交付结果、实测数据、服务启动与自启、下一步与遗留事项 | 汇报、阶段评审 |
| [multi-tenant-design.md](multi-tenant-design.md) | 多租户部门隔离与门户方案：角色矩阵、成员/账号权限管控（提权保护、只能管理更低权限者、受保护管理员账号）、登录与注册策略（80 端口仅管理员可登录、任何人都不能自助注册、账号一律由管理员开通）、隔离机制、邀请流程、部署步骤 | 设计对齐、权限复核 |

## 相关位置

- 主文档（部署方案与验收清单）：[../README.md](../README.md)
- 脚本索引（部署 / 非部署）：[../scripts/README.md](../scripts/README.md)
- 知识库资料：[../welding-gun-selection-kb/welding-gun-kb-overview.md](../welding-gun-selection-kb/welding-gun-kb-overview.md)

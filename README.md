# singbox-nodejs
直接git运行即可，无需修改任何东西

## 运行模式

- **单端口模式**：启用 HY2 + HTTP(订阅) + Argo（可以手动选择 TUIC）
- **多端口模式**：TUIC + HTTP(订阅) + Argo + HY2 + REALITY

## 订阅链接

支持多种订阅格式：

- **Clash Meta 订阅**：`http://IP:PORT/clash`  
  适用于：Clash Meta / Clash Verge / mihomo 等客户端

- **通用订阅**：`http://IP:PORT/sub`  
  适用于：V2Ray / V2RayN / Shadowrocket / Surge 等客户端

- **管理页面**：`http://IP:PORT/`  
  浏览器访问可查看所有订阅链接和节点信息

## 配置说明

如果系统无法自动获取到可用端口，则需自己手动新建 `${FILE_PATH}/ports.txt` 文件，一行一个端口号

## Clash Meta 配置

生成的 Clash Meta 配置包含：
- 所有可用代理节点
- 自动代理组（URL 测试）
- 手动选择代理组
- 基础分流规则（国内直连）

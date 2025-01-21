## 使用方法：
复制这个运行：`wget https://raw.githubusercontent.com/xspoco/RealmPortForwarding/refs/heads/main/RealmOneKey.sh && chmod +x RealmOneKey.sh && ./RealmOneKey.sh`

后面再运行：`./RealmOneKey.sh` 即可

## 完善脚本
原脚本已经很好的实现了一键安装环境和启动服务，不过还可以再进行一些完善：
- [x] 提供可查看的转发细则选项
- [x] 提示添加的是目标的IP与端口，让说明更加清晰
- [x] 添加支持tcp和udp的默认配置
- [x] 实现本地添加与远程不一样的端口
- [ ] ~~将添加的始终下载最新版的功能去掉。总是部署最新版本的应用并不是好事。~~不过这个功能很简单，应该不会出现兼容性问题。
- [x] 用户选择卸载的时候，将下载的“RealmOneKey.sh”脚本文件也删除掉，将所有的东西都删除干净。

## 参考资料
1. https://github.com/Jaydooooooo/Port-forwarding
2. https://github.com/zhboner/realm

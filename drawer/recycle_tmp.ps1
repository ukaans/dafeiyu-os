# recycle_tmp.ps1 —— 运行时临时脚本的**空模板**，不要在这里写具体路径。
#
# 真正的用法：抽屉执行「删除文件到回收站…」时，DoRecycle() 会用 FileAppend 把本文件
# 整份重写成一次性的删除脚本（Add-Type + FileSystem.DeleteFile(..., SendToRecycleBin)），
# 再用 powershell -File 跑一次，跑完就留在原地等下次覆盖。
#
# 维护约定：
#   · 本文件只保留注释，**不许出现任何个人绝对路径**（换机器会坏，测试 STA-008 会红）；
#   · 修改删除方式（比如改用 Shell.Application 的 Verb）请改 DesktopPage.ahk 里
#     DoRecycle() 拼出来的脚本文本，不要改这里；
#   · 本文件即使被删掉也能自动重建（DoRecycle 用 FileAppend 创建）。
exit 0

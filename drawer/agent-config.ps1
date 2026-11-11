# =============================================================================
#  agent-config.ps1 — 本地代理端口的唯一定义处
#
#  被 dsh-agent.ps1 / agent-watch.ps1 / ensure-all.ps1 dot-source。
#  另外两份生成物也以这里为准（install.ps1 与代理启动时写入）：
#    %LOCALAPPDATA%\DesktopPage\agent-port.txt   ← 抽屉（AHK）读
#    <壁纸目录>\port.js                          ← 壁纸页读（window.__DSH_AGENT_PORT）
#  改端口只改这一行，然后重跑 install.ps1（或重启代理 + 抽屉）。
# =============================================================================
$AgentPort = 17433
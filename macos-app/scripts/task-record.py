#!/usr/bin/env python3
# 保留原清单，增量登记任务状态和证据，by AI.Coding。
from pathlib import Path
import sys, re, datetime
path = Path(__file__).resolve().parents[2] / 'paste-report/development-plan/tasks.md'
task, state, evidence = sys.argv[1:4]
text = path.read_text()
start = text.index('**' + task + '【')
end = text.find('\n- [', start)
if end < 0: end = text.index('\n## 完成状态', start)
section = text[start:end]
section = re.sub(r'  - 执行记录：.*\n?', '', section)
section += '\n  - 执行记录：负责人 Codex；状态：' + state + '；更新时间：' + datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(timespec='seconds') + '；' + evidence + '\n'
text = text[:start] + section + text[end:]
text = re.sub(r'- \[[ x]\] (\*\*' + task + '【)', '- [' + ('x' if state == '完成' else ' ') + '] \\1', text)
count = len(re.findall(r'- \[x\] \*\*T', text))
text = re.sub(r'进度：\d+/22', f'进度：{count}/22', text)
text = text.replace('状态：未开始。本文列出的工程文件、脚本和测试均为待创建产物。', '状态：实施中。逐项证据见执行记录，未勾选不代表完成。')
path.write_text(text)

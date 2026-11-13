#!/bin/sh
[ -n "$PLUGIN_ROOT" ] || exit 0
runtime=$(command -v node 2>/dev/null)
if [ -z "$runtime" ]; then
  for candidate in "/Applications/Mac 任务通知.app/Contents/Resources/node" "$HOME/Applications/Mac 任务通知.app/Contents/Resources/node"; do
    if [ -x "$candidate" ]; then runtime=$candidate; break; fi
  done
fi
if [ -z "$runtime" ]; then
  printf '%s\n' 'mac-task-notifier: 需要 Node 20+ 或已安装的 Mac 应用，通知已跳过。' >&2
  exit 0
fi
exec "$runtime" "$PLUGIN_ROOT/scripts/send-notification.mjs"

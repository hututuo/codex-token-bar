import type { CommandFailureDiagnostic } from "../../api/client";

interface DiagnosticStripProps {
  diagnostic: CommandFailureDiagnostic;
}

export function DiagnosticStrip({ diagnostic }: DiagnosticStripProps) {
  return (
    <div className="diagnostic-strip" title={diagnostic.message}>
      <span className="diagnostic-strip__label">本地读取提醒</span>
      <span className="diagnostic-strip__message">{diagnosticSummary(diagnostic)}</span>
      <span className="diagnostic-strip__meta">
        {formatDiagnosticTime(diagnostic.occurredAt)}
        {diagnostic.count > 1 ? ` · ${diagnostic.count} 次` : ""}
      </span>
    </div>
  );
}

function diagnosticSummary(diagnostic: CommandFailureDiagnostic): string {
  if (diagnostic.command.startsWith("local:")) {
    return `${commandDisplayName(diagnostic.command)}：${diagnostic.message}`;
  }
  return `${commandDisplayName(diagnostic.command)} 失败，已显示待读取/零值数据。`;
}

function commandDisplayName(command: string): string {
  const knownNames: Record<string, string> = {
    "local:quota_history": "额度历史",
    "local:token_event_cache": "精确 token 缓存",
    "local:jsonl_scan": "会话 JSONL 扫描",
    "local:jsonl_file": "会话 JSONL 文件",
    "local:thread_info": "会话标题索引",
    "local:live_rate_stream": "实时速率输出流",
    "local:live_rate_summary": "实时速率汇总",
    "local:live_rate_thread_title": "实时速率会话标题",
    get_codex_home: "Codex 目录读取",
    read_platform_capabilities: "平台能力读取",
    read_dashboard_snapshot: "首页快速统计读取",
    read_precise_dashboard_snapshot: "精确 token 扫描",
    read_account_quota: "额度读取",
    read_live_rate_snapshot: "实时速率读取",
    read_live_thread_options: "会话列表读取",
    read_floating_snapshot: "悬浮窗数据读取",
    read_unread_summary: "未读状态读取",
    read_autostart_status: "开机自启读取",
    set_codex_home: "Codex 目录保存",
    reset_codex_home: "Codex 目录恢复",
    set_autostart_enabled: "开机自启设置",
    save_floating_settings: "悬浮窗设置保存",
    save_floating_position: "悬浮窗位置保存",
    save_display_surfaces: "显示设置保存",
    save_setup_guide_completed: "首次设置保存",
    create_provider_backup: "会话修复备份",
    sync_provider_history: "会话修复同步",
    verify_provider_repair: "会话修复验证",
    rollback_provider_backup: "会话修复回滚",
    "platform:command:show_floating_window": "悬浮窗打开",
    "platform:command:hide_floating_window": "悬浮窗关闭",
    "platform:command:show_status_panel_window": "状态栏面板打开",
    "platform:command:hide_status_panel_window": "状态栏面板关闭",
    "platform:command:show_dashboard_window": "主界面打开",
    "platform:command:set_status_tray_readout": "状态栏数字更新",
    "platform:command:start_live_rate_stream": "实时速率事件流",
    "platform:command:stop_live_rate_stream": "实时速率事件流停止",
    "platform:emit-floating-window-hidden": "悬浮窗关闭同步",
    "platform:publish-floating-settings": "悬浮窗设置同步",
    "platform:resize-floating-window": "悬浮窗尺寸调整",
    "platform:start-floating-window-drag": "悬浮窗拖动",
    "platform:restore-floating-window-position": "悬浮窗位置恢复",
    "platform:listen-floating-window-moved": "悬浮窗位置监听",
    "platform:listen:floating-window-hidden": "悬浮窗关闭监听",
    "platform:listen:floating-settings-changed": "悬浮窗设置监听",
    "platform:listen:live-rate-snapshot": "实时速率事件监听",
    "platform:read-window-label": "窗口类型识别",
  };
  if (knownNames[command]) {
    return knownNames[command];
  }
  if (command.startsWith("platform:")) {
    return command.slice("platform:".length).replaceAll("_", " ").replaceAll(":", " ");
  }
  return command.replaceAll("_", " ");
}

function formatDiagnosticTime(value: string): string {
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(value));
}

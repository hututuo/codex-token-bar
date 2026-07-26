import assert from "node:assert/strict";
import test from "node:test";
import { buildLocalCommandNoticeLines } from "./localCommandNotice.ts";

function diagnostic(command, message, count = 1) {
  return { command, message, occurredAt: "2026-07-27T00:00:00.000Z", count };
}

test("settings error renders first and settings-owned commands are deduplicated", () => {
  const lines = buildLocalCommandNoticeLines("读取本地设置失败：磁盘错误", [
    diagnostic("read_app_settings", "磁盘错误"),
    diagnostic("save_floating_settings", "磁盘错误"),
    diagnostic("read_dashboard_snapshot", "超时"),
  ]);

  assert.deepEqual(lines.map((line) => line.key), ["settings", "command:read_dashboard_snapshot"]);
  assert.equal(lines[0].text, "读取本地设置失败：磁盘错误");
  assert.equal(lines[1].text, "本地操作 read_dashboard_snapshot 失败：超时");
});

test("repeat counts show up and the list caps at three lines with an overflow summary", () => {
  const lines = buildLocalCommandNoticeLines(null, [
    diagnostic("a_command", "失败一", 3),
    diagnostic("b_command", "失败二"),
    diagnostic("c_command", "失败三"),
    diagnostic("d_command", "失败四"),
  ]);

  assert.equal(lines.length, 3);
  assert.equal(lines[0].text, "本地操作 a_command 失败 ×3：失败一");
  assert.equal(lines[1].text, "本地操作 b_command 失败：失败二");
  assert.equal(lines[2].key, "overflow");
  assert.equal(lines[2].text, "另有 2 项本地操作失败（详见开发者控制台）");
});

test("empty inputs render nothing and blank settings error is ignored", () => {
  assert.deepEqual(buildLocalCommandNoticeLines(null, []), []);
  assert.deepEqual(buildLocalCommandNoticeLines("  ", []), []);
});

test("settings error alone occupies one slot and leaves two for commands", () => {
  const lines = buildLocalCommandNoticeLines("保存悬浮窗设置失败：只读文件系统", [
    diagnostic("a_command", "失败一"),
    diagnostic("b_command", "失败二"),
    diagnostic("c_command", "失败三"),
  ]);

  assert.equal(lines.length, 3);
  assert.equal(lines[0].key, "settings");
  assert.equal(lines[1].key, "command:a_command");
  assert.equal(lines[2].key, "overflow");
  assert.equal(lines[2].text, "另有 2 项本地操作失败（详见开发者控制台）");
});

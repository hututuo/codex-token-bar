import assert from "node:assert/strict";
import test from "node:test";
import { finishUpdateInstall } from "./updateInstallOutcome.ts";

test("stale availability becomes latest after install precheck, not a generic failure", async () => {
  const result = await finishUpdateInstall(async () => "alreadyLatest", async () => ({status:"none",message:"",revision:3}));
  assert.equal(result.status, "none");
  assert.equal(result.message, "已是最新版");
});
test("failed launch keeps the available update retryable and explains the failure", async () => {
  const result = await finishUpdateInstall(async () => {throw "安装器未能启动：ShellExecuteW=5";},
    async () => ({status:"available", version:"0.9.4",message:"new",body:"",date:null,revision:4}));
  assert.equal(result.status, "available");
  assert.match(result.message, /ShellExecuteW=5/);
});
test("registry cleared during failed install is read again instead of retaining old availability", async () => {
  let reads=0;
  const result = await finishUpdateInstall(async () => {throw "changed";}, async () => {reads++;return {status:"none",message:"",revision:4};});
  assert.equal(reads,1);
  assert.equal(result.status,"error");
  assert.equal("version" in result,false);
});

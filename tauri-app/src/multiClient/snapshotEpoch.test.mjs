import assert from "node:assert/strict";
import test from "node:test";
import {SnapshotEpoch} from "./snapshotEpoch.ts";
test("source replacement and retirement reject late replies while a same-source rerender preserves its request",()=>{
 const epoch=new SnapshotEpoch();assert.equal(epoch.select("a"),true);const old=epoch.capture();
 assert.equal(epoch.select("a"),false);assert.equal(epoch.accepts(old),true);
 epoch.select("b");assert.equal(epoch.accepts(old),false);const active=epoch.capture();
 epoch.invalidate();assert.equal(epoch.accepts(active),false);
 epoch.select("a");assert.equal(epoch.accepts(old),false,"returning to a source cannot revive its old pending reply");
});

import test from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {Window} from 'happy-dom';
import {withSsrModules} from '../../test/ssrHarness.mjs';
test('scope, compact reporting and editable identity share the same top row',async()=>withSsrModules(async load=>{
 const {DashboardHeader}=await load('/src/components/DashboardHeader.tsx');
 const html=renderToStaticMarkup(React.createElement(DashboardHeader,{
  scopeControl:React.createElement('nav',{'aria-label':'统计客户端范围'},'Codex / Claude CLI / 汇总'),
  reportingStatus:React.createElement('button',{className:'speed-report-header-status'},'正在上报'),
  account:{displayName:'Local User',planLabel:'PRO'},customAccountDisplayName:'',generatedAt:'2026-10-28T09:00:00Z',
  codexHome:{exists:true,source:'auto',path:'/local'},autostartStatus:{available:true,enabled:false,message:''},
  appUpdateState:{kind:'idle',message:''},threadDeleteBridgeStatus:{connected:false,debugPort:null,message:''},autoResumeEnabled:false,
  onCodexHomeChange:async()=>{},onCodexHomeReset:async()=>{},onCustomAccountDisplayNameChange:async()=>{},onCheckForUpdate:async()=>{},
  onExportCsv(){},onExportPng(){},onOpenProviderRepair(){},onOpenSessionManagement(){},onOpenSettings(){},onRefresh:async()=>{},onToggleAutostart(){},refreshing:false,
 }));
 const w=new Window();w.document.body.innerHTML=html;
 const top=w.document.querySelector('.dashboard-header-top');assert.ok(top);
 assert.ok(top.querySelector('[aria-label="统计客户端范围"]'));assert.ok(top.querySelector('.speed-report-header-status'));
 assert.equal(top.querySelector('.dashboard-profile .account-name').textContent,'Local User');
 assert.equal(w.document.querySelectorAll('.brand-mark').length,1);
 assert.equal(w.document.querySelector('.floating-title-spacer'),null);
 assert.ok(w.document.querySelector('.dash-head__strip'));assert.ok(w.document.querySelector('.dash-head__actions'));
 w.close();
}));

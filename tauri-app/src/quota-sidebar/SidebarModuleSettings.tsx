import { DEFAULT_MODULE_ORDER, SIDEBAR_MODULE_TITLES, moveSidebarModule, type SidebarModule, type SidebarModuleVisibility } from "./moduleVisibility";

export function SidebarModuleSettings({ order, visibility, disabled = false, onOrder, onToggle }: {
  order: readonly SidebarModule[]; visibility: SidebarModuleVisibility; disabled?: boolean;
  onOrder: (next: SidebarModule[]) => void; onToggle: (module: SidebarModule, visible: boolean) => void;
}) {
  return <section className="qs-module-settings" aria-label="侧栏设置">
    <div className="qs-section-heading"><h3>侧栏设置</h3><button disabled={disabled || JSON.stringify(order) === JSON.stringify(DEFAULT_MODULE_ORDER)} onClick={() => onOrder([...DEFAULT_MODULE_ORDER])}>恢复默认顺序</button></div>
    <p>勾选显示，点箭头调整从上到下的顺序。</p>
    <ol>{order.map((module, index) => <li key={module} data-module={module}>
      <span>{index + 1}</span><label><input type="checkbox" checked={visibility[module]} disabled={disabled} onChange={e => onToggle(module, e.target.checked)}/>{SIDEBAR_MODULE_TITLES[module]}</label>
      <button aria-label={`上移${SIDEBAR_MODULE_TITLES[module]}`} title="上移" disabled={disabled || index === 0} onClick={() => onOrder(moveSidebarModule(order, module, -1))}>↑</button>
      <button aria-label={`下移${SIDEBAR_MODULE_TITLES[module]}`} title="下移" disabled={disabled || index === order.length - 1} onClick={() => onOrder(moveSidebarModule(order, module, 1))}>↓</button>
    </li>)}</ol>
    <p>设置入口固定在底部，隐藏的项目会保留顺序。</p>
  </section>;
}

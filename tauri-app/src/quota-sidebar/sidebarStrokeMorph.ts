import { sidebarStrokes, strokePath, type SidebarStrokeSpec } from "./sidebarStrokeGeometry";

type StrokePresentation = { d: string; width: string; dash?: string; offset?: string; opacity?: string };
const namespace = "http://www.w3.org/2000/svg";

/** One bounded compositor animation. Original strokes remain mounted and are
 * restored in the same task that removes the overlay. No display-tick JS. */
export function animateSidebarStrokes(root: HTMLElement, expanded: boolean, previous = new Map<string, StrokePresentation>()) {
  const doc = root.ownerDocument, win = doc.defaultView;
  const empty = () => new Map<string, StrokePresentation>();
  if (!win?.CSS?.supports("d", 'path("M0 0 L1 1")')) return empty;
  const origin = root.getBoundingClientRect();
  const layer = doc.createElementNS(namespace, "svg");
  layer.setAttribute("class", "qs-stroke-morph"); layer.setAttribute("aria-hidden", "true");
  if (typeof layer.animate !== "function") return empty;
  const targets = new Map([...root.querySelectorAll<HTMLElement>("[data-sidebar-stroke-target]")].map(node => [node.dataset.sidebarStrokeTarget, node]));
  const guideLayer=doc.createElementNS(namespace,"svg");
  guideLayer.setAttribute("class","qs-pace-morph");guideLayer.setAttribute("aria-hidden","true");
  const guides=new Map([...root.querySelectorAll<HTMLElement>("[data-sidebar-pace-target]")].map(node=>[node.dataset.sidebarPaceTarget,node]));
  const originals = new Map<Element, string>(), animations: Animation[] = [];
  let removed = false;
  const restore = () => {
    if (removed) return;
    removed = true;
    originals.forEach((visibility, node) => { (node as HTMLElement | SVGElement).style.visibility = visibility; });
    layer.remove(); guideLayer.remove(); animations.forEach(animation => animation.cancel());
  };
  const paths: { id: string; node: SVGPathElement }[] = [], groups = new Map<string, SVGGElement>();
  const hide = (node: Element) => {
    const style = (node as HTMLElement | SVGElement).style;
    if (!originals.has(node)) originals.set(node, style.visibility);
    style.visibility = "hidden";
  };
  try {
    for (const node of root.querySelectorAll<HTMLElement | SVGElement>("[data-sidebar-stroke-source]")) {
      let specs: SidebarStrokeSpec[];
      try { specs = JSON.parse(node.dataset.strokeSpec ?? "[]"); } catch { continue; }
      if (!Array.isArray(specs)) continue;
      const measure = node.dataset.strokeInset ? node.closest("svg") ?? node : node;
      const rect = measure.getBoundingClientRect(), inset = Number(node.dataset.strokeInset ?? 0);
      const source = { x: rect.x - origin.x + rect.width * inset, y: rect.y - origin.y + rect.height * inset,
        width: rect.width * (1 - 2 * inset), height: rect.height * (1 - 2 * inset) };
      for (const spec of specs) {
        const target = targets.get(spec.id);
        if (!target) continue;
        const end = target.getBoundingClientRect();
        const strokes = sidebarStrokes(spec, source, { x: end.x - origin.x, y: end.y - origin.y, width: end.width, height: end.height });
        if (!strokes.length) continue;
        hide(node); hide(target);
        const guide=guides.get(spec.id);if(guide && strokes.some(stroke=>stroke.foreground))hide(guide);
        for (const stroke of strokes) {
          const path = doc.createElementNS(namespace, "path");
          const sourcePath = stroke.sourcePath ?? stroke.source, targetPath = stroke.targetPath ?? stroke.target;
          const fromRange = (expanded ? stroke.targetRange : stroke.sourceRange) ?? [0, 1];
          const toRange = (expanded ? stroke.sourceRange : stroke.targetRange) ?? [0, 1];
          const rangeStyle = (range: number[]) => ({ dash: `${Math.max(0, range[1] - range[0])} 2`, offset: String(-range[0]), opacity: range[1] > range[0] ? "1" : "0" });
          const from = previous.get(stroke.id) ?? { d: `path("${strokePath(expanded ? targetPath : sourcePath)}")`, width: String(expanded ? stroke.targetWidth : stroke.sourceWidth), ...rangeStyle(fromRange) };
          const endStyle = rangeStyle(toRange);
          const points = expanded ? sourcePath : targetPath;
          const width = expanded ? stroke.sourceWidth : stroke.targetWidth;
          path.setAttribute("d", strokePath(points)); path.setAttribute("fill", "none");
          path.setAttribute("stroke", stroke.color); path.setAttribute("stroke-width", String(width));
          path.setAttribute("stroke-linecap", "round"); path.setAttribute("stroke-linejoin", "round");
          // Keep the whole arc as an affine ellipse. Animate the actual fill
          // interval along it instead of bending a separately trimmed path.
          path.setAttribute("pathLength", "1");
          path.style.strokeDasharray = endStyle.dash; path.style.strokeDashoffset = endStyle.offset; path.style.opacity = endStyle.opacity;
          let group = groups.get(stroke.group);
          if (!group) {
            group = doc.createElementNS(namespace, "g"); group.setAttribute("opacity", String(stroke.opacity));
            (stroke.foreground ? guideLayer : layer).append(group); groups.set(stroke.group, group);
          }
          group.append(path); paths.push({ id: stroke.id, node: path });
          animations.push(path.animate([
            { d: from.d, strokeWidth: from.width, strokeDasharray: from.dash ?? rangeStyle(fromRange).dash, strokeDashoffset: from.offset ?? rangeStyle(fromRange).offset, opacity: from.opacity ?? rangeStyle(fromRange).opacity },
            { d: `path("${strokePath(points)}")`, strokeWidth: String(width), strokeDasharray: endStyle.dash, strokeDashoffset: endStyle.offset, opacity: endStyle.opacity },
          ] as Keyframe[], { duration: 440, easing: expanded ? "cubic-bezier(.2,.8,.2,1)" : "cubic-bezier(.333333,1,.666667,1)", fill: "forwards" }));
        }
      }
    }
  } catch {
    // A WebView without working SVG path animation keeps its original crossfade.
    restore(); return empty;
  }
  if (!paths.length) return empty;
  root.append(layer);
  if(guideLayer.children.length)root.append(guideLayer);
  void Promise.all(animations.map(animation => animation.finished.catch(() => {}))).then(restore);
  return () => {
    if (removed) return empty();
    const presentation = new Map(paths.map(({ id, node }) => {
      const style = win.getComputedStyle(node);
      return [id, { d: style.d || `path("${node.getAttribute("d")}")`, width: style.strokeWidth, dash: style.strokeDasharray, offset: style.strokeDashoffset, opacity: style.opacity }];
    }));
    restore(); return presentation;
  };
}

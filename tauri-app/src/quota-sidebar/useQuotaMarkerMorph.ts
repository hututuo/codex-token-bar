import { useLayoutEffect, useRef, type RefObject } from "react";
import { animateSidebarStrokes } from "./sidebarStrokeMorph";

type MarkerFrame = { x: number; y: number; diameter: number };
const markerFrame = (node: HTMLElement): MarkerFrame => { const r=node.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2,diameter:Math.min(r.width,r.height)}; };

/** Quota markers only. One compositor animation per transition; no frame loop,
 * scans, timers while settled, or network/IPC. Preserve both the presentation
 * center and diameter on reversal; the 3px rail dot grows into the 5px ring dot. */
export function animateQuotaMarkers(root: HTMLElement, expanded: boolean, previous = new Map<string,MarkerFrame>()) {
  const animations: Animation[]=[];
  const markers: {id:string;node:HTMLElement}[]=[];
  const originals=new Map<HTMLElement,string>();
  const origin=root.getBoundingClientRect();
  const ends=[...root.querySelectorAll<HTMLElement>("[data-quota-marker-end]")];
  const hide=(node:HTMLElement)=>{if(!originals.has(node))originals.set(node,node.style.visibility);node.style.visibility="hidden";};
  const layer=document.createElement("div");
  layer.className="qs-quota-marker-morph";layer.setAttribute("aria-hidden","true");
  root.append(layer);
  for(const start of root.querySelectorAll<HTMLElement>("[data-quota-marker-start]")) {
    const id=start.dataset.quotaMarkerStart!;
    const end=ends.find(node=>node.dataset.quotaMarkerEnd?.split(" ").includes(id));
    if(!end)continue;
    const from=previous.get(id)??markerFrame(expanded?start:end),to=markerFrame(expanded?end:start);
    if(![from.x,from.y,to.x,to.y,from.diameter,to.diameter].every(Number.isFinite)||from.diameter<=0||to.diameter<=0)continue;
    const dot=document.createElement("i");
    Object.assign(dot.style,{position:"absolute",width:`${from.diameter}px`,height:`${from.diameter}px`,borderRadius:"50%",background:start.style.background,
      left:`${from.x-origin.x-from.diameter/2}px`,top:`${from.y-origin.y-from.diameter/2}px`,transformOrigin:"center"});
    layer.append(dot);hide(start);hide(end);markers.push({id,node:dot});
    animations.push(dot.animate([{transform:"translate(0,0) scale(1)"},{transform:`translate(${to.x-from.x}px,${to.y-from.y}px) scale(${to.diameter/from.diameter})`}],
      {duration:440,easing:"cubic-bezier(.2,.8,.2,1)",fill:"forwards"}));
  }
  let removed=false;
  const restore=()=>{if(removed)return;removed=true;originals.forEach((value,node)=>node.style.visibility=value);layer.remove();animations.forEach(a=>a.cancel());};
  void Promise.all(animations.map(a=>a.finished.catch(()=>{}))).then(restore);
  return ()=>{if(removed)return new Map<string,MarkerFrame>();const positions=new Map(markers.map(({id,node})=>[id,markerFrame(node)]));restore();return positions;};
}

export function useQuotaMarkerMorph(root:RefObject<HTMLElement|null>,expanded:boolean,enabled:boolean) {
  const prior=useRef(expanded),positions=useRef(new Map<string,MarkerFrame>());
  const strokes=useRef<ReturnType<ReturnType<typeof animateSidebarStrokes>>>(new Map());
  useLayoutEffect(()=>{
    const changed=prior.current!==expanded;prior.current=expanded;
    if(!enabled||!changed||!root.current||window.matchMedia("(prefers-reduced-motion: reduce)").matches||typeof root.current.animate!=="function"){
      positions.current.clear();strokes.current.clear();return;
    }
    const cancel=animateQuotaMarkers(root.current,expanded,positions.current);positions.current.clear();
    const cancelStrokes=animateSidebarStrokes(root.current,expanded,strokes.current);strokes.current.clear();
    return()=>{positions.current=cancel();strokes.current=cancelStrokes();};
  },[expanded,enabled,root]);
}

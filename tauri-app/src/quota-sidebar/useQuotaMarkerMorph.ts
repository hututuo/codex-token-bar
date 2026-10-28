import { useLayoutEffect, useRef, type RefObject } from "react";
import { animateSidebarStrokes } from "./sidebarStrokeMorph";

type Center = { x: number; y: number };
const center = (node: HTMLElement): Center => { const r=node.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}; };

/** Quota markers only. One compositor animation per transition; no frame loop,
 * scans, timers while settled, or network/IPC. Return presentation positions on
 * reversal so a rapid pointer change does not restart from the old endpoint. */
export function animateQuotaMarkers(root: HTMLElement, expanded: boolean, previous = new Map<string,Center>()) {
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
    const from=previous.get(id)??center(expanded?start:end),to=center(expanded?end:start);
    if(![from.x,from.y,to.x,to.y].every(Number.isFinite))continue;
    const dot=document.createElement("i");
    Object.assign(dot.style,{position:"absolute",width:"5px",height:"5px",borderRadius:"50%",background:start.style.background,
      left:`${from.x-origin.x-2.5}px`,top:`${from.y-origin.y-2.5}px`});
    layer.append(dot);hide(start);hide(end);markers.push({id,node:dot});
    animations.push(dot.animate([{transform:"translate(0,0)"},{transform:`translate(${to.x-from.x}px,${to.y-from.y}px)`}],
      {duration:440,easing:"cubic-bezier(.2,.8,.2,1)",fill:"forwards"}));
  }
  let removed=false;
  const restore=()=>{if(removed)return;removed=true;originals.forEach((value,node)=>node.style.visibility=value);layer.remove();animations.forEach(a=>a.cancel());};
  void Promise.all(animations.map(a=>a.finished.catch(()=>{}))).then(restore);
  return ()=>{if(removed)return new Map<string,Center>();const positions=new Map(markers.map(({id,node})=>[id,center(node)]));restore();return positions;};
}

export function useQuotaMarkerMorph(root:RefObject<HTMLElement|null>,expanded:boolean,enabled:boolean) {
  const prior=useRef(expanded),positions=useRef(new Map<string,Center>());
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

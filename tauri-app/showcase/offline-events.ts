// Offline replacement for native event transport only. No view or CSS changes.
export async function listen<T>(event:string, handler:(event:{payload:T})=>void){
  const receive=(message:MessageEvent)=>{
    if(message.origin===location.origin&&message.source===window.parent&&message.data?.type==='showcase-product-event'&&message.data.event===event)
      handler({payload:message.data.payload});
  };
  window.addEventListener('message',receive);
  return ()=>window.removeEventListener('message',receive);
}
export async function emitTo(target:string,event:string,payload?:unknown){
  window.parent.postMessage({type:'showcase-product-event',target,event,payload},location.origin);
}
export async function emit(event:string,payload?:unknown){return emitTo('*',event,payload);}
export const TauriEvent={WINDOW_RESIZED:'tauri://resize',WINDOW_MOVED:'tauri://move',WINDOW_CLOSE_REQUESTED:'tauri://close-requested',WINDOW_FOCUS:'tauri://focus',WINDOW_BLUR:'tauri://blur'};

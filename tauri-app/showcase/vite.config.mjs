import {defineConfig} from 'vite';
import react from '@vitejs/plugin-react';
import {fileURLToPath} from 'node:url';
import {readFileSync} from 'node:fs';
const here = name => fileURLToPath(new URL(name, import.meta.url));
const sourceSurfaces = {
  name:'showcase-source-surfaces',
  // Expose the complete existing detail view for the offline host. Its JSX,
  // styles and behaviour remain exactly as written in the production module.
  transform(code,id){
    if(id.endsWith('/src/quota-sidebar/QuotaSidebarApp.tsx'))
      return {code:code+'\nexport { DetailSurface as ShowcaseDetailSurface };\n',map:null};
  },
  resolveId(id){if(id==='virtual:showcase-geometry')return '\0'+id;},
  load(id){
    if(id!=='\0virtual:showcase-geometry')return;
    const geometry=readFileSync(here('../src-tauri/src/platform/quota_sidebar.rs'),'utf8');
    const metrics=readFileSync(here('../src-tauri/src/platform/quota_sidebar/canvas_metrics.rs'),'utf8');
    const rest=geometry.match(/\(SidebarMode::Rest, true\) => \(([\d.]+), ([\d.]+)\)/);
    const height=metrics.match(/SIDEBAR_CANVAS_HEIGHT: f64 = ([\d.]+)/);
    const detail=geometry.match(/let detail_width = ([\d.]+)_f64/);
    const detailHeight=geometry.match(/let detail_height = ([\d.]+)_f64/);
    const gap=geometry.match(/let gap = ([\d.]+)_f64/);
    const width=geometry.match(/\(_, true\) => \(([\d.]+), SIDEBAR_CANVAS_HEIGHT\)/);
    if(!rest||!height||!detail||!detailHeight||!gap||!width)throw new Error('Production sidebar geometry changed; review the showcase host');
    return 'export default '+JSON.stringify({restWidth:+rest[1],restHeight:+rest[2],width:+width[1],height:+height[1],detailWidth:+detail[1],detailHeight:+detailHeight[1],gap:+gap[1]})+';';
  }
};
export default defineConfig({root:here('.'),base:'./',plugins:[sourceSurfaces,react()],build:{outDir:'../../docs/showcase/demo',emptyOutDir:true,rollupOptions:{input:{index:here('index.html'),surface:here('surface.html')}}},resolve:{dedupe:['react','react-dom'],alias:{'@tauri-apps/api/event':here('offline-events.ts'),'/floating-paging-touch.png':here('../public/floating-paging-touch.png')}}});

import {defineConfig} from 'vite';
import react from '@vitejs/plugin-react';
import {fileURLToPath} from 'node:url';
export default defineConfig({root:fileURLToPath(new URL('.',import.meta.url)),base:'./',plugins:[react()],build:{outDir:'../../docs/showcase/demo',emptyOutDir:true},resolve:{dedupe:['react','react-dom'],alias:{'/floating-paging-touch.png':fileURLToPath(new URL('../public/floating-paging-touch.png',import.meta.url))}}});

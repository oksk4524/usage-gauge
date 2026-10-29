'use strict';
const fs=require('node:fs'),path=require('node:path');
const ASSETS=path.resolve(__dirname,'../assets');
const FILES={codex:'codex.png',codexdark:'codex-dark.png',claude:'claude.png',grok:'grok.png',grokdark:'grok-dark.png',gemini:'gemini.png',antigravity:'antigravity.png',aside:'aside.png'};
function load(){return Object.fromEntries(Object.entries(FILES).map(([key,file])=>[key,'data:image/png;base64,'+fs.readFileSync(path.join(ASSETS,file)).toString('base64')]));}
module.exports={load,FILES};

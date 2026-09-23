// Swarm Assembly dashboard — bench -> work-zone assembly + shared-sandbox box.
const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');
const feed = document.getElementById('feed');
const phaseEl = document.getElementById('phase');
const controls = document.getElementById('controls');
const reportEl = document.getElementById('report');
const reportBody = document.getElementById('reportbody');

const COLORS = { idle:'#8b97a8', recruited:'#ffcf33', assembling:'#2fb8ff',
                 working:'#2fb8ff', done:'#76B900' };

let supervisor = null;      // {id,name,emoji}
let bench = [];             // [{id,name,emoji,skills}]
let nodes = {};             // id -> {benchX,benchY, x,y, tx,ty, state, pulse, inTeam}
let team = [];              // current recruited team ids
let sandboxBox = null;      // {team:[ids], up:bool}
let telemetry = {};         // {1:{gpu,mem_pct,...}, 2:{...}} live per-Spark stats
let agentFilter = null;     // when set, log shows only this agent's messages
let dpr = window.devicePixelRatio || 1, frame = 0;

function resize() {
  const r = canvas.getBoundingClientRect();
  canvas.width = r.width * dpr; canvas.height = r.height * dpr;
  ctx.setTransform(dpr,0,0,dpr,0,0);
  layout(r.width, r.height);
}
window.addEventListener('resize', resize);

// Click an agent node to filter the log to just its messages (see what it's
// doing/thinking). Click empty space or the same node again to clear.
canvas.addEventListener('click', e=>{
  const r = canvas.getBoundingClientRect();
  const mx = e.clientX - r.left, my = e.clientY - r.top;
  let hit = null;
  const all = supervisor ? [supervisor, ...bench] : bench;
  for(const a of all){
    const n = nodes[a.id]; if(!n) continue;
    const R = n.sup ? 40 : 30;
    if((mx-n.x)**2 + (my-n.y)**2 <= (R+6)**2){ hit = a.id; break; }
  }
  agentFilter = (hit && hit !== agentFilter) ? hit : null;
  applyFilter();
});

// Pointer cursor when hovering an agent node (hints they're clickable).
canvas.addEventListener('mousemove', e=>{
  const r = canvas.getBoundingClientRect();
  const mx = e.clientX - r.left, my = e.clientY - r.top;
  const all = supervisor ? [supervisor, ...bench] : bench;
  let over = false;
  for(const a of all){ const n=nodes[a.id]; if(!n) continue;
    const R=n.sup?40:30; if((mx-n.x)**2+(my-n.y)**2<=(R+6)**2){ over=true; break; } }
  canvas.style.cursor = over ? 'pointer' : 'default';
});

function applyFilter(){
  for(const div of feed.children)
    div.style.display = (!agentFilter || div.dataset.agent===agentFilter) ? '' : 'none';
  // header hint
  let hint = document.getElementById('filterhint');
  if(agentFilter){
    if(!hint){ hint=document.createElement('div'); hint.id='filterhint'; feed.parentNode.insertBefore(hint, feed); }
    const name=(agentFilter==='supervisor'?supervisor:bench.find(a=>a.id===agentFilter))?.name||agentFilter;
    hint.innerHTML=`<span style="color:${agentColor(agentFilter)}">\u25c9 ${name}</span> — click node again or empty space to show all`;
    hint.style.cssText='padding:6px 14px;font-size:11px;border-bottom:1px solid var(--edge);background:rgba(255,255,255,0.03)';
  } else if(hint){ hint.remove(); }
  feed.scrollTop=feed.scrollHeight;
}

// Two Spark zones (left=Spark1, right=Spark2). Supervisor top-center spanning
// both. Each specialist benches in its HOME node's zone.
function layout(w, h) {
  const prev = nodes; nodes = {};
  midX = w/2;
  if (supervisor) {
    const p = prev[supervisor.id] || {};
    nodes[supervisor.id] = { x:p.x??w/2, y:p.y??h*0.12, tx:w/2, ty:h*0.12,
      benchX:w/2, benchY:h*0.12, state:p.state||'idle', pulse:0, sup:true };
  }
  // group bench agents by node
  const byNode = {1:[], 2:[]};
  bench.forEach(a => byNode[a.node===2?2:1].push(a));
  const benchY = h*0.80;
  for (const nd of [1,2]) {
    const list = byNode[nd], n = list.length;
    const x0 = nd===1 ? w*0.04 : w*0.54, spanW = w*0.42;
    list.forEach((a,i) => {
      const bx = x0 + spanW*(i+0.5)/Math.max(n,1), by = benchY;
      const p = prev[a.id] || {};
      nodes[a.id] = { benchX:bx, benchY:by, x:p.x??bx, y:p.y??by, tx:p.tx??bx, ty:p.ty??by,
        node:nd, state:p.state||'idle', pulse:Math.random()*6, inTeam:p.inTeam||false };
    });
  }
  // one work zone per node (same y on both = aligned; lowered so the box top
  // clears the telemetry panel above)
  workZones = {
    1:{ x:w*0.25, y:h*0.58, w:Math.min(w*0.44,380), h:h*0.30 },
    2:{ x:w*0.75, y:h*0.58, w:Math.min(w*0.44,380), h:h*0.30 },
  };
}
let workZones = {1:{},2:{}}, midX = 0;

// Assign recruited agents to slots inside their node's work zone.
function positionTeam() {
  const byNode = {1:[], 2:[]};
  team.forEach(id => { const a=bench.find(b=>b.id===id); if(a) byNode[a.node===2?2:1].push(id); });
  for (const nd of [1,2]) {
    const ids = byNode[nd], z = workZones[nd], n = ids.length;
    ids.forEach((id,i) => {
      const node = nodes[id]; if(!node) return;
      const cols = Math.min(n,2), row=Math.floor(i/cols), rows=Math.ceil(n/cols);
      const col=i%cols, ncol=Math.min(n-row*cols,cols);
      node.tx = z.x + (col-(ncol-1)/2)*150;   // wider still: generous separation
      node.ty = z.y - (rows-1)*54 + row*108;   // taller rows
      node.inTeam = true;
    });
  }
}
function returnTeamToBench() {
  team.forEach(id => { const nn = nodes[id]; if (nn){ nn.tx=nn.benchX; nn.ty=nn.benchY; nn.inTeam=false; } });
}

function rgba(hex,a){ const n=parseInt(hex.slice(1),16); return `rgba(${(n>>16)&255},${(n>>8)&255},${n&255},${a})`; }

function drawBackground(w,h){
  ctx.fillStyle='#080b11'; ctx.fillRect(0,0,w,h);
  ctx.strokeStyle='rgba(255,255,255,0.03)'; ctx.lineWidth=1;
  for(let x=0;x<w;x+=42){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,h);ctx.stroke();}
  for(let y=0;y<h;y+=42){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(w,y);ctx.stroke();}
  // divider between the two Spark zones
  ctx.strokeStyle=rgba('#2fb8ff',0.18); ctx.lineWidth=2; ctx.setLineDash([6,8]);
  ctx.beginPath(); ctx.moveTo(midX, h*0.24); ctx.lineTo(midX, h); ctx.stroke(); ctx.setLineDash([]);
  // zone labels
  ctx.font='600 12px Segoe UI'; ctx.textAlign='center';
  ctx.fillStyle=rgba('#76B900',0.75); ctx.fillText('◢ SPARK 1  ·  192.168.1.124', w*0.25, h*0.28);
  ctx.fillStyle=rgba('#c186ff',0.75); ctx.fillText('SPARK 2  ·  192.168.1.188 ◣', w*0.75, h*0.28);
  ctx.fillStyle='#ffffff'; ctx.font='700 13px Segoe UI';
  ctx.fillText('BENCH — idle specialists', w*0.25, h*0.94);
  ctx.fillText('BENCH — idle specialists', w*0.75, h*0.94);
}

// Live per-Spark telemetry panel under each zone label.
function drawTelemetry(w,h){
  for(const nd of [1,2]){
    const t = telemetry[nd]; if(!t) continue;
    const cx = nd===1 ? w*0.25 : w*0.75, y0 = h*0.30;
    const col = nd===1 ? '#76B900' : '#c186ff';
    if(!t.ok){
      ctx.fillStyle=rgba('#8b97a8',0.5); ctx.font='10px SF Mono,Consolas,monospace';
      ctx.textAlign='center'; ctx.fillText('telemetry offline', cx, y0+6); continue;
    }
    // GPU util bar
    const bw=150, bh=8, bx=cx-bw/2;
    ctx.font='10px SF Mono,Consolas,monospace'; ctx.textAlign='center';
    ctx.fillStyle=rgba('#e6edf3',0.85);
    ctx.fillText(`GPU ${t.gpu}%   MEM ${t.mem_used_gb}/${t.mem_total_gb}GB   ${t.temp}°C   ${t.power}W`, cx, y0);
    // gpu bar
    ctx.fillStyle=rgba('#ffffff',0.10); ctx.fillRect(bx, y0+8, bw, bh);
    ctx.fillStyle=col; ctx.fillRect(bx, y0+8, bw*Math.min(t.gpu,100)/100, bh);
    // mem bar
    ctx.fillStyle=rgba('#ffffff',0.10); ctx.fillRect(bx, y0+20, bw, bh);
    ctx.fillStyle=rgba(col,0.55); ctx.fillRect(bx, y0+20, bw*Math.min(t.mem_pct,100)/100, bh);
  }
}

function drawSandboxBox(){
  if(!sandboxBox || !sandboxBox.up) return;
  // draw a containment box in each node-zone that has recruited agents
  const nodesUsed = new Set();
  team.forEach(id=>{ const a=bench.find(b=>b.id===id); if(a) nodesUsed.add(a.node===2?2:1); });
  for(const nd of nodesUsed){
    const z=workZones[nd], pad=48;
    const x=z.x - z.w/2 - pad*0.3, y=z.y - z.h/2 - pad*0.6, w=z.w + pad*0.6, h=z.h + pad*1.0;
    const col=nd===1?COLORS.assembling:'#c186ff', r=16;
    ctx.save();
    const path=()=>{ctx.beginPath();ctx.moveTo(x+r,y);ctx.arcTo(x+w,y,x+w,y+h,r);ctx.arcTo(x+w,y+h,x,y+h,r);ctx.arcTo(x,y+h,x,y,r);ctx.arcTo(x,y,x+w,y,r);ctx.closePath();};
    path(); ctx.fillStyle=rgba(col,0.07); ctx.fill();
    path(); ctx.strokeStyle=col; ctx.lineWidth=3; ctx.stroke();
    path(); ctx.setLineDash([10,6]); ctx.lineDashOffset=-(frame%32);
    ctx.strokeStyle='#fff'; ctx.globalAlpha=0.4; ctx.lineWidth=1.5; ctx.stroke();
    ctx.globalAlpha=1; ctx.setLineDash([]);
    ctx.restore();
  }
}

function drawNode(a){
  const node=nodes[a.id]; if(!node) return;
  // ease toward target position
  node.x += (node.tx - node.x)*0.12; node.y += (node.ty - node.y)*0.12;
  node.pulse += 0.12;
  const R = node.sup ? 40 : 30;
  const col = COLORS[node.state] || COLORS.idle;
  const busy = node.state==='working' || node.state==='assembling';
  const p=(Math.sin(node.pulse)+1)/2;
  if(busy){
    for(let k=0;k<2;k++){ const ph=(node.pulse*14+k*22)%44; const rr=R+6+ph;
      ctx.beginPath();ctx.arc(node.x,node.y,rr,0,Math.PI*2);
      ctx.strokeStyle=rgba(col,Math.max(0,0.4*(1-ph/44)));ctx.lineWidth=2;ctx.stroke(); }
  }
  ctx.save(); ctx.shadowColor=col; ctx.shadowBlur=busy?24:(node.state==='done'?16:6);
  ctx.beginPath();ctx.arc(node.x,node.y,R,0,Math.PI*2);
  const g=ctx.createRadialGradient(node.x,node.y,R*0.2,node.x,node.y,R);
  g.addColorStop(0,'#151c28');g.addColorStop(1,rgba(col,0.18));
  ctx.fillStyle=g;ctx.fill();ctx.restore();
  ctx.beginPath();ctx.arc(node.x,node.y,R,0,Math.PI*2);
  ctx.lineWidth=busy?4:2.5;ctx.strokeStyle=col;ctx.stroke();
  ctx.font=`${R-6}px sans-serif`;ctx.textAlign='center';ctx.textBaseline='middle';
  ctx.fillStyle='#fff';ctx.fillText(a.emoji,node.x,node.y+1);
  ctx.font=(node.sup?'600 12px':'11px')+' Segoe UI';ctx.fillStyle='#e6edf3';
  ctx.fillText(a.name,node.x,node.y+R+13);
  // model tag (shows the specialist's own model)
  if(a.model && !node.sup){
    const mshort={'nemotron-lightning':'Nemotron-30B','coder':'Qwen-Coder-7B','writer':'Qwen3-4B','analyst':'Nemotron-Nano-4B','architect':'Qwen3-4B','reviewer':'Nemotron-Nano-4B','tester':'Qwen-Coder-7B','researcher':'Nemotron-Nano-4B','designer':'Nemotron-Nano-4B'}[a.model]||a.model;
    ctx.font='9px SF Mono,Consolas,monospace'; ctx.fillStyle=rgba(col,0.85);
    ctx.fillText(mshort,node.x,node.y+R+25);
  }
}

function drawRecruitLinks(){
  if(!supervisor) return;
  const S=nodes[supervisor.id]; if(!S) return;
  team.forEach(id=>{ const n=nodes[id]; if(!n||!n.inTeam) return;
    ctx.strokeStyle=rgba(COLORS.recruited,0.25);ctx.lineWidth=1.5;
    ctx.beginPath();ctx.moveTo(S.x,S.y);ctx.lineTo(n.x,n.y);ctx.stroke(); });
}

function render(){
  frame++;
  const r=canvas.getBoundingClientRect();
  drawBackground(r.width,r.height);
  drawTelemetry(r.width,r.height);
  drawSandboxBox();
  drawRecruitLinks();
  if(supervisor) drawNode(supervisor);
  bench.forEach(drawNode);
  requestAnimationFrame(render);
}

// Color a log entry by its agent's home Spark: Spark1=green, Spark2=purple,
// Supervisor=cyan. Makes the scrolling log show which node each line came from.
function agentColor(id){
  if(id==='supervisor') return '#76e0c2';           // supervisor: teal/cyan
  const a = bench.find(b=>b.id===id);
  if(!a) return '#e6edf3';
  return a.node===2 ? '#c186ff' : '#76B900';         // Spark2 purple / Spark1 green
}

function addMsg(id, text, cls=''){
  const name=(id==='supervisor'?supervisor:bench.find(a=>a.id===id))?.name || id;
  const div=document.createElement('div'); div.className='msg '+cls; div.dataset.agent=id;
  div.innerHTML=`<span class="who" style="color:${agentColor(id)}">[${name}]</span> `+
                text.replace(/&/g,'&amp;').replace(/</g,'&lt;');
  if(agentFilter && id!==agentFilter) div.style.display='none';
  feed.appendChild(div); feed.scrollTop=feed.scrollHeight;
  while(feed.children.length>400) feed.removeChild(feed.firstChild);
}

function connectWS(){
  const proto=location.protocol==='https:'?'wss':'ws';
  const ws=new WebSocket(`${proto}://${location.host}/ws`);
  ws.onmessage=ev=>handleEvent(JSON.parse(ev.data));
  ws.onclose=()=>setTimeout(connectWS,1500);
  setInterval(()=>{if(ws.readyState===1)ws.send('ping');},15000);
}

function handleEvent({event,data}){
  switch(event){
    case 'agent_state': if(nodes[data.agent]) nodes[data.agent].state=data.state; break;
    case 'recruit':
      team=data.team.slice(); positionTeam();
      addMsg('supervisor','🧠 recruited: '+team.join(', ')+(data.reasoning?' — '+data.reasoning:'')); break;
    case 'team_sandbox':
      if(data.state==='up'){ sandboxBox={team:data.team,up:true}; positionTeam(); }
      else { sandboxBox=null; returnTeamToBench(); } break;
    case 'stream': addMsg(data.agent,data.text); break;
    case 'reasoning': addMsg(data.agent,'💭 '+data.text,'reason'); break;
    case 'exec': addMsg(data.agent,`⚙️ ${data.command} → rc=${data.code}`,'exec');
      if(data.stdout) addMsg(data.agent,'  '+data.stdout.split('\n')[0].slice(0,90),'exec'); break;
    case 'phase': phaseEl.textContent=data.phase; break;
    case 'final': reportBody.textContent=data.report; reportEl.style.display='block'; setRunning(false); showCodeActions(); break;
    case 'error': addMsg('supervisor','❌ '+data.message); setRunning(false); break;
  }
}

let running=false;
function setRunning(v){ running=v; controls.querySelectorAll('button').forEach(b=>b.disabled=v); }

// After a run, if the team produced code, offer Download + Re-test in the report.
async function showCodeActions(){
  let info; try { info = await (await fetch('/api/code/info')).json(); } catch(e){ return; }
  document.getElementById('codeactions')?.remove();
  if(!info.has_code) return;
  const bar=document.createElement('div'); bar.id='codeactions';
  bar.style.cssText='margin-top:10px;display:flex;gap:8px;align-items:center;flex-wrap:wrap';
  bar.innerHTML=`<span style="font-size:11px;color:var(--dim)">code by: ${info.agents.join(', ')}</span>`;
  const dl=document.createElement('button'); dl.textContent='⬇ Download code';
  dl.style.cssText='padding:6px 12px;font-size:12px';
  dl.onclick=()=>{ const a=document.createElement('a'); a.href='/api/code'; a.download='swarm_output.py'; a.click(); };
  const test=document.createElement('button'); test.textContent='▶ Re-test in sandbox';
  test.style.cssText='padding:6px 12px;font-size:12px';
  const res=document.createElement('span'); res.style.cssText='font-size:11px;font-family:SF Mono,Consolas,monospace';
  test.onclick=async()=>{ test.disabled=true; res.textContent=' running…';
    try{ const r=await (await fetch('/api/code/run',{method:'POST'})).json();
      res.innerHTML = r.rc===0 ? `<span style="color:var(--nv)">✓ rc=0</span> ${(r.stdout||'').split('\n')[0].slice(0,80)}`
                               : `<span style="color:#ff6b6b">rc=${r.rc}</span> ${(r.stdout||r.error||'').slice(0,80)}`;
    }catch(e){ res.textContent=' error'; } test.disabled=false; };
  bar.append(dl, test, res);
  reportEl.appendChild(bar);
}

async function boot(){
  const b=await (await fetch('/api/bench')).json();
  supervisor=b.supervisor; bench=b.bench;
  resize();
  const tasks=await (await fetch('/api/tasks')).json();
  tasks.forEach(t=>{ const btn=document.createElement('button');
    btn.textContent='▶ '+t.title; btn.title=t.task;
    btn.onclick=async()=>{ if(running)return;
      feed.innerHTML=''; reportEl.style.display='none'; team=[]; sandboxBox=null;
      agentFilter=null; applyFilter();
      Object.values(nodes).forEach(n=>{n.state='idle';n.inTeam=false;n.tx=n.benchX;n.ty=n.benchY;});
      setRunning(true);
      const r=await fetch('/api/run/'+t.id,{method:'POST'});
      if(!r.ok){ addMsg('supervisor','❌ '+(await r.json()).error); setRunning(false); }
    };
    controls.appendChild(btn); });
  const h=await (await fetch('/api/health')).json();
  document.getElementById('llmdot').className='dot '+(h.llm?'ok':'');
  document.getElementById('llmtxt').textContent=h.llm?'Nemotron online':'LLM offline';
  connectWS(); render(); pollTelemetry();
}

async function pollTelemetry(){
  try { telemetry = await (await fetch('/api/telemetry')).json(); } catch(e){}
  setTimeout(pollTelemetry, 1500);
}
boot();

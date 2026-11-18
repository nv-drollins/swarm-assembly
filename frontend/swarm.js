// Swarm Assembly dashboard — bench -> work-zone assembly + shared-sandbox box.
const canvas = document.getElementById('canvas');
const ctx = canvas.getContext('2d');
const feed = document.getElementById('feed');
const phaseEl = document.getElementById('phase');
const controls = document.getElementById('controls');
const reportEl = document.getElementById('report');
const reportBody = document.getElementById('reportbody');
const runStatusEl = document.getElementById('runstatus');

const COLORS = { idle:'#8b97a8', recruited:'#ffcf33', assembling:'#2fb8ff',
                 working:'#2fb8ff', done:'#76B900' };

let supervisor = null;      // {id,name,emoji,model,clustered}
let bench = [];             // [{id,name,emoji,skills,node,model}]
let nodeHosts = {'1':'Spark 1', '2':'Spark 2'};
let nodes = {};             // id -> {benchX,benchY, x,y, tx,ty, state, pulse, inTeam}
let team = [];              // current recruited team ids
let sandboxBox = null;      // {team:[ids], up:bool}
let telemetry = {};         // {1:{gpu,mem_pct,roce_mb_s,...}, 2:{...}} live per-Spark stats
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
  for(const div of feed.children){
    const match = (!agentFilter || div.dataset.agent===agentFilter);
    div.style.display = match ? '' : 'none';
    // When filtering to a specific agent, auto-expand its reasoning blocks.
    if(div.classList.contains('reason') && div.dataset.ManualToggle!=='1'){
      if(agentFilter && div.dataset.agent===agentFilter){
        div.classList.remove('collapsed');
        const t = div.querySelector('.r-toggle'); if(t) t.textContent='[collapse]';
      } else if(!agentFilter){
        div.classList.add('collapsed');
        const t = div.querySelector('.r-toggle'); if(t) t.textContent='[expand]';
      }
    }
  }
  let hint = document.getElementById('filterhint');
  if(agentFilter){
    if(!hint){ hint=document.createElement('div'); hint.id='filterhint'; feed.parentNode.insertBefore(hint, feed); }
    const name=(agentFilter==='supervisor'?supervisor:bench.find(a=>a.id===agentFilter))?.name||agentFilter;
    hint.innerHTML=`<span style="color:${agentColor(agentFilter)}">\u25c9 Filtering: ${name}</span> — click node again or empty canvas to show all`;
    hint.style.cssText='padding:7px 14px;font-size:11.5px;border-bottom:1px solid var(--edge);background:rgba(47,184,255,0.08)';
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
    nodes[supervisor.id] = { x:p.x??w/2, y:p.y??h*0.11, tx:w/2, ty:h*0.11,
      benchX:w/2, benchY:h*0.11, state:p.state||'idle', pulse:0, sup:true };
  }
  // group bench agents by node
  const byNode = {1:[], 2:[]};
  bench.forEach(a => byNode[a.node===2?2:1].push(a));
  const benchY = h*0.83;
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
  // one work zone per node (positioned below the larger telemetry HUD cards)
  workZones = {
    1:{ x:w*0.25, y:h*0.61, w:Math.min(w*0.44,380), h:h*0.26 },
    2:{ x:w*0.75, y:h*0.61, w:Math.min(w*0.44,380), h:h*0.26 },
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
      node.tx = z.x + (col-(ncol-1)/2)*145;
      node.ty = z.y - (rows-1)*48 + row*96;
      node.inTeam = true;
    });
  }
}
function returnTeamToBench() {
  team.forEach(id => { const nn = nodes[id]; if (nn){ nn.tx=nn.benchX; nn.ty=nn.benchY; nn.inTeam=false; } });
}

function rgba(hex,a){ const n=parseInt(hex.slice(1),16); return `rgba(${(n>>16)&255},${(n>>8)&255},${n&255},${a})`; }

function roundRect(x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x+r, y);
  ctx.arcTo(x+w, y, x+w, y+h, r);
  ctx.arcTo(x+w, y+h, x, y+h, r);
  ctx.arcTo(x, y+h, x, y, r);
  ctx.arcTo(x, y, x+w, y, r);
  ctx.closePath();
}

function drawBackground(w,h){
  ctx.fillStyle='#080b11'; ctx.fillRect(0,0,w,h);
  ctx.strokeStyle='rgba(255,255,255,0.028)'; ctx.lineWidth=1;
  for(let x=0;x<w;x+=42){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,h);ctx.stroke();}
  for(let y=0;y<h;y+=42){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(w,y);ctx.stroke();}
  // divider between the two Spark zones
  ctx.strokeStyle=rgba('#2fb8ff',0.18); ctx.lineWidth=2; ctx.setLineDash([6,8]);
  ctx.beginPath(); ctx.moveTo(midX, h*0.23); ctx.lineTo(midX, h); ctx.stroke(); ctx.setLineDash([]);
  // bench labels
  ctx.fillStyle='rgba(230,237,243,0.75)'; ctx.font='700 12.5px Segoe UI'; ctx.textAlign='center';
  ctx.fillText('BENCH — SPARK 1 SPECIALISTS', w*0.25, h*0.95);
  ctx.fillText('BENCH — SPARK 2 SPECIALISTS', w*0.75, h*0.95);
}

// Draw the 200GbE ConnectX-7 RoCEv2 Interconnect Bridge between Spark 1 and Spark 2
function drawRoceBridge(w, h) {
  if (!supervisor?.clustered) return;
  const supNode = nodes[supervisor.id];
  const supBusy = supNode && (supNode.state === 'working' || supNode.state === 'assembling');
  const t1 = telemetry[1] || {}, t2 = telemetry[2] || {};
  const mbps = Math.max(t1.roce_mb_s || 0, t2.roce_mb_s || 0);
  const totalGb = Math.max(t1.roce_total_gb || 0, t2.roce_total_gb || 0);
  const active = supBusy || mbps > 5;

  const y = h * 0.215;
  const x1 = w * 0.25, x2 = w * 0.75;

  ctx.save();
  // Bridge line linking Spark 1 HUD and Spark 2 HUD
  ctx.strokeStyle = active ? rgba('#76e0c2', 0.85) : rgba('#2fb8ff', 0.32);
  ctx.lineWidth = active ? 3 : 2;
  ctx.beginPath();
  ctx.moveTo(x1, y + 22);
  ctx.lineTo(x1, y);
  ctx.lineTo(x2, y);
  ctx.lineTo(x2, y + 22);
  ctx.stroke();

  if (active) {
    ctx.setLineDash([8, 8]);
    ctx.lineDashOffset = -(frame * 1.5) % 16;
    ctx.strokeStyle = '#ffffff';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(x1, y);
    ctx.lineTo(x2, y);
    ctx.stroke();
    ctx.setLineDash([]);
  }

  // Center pill on the bridge showing 200GbE ConnectX-7 status & live RDMA throughput
  const pw = 330, ph = 24, px = midX - pw / 2, py = y - ph / 2;
  roundRect(px, py, pw, ph, 12);
  ctx.fillStyle = active ? '#0e2229' : '#0e1520';
  ctx.fill();
  ctx.strokeStyle = active ? '#76e0c2' : rgba('#2fb8ff', 0.45);
  ctx.lineWidth = 1.5;
  ctx.stroke();

  ctx.font = '600 11px SF Mono,Consolas,monospace';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillStyle = active ? '#76e0c2' : '#9fb0c4';
  const rateTxt = mbps > 0.5
    ? `${mbps.toFixed(0)} MB/s (${(mbps * 0.008).toFixed(1)} Gbps)`
    : `${totalGb.toFixed(1)} GB RDMA total`;
  ctx.fillText(`⚡ 2× 200GbE CX7 RoCEv2 (TP=2) · ${rateTxt}`, midX, y + 0.5);
  ctx.restore();
}

// Large, booth-grade Per-Spark Telemetry HUD Cards
function drawTelemetry(w,h){
  drawRoceBridge(w, h);

  for(const nd of [1,2]){
    const t = telemetry[nd];
    const cx = nd===1 ? w*0.25 : w*0.75;
    const col = nd===1 ? '#76B900' : '#c186ff';
    const cardW = Math.min(w * 0.44, 390);
    const cardH = 114;
    const x0 = cx - cardW / 2;
    const y0 = h * 0.245;

    ctx.save();
    // Card background + border
    roundRect(x0, y0, cardW, cardH, 12);
    ctx.fillStyle = 'rgba(17, 23, 33, 0.92)';
    ctx.fill();
    ctx.strokeStyle = rgba(col, (t && t.gpu > 15) ? 0.85 : 0.40);
    ctx.lineWidth = (t && t.gpu > 15) ? 2.2 : 1.4;
    ctx.stroke();

    // Header row inside card: SPARK N + hostname + temp & power pills
    const pad = 14;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.font = '700 13.5px Segoe UI';
    ctx.fillStyle = col;
    const hostLabel = nodeHosts[String(nd)] || `node${nd}`;
    ctx.fillText(`◢ SPARK ${nd} · ${hostLabel}`, x0 + pad, y0 + 20);

    if(!t || !t.ok){
      ctx.fillStyle = rgba('#8b97a8', 0.65);
      ctx.font = '12px SF Mono,Consolas,monospace';
      ctx.textAlign = 'center';
      ctx.fillText('waiting for telemetry…', cx, y0 + 66);
      ctx.restore();
      continue;
    }

    // Top-right Temp & Power badge
    ctx.textAlign = 'right';
    ctx.font = '600 12px SF Mono,Consolas,monospace';
    ctx.fillStyle = '#e6edf3';
    ctx.fillText(`${Math.round(t.temp)}°C  ·  ${Number(t.power).toFixed(1)}W`, x0 + cardW - pad, y0 + 20);

    const barX = x0 + pad;
    const barW = cardW - pad * 2;
    const barH = 14;

    // 1) GPU Utilization row + bar
    const gpuY = y0 + 40;
    ctx.textAlign = 'left';
    ctx.font = '600 11.5px SF Mono,Consolas,monospace';
    ctx.fillStyle = '#c9d4e0';
    ctx.fillText('GPU COMPUTE', barX, gpuY);
    ctx.textAlign = 'right';
    ctx.fillStyle = t.gpu > 10 ? '#ffffff' : '#9aa6b5';
    const shardTag = supervisor?.clustered ? `  [120B TP=2 Shard ${nd-1}]` : '';
    ctx.fillText(`${Math.round(t.gpu)}%${shardTag}`, barX + barW, gpuY);

    roundRect(barX, gpuY + 9, barW, barH, 5);
    ctx.fillStyle = 'rgba(255,255,255,0.09)';
    ctx.fill();
    const gpuFillW = Math.max(0, barW * Math.min(t.gpu, 100) / 100);
    if (gpuFillW > 0) {
      roundRect(barX, gpuY + 9, Math.max(gpuFillW, 8), barH, 5);
      ctx.fillStyle = col;
      ctx.fill();
    }

    // 2) Unified Memory row + bar
    const memY = y0 + 78;
    ctx.textAlign = 'left';
    ctx.font = '600 11.5px SF Mono,Consolas,monospace';
    ctx.fillStyle = '#c9d4e0';
    ctx.fillText('UNIFIED MEM', barX, memY);
    ctx.textAlign = 'right';
    ctx.fillStyle = '#e6edf3';
    const availTxt = t.mem_avail_gb !== undefined ? ` (${t.mem_avail_gb}GB free)` : '';
    ctx.fillText(`${t.mem_used_gb} / ${t.mem_total_gb} GB · ${t.mem_pct}%${availTxt}`, barX + barW, memY);

    roundRect(barX, memY + 9, barW, barH, 5);
    ctx.fillStyle = 'rgba(255,255,255,0.09)';
    ctx.fill();
    const memFillW = Math.max(0, barW * Math.min(t.mem_pct, 100) / 100);
    if (memFillW > 0) {
      roundRect(barX, memY + 9, Math.max(memFillW, 8), barH, 5);
      ctx.fillStyle = rgba(col, 0.72);
      ctx.fill();
    }

    ctx.restore();
  }
}

function drawSandboxBox(){
  if(!sandboxBox || !sandboxBox.up) return;
  const nodesUsed = new Set();
  team.forEach(id=>{ const a=bench.find(b=>b.id===id); if(a) nodesUsed.add(a.node===2?2:1); });
  for(const nd of nodesUsed){
    const z=workZones[nd], pad=44;
    const x=z.x - z.w/2 - pad*0.3, y=z.y - z.h/2 - pad*0.5, w=z.w + pad*0.6, h=z.h + pad*0.95;
    const col=nd===1?COLORS.assembling:'#c186ff', r=16;
    ctx.save();
    const path=()=>{roundRect(x,y,w,h,r);};
    path(); ctx.fillStyle=rgba(col,0.07); ctx.fill();
    path(); ctx.strokeStyle=col; ctx.lineWidth=2.5; ctx.stroke();
    path(); ctx.setLineDash([10,6]); ctx.lineDashOffset=-(frame%32);
    ctx.strokeStyle='#fff'; ctx.globalAlpha=0.35; ctx.lineWidth=1.3; ctx.stroke();
    ctx.globalAlpha=1; ctx.setLineDash([]);
    ctx.font='600 10.5px SF Mono,Consolas,monospace';
    ctx.fillStyle=rgba(col,0.85); ctx.textAlign='left';
    ctx.fillText('📦 shared sandbox: swarm-team', x+12, y+15);
    ctx.restore();
  }
}

function drawNode(a){
  const node=nodes[a.id]; if(!node) return;
  node.x += (node.tx - node.x)*0.12; node.y += (node.ty - node.y)*0.12;
  node.pulse += 0.08;
  const R = node.sup ? 38 : 28;
  const col = COLORS[node.state] || COLORS.idle;
  const busy = node.state==='working' || node.state==='assembling';
  if(busy){
    for(let k=0;k<2;k++){ const ph=(node.pulse*14+k*22)%44; const rr=R+5+ph;
      ctx.beginPath();ctx.arc(node.x,node.y,rr,0,Math.PI*2);
      ctx.strokeStyle=rgba(col,Math.max(0,0.35*(1-ph/44)));ctx.lineWidth=2;ctx.stroke(); }
  }
  ctx.save(); ctx.shadowColor=col; ctx.shadowBlur=busy?22:(node.state==='done'?14:6);
  ctx.beginPath();ctx.arc(node.x,node.y,R,0,Math.PI*2);
  const g=ctx.createRadialGradient(node.x,node.y,R*0.2,node.x,node.y,R);
  g.addColorStop(0,'#151c28');g.addColorStop(1,rgba(col,0.20));
  ctx.fillStyle=g;ctx.fill();ctx.restore();
  ctx.beginPath();ctx.arc(node.x,node.y,R,0,Math.PI*2);
  ctx.lineWidth=busy?3.5:2.2;ctx.strokeStyle=col;ctx.stroke();
  ctx.font=`${R-6}px sans-serif`;ctx.textAlign='center';ctx.textBaseline='middle';
  ctx.fillStyle='#fff';ctx.fillText(a.emoji,node.x,node.y+1);
  ctx.font=(node.sup?'600 12px':'600 11px')+' Segoe UI';ctx.fillStyle='#e6edf3';
  ctx.fillText(a.name,node.x,node.y+R+12);
  if(a.model){
    const mshort={'nemotron-super':'Nemotron-3-Super-120B · TP=2 (200GbE)','nemotron-lightning':'Nemotron-3.5-Lightning-30B','devstral-24b':'Devstral-Small-2-24B','nemotron-nano-30b':'Nemotron-3-Nano-30B','gemma4-26b':'Gemma-4-26B-A4B'}[a.model]||a.model;
    ctx.font='9.5px SF Mono,Consolas,monospace'; ctx.fillStyle=rgba(col,0.90);
    ctx.fillText(mshort,node.x,node.y+R+24);
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

function escHtml(s){
  return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

// Turn any mention of /tmp/sample.txt or sample.txt into a clickable inspector link.
function linkifySample(html){
  return html.replace(/(\/tmp\/sample\.txt|\bsample\.txt\b)/g,
    '<span class="file-link" onclick="event.stopPropagation();openSampleModal()" title="Click to inspect /tmp/sample.txt and ground-truth stats">📄 $1</span>');
}

async function openSampleModal(retestStdout=null){
  const modal = document.getElementById('sample-modal');
  const body = document.getElementById('sample-modal-body');
  if(!modal || !body) return;
  modal.classList.add('open');
  try {
    const d = await (await fetch('/api/sample')).json();
    const s = d.stats || {};
    const topRows = (s.top_words || []).map(([w, c], i) =>
      `<span style="display:inline-block;min-width:110px;padding:3px 8px;margin:2px;background:rgba(255,255,255,0.04);border:1px solid var(--edge);border-radius:5px;font-family:'SF Mono',Consolas,monospace;font-size:11.5px">#${i+1} <strong style="color:var(--accent)">${escHtml(w)}</strong>: ${c}</span>`
    ).join('');
    const retestBlock = retestStdout !== null
      ? `<div style="margin-top:10px"><div style="color:var(--nv);font-weight:600;font-size:11.5px;text-transform:uppercase;letter-spacing:0.8px">▶ Latest Sandbox Execution Output (stdout)</div><div class="modal-pre" style="border-color:var(--nv)">${escHtml(retestStdout || '(empty stdout)')}</div></div>`
      : '';
    body.innerHTML = `
      <div style="display:flex;align-items:center;justify-content:space-between;gap:8px">
        <span style="color:var(--dim);font-size:11.5px;text-transform:uppercase;letter-spacing:0.8px;font-weight:600">Raw File Content (${escHtml(d.path)})</span>
        <a href="/api/sample.txt" target="_blank" style="color:var(--blue);font-size:11.5px;font-family:'SF Mono',Consolas,monospace">↗ Open raw /api/sample.txt</a>
      </div>
      <div class="modal-pre">${escHtml(d.content)}</div>
      <div style="color:var(--dim);font-size:11.5px;text-transform:uppercase;letter-spacing:0.8px;font-weight:600;margin-bottom:6px">Ground-Truth Reference Statistics (to verify generated code)</div>
      <div style="display:flex;gap:14px;flex-wrap:wrap;margin-bottom:10px;font-family:'SF Mono',Consolas,monospace;font-size:12px">
        <span>Total words: <strong style="color:#fff">${s.total_words}</strong></span>
        <span>Unique words: <strong style="color:#fff">${s.unique_words}</strong></span>
        <span>Avg word length: <strong style="color:#fff">${s.avg_word_length}</strong></span>
      </div>
      <div style="margin-bottom:4px;font-size:11.5px;color:var(--dim)">Expected Word Frequencies (Top 10):</div>
      <div>${topRows}</div>
      ${retestBlock}
    `;
  } catch (e) {
    body.textContent = 'Could not load /api/sample';
  }
}

// Safe lightweight Markdown renderer for the Final Result panel.
function renderMarkdown(md){
  const lines = escHtml(md || '').split('\n');
  let html = '', inList = false;
  const inline = s => linkifySample(
    s.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
     .replace(/`([^`]+)`/g, '<code>$1</code>')
  );

  for(const raw of lines){
    const l = raw.trim();
    if(!l){
      if(inList){ html += '</ul>'; inList = false; }
      continue;
    }
    const bullet = l.match(/^[-*•]\s+(.*)$/) || l.match(/^\d+\.\s+(.*)$/);
    if(bullet){
      if(!inList){ html += '<ul>'; inList = true; }
      html += `<li>${inline(bullet[1])}</li>`;
    } else {
      if(inList){ html += '</ul>'; inList = false; }
      html += `<p>${inline(l)}</p>`;
    }
  }
  if(inList) html += '</ul>';
  return html || `<p>${linkifySample(escHtml(md))}</p>`;
}

function addMsg(id, text, cls=''){
  const name=(id==='supervisor'?supervisor:bench.find(a=>a.id===id))?.name || id;
  const div=document.createElement('div'); div.className='msg '+cls; div.dataset.agent=id;

  if(cls === 'reason'){
    const long = (text || '').length > 180;
    if(long && agentFilter !== id) div.classList.add('collapsed');
    const toggleHtml = long
      ? `<span class="r-toggle">${div.classList.contains('collapsed') ? '[expand]' : '[collapse]'}</span>`
      : '';
    div.innerHTML = `<span class="who" style="color:${agentColor(id)}">[${name}]</span> ${toggleHtml}<div class="r-body">${linkifySample(escHtml(text))}</div>`;
    if(long){
      div.onclick = () => {
        div.dataset.ManualToggle = '1';
        const c = div.classList.toggle('collapsed');
        const t = div.querySelector('.r-toggle');
        if(t) t.textContent = c ? '[expand]' : '[collapse]';
      };
    }
  } else {
    div.innerHTML=`<span class="who" style="color:${agentColor(id)}">[${name}]</span> `+linkifySample(escHtml(text));
  }

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
    case 'phase':
      phaseEl.textContent=data.phase;
      if(runStatusEl) runStatusEl.textContent = data.phase === 'done' ? 'idle' : `phase: ${data.phase}`;
      break;
    case 'final':
      reportBody.innerHTML=renderMarkdown(data.report);
      reportEl.style.display='block';
      setRunning(false);
      showCodeActions();
      break;
    case 'error': addMsg('supervisor','❌ '+data.message); setRunning(false); break;
  }
}

let running=false;
function setRunning(v){
  running=v;
  controls.querySelectorAll('button').forEach(b=>b.disabled=v);
  if(runStatusEl) runStatusEl.textContent = v ? 'running…' : 'idle';
}

// After a run, if the team produced code, offer Download + Re-test + Inspect sample.txt in the report.
async function showCodeActions(){
  let info; try { info = await (await fetch('/api/code/info')).json(); } catch(e){ return; }
  document.getElementById('codeactions')?.remove();
  if(!info.has_code) return;
  let lastRetestStdout = null;
  const bar=document.createElement('div'); bar.id='codeactions';
  bar.style.cssText='margin-top:10px;display:flex;gap:8px;align-items:center;flex-wrap:wrap';
  bar.innerHTML=`<span style="font-size:11px;color:var(--dim)">code by: ${info.agents.join(', ')}</span>`;
  const dl=document.createElement('button'); dl.textContent='⬇ Download code';
  dl.style.cssText='padding:6px 12px;font-size:12px';
  dl.onclick=()=>{ const a=document.createElement('a'); a.href='/api/code'; a.download='swarm_output.py'; a.click(); };
  const sampleBtn=document.createElement('button'); sampleBtn.textContent='📄 Inspect /tmp/sample.txt';
  sampleBtn.style.cssText='padding:6px 12px;font-size:12px';
  sampleBtn.onclick=()=>openSampleModal(lastRetestStdout);
  const test=document.createElement('button'); test.textContent='▶ Re-test in sandbox';
  test.style.cssText='padding:6px 12px;font-size:12px';
  const outBox=document.createElement('pre');
  outBox.style.cssText='width:100%;margin:6px 0 0;padding:8px 10px;background:#080b11;border:1px solid var(--edge);border-radius:6px;font-size:11.5px;font-family:SF Mono,Consolas,monospace;white-space:pre-wrap;word-break:break-word;display:none;max-height:140px;overflow-y:auto';
  outBox.className='scroll-pane';
  const res=document.createElement('span'); res.style.cssText='font-size:11px;font-family:SF Mono,Consolas,monospace';
  test.onclick=async()=>{ test.disabled=true; res.textContent=' running…';
    try{ const r=await (await fetch('/api/code/run',{method:'POST'})).json();
      lastRetestStdout = r.stdout || r.error || '';
      res.innerHTML = r.rc===0
        ? `<span style="color:var(--nv)">✓ rc=0</span> <span class="file-link" id="verify-sample-link">[verify vs sample.txt]</span>`
        : `<span style="color:#ff6b6b">rc=${r.rc}</span>`;
      const vlink = res.querySelector('#verify-sample-link');
      if(vlink) vlink.onclick = () => openSampleModal(lastRetestStdout);
      outBox.textContent = lastRetestStdout || '(no stdout)';
      outBox.style.borderColor = r.rc===0 ? 'rgba(118,185,0,0.45)' : '#ff6b6b';
      outBox.style.display = 'block';
    }catch(e){ res.textContent=' error'; } test.disabled=false; };
  bar.append(dl, sampleBtn, test, res, outBox);
  reportEl.appendChild(bar);
}

async function boot(){
  const b=await (await fetch('/api/bench')).json();
  supervisor=b.supervisor; bench=b.bench; if(b.nodes) nodeHosts=b.nodes;
  const badges=document.querySelectorAll('header .badge');
  if(badges[1] && supervisor?.model){
    badges[1].textContent = supervisor.clustered
      ? 'Nemotron-3-Super-120B (TP=2 · 200GbE CX7) · 2× DGX Spark'
      : 'Nemotron-3.5-Lightning-30B · 2× DGX Spark';
  }
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
  setTimeout(pollTelemetry, 1200);
}
boot();

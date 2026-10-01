// Offline prototype from phase 1 (Node, no dependencies). Input: 8 kHz stereo s16le .raw files
// (ffmpeg -i in.mp3 -ac 2 -ar 8000 -f s16le out.raw). Usage: node nno-prototype.js <dir> <labels.json>
// Reference for the Swift NNODetector in phase 2; not shipped in the app.
// Prototype NNO features + rule. Channel map (stereo session): L = Kiran mic, R = remote (Phone.app output).
const fs=require("fs"),path=require("path"),SR=8000,F=800;
function g(x,o,n,f){const k=2*Math.cos(2*Math.PI*f/SR);let a=0,b=0;for(let i=0;i<n;i++){const s=x[o+i]+k*a-b;b=a;a=s}return (a*a+b*b-k*a*b)/(n*n/4)/2}
function frames(x){const out=[];for(let o=0;o+F<=x.length;o+=F){let e=0;for(let i=0;i<F;i++)e+=x[o+i]*x[o+i];e/=F;
  const t425=g(x,o,F,425), t440=g(x,o,F,440)+g(x,o,F,480), sit=g(x,o,F,950)+g(x,o,F,1400)+g(x,o,F,1800);
  const db=10*Math.log10(e+1e-12);
  out.push({db, tone:e>1e-6&&(t425/e>0.6||t440/e>0.6), sit:e>1e-6&&sit/e>0.6, voice:db>-45&&!(t425/e>0.6||t440/e>0.6||sit/e>0.6)})}return out}
function segs(b){const s=[];let st=-1;for(let i=0;i<=b.length;i++){if(b[i]&&st<0)st=i;if(!b[i]&&st>=0){s.push([st,i]);st=-1}}return s}
// merge gaps < 0.5 s, drop blips < 0.3 s
function speech(b){let s=segs(b),m=[];for(const x of s){if(m.length&&x[0]-m[m.length-1][1]<5)m[m.length-1][1]=x[1];else m.push([...x])}return m.filter(x=>x[1]-x[0]>=3)}
const labels=JSON.parse(fs.readFileSync(process.argv[3]));
const rows=[];
for(const f of fs.readdirSync(process.argv[2]).filter(f=>f.endsWith(".raw")).sort()){
  const buf=fs.readFileSync(path.join(process.argv[2],f)),n=buf.length/4,L=new Float32Array(n),R=new Float32Array(n);
  for(let i=0;i<n;i++){L[i]=buf.readInt16LE(i*4)/32768;R[i]=buf.readInt16LE(i*4+2)/32768}
  let sll=0,srr=0,slr=0;for(let i=0;i<n;i++){sll+=L[i]*L[i];srr+=R[i]*R[i];slr+=L[i]*R[i]}
  const mono=slr/Math.sqrt(sll*srr+1e-12)>0.95;
  const fr=frames(R), fl=frames(L);
  const ringS=fr.filter(x=>x.tone).length/10, sit=fr.filter(x=>x.sit).length>=3;
  // speech only counts after the last tone frame (ringback is not speech)
  let lastTone=-1;fr.forEach((x,i)=>{if(x.tone||x.sit)lastTone=i});
  const rSeg=speech(fr.map((x,i)=>i>lastTone&&x.voice)), lSeg=mono?[]:speech(fl.map((x,i)=>i>lastTone&&x.voice));
  const rS=rSeg.reduce((s,x)=>s+x[1]-x[0],0)/10, lS=lSeg.reduce((s,x)=>s+x[1]-x[0],0)/10;
  // turns: alternations between L and R segments in time order
  const ev=[...rSeg.map(x=>[x[0],"R"]),...lSeg.map(x=>[x[0],"L"])].sort((a,b)=>a[0]-b[0]);
  let turns=0;for(let i=1;i<ev.length;i++)if(ev[i][1]!==ev[i-1][1])turns++;
  const dur=n/SR;
  // rule
  const lSegs=lSeg.length;
  // remote speaks first for a while (greeting), then Kiran talks once: left a voicemail
  const firstL=lSeg.length?lSeg[0][0]:Infinity;
  // all remote speech before Kiran first talks, also before/between ringback (announcements, greeting)
  const rAll=speech(fr.map(x=>x.voice));
  const remoteBefore=rAll.filter(x=>x[1]<=firstL).reduce((s,x)=>s+x[1]-x[0],0)/10;
  let v,why;
  if(sit){v="NNO";why="SIT-toon (nummer bestaat niet)"}
  else if(mono){v=dur>90?"GESPREK":"ONZEKER";why=`mono-opname, ${dur.toFixed(0)}s`}
  else if(lS>=10||lSegs>=4){v="GESPREK";why=`${lS.toFixed(0)}s eigen spraak in ${lSegs} stukken`}
  else if(lS<1.5){v="NNO";why=`${ringS}s kiestoon, ${remoteBefore.toFixed(0)}s spraak andere kant, zelf niets gezegd`}
  else if(lSegs<=2&&remoteBefore>=8){v="NNO";why=`voicemail ingesproken: ${remoteBefore.toFixed(0)}s groet, daarna ${lS.toFixed(0)}s eigen spraak`}
  else {v="ONZEKER";why=`eigen=${lS}s in ${lSegs} stukken, L-segs=${JSON.stringify(lSeg.map(x=>[x[0]/10,x[1]/10]))} lastTone=${lastTone/10} remoteBefore=${remoteBefore}`}
  const name=f.replace(".raw","");
  rows.push({name,dur:dur.toFixed(0),mono,ringS,sit,rS,lS,turns,v,why,label:labels[name]||"?"});
}
console.log("file".padEnd(32),"dur  mono ring  sit   R-sp  L-sp turns verdict  label          reason");
for(const r of rows)console.log(r.name.padEnd(32),String(r.dur).padStart(4),String(r.mono).padEnd(5),String(r.ringS).padStart(4),String(r.sit).padEnd(5),String(r.rS.toFixed(1)).padStart(5),String(r.lS.toFixed(1)).padStart(5),String(r.turns).padStart(4),"",r.v.padEnd(8),r.label.padEnd(14),r.why);
